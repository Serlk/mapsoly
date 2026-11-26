/// GNSS source reading raw NMEA from a unix stream socket (on the Titan 2:
/// `/run/t2-gnss/nmea.sock`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models.dart';
import '../nmea.dart';
import 'sources.dart';

/// Connects when the socket exists, parses lines into fixes and reconnects
/// with exponential backoff (1 s .. [maxBackoff]) after any failure:
/// missing socket, permission denied, service restart or a silent stream
/// (no data for [silenceTimeout]).
///
/// UNVERIFIED against the real service: on 2026-11-26 `t2-gnss` was not
/// running and `/run/t2-gnss` did not exist. Tested against a local unix
/// socket server replaying NMEA.
class NmeaSocketGnssSource implements GnssSource {
  NmeaSocketGnssSource({
    this.path = '/run/t2-gnss/nmea.sock',
    this.maxBackoff = const Duration(seconds: 15),
    this.silenceTimeout = const Duration(seconds: 10),
    NmeaParser? parser,
  }) : _parser = parser ?? NmeaParser();

  final String path;
  final Duration maxBackoff;
  final Duration silenceTimeout;
  final NmeaParser _parser;

  final _controller = StreamController<GnssFix>.broadcast();
  Socket? _socket;
  StreamSubscription<String>? _sub;
  Timer? _retry;
  Timer? _silence;
  bool _running = false;
  Duration _backoff = const Duration(seconds: 1);

  /// Last connection problem, for diagnostics; null while connected.
  String? lastError;

  @override
  Stream<GnssFix> get fixes => _controller.stream;

  @override
  bool get connected => _socket != null;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _backoff = const Duration(seconds: 1);
    unawaited(_connect());
  }

  @override
  Future<void> stop() async {
    _running = false;
    _retry?.cancel();
    _retry = null;
    await _teardown();
  }

  Future<void> _teardown() async {
    _silence?.cancel();
    _silence = null;
    final sub = _sub;
    _sub = null;
    final s = _socket;
    _socket = null;
    await sub?.cancel();
    s?.destroy();
  }

  void _scheduleRetry() {
    if (!_running) return;
    _retry?.cancel();
    _retry = Timer(_backoff > maxBackoff ? maxBackoff : _backoff, _connect);
    final next = _backoff * 2;
    _backoff = next > maxBackoff ? maxBackoff : next;
  }

  void _armSilence() {
    _silence?.cancel();
    _silence = Timer(silenceTimeout, () {
      lastError = 'no data for ${silenceTimeout.inSeconds}s';
      _teardown().whenComplete(_scheduleRetry);
    });
  }

  Future<void> _connect() async {
    if (!_running || _socket != null) return;
    try {
      if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) {
        lastError = 'socket $path does not exist';
        _scheduleRetry();
        return;
      }
      final socket = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
        timeout: const Duration(seconds: 5),
      );
      if (!_running) {
        socket.destroy();
        return;
      }
      _socket = socket;
      lastError = null;
      _armSilence();
      _sub = socket
          .cast<List<int>>()
          .transform(const Latin1Decoder(allowInvalid: true))
          .transform(const LineSplitter())
          .listen(
            (line) {
              _backoff = const Duration(seconds: 1);
              _armSilence();
              final fix = _parser.addLine(line);
              if (fix != null && !_controller.isClosed) _controller.add(fix);
            },
            onError: (Object e) {
              lastError = '$e';
              _teardown().whenComplete(_scheduleRetry);
            },
            onDone: () {
              lastError = 'connection closed';
              _teardown().whenComplete(_scheduleRetry);
            },
            cancelOnError: true,
          );
    } on Object catch (e) {
      lastError = '$e';
      _scheduleRetry();
    }
  }

  /// Stops and releases the stream. The source cannot be restarted afterwards.
  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}
