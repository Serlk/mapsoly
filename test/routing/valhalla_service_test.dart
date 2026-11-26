import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mapsoly/routing/valhalla_service.dart';

void main() {
  group('buildRuntimeConfig', () {
    final packConfig = {
      'mjolnir': {
        'tile_extract': 'tiles.tar',
        'traffic_extract': 'traffic.tar',
        'tile_dir': 'no-tile-dir',
        'admin': '/abs/admin.sqlite',
        'max_cache_size': 1000000000,
      },
      'httpd': {
        'service': {
          'listen': 'tcp://127.0.0.1:8002',
          'loopback': 'ipc:///tmp/loopback',
          'interrupt': 'ipc:///tmp/interrupt',
        },
      },
      'loki': {
        'actions': ['route', 'status'],
        'service': {'proxy': 'ipc:///tmp/loki'},
      },
      'thor': {
        'service': {'proxy': 'ipc:///tmp/thor'},
      },
      'service_limits': {
        'auto': {'max_distance': 5000000.0},
      },
    };

    final config = LocalValhallaBackend.buildRuntimeConfig(
      packConfig,
      dataDirectory: '/packs/moscow/valhalla',
      runtimeDirectory: '/tmp/rt',
      port: 40123,
    );

    test('makes data paths absolute', () {
      final mjolnir = config['mjolnir'] as Map<String, dynamic>;
      expect(mjolnir['tile_extract'], '/packs/moscow/valhalla/tiles.tar');
      expect(mjolnir['traffic_extract'], '/packs/moscow/valhalla/traffic.tar');
      expect(mjolnir['tile_dir'], '/packs/moscow/valhalla/no-tile-dir');
      expect(mjolnir['admin'], '/abs/admin.sqlite');
      expect(mjolnir['max_cache_size'], 1000000000);
    });

    test('binds to loopback on the chosen port with private sockets', () {
      final httpd = (config['httpd'] as Map)['service'] as Map;
      expect(httpd['listen'], 'tcp://127.0.0.1:40123');
      expect(httpd['loopback'], 'ipc:///tmp/rt/loopback');
      expect(httpd['interrupt'], 'ipc:///tmp/rt/interrupt');
      expect(
        ((config['loki'] as Map)['service'] as Map)['proxy'],
        'ipc:///tmp/rt/loki',
      );
      expect(
        ((config['thor'] as Map)['service'] as Map)['proxy'],
        'ipc:///tmp/rt/thor',
      );
      expect(
        ((config['odin'] as Map)['service'] as Map)['proxy'],
        'ipc:///tmp/rt/odin',
      );
    });

    test('keeps everything else and does not touch the input', () {
      expect((config['loki'] as Map)['actions'], ['route', 'status']);
      expect(config['service_limits'], packConfig['service_limits']);
      expect((packConfig['mjolnir'] as Map)['tile_extract'], 'tiles.tar');
      expect(
        ((packConfig['httpd'] as Map)['service'] as Map)['listen'],
        'tcp://127.0.0.1:8002',
      );
    });
  });

  group('findBinary', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('mapsoly-find-'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('honours MAPSOLY_VALHALLA_BIN', () {
      final bin = File('${dir.path}/custom')..writeAsStringSync('');
      expect(
        LocalValhallaBackend.findBinary(
          environment: {'MAPSOLY_VALHALLA_BIN': bin.path, 'PATH': ''},
          executable: '/nowhere/app',
        ),
        bin.path,
      );
      expect(
        LocalValhallaBackend.findBinary(
          environment: {'MAPSOLY_VALHALLA_BIN': '${dir.path}/missing'},
          executable: '/nowhere/app',
        ),
        isNull,
      );
    });

    test('prefers the app bundle over PATH', () {
      final bundle = Directory('${dir.path}/bundle/lib')
        ..createSync(recursive: true);
      final path = Directory('${dir.path}/path')..createSync();
      File('${path.path}/valhalla_service').writeAsStringSync('');
      expect(
        LocalValhallaBackend.findBinary(
          environment: {'PATH': '/does-not-exist:${path.path}'},
          executable: '${dir.path}/bundle/mapsoly',
        ),
        '${path.path}/valhalla_service',
      );
      File('${bundle.path}/mapsoly_valhalla').writeAsStringSync('');
      expect(
        LocalValhallaBackend.findBinary(
          environment: {'PATH': path.path},
          executable: '${dir.path}/bundle/mapsoly',
        ),
        '${bundle.path}/mapsoly_valhalla',
      );
    });

    test('returns null when there is none', () {
      expect(
        LocalValhallaBackend.findBinary(
          environment: {'PATH': dir.path},
          executable: '${dir.path}/app',
        ),
        isNull,
      );
    });
  });

  group('LocalValhallaBackend process lifecycle', () {
    final fake = File(
      'test/routing/fixtures/fake_valhalla_service.py',
    ).absolute.path;
    final hasPython =
        Process.runSync('sh', ['-c', 'command -v python3']).exitCode == 0;
    late Directory pack;

    setUp(() {
      pack = Directory.systemTemp.createTempSync('mapsoly-pack-');
      File('${pack.path}/tiles.tar').writeAsStringSync('');
      File('${pack.path}/valhalla.json').writeAsStringSync(
        jsonEncode({
          'mjolnir': {'tile_extract': 'tiles.tar'},
          'httpd': {
            'service': {'listen': 'tcp://127.0.0.1:8002'},
          },
        }),
      );
    });
    tearDown(() => pack.deleteSync(recursive: true));

    bool alive(int pid) => Directory('/proc/$pid').existsSync();

    test(
      'starts, restarts after a crash and stops on dispose',
      () async {
        final log = <String>[];
        final backend = LocalValhallaBackend(
          dataDirectory: pack,
          binary: fake,
          onLog: log.add,
        );
        addTearDown(backend.dispose);
        final states = <RoutingBackendState>[];
        backend.states.listen(states.add);

        expect(() => backend.baseUrl, throwsStateError);
        await backend.start();
        expect(backend.state, RoutingBackendState.ready);
        expect(backend.baseUrl.host, '127.0.0.1');
        expect((await backend.client.status()).version, 'fake');
        final firstPid = backend.pid!;
        final firstUrl = backend.baseUrl;
        expect(log.join('\n'), contains('fake valhalla listening'));

        // start() while ready is a no-op.
        await backend.start();
        expect(backend.pid, firstPid);

        final ready = backend.states
            .firstWhere((s) => s == RoutingBackendState.ready)
            .timeout(const Duration(seconds: 20));
        await http
            .post(firstUrl.replace(path: '/crash'))
            .then((_) {}, onError: (Object _) {});
        await ready;
        expect(backend.pid, isNot(firstPid));
        expect(
          states,
          containsAllInOrder([
            RoutingBackendState.starting,
            RoutingBackendState.ready,
            RoutingBackendState.restarting,
            RoutingBackendState.ready,
          ]),
        );
        expect(backend.lastError, isNull);
        // The same client keeps working after the restart.
        expect((await backend.client.status()).version, 'fake');

        final secondPid = backend.pid!;
        await backend.dispose();
        expect(backend.state, RoutingBackendState.stopped);
        expect(alive(secondPid), isFalse);
      },
      skip: hasPython ? false : 'python3 not installed',
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'reports a backend that dies during start-up',
      () async {
        File('${pack.path}/tiles.tar').deleteSync();
        final backend = LocalValhallaBackend(dataDirectory: pack, binary: fake);
        addTearDown(backend.dispose);
        await expectLater(
          backend.start(),
          throwsA(isA<RoutingBackendException>()),
        );
        expect(backend.state, RoutingBackendState.failed);
        expect(backend.lastError, contains('no tiles'));
        await backend.dispose();
      },
      skip: hasPython ? false : 'python3 not installed',
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('fails cleanly without a binary or a config', () async {
      final noBinary = LocalValhallaBackend(
        dataDirectory: pack,
        binary: '${pack.path}/does-not-exist',
      );
      await expectLater(
        noBinary.start(),
        throwsA(isA<RoutingBackendException>()),
      );
      expect(noBinary.state, RoutingBackendState.failed);
      await noBinary.dispose();

      File('${pack.path}/valhalla.json').deleteSync();
      final noConfig = LocalValhallaBackend(dataDirectory: pack, binary: fake);
      await expectLater(
        noConfig.start(),
        throwsA(
          isA<RoutingBackendException>().having(
            (e) => e.message,
            'message',
            contains('valhalla.json'),
          ),
        ),
      );
      await noConfig.dispose();
    });
  });

  test('RemoteValhallaBackend fails when nothing listens', () async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final backend = RemoteValhallaBackend(Uri.parse('http://127.0.0.1:$port'));
    await expectLater(backend.start(), throwsA(isA<RoutingBackendException>()));
    expect(backend.state, RoutingBackendState.failed);
    await backend.dispose();
  });
}
