import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'catalog.dart';
import 'tar_reader.dart';

/// A pack present on the device.
class InstalledPack {
  const InstalledPack(this.directory, this.info, this.sizeOnDisk);

  final Directory directory;

  /// Catalog entry it was installed from; null for packs copied by hand.
  final PackInfo? info;
  final int sizeOnDisk;

  String get id => directory.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
  String get name => info?.name ?? id;
}

class PackProgress {
  const PackProgress(this.received, this.total, {this.file});

  final int received, total;

  /// File being downloaded or verified right now.
  final String? file;

  double get fraction => total == 0 ? 0 : received / total;
}

/// The download was stopped by [PackDownload.cancel]; partial files stay on
/// disk and the next attempt resumes from them.
class PackDownloadCancelled implements Exception {
  const PackDownloadCancelled();
}

class PackDownloadException implements Exception {
  const PackDownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Handle of a running download.
class PackDownload {
  PackDownload._(this.pack, this.progress, this.done, this._cancel);

  final PackInfo pack;
  final Stream<PackProgress> progress;

  /// Completes when the pack is installed; fails with
  /// [PackDownloadCancelled] or [PackDownloadException].
  final Future<InstalledPack> done;
  final void Function() _cancel;

  /// Stops the download, keeping what was received for a later resume.
  void cancel() => _cancel();
}

/// Region packs on this device: listing, downloading with resume, deleting.
///
/// Layout: `<root>/<id>/` is an installed pack (`map.pmtiles`, `valhalla/`,
/// `places.sqlite`, `pack.json`); `<root>/.downloads/<id>/` holds files
/// still being fetched. A pack appears under `<root>` only when every file
/// has been verified, so a half-downloaded pack is never used.
class PackStore {
  PackStore(this.root, {http.Client? client})
    : _client = client ?? http.Client();

  final Directory root;
  final http.Client _client;

  static const _manifest = 'pack.json';

  /// Tiles a pack put into the shared routing folder, one path per line.
  static const _routingList = 'routing_tiles.txt';

  /// Routing graph shared by all packs: `valhalla.json`, `build.txt` and
  /// `tiles/`. Dot-prefixed, so it is not listed as a pack.
  Directory get sharedRouting => Directory('${root.path}/.shared/valhalla');

  Directory get _staging => Directory('${root.path}/.downloads');

  Future<PackCatalog> fetchCatalog(Uri url) async {
    final r = await _client
        .get(url, headers: const {'User-Agent': 'mapsoly/0.1'})
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) {
      throw PackDownloadException('Каталог недоступен (HTTP ${r.statusCode})');
    }
    return PackCatalog.parse(utf8.decode(r.bodyBytes), url);
  }

  List<InstalledPack> installed() {
    if (!root.existsSync()) return const [];
    final packs = <InstalledPack>[];
    for (final dir in root.listSync().whereType<Directory>()) {
      final name = dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (name.startsWith('.')) continue;
      PackInfo? info;
      final manifest = File('${dir.path}/$_manifest');
      if (manifest.existsSync()) {
        try {
          info = PackInfo.fromJson(
            jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>,
            Uri.parse('file:///'),
          );
        } on Exception {
          info = null; // unreadable manifest: still list the pack
        }
      }
      var size = 0;
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        size += f.lengthSync();
      }
      packs.add(InstalledPack(dir, info, size));
    }
    packs.sort((a, b) => a.name.compareTo(b.name));
    return packs;
  }

  /// Bytes already on disk for a download of [pack] that was interrupted.
  int partialBytes(PackInfo pack) {
    var bytes = 0;
    for (final f in pack.files) {
      final done = File('${_staging.path}/${pack.id}/${f.path}');
      final part = File('${done.path}.part');
      if (done.existsSync()) {
        bytes += done.lengthSync();
      } else if (part.existsSync()) {
        bytes += part.lengthSync();
      }
    }
    return bytes;
  }

  void delete(String id) {
    final own = _routingTiles(Directory('${root.path}/$id'));
    for (final dir in [
      Directory('${root.path}/$id'),
      Directory('${_staging.path}/$id'),
    ]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
    _dropUnreferencedTiles(own);
  }

  Set<String> _routingTiles(Directory pack) {
    final list = File('${pack.path}/$_routingList');
    return list.existsSync() ? list.readAsLinesSync().toSet() : {};
  }

  /// Removes shared routing tiles from [candidates] that no installed pack
  /// lists any more; the last pack going takes the whole graph with it.
  void _dropUnreferencedTiles(Set<String> candidates) {
    if (candidates.isEmpty) return;
    final packs = root.existsSync()
        ? root.listSync().whereType<Directory>().where(
            (d) => !d.uri.pathSegments
                .lastWhere((s) => s.isNotEmpty)
                .startsWith('.'),
          )
        : const <Directory>[];
    final used = <String>{for (final p in packs) ..._routingTiles(p)};
    if (used.isEmpty) {
      if (sharedRouting.existsSync()) sharedRouting.deleteSync(recursive: true);
      return;
    }
    for (final tile in candidates.difference(used)) {
      final file = File('${sharedRouting.path}/$tile');
      if (file.existsSync()) file.deleteSync();
    }
  }

  /// Unpacks a verified routing tar into the shared folder and returns the
  /// tiles it contained. Only the expected file names are accepted.
  ///
  /// All packs must come from one graph build: tiles of different builds do
  /// not connect at the seams. When [tar] belongs to another build than the
  /// tiles already present, the old graph is dropped first (the packs it
  /// came from keep their maps and get their routing back when updated).
  ///
  /// Runs in a separate isolate: a district's graph is close to a gigabyte,
  /// and the map has to keep moving meanwhile.
  Future<Set<String>> _installRouting(File tar) {
    final tarPath = tar.path, rootPath = root.path;
    return Isolate.run(() => _unpackRouting(tarPath, rootPath));
  }

  static Set<String> _unpackRouting(String tarPath, String rootPath) {
    final tar = File(tarPath);
    final root = Directory(rootPath);
    final tilePath = RegExp(r'^tiles/[0-9]+(/[0-9]+)+\.gph$');
    String clean(String name) =>
        name.startsWith('./') ? name.substring(2) : name;

    String? build;
    readTar(tar, (e) {
      if (clean(e.name) == 'build.txt' && e.size < 256) {
        final tmp = File('${tar.path}.build');
        e.extractTo(tmp);
        build = tmp.readAsStringSync().trim();
        tmp.deleteSync();
      }
    });
    if (build == null || build!.isEmpty) {
      throw const PackDownloadException(
        'В пакете нет сведений о сборке графа маршрутов',
      );
    }
    final shared = Directory('${root.path}/.shared/valhalla');
    final marker = File('${shared.path}/build.txt');
    if (marker.existsSync() && marker.readAsStringSync().trim() != build) {
      shared.deleteSync(recursive: true);
      for (final pack in root.listSync().whereType<Directory>()) {
        final list = File('${pack.path}/$_routingList');
        if (list.existsSync()) list.deleteSync();
      }
    }
    shared.createSync(recursive: true);

    final tiles = <String>{};
    readTar(tar, (e) {
      final name = clean(e.name);
      if (name == 'valhalla.json') {
        e.extractTo(File('${shared.path}/valhalla.json'));
      } else if (tilePath.hasMatch(name)) {
        e.extractTo(File('${shared.path}/$name'));
        tiles.add(name);
      }
    });
    if (tiles.isEmpty || !File('${shared.path}/valhalla.json').existsSync()) {
      throw const PackDownloadException('Пакет маршрутов пуст или повреждён');
    }
    marker.writeAsStringSync('$build\n');
    return tiles;
  }

  /// Downloads [pack] (resuming partial files), verifies every file and
  /// installs it, replacing an older version of the same pack.
  PackDownload download(PackInfo pack) {
    final progress = StreamController<PackProgress>.broadcast();
    var cancelled = false;
    http.StreamedResponse? active;
    final done = () async {
      try {
        return await _download(
          pack,
          progress,
          () => cancelled,
          (r) => active = r,
        );
      } finally {
        await progress.close();
      }
    }();
    return PackDownload._(pack, progress.stream, done, () {
      cancelled = true;
      // Closing the client side makes the body stream end right away.
      active?.stream.listen((_) {}).cancel();
    });
  }

  Future<InstalledPack> _download(
    PackInfo pack,
    StreamController<PackProgress> progress,
    bool Function() cancelled,
    void Function(http.StreamedResponse?) track,
  ) async {
    final staging = Directory('${_staging.path}/${pack.id}');
    final total = pack.size;
    var before = 0; // bytes of the files finished so far

    for (final file in pack.files) {
      final target = File('${staging.path}/${file.path}');
      final part = File('${target.path}.part');
      target.parent.createSync(recursive: true);

      // Already fetched and verified in an earlier attempt (a routing tar
      // may even be unpacked and gone).
      final unpacked =
          file.routing && File('${staging.path}/$_routingList').existsSync();
      if (!target.existsSync() && !unpacked) {
        var have = part.existsSync() ? part.lengthSync() : 0;
        if (have > file.size) {
          part.deleteSync();
          have = 0;
        }
        if (have < file.size) {
          have = await _fetch(
            file,
            part,
            have,
            (received) {
              progress.add(
                PackProgress(before + received, total, file: file.path),
              );
            },
            cancelled,
            track,
          );
        }
        if (cancelled()) throw const PackDownloadCancelled();
        if (have != file.size) {
          throw PackDownloadException(
            'Файл ${file.path}: получено $have из ${file.size} байт',
          );
        }
        progress.add(PackProgress(before + have, total, file: file.path));
        final digest = (await sha256.bind(part.openRead()).first).toString();
        if (digest != file.sha256) {
          // A corrupted file cannot be resumed: start it over next time.
          part.deleteSync();
          throw PackDownloadException(
            'Файл ${file.path} повреждён при загрузке',
          );
        }
        part.renameSync(target.path);
      }
      before += file.size;
      progress.add(PackProgress(before, total, file: file.path));
    }

    // Routing tiles go to the shared graph; the tar itself is not kept.
    final live = Directory('${root.path}/${pack.id}');
    final previousTiles = _routingTiles(live);
    final tiles = <String>{};
    for (final file in pack.files.where((f) => f.routing)) {
      final tar = File('${staging.path}/${file.path}');
      // Absent when an earlier attempt already unpacked it.
      if (tar.existsSync()) {
        tiles.addAll(await _installRouting(tar));
        tar.deleteSync();
        File(
          '${staging.path}/$_routingList',
        ).writeAsStringSync('${tiles.join('\n')}\n', mode: FileMode.append);
      }
    }
    File(
      '${staging.path}/$_manifest',
    ).writeAsStringSync(jsonEncode(pack.toJson()));
    // Swap in the complete pack; the old version goes only now.
    if (live.existsSync()) live.deleteSync(recursive: true);
    root.createSync(recursive: true);
    staging.renameSync(live.path);
    // Tiles the previous version had and the new one does not.
    _dropUnreferencedTiles(previousTiles);
    return installed().firstWhere((p) => p.id == pack.id);
  }

  /// Appends to [part] from byte [have]; returns the new length.
  Future<int> _fetch(
    PackFile file,
    File part,
    int have,
    void Function(int received) onProgress,
    bool Function() cancelled,
    void Function(http.StreamedResponse?) track,
  ) async {
    final request = http.Request('GET', file.url)
      ..headers['User-Agent'] = 'mapsoly/0.1';
    if (have > 0) request.headers['Range'] = 'bytes=$have-';
    final http.StreamedResponse response;
    try {
      response = await _client
          .send(request)
          .timeout(const Duration(seconds: 30));
    } on Exception catch (e) {
      throw PackDownloadException('Нет связи с сервером карт: $e');
    }
    track(response);
    // 200 to a ranged request means the server ignored the range: restart.
    if (response.statusCode == 200 && have > 0) {
      part.deleteSync();
      have = 0;
    } else if (response.statusCode != 200 && response.statusCode != 206) {
      await response.stream.listen((_) {}).cancel();
      throw PackDownloadException(
        'Файл ${file.path} недоступен (HTTP ${response.statusCode})',
      );
    }
    final sink = part.openWrite(mode: FileMode.append);
    var lastReport = DateTime.now();
    try {
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        if (cancelled()) break;
        sink.add(chunk);
        have += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastReport) > const Duration(milliseconds: 250)) {
          lastReport = now;
          onProgress(have);
        }
      }
    } on Exception catch (e) {
      if (!cancelled()) {
        throw PackDownloadException('Загрузка прервалась: $e');
      }
    } finally {
      await sink.flush();
      await sink.close();
      track(null);
    }
    return have;
  }

  void close() => _client.close();
}
