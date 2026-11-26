import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'catalog.dart';

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
    for (final dir in [
      Directory('${root.path}/$id'),
      Directory('${_staging.path}/$id'),
    ]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
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

      // Already fetched and verified in an earlier attempt.
      if (!target.existsSync()) {
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

    File(
      '${staging.path}/$_manifest',
    ).writeAsStringSync(jsonEncode(pack.toJson()));
    // Swap in the complete pack; the old version goes only now.
    final live = Directory('${root.path}/${pack.id}');
    if (live.existsSync()) live.deleteSync(recursive: true);
    root.createSync(recursive: true);
    staging.renameSync(live.path);
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
