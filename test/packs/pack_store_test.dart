import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/packs/catalog.dart';
import 'package:mapsoly/packs/pack_downloads.dart';
import 'package:mapsoly/packs/pack_store.dart';

/// A tiny file server with switchable faults.
class TestServer {
  late HttpServer _server;
  final files = <String, Uint8List>{};
  final requests = <String>[];

  /// Honour `Range` requests (real servers do; some proxies do not).
  bool ranges = true;

  /// Send only this many bytes of a body, then drop the connection.
  int? cutAfter;

  /// Delay between 16 KiB chunks, to leave time for a cancel.
  Duration chunkDelay = Duration.zero;

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}/');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((req) async {
      final name = req.uri.path.substring(1);
      final range = req.headers.value('range');
      requests.add('$name ${range ?? '-'}');
      final data = files[name];
      if (data == null) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      var from = 0;
      if (range != null && ranges) {
        from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
        req.response.statusCode = 206;
      }
      final body = data.sublist(from);
      final limit = cutAfter;
      if (limit != null && limit < body.length) {
        // Write a raw response that promises the whole body, send part of
        // it, then drop the connection.
        final socket = await req.response.detachSocket(writeHeaders: false);
        socket.add(
          ascii.encode(
            'HTTP/1.1 ${from > 0 && ranges ? 206 : 200} OK\r\n'
            'Content-Length: ${body.length}\r\n\r\n',
          ),
        );
        socket.add(body.sublist(0, limit));
        await socket.flush();
        socket.destroy();
        return;
      }
      req.response.contentLength = body.length;
      try {
        for (var i = 0; i < body.length; i += 16384) {
          final end = i + 16384 > body.length ? body.length : i + 16384;
          req.response.add(body.sublist(i, end));
          await req.response.flush();
          if (chunkDelay > Duration.zero) {
            await Future<void>.delayed(chunkDelay);
          }
        }
        await req.response.close();
      } on Exception {
        // The client went away (cancelled download).
      }
    });
  }

  Future<void> stop() => _server.close(force: true);
}

Uint8List bytes(int n, int seed) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 31 + seed) & 0xFF));

void main() {
  late TestServer server;
  late Directory root;
  late PackStore store;

  setUp(() async {
    server = TestServer();
    await server.start();
    root = Directory.systemTemp.createTempSync('mapsoly-packs-');
    store = PackStore(Directory('${root.path}/packs'));
  });

  tearDown(() async {
    store.close();
    await server.stop();
    root.deleteSync(recursive: true);
  });

  PackInfo publish(
    String id,
    Map<String, Uint8List> content, {
    String version = '1',
  }) {
    final files = <Map<String, dynamic>>[];
    content.forEach((path, data) {
      final name = '$id-$version-${path.replaceAll('/', '_')}';
      server.files[name] = data;
      files.add({
        'path': path,
        'url': name,
        'size': data.length,
        'sha256': sha256.convert(data).toString(),
      });
    });
    final catalog = {
      'format': 1,
      'packs': [
        {
          'id': id,
          'name': 'Тестовый регион',
          'version': version,
          'bounds': [35.1, 54.25, 40.25, 56.97],
          'files': files,
        },
      ],
    };
    server.files['catalog.json'] = Uint8List.fromList(
      utf8.encode(jsonEncode(catalog)),
    );
    return PackCatalog.parse(jsonEncode(catalog), server.base).packs.single;
  }

  final content = {
    'map.pmtiles': bytes(200000, 1),
    'valhalla/tiles.tar': bytes(300000, 2),
    'places.sqlite': bytes(50000, 3),
  };

  test('catalog is fetched and relative URLs are resolved', () async {
    publish('moscow', content);
    final catalog = await store.fetchCatalog(
      server.base.resolve('catalog.json'),
    );
    final pack = catalog.packs.single;
    expect(pack.name, 'Тестовый регион');
    expect(pack.size, 550000);
    expect(pack.files.first.url.toString(), startsWith(server.base.toString()));
  });

  test('downloads, verifies and installs a pack', () async {
    final pack = publish('moscow', content);
    final download = store.download(pack);
    final seen = <PackProgress>[];
    download.progress.listen(seen.add);
    final installed = await download.done;
    expect(installed.id, 'moscow');
    expect(installed.info!.version, '1');
    for (final entry in content.entries) {
      expect(
        File('${installed.directory.path}/${entry.key}').readAsBytesSync(),
        entry.value,
      );
    }
    expect(seen.last.fraction, 1);
    expect(store.installed().single.name, 'Тестовый регион');
    expect(
      Directory('${root.path}/packs/.downloads/moscow').existsSync(),
      isFalse,
    );
  });

  test('downloads run without a screen and report when installed', () async {
    final pack = publish('moscow', content);
    // Its own store: the manager closes the one it is given.
    var installed = 0;
    final downloads = PackDownloads(
      PackStore(Directory('${root.path}/packs')),
      onInstalled: () => installed++,
    );
    addTearDown(downloads.dispose);
    var notified = 0;
    downloads.addListener(() => notified++);
    expect(downloads.active, isFalse);
    downloads.start(pack);
    downloads.start(pack); // a second tap changes nothing
    expect(downloads.isRunning('moscow'), isTrue);
    expect(downloads.running.single.id, 'moscow');
    expect(downloads.progressOf('moscow')!.received, 0);
    for (var i = 0; i < 200 && downloads.active; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(downloads.active, isFalse);
    expect(downloads.errorOf('moscow'), isNull);
    expect(installed, 1);
    expect(notified, greaterThan(2));
    expect(store.installed().single.id, 'moscow');
  });

  test('a dropped connection is resumed from where it stopped', () async {
    final pack = publish('moscow', content);
    server.cutAfter = 100000;
    await expectLater(
      store.download(pack).done,
      throwsA(isA<PackDownloadException>()),
    );
    expect(store.installed(), isEmpty);
    final partial = store.partialBytes(pack);
    expect(partial, inInclusiveRange(1, 199999));

    server.cutAfter = null;
    server.requests.clear();
    final installed = await store.download(pack).done;
    expect(server.requests.first, 'moscow-1-map.pmtiles bytes=$partial-');
    expect(
      File('${installed.directory.path}/map.pmtiles').readAsBytesSync(),
      content['map.pmtiles'],
    );
  });

  test('cancel keeps the partial file and a later run finishes it', () async {
    final pack = publish('moscow', content);
    server.chunkDelay = const Duration(milliseconds: 5);
    final download = store.download(pack);
    await download.progress.firstWhere((p) => p.received > 30000);
    download.cancel();
    await expectLater(download.done, throwsA(isA<PackDownloadCancelled>()));
    expect(store.installed(), isEmpty);
    expect(store.partialBytes(pack), greaterThan(0));

    server.chunkDelay = Duration.zero;
    await store.download(pack).done;
    expect(store.installed(), hasLength(1));
  });

  test('a server that ignores ranges restarts the file', () async {
    final pack = publish('moscow', content);
    server.cutAfter = 100000;
    await expectLater(store.download(pack).done, throwsA(anything));
    server
      ..cutAfter = null
      ..ranges = false;
    final installed = await store.download(pack).done;
    expect(
      File('${installed.directory.path}/map.pmtiles').readAsBytesSync(),
      content['map.pmtiles'],
    );
  });

  test('a corrupted file is rejected and nothing is installed', () async {
    final pack = publish('moscow', content);
    server.files['moscow-1-places.sqlite'] = bytes(50000, 99);
    await expectLater(
      store.download(pack).done,
      throwsA(
        isA<PackDownloadException>().having(
          (e) => e.message,
          'message',
          contains('повреждён'),
        ),
      ),
    );
    expect(store.installed(), isEmpty);
    // The good files are kept, only the bad one is fetched again.
    server.files['moscow-1-places.sqlite'] = content['places.sqlite']!;
    server.requests.clear();
    await store.download(pack).done;
    expect(server.requests, ['moscow-1-places.sqlite -']);
  });

  test('an update replaces the old pack only when complete', () async {
    await store.download(publish('moscow', content)).done;
    final v2 = publish('moscow', {
      'map.pmtiles': bytes(120000, 7),
    }, version: '2');
    server.cutAfter = 50000;
    await expectLater(store.download(v2).done, throwsA(anything));
    // The interrupted update left the old pack usable.
    expect(store.installed().single.info!.version, '1');
    server.cutAfter = null;
    await store.download(v2).done;
    final now = store.installed().single;
    expect(now.info!.version, '2');
    expect(File('${now.directory.path}/places.sqlite').existsSync(), isFalse);
  });

  test('delete removes the pack and its partial download', () async {
    final pack = publish('moscow', content);
    await store.download(pack).done;
    store.delete('moscow');
    expect(store.installed(), isEmpty);
  });

  test('a pack copied by hand is listed without a manifest', () {
    Directory('${root.path}/packs/manual').createSync(recursive: true);
    File(
      '${root.path}/packs/manual/map.pmtiles',
    ).writeAsBytesSync(bytes(10, 1));
    final pack = store.installed().single;
    expect(pack.id, 'manual');
    expect(pack.info, isNull);
    expect(pack.sizeOnDisk, 10);
  });

  test('catalog entries cannot escape the pack folder', () {
    String catalog(String path, [String id = 'moscow']) => jsonEncode({
      'format': 1,
      'packs': [
        {
          'id': id,
          'version': '1',
          'files': [
            {'path': path, 'url': 'x', 'size': 1, 'sha256': 'ab'},
          ],
        },
      ],
    });
    for (final bad in ['../evil', '/etc/passwd', 'a/../../b', '']) {
      expect(
        () => PackCatalog.parse(catalog(bad), server.base),
        throwsFormatException,
        reason: bad,
      );
    }
    expect(
      () => PackCatalog.parse(catalog('map.pmtiles', '../x'), server.base),
      throwsFormatException,
    );
    expect(
      () => PackCatalog.parse('{"format":2,"packs":[]}', server.base),
      throwsFormatException,
    );
  });

  group('shared routing graph', () {
    /// Builds an uncompressed ustar archive from [files].
    Uint8List tar(Map<String, List<int>> files) {
      final out = BytesBuilder();
      files.forEach((name, data) {
        final header = Uint8List(512);
        header.setAll(0, ascii.encode(name));
        header.setAll(100, ascii.encode('0000644\x00'));
        header.setAll(
          124,
          ascii.encode('${data.length.toRadixString(8).padLeft(11, '0')}\x00'),
        );
        header[156] = 0x30;
        header.setAll(257, ascii.encode('ustar\x00'));
        out
          ..add(header)
          ..add(data)
          ..add(Uint8List((512 - data.length % 512) % 512));
      });
      out.add(Uint8List(1024));
      return out.toBytes();
    }

    PackInfo routingPack(
      String id,
      Map<String, List<int>> tiles, {
      String build = 'b1',
      String version = '1',
      Map<String, List<int>> extra = const {},
    }) {
      final archive = tar({
        'build.txt': ascii.encode(build),
        'valhalla.json': ascii.encode('{"mjolnir":{"tile_dir":"tiles"}}'),
        ...tiles,
        ...extra,
      });
      final map = bytes(1000, id.hashCode & 0xFF);
      server.files['$id-$version-map'] = map;
      server.files['$id-$version-routing'] = archive;
      final catalog = jsonEncode({
        'format': 1,
        'packs': [
          {
            'id': id,
            'version': version,
            'files': [
              {
                'path': 'map.pmtiles',
                'url': '$id-$version-map',
                'size': map.length,
                'sha256': sha256.convert(map).toString(),
              },
              {
                'path': 'routing.tar',
                'url': '$id-$version-routing',
                'size': archive.length,
                'sha256': sha256.convert(archive).toString(),
                'routing': true,
              },
            ],
          },
        ],
      });
      return PackCatalog.parse(catalog, server.base).packs.single;
    }

    File tile(String name) => File('${root.path}/packs/.shared/valhalla/$name');

    test('tiles of two packs land in one graph; the tar is not kept', () async {
      final a = await store
          .download(
            routingPack('central', {
              'tiles/2/000/001.gph': [1, 1],
              'tiles/1/000/007.gph': [7],
            }),
          )
          .done;
      await store
          .download(
            routingPack('volga', {
              'tiles/2/000/002.gph': [2, 2],
              'tiles/1/000/007.gph': [7],
            }),
          )
          .done;
      expect(tile('tiles/2/000/001.gph').readAsBytesSync(), [1, 1]);
      expect(tile('tiles/2/000/002.gph').existsSync(), isTrue);
      expect(tile('valhalla.json').existsSync(), isTrue);
      expect(tile('build.txt').readAsStringSync().trim(), 'b1');
      expect(File('${a.directory.path}/routing.tar').existsSync(), isFalse);
      // The shared folder is not listed as a pack.
      expect(store.installed().map((p) => p.id), ['central', 'volga']);
    });

    test('deleting a pack keeps tiles another pack still needs', () async {
      await store
          .download(
            routingPack('central', {
              'tiles/2/000/001.gph': [1],
              'tiles/1/000/007.gph': [7],
            }),
          )
          .done;
      await store
          .download(
            routingPack('volga', {
              'tiles/2/000/002.gph': [2],
              'tiles/1/000/007.gph': [7],
            }),
          )
          .done;
      store.delete('central');
      expect(tile('tiles/2/000/001.gph').existsSync(), isFalse);
      expect(tile('tiles/1/000/007.gph').existsSync(), isTrue);
      expect(tile('tiles/2/000/002.gph').existsSync(), isTrue);
      store.delete('volga');
      expect(
        Directory('${root.path}/packs/.shared/valhalla').existsSync(),
        isFalse,
      );
    });

    test('a pack from another graph build replaces the old graph', () async {
      await store
          .download(
            routingPack('central', {
              'tiles/2/000/001.gph': [1],
            }),
          )
          .done;
      await store
          .download(
            routingPack('volga', {
              'tiles/2/000/002.gph': [2],
            }, build: 'b2'),
          )
          .done;
      expect(tile('build.txt').readAsStringSync().trim(), 'b2');
      // Tiles of the old build would not connect to the new ones.
      expect(tile('tiles/2/000/001.gph').existsSync(), isFalse);
      expect(tile('tiles/2/000/002.gph').existsSync(), isTrue);
      // The older pack keeps its map.
      expect(store.installed().map((p) => p.id), ['central', 'volga']);
    });

    test('unexpected names in the tar are not written anywhere', () async {
      await store
          .download(
            routingPack(
              'central',
              {
                'tiles/2/000/001.gph': [1],
              },
              extra: {
                '../../escape.gph': [9],
                '/tmp/mapsoly-abs.gph': [9],
                'tiles/../../up.gph': [9],
                'tiles/2/evil.sh': [9],
                'notes.txt': [9],
              },
            ),
          )
          .done;
      final written = Directory('${root.path}/packs/.shared')
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path.split('.shared/valhalla/').last)
          .toSet();
      expect(written, {'build.txt', 'valhalla.json', 'tiles/2/000/001.gph'});
      expect(File('${root.path}/escape.gph').existsSync(), isFalse);
      expect(File('/tmp/mapsoly-abs.gph').existsSync(), isFalse);
    });

    test('an update drops tiles the new version no longer has', () async {
      await store
          .download(
            routingPack('central', {
              'tiles/2/000/001.gph': [1],
              'tiles/2/000/009.gph': [9],
            }),
          )
          .done;
      await store
          .download(
            routingPack('central', {
              'tiles/2/000/001.gph': [5],
            }, version: '2'),
          )
          .done;
      expect(tile('tiles/2/000/001.gph').readAsBytesSync(), [5]);
      expect(tile('tiles/2/000/009.gph').existsSync(), isFalse);
    });
  });
}
