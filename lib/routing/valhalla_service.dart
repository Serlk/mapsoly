import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'valhalla_client.dart';

/// Where a routing backend is in its life.
enum RoutingBackendState {
  /// Not started yet, or stopped.
  stopped,

  /// Process spawned (or first health check running), not answering yet.
  starting,

  /// Answering `/status`.
  ready,

  /// The local process died and is being restarted.
  restarting,

  /// Could not be started, or crashed too often. See
  /// [RoutingBackend.lastError]. Call [RoutingBackend.start] to retry.
  failed,
}

/// Something that serves the Valhalla HTTP API.
///
/// The UI talks to [client] only, so it does not matter whether the backend
/// is a subprocess on the phone ([LocalValhallaBackend]) or an already
/// running server such as the Docker container on the PC
/// ([RemoteValhallaBackend]).
abstract class RoutingBackend {
  /// Picks a backend: [url] (or the `MAPSOLY_VALHALLA_URL` environment
  /// variable) selects an external server, otherwise a local subprocess is
  /// run on the tiles in [packDirectory]`/valhalla`.
  factory RoutingBackend.forPack(
    Directory packDirectory, {
    Uri? url,
    void Function(String line)? onLog,
  }) {
    final env = Platform.environment['MAPSOLY_VALHALLA_URL'];
    final external =
        url ?? (env == null || env.isEmpty ? null : Uri.parse(env));
    if (external != null) return RemoteValhallaBackend(external);
    return LocalValhallaBackend(
      dataDirectory: Directory('${packDirectory.path}/valhalla'),
      onLog: onLog,
    );
  }

  /// Base URL of the HTTP API. Throws [StateError] before the backend has
  /// been started for the first time.
  Uri get baseUrl;

  /// A client bound to this backend. Valid for the backend's whole life,
  /// including across restarts.
  ValhallaClient get client;

  RoutingBackendState get state;

  /// Emits every change of [state] (broadcast).
  Stream<RoutingBackendState> get states;

  /// Human-readable reason of the last failure, for logs.
  String? get lastError;

  /// Brings the backend up and completes once it answers. Safe to call
  /// again; throws [RoutingBackendException] if it cannot be started.
  Future<void> start();

  /// Stops the backend and frees everything. The object is dead afterwards.
  Future<void> dispose();
}

/// The backend could not be brought up.
class RoutingBackendException implements Exception {
  RoutingBackendException(this.message);

  final String message;

  @override
  String toString() => 'RoutingBackendException: $message';
}

/// A Valhalla server somebody else runs: Docker on the PC, a LAN box, etc.
class RemoteValhallaBackend implements RoutingBackend {
  RemoteValhallaBackend(this.baseUrl) : client = ValhallaClient(baseUrl);

  @override
  final Uri baseUrl;

  @override
  final ValhallaClient client;

  final _states = StreamController<RoutingBackendState>.broadcast();
  RoutingBackendState _state = RoutingBackendState.stopped;

  @override
  RoutingBackendState get state => _state;

  @override
  Stream<RoutingBackendState> get states => _states.stream;

  @override
  String? lastError;

  void _set(RoutingBackendState s) {
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  @override
  Future<void> start() async {
    _set(RoutingBackendState.starting);
    if (await client.isHealthy(timeout: const Duration(seconds: 5))) {
      lastError = null;
      _set(RoutingBackendState.ready);
      return;
    }
    lastError = 'No Valhalla at $baseUrl';
    _set(RoutingBackendState.failed);
    throw RoutingBackendException(lastError!);
  }

  @override
  Future<void> dispose() async {
    _set(RoutingBackendState.stopped);
    client.close();
    await _states.close();
  }
}

/// Runs a Valhalla HTTP server as a child process bound to 127.0.0.1.
///
/// The binary is either upstream `valhalla_service` or `mapsoly_valhalla`
/// (lib/routing/native/valhalla_shim.cc, used on Alpine where the package
/// has no service binary, and on Android); both take
/// `<config.json> <threads>`.
class LocalValhallaBackend implements RoutingBackend {
  /// [dataDirectory] is a pack's `valhalla/` directory holding `tiles.tar`
  /// and `valhalla.json` as written by tool/build_routing.sh.
  ///
  /// [binary] overrides the search done by [findBinary].
  /// [port] fixes the port; by default a free one is picked.
  /// [runtimeDirectory] is where the rewritten config and Valhalla's IPC
  /// sockets go; by default a fresh directory under the system temp dir
  /// (keep it short: Unix socket paths are limited to ~100 characters).
  LocalValhallaBackend({
    required this.dataDirectory,
    this.binary,
    this.port,
    this.threads = 2,
    Directory? runtimeDirectory,
    this.startTimeout = const Duration(seconds: 30),
    this.maxRestarts = 5,
    this.onLog,
  }) : _runtimeDirectory = runtimeDirectory,
       _ownsRuntimeDirectory = runtimeDirectory == null {
    client = ValhallaClient.dynamic(() => baseUrl);
  }

  /// Names tried by [findBinary], in order.
  static const binaryNames = ['mapsoly_valhalla', 'valhalla_service'];

  final Directory dataDirectory;
  final String? binary;
  final int? port;

  /// Worker threads of the server. Each concurrent request needs one.
  final int threads;
  final Duration startTimeout;

  /// How many crashes in a row are tolerated before giving up. The counter
  /// resets once the service has stayed up for a minute.
  final int maxRestarts;

  /// Receives the server's stdout/stderr lines and lifecycle messages.
  final void Function(String line)? onLog;

  @override
  late final ValhallaClient client;

  Directory? _runtimeDirectory;
  final bool _ownsRuntimeDirectory;
  final _states = StreamController<RoutingBackendState>.broadcast();
  RoutingBackendState _state = RoutingBackendState.stopped;
  Process? _process;
  Uri? _baseUrl;
  Future<void>? _starting;
  Timer? _restartTimer;
  int _crashes = 0;
  DateTime? _readySince;
  bool _disposed = false;
  String? _lastOutputError;

  @override
  String? lastError;

  @override
  RoutingBackendState get state => _state;

  @override
  Stream<RoutingBackendState> get states => _states.stream;

  @override
  Uri get baseUrl =>
      _baseUrl ?? (throw StateError('LocalValhallaBackend not started'));

  /// Pid of the running server, for diagnostics.
  int? get pid => _process?.pid;

  /// File name of the server on Android. It is an executable, but only files
  /// named `lib*.so` get installed into the app's native library directory,
  /// the one place an app may exec from (tool/build_valhalla_android.sh).
  static const androidBinaryName = 'libmapsoly_valhalla.so';

  /// Finds the server binary:
  ///  1. `MAPSOLY_VALHALLA_BIN` environment variable,
  ///  2. on Android, [androidBinaryName] in the app's native library
  ///     directory (see [nativeLibraryDirFromMaps]),
  ///  3. next to the app executable (`<bundle>/`, `<bundle>/lib/`,
  ///     `<bundle>/data/`), which is where a deploy script should put it,
  ///  4. `$PATH`.
  /// Returns null if there is none.
  ///
  /// [android] and [procMaps] default to the real platform and
  /// `/proc/self/maps`; they are parameters for tests.
  static String? findBinary({
    Map<String, String>? environment,
    String? executable,
    bool? android,
    String? procMaps,
  }) {
    final env = environment ?? Platform.environment;
    final override = env['MAPSOLY_VALHALLA_BIN'];
    if (override != null && override.isNotEmpty) {
      return File(override).existsSync() ? override : null;
    }
    if (android ?? Platform.isAndroid) {
      final libDir = nativeLibraryDirFromMaps(procMaps ?? _readProcMaps());
      if (libDir != null) {
        final file = File('$libDir/$androidBinaryName');
        if (file.existsSync()) return file.path;
      }
    }
    final exeDir = File(executable ?? Platform.resolvedExecutable).parent.path;
    final dirs = [
      exeDir,
      '$exeDir/lib',
      '$exeDir/data',
      ...(env['PATH'] ?? '').split(':').where((d) => d.isNotEmpty),
    ];
    for (final dir in dirs) {
      for (final name in binaryNames) {
        final file = File('$dir/$name');
        if (file.existsSync()) return file.path;
      }
    }
    return null;
  }

  /// The app's native library directory (`ApplicationInfo.nativeLibraryDir`)
  /// worked out from the contents of `/proc/self/maps`: it is the directory
  /// the Flutter engine or the AOT snapshot was loaded from. Asking Android
  /// itself would need a platform channel, and this class has no engine
  /// dependency otherwise.
  ///
  /// Returns null when the libraries were mapped straight from the APK
  /// (`extractNativeLibs=false`); nothing can be executed in that case.
  static String? nativeLibraryDirFromMaps(String maps) {
    for (final line in const LineSplitter().convert(maps)) {
      // address perms offset dev inode pathname
      final slash = line.indexOf('/');
      if (slash < 0) continue;
      final path = line.substring(slash).trimRight();
      for (final lib in const ['/libapp.so', '/libflutter.so']) {
        if (path.endsWith(lib)) {
          return path.substring(0, path.length - lib.length);
        }
      }
    }
    return null;
  }

  static String _readProcMaps() {
    try {
      return File('/proc/self/maps').readAsStringSync();
    } on FileSystemException {
      return '';
    }
  }

  /// Rewrites a pack's `valhalla.json` for this run: absolute data paths,
  /// the chosen loopback port, private IPC socket names. Everything else
  /// (costing defaults, limits) is kept as built.
  static Map<String, dynamic> buildRuntimeConfig(
    Map<String, dynamic> packConfig, {
    required String dataDirectory,
    required String runtimeDirectory,
    required int port,
  }) {
    final config = jsonDecode(jsonEncode(packConfig)) as Map<String, dynamic>;
    Map<String, dynamic> section(Map<String, dynamic> parent, String key) =>
        (parent[key] ??= <String, dynamic>{}) as Map<String, dynamic>;

    final mjolnir = section(config, 'mjolnir');
    // Relative paths in the pack config are relative to the pack directory.
    for (final key in const [
      'tile_extract',
      'traffic_extract',
      'tile_dir',
      'admin',
      'timezone',
      'landmarks',
      'transit_dir',
      'transit_feeds_dir',
    ]) {
      final value = mjolnir[key];
      if (value is String && value.isNotEmpty && !value.startsWith('/')) {
        mjolnir[key] = '$dataDirectory/$value';
      }
    }
    final logging = section(mjolnir, 'logging');
    logging['type'] = 'std_out';
    logging['color'] = false;

    // valhalla_service wires its workers together with Unix sockets; the
    // defaults live in /tmp and would clash between two instances.
    final httpd = section(section(config, 'httpd'), 'service');
    httpd['listen'] = 'tcp://127.0.0.1:$port';
    httpd['loopback'] = 'ipc://$runtimeDirectory/loopback';
    httpd['interrupt'] = 'ipc://$runtimeDirectory/interrupt';
    // Upstream waits this long for open requests on SIGTERM (default 28 s).
    httpd['drain_seconds'] = 1;
    httpd['shutdown_seconds'] = 1;
    for (final worker in const ['loki', 'thor', 'odin', 'meili']) {
      final service = section(section(config, worker), 'service');
      service['proxy'] = 'ipc://$runtimeDirectory/$worker';
    }
    return config;
  }

  @override
  Future<void> start() {
    if (_disposed) throw StateError('LocalValhallaBackend is disposed');
    if (_state == RoutingBackendState.ready) return Future.value();
    _restartTimer?.cancel();
    return _starting ??= _spawn().whenComplete(() => _starting = null);
  }

  Future<void> _spawn() async {
    _set(
      _state == RoutingBackendState.restarting
          ? RoutingBackendState.restarting
          : RoutingBackendState.starting,
    );
    try {
      final exe = binary ?? findBinary();
      if (exe == null) {
        throw RoutingBackendException(
          'No Valhalla binary (${binaryNames.join(' / ')}) found',
        );
      }
      final packConfigFile = File('${dataDirectory.path}/valhalla.json');
      if (!packConfigFile.existsSync()) {
        throw RoutingBackendException('Missing ${packConfigFile.path}');
      }
      final packConfig =
          jsonDecode(await packConfigFile.readAsString())
              as Map<String, dynamic>;

      final runtime = _runtimeDirectory ??= await Directory.systemTemp
          .createTemp('mapsoly-valhalla-');
      await runtime.create(recursive: true);
      // Stale sockets of a crashed run would make zmq fail to bind.
      for (final entity in runtime.listSync()) {
        if (entity is! Directory) entity.deleteSync();
      }

      final chosenPort = port ?? await _freePort(preferred: _baseUrl?.port);
      final configFile = File('${runtime.path}/valhalla.json');
      await configFile.writeAsString(
        const JsonEncoder.withIndent(' ').convert(
          buildRuntimeConfig(
            packConfig,
            dataDirectory: dataDirectory.absolute.path,
            runtimeDirectory: runtime.absolute.path,
            port: chosenPort,
          ),
        ),
      );
      _baseUrl = Uri.parse('http://127.0.0.1:$chosenPort');

      final process = await Process.start(
        exe,
        [configFile.path, '$threads'],
        workingDirectory: dataDirectory.path,
        // Honoured by mapsoly_valhalla: quit when our end of stdin closes,
        // i.e. even if the app is killed without running dispose().
        environment: const {'MAPSOLY_EXIT_ON_STDIN_EOF': '1'},
      );
      _process = process;
      _log('started $exe (pid ${process.pid}) on $_baseUrl');
      _lastOutputError = null;
      final drained = Future.wait([
        _pipe(process.stdout, isStderr: false),
        _pipe(process.stderr, isStderr: true),
      ]);
      var exited = false;
      unawaited(
        process.exitCode.then((code) async {
          // Let the last output lines arrive: they say why it died.
          await drained.timeout(
            const Duration(seconds: 1),
            onTimeout: () => const [],
          );
          exited = true;
          _onExit(process, code);
        }),
      );

      final deadline = DateTime.now().add(startTimeout);
      while (true) {
        if (_disposed) return;
        if (exited) {
          throw RoutingBackendException(
            lastError ?? 'Valhalla exited during start-up',
          );
        }
        if (await client.isHealthy(timeout: const Duration(seconds: 1))) break;
        if (DateTime.now().isAfter(deadline)) {
          throw RoutingBackendException(
            'Valhalla did not answer within ${startTimeout.inSeconds} s',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      lastError = null;
      _readySince = DateTime.now();
      _set(RoutingBackendState.ready);
    } on Object catch (e) {
      lastError = e is RoutingBackendException ? e.message : '$e';
      _log('start failed: $lastError');
      await _terminate();
      if (!_disposed) _set(RoutingBackendState.failed);
      if (e is RoutingBackendException) rethrow;
      throw RoutingBackendException(lastError!);
    }
  }

  void _onExit(Process process, int code) {
    if (!identical(process, _process)) return; // stopped or replaced by us
    _process = null;
    if (_disposed) return;
    final wasReady = _state == RoutingBackendState.ready;
    final reason = _lastOutputError;
    lastError =
        'Valhalla exited with code $code${reason == null ? '' : ': $reason'}';
    _log(lastError!);
    if (!wasReady) return; // _spawn() reports start-up failures itself

    final since = _readySince;
    if (since != null &&
        DateTime.now().difference(since) > const Duration(minutes: 1)) {
      _crashes = 0;
    }
    _crashes++;
    if (_crashes > maxRestarts) {
      _set(RoutingBackendState.failed);
      return;
    }
    _scheduleRestart();
  }

  void _scheduleRestart() {
    _set(RoutingBackendState.restarting);
    // 0.5 s, 1 s, 2 s, ... between attempts.
    final delay = Duration(milliseconds: 250 * (1 << _crashes.clamp(1, 6)));
    _restartTimer = Timer(delay, () {
      if (_disposed) return;
      start().catchError((Object _) {
        // The respawn itself failed (e.g. the port got taken): keep trying
        // until the crash budget is used up.
        if (_disposed) return;
        _crashes++;
        if (_crashes <= maxRestarts) _scheduleRestart();
      });
    });
  }

  Future<void> _pipe(Stream<List<int>> stream, {required bool isStderr}) {
    return stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          if (line.trim().isEmpty) return;
          if (isStderr || line.contains('[ERROR]')) _lastOutputError = line;
          _log(line);
        }, onError: (Object _) {})
        .asFuture<void>();
  }

  void _log(String line) => onLog?.call(line);

  void _set(RoutingBackendState s) {
    if (_state == s) return;
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  static Future<int> _freePort({int? preferred}) async {
    // Reuse the previous port after a crash when it is still free.
    for (final candidate in [?preferred, 0]) {
      try {
        final socket = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          candidate,
        );
        final port = socket.port;
        await socket.close();
        return port;
      } on SocketException {
        continue;
      }
    }
    throw RoutingBackendException('No free TCP port on 127.0.0.1');
  }

  /// SIGTERM, then SIGKILL if the process is still there after 2 s.
  Future<void> _terminate() async {
    final process = _process;
    _process = null;
    if (process == null) return;
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return process.exitCode;
      },
    );
  }

  /// Stops the server but keeps the object usable; [start] brings it back.
  Future<void> stop() async {
    _restartTimer?.cancel();
    await _terminate();
    if (!_disposed) _set(RoutingBackendState.stopped);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    _state = RoutingBackendState.stopped;
    if (!_states.isClosed) _states.add(_state);
    client.close();
    await _states.close();
    final runtime = _runtimeDirectory;
    if (_ownsRuntimeDirectory && runtime != null && runtime.existsSync()) {
      try {
        runtime.deleteSync(recursive: true);
      } on FileSystemException {
        // Best effort; it is in the temp directory anyway.
      }
    }
  }
}
