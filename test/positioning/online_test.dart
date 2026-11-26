import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mapsoly/positioning/geo.dart';
import 'package:mapsoly/positioning/location_db.dart';
import 'package:mapsoly/positioning/models.dart';
import 'package:mapsoly/positioning/online/apple_wps.dart';
import 'package:mapsoly/positioning/online/beacondb.dart';
import 'package:mapsoly/positioning/online/protobuf_lite.dart';
import 'package:mapsoly/positioning/online/resolver.dart';

final t0 = DateTime.utc(2026, 11, 26, 12);
const lat0 = 59.92, lon0 = 30.65;
final proj = LocalProjection(lat0, lon0);

const cell = CellObservation(
  radio: RadioType.lte,
  mcc: 250,
  mnc: 20,
  area: 8000,
  cellId: 27440068,
  pci: 301,
  signalDbm: -97,
  timingAdvance: 7,
  serving: true,
);

/// A synthetic city: APs on a 50 m grid, 1 km x 1 km around the origin.
/// Answers like the real service: the requested BSSID plus everything
/// within 300 m of the FIRST one (max 400), unknown ones as -180/-180.
class FakeApple {
  FakeApple() {
    var i = 0;
    for (var x = -500; x <= 500; x += 50) {
      for (var y = -500; y <= 500; y += 50) {
        aps[_mac(i++)] = (x.toDouble(), y.toDouble());
      }
    }
  }

  final Map<String, (double, double)> aps = {};
  final List<List<String>> requests = [];
  int failNext = 0;

  static String _mac(int i) =>
      '02:00:00:00:${(i >> 8).toRadixString(16).padLeft(2, '0')}:'
      '${(i & 255).toRadixString(16).padLeft(2, '0')}';

  String macAt(double x, double y) =>
      aps.entries.firstWhere((e) => e.value == (x, y)).key;

  Future<http.Response> handle(http.Request req) async {
    if (failNext > 0) {
      failNext--;
      return http.Response('busy', 503);
    }
    // Decode the request the way the server must: skip the header.
    final body = req.bodyBytes;
    const header = 2 + 7 + 21 + 12 + 8;
    final asked = [
      for (final f in readProto(Uint8List.sublistView(body, header)))
        if (f.number == 2) readProto(f.bytes!).first.string,
    ];
    requests.add(asked);
    final out = ProtoWriter();
    void put(String mac, double? x, double? y) {
      final loc = ProtoWriter();
      if (x == null) {
        loc
          ..writeInt(1, -18000000000)
          ..writeInt(2, -18000000000)
          ..writeInt(3, -1);
      } else {
        loc
          ..writeInt(1, (proj.lat(y!) * 1e8).round())
          ..writeInt(2, (proj.lon(x) * 1e8).round())
          ..writeInt(3, 25);
      }
      // Like Apple: strip leading zeros of each octet.
      final shown = x == null
          ? mac
          : mac
                .split(':')
                .map((o) => int.parse(o, radix: 16).toRadixString(16))
                .join(':');
      out.writeMessage(
        2,
        ProtoWriter()
          ..writeString(1, shown)
          ..writeMessage(2, loc)
          ..writeInt(21, 6),
      );
    }

    final sent = <String>{};
    for (final mac in asked) {
      final p = aps[mac];
      put(mac, p?.$1, p?.$2);
      sent.add(mac);
    }
    final first = aps[asked.first];
    if (first != null) {
      var n = 0;
      for (final e in aps.entries) {
        if (sent.contains(e.key)) continue;
        final dx = e.value.$1 - first.$1, dy = e.value.$2 - first.$2;
        if (dx * dx + dy * dy <= 300 * 300 && n++ < 400) {
          put(e.key, e.value.$1, e.value.$2);
        }
      }
    }
    final payload = out.toBytes();
    final resp = BytesBuilder()
      ..add([0, 1, 0, 0, 0, 1])
      ..add([
        payload.length >> 24,
        (payload.length >> 16) & 255,
        (payload.length >> 8) & 255,
        payload.length & 255,
      ])
      ..add(payload);
    return http.Response.bytes(resp.toBytes(), 200);
  }
}

void main() {
  group('beaconDB', () {
    test('request body follows the MLS geolocate schema', () {
      final body = buildGeolocateRequest(
        wifi: const [
          WifiObservation(
            bssid: 'aa:bb:cc:6b:1f:94',
            frequencyMhz: 5180,
            signalDbm: -35,
            age: Duration(milliseconds: 1500),
            ssid: 'never sent',
          ),
          WifiObservation(bssid: 'aa:bb:cc:95:7d:d6', signalPercent: 52),
          WifiObservation(bssid: 'aa:bb:cc:00:00:01', ssid: 'x_nomap'),
        ],
        cells: const [
          cell,
          CellObservation(radio: RadioType.lte, pci: 26, arfcn: 3048),
        ],
      );
      expect(body['considerIp'], false);
      expect(body['fallbacks'], {'ipf': false, 'lacf': true});
      expect(body['wifiAccessPoints'], [
        {
          'macAddress': 'aa:bb:cc:6b:1f:94',
          'signalStrength': -35,
          'frequency': 5180,
          'age': 1500,
        },
        {'macAddress': 'aa:bb:cc:95:7d:d6', 'signalStrength': -69, 'age': 0},
      ]);
      expect(body['cellTowers'], [
        {
          'radioType': 'lte',
          'mobileCountryCode': 250,
          'mobileNetworkCode': 20,
          'locationAreaCode': 8000,
          'cellId': 27440068,
          'psc': 301,
          'signalStrength': -97,
          'timingAdvance': 7,
        },
      ]);
      expect(jsonEncode(body), isNot(contains('never sent')));
    });

    test('parses a fix, a 404 and errors; sends a neutral User-Agent', () async {
      late http.Request seen;
      // Real answer for the phone's two serving cells (2026-11-26), with the
      // coordinates rounded.
      final ok = BeaconDb(
        client: MockClient((r) async {
          seen = r;
          return http.Response(
            '{"location":{"lat":59.92,"lng":30.65},"accuracy":968}',
            200,
          );
        }),
      );
      final r = await ok.geolocate(cells: [cell]);
      expect(r.fix!.lat, 59.92);
      expect(r.fix!.lon, 30.65);
      expect(r.fix!.accuracyM, 968);
      expect(seen.headers['User-Agent'], 'mapsoly/0.1');
      expect(seen.url.toString(), 'https://api.beacondb.net/v1/geolocate');
      expect(seen.headers['Content-Type'], startsWith('application/json'));

      // Real 404 body.
      final nf = await BeaconDb(
        client: MockClient(
          (_) async => http.Response(
            '{"error":{"code":404,"errors":[{"domain":"geolocation",'
            '"message":"No location could be estimated based on the data '
            'provided","reason":"notFound"}],"message":"Not found"}}',
            404,
          ),
        ),
      ).geolocate(cells: [cell]);
      expect(nf.notFound, isTrue);
      expect(nf.fix, isNull);

      final err = await BeaconDb(
        client: MockClient((_) async => http.Response('oops', 500)),
      ).geolocate(cells: [cell]);
      expect(err.notFound, isFalse);
      expect(err.error, 'HTTP 500');

      final ip = await BeaconDb(
        client: MockClient(
          (_) async => http.Response(
            '{"location":{"lat":1,"lng":2},"accuracy":50000,"fallback":"ipf"}',
            200,
          ),
        ),
      ).geolocate(cells: [cell]);
      expect(ip.notFound, isTrue);

      final none = await BeaconDb(
        client: MockClient((_) async => fail('no request expected')),
      ).geolocate();
      expect(none.notFound, isTrue);
    });
  });

  group('OnlineResolver', () {
    late LocationDb db;
    late FakeApple apple;
    late OnlineResolver resolver;
    late List<Map<String, Object?>> beaconRequests;
    http.Response Function(Map<String, Object?>) beaconAnswer = (_) =>
        http.Response('{}', 404);

    setUp(() {
      db = LocationDb.inMemory();
      apple = FakeApple();
      beaconRequests = [];
      beaconAnswer = (_) => http.Response('{}', 404);
      resolver = OnlineResolver(
        db,
        apple: AppleWps(client: MockClient(apple.handle)),
        beaconDb: BeaconDb(
          client: MockClient((r) async {
            final body = jsonDecode(r.body) as Map<String, Object?>;
            beaconRequests.add(body);
            return beaconAnswer(body);
          }),
        ),
        minInterval: Duration.zero,
        now: () => t0,
      );
    });
    tearDown(() => db.close());

    test('resolveWifi caches the answer, neighbours and unknowns', () async {
      final known = apple.macAt(0, 0);
      final scan = [
        const WifiObservation(bssid: 'aa:aa:aa:00:00:01', signalDbm: -80),
        WifiObservation(bssid: known, signalDbm: -55),
        const WifiObservation(
          bssid: 'aa:aa:aa:00:00:02',
          signalDbm: -40,
          ssid: 'me_nomap',
        ),
      ];
      final written = await resolver.resolveWifi(scan);
      // Strongest eligible AP first; the opted-out one is never sent.
      expect(apple.requests.single, [known, 'aa:aa:aa:00:00:01']);
      // The AP itself plus its neighbours within 300 m on a 50 m grid.
      expect(written, greaterThan(100));
      final rec = db.get(TransmitterKind.wifi, known)!;
      expect(rec.source, TransmitterSource.apple);
      expect(rec.accuracyM, 25);
      expect(haversineM(rec.lat, rec.lon, lat0, lon0), lessThan(0.01));
      expect(db.get(TransmitterKind.wifi, apple.macAt(50, 50)), isNotNull);

      // Second round: everything is cached or negatively cached.
      expect(await resolver.resolveWifi(scan), 0);
      expect(apple.requests.length, 1);
      expect(
        db.recentlyUnknown(TransmitterKind.wifi, ['aa:aa:aa:00:00:01'], t0),
        hasLength(1),
      );
    });

    test('resolveWifi failure is soft and not negatively cached', () async {
      apple.failNext = 1;
      const scan = [
        WifiObservation(bssid: 'aa:aa:aa:00:00:01', signalDbm: -80),
      ];
      expect(await resolver.resolveWifi(scan), 0);
      expect(resolver.failures, 1);
      expect(resolver.lastError, contains('503'));
      expect(
        db.recentlyUnknown(TransmitterKind.wifi, ['aa:aa:aa:00:00:01'], t0),
        isEmpty,
      );
      // Retried next time.
      await resolver.resolveWifi(scan);
      expect(apple.requests.length, 1);
    });

    test('resolveCells asks one bare cell per request and caches it', () async {
      beaconAnswer = (_) => http.Response(
        '{"location":{"lat":59.92,"lng":30.65},"accuracy":968}',
        200,
      );
      expect(await resolver.resolveCells([cell]), 1);
      expect(beaconRequests.single['cellTowers'], [
        {
          'radioType': 'lte',
          'mobileCountryCode': 250,
          'mobileNetworkCode': 20,
          'locationAreaCode': 8000,
          'cellId': 27440068,
        },
      ]);
      expect(beaconRequests.single.containsKey('wifiAccessPoints'), isFalse);
      final rec = db.get(TransmitterKind.cell, cell.key!)!;
      expect(rec.accuracyM, 968);
      expect(rec.source, TransmitterSource.beacondb);
      expect(await resolver.resolveCells([cell]), 0);
      expect(beaconRequests.length, 1);
    });

    test('unknown cells are negatively cached; errors are not', () async {
      expect(await resolver.resolveCells([cell]), 0);
      expect(
        db.recentlyUnknown(TransmitterKind.cell, [cell.key!], t0),
        hasLength(1),
      );
      await resolver.resolveCells([cell]);
      expect(beaconRequests.length, 1);

      const other = CellObservation(
        radio: RadioType.lte,
        mcc: 250,
        mnc: 2,
        area: 10795,
        cellId: 45335765,
      );
      beaconAnswer = (_) => http.Response('down', 502);
      expect(await resolver.resolveCells([other]), 0);
      expect(
        db.recentlyUnknown(TransmitterKind.cell, [other.key!], t0),
        isEmpty,
      );
      expect(resolver.lastError, contains('502'));
    });

    test('geolocate falls back to a whole-scan fix', () async {
      beaconAnswer = (_) => http.Response(
        '{"location":{"lat":59.921,"lng":30.651},"accuracy":35}',
        200,
      );
      final e = await resolver.geolocate(
        wifi: const [
          WifiObservation(bssid: 'aa:aa:aa:00:00:01', signalDbm: -60),
          WifiObservation(bssid: 'aa:aa:aa:00:00:02', signalDbm: -70),
        ],
      );
      expect(e!.source, PositionSource.wifi);
      expect(e.accuracyM, 35);
      expect(e.lat, 59.921);
      // One AP alone is not sent (MLS needs two; a single MAC is a privacy
      // leak with no benefit).
      beaconRequests.clear();
      expect(
        await resolver.geolocate(
          wifi: const [WifiObservation(bssid: 'aa:aa:aa:00:00:01')],
        ),
        isNull,
      );
      expect(beaconRequests, isEmpty);
    });

    test('preloadRegion snowballs through the whole region', () async {
      final progress = <int>[];
      final p = await resolver.preloadRegion(
        GeoBounds.around(lat0, lon0, 400),
        seeds: [apple.macAt(0, 0)],
        onProgress: (x) => progress.add(x.requests),
      );
      expect(p.finished, 'complete');
      // Every AP inside the 800 m box (17 x 17 grid points) is cached...
      final inside = apple.aps.values
          .where((v) => v.$1.abs() <= 400 && v.$2.abs() <= 400)
          .length;
      expect(inside, 17 * 17);
      expect(p.stored, inside);
      expect(db.stats().wifi, inside);
      // ...and nothing outside it.
      expect(db.get(TransmitterKind.wifi, apple.macAt(450, 0)), isNull);
      // One seed per 150 m grid cell at most: 6 x 6 cells (+ the blind seed).
      expect(p.requests, lessThanOrEqualTo(37));
      expect(p.requests, greaterThanOrEqualTo(4));
      expect(apple.requests.every((r) => r.length == 1), isTrue);
      expect(progress.last, p.requests);

      // Running it again uses the cached APs as seeds and stays bounded.
      final again = await resolver.preloadRegion(
        GeoBounds.around(lat0, lon0, 400),
      );
      expect(again.finished, 'complete');
      expect(again.requests, lessThanOrEqualTo(37));
    });

    test(
      'preloadRegion honours the hard request cap and cancellation',
      () async {
        final capped = await resolver.preloadRegion(
          GeoBounds.around(lat0, lon0, 500),
          seeds: [apple.macAt(0, 0)],
          maxRequests: 3,
        );
        expect(capped.finished, 'requestCap');
        expect(capped.requests, 3);
        expect(apple.requests.length, 3);

        var calls = 0;
        final cancelled = await resolver.preloadRegion(
          GeoBounds.around(lat0, lon0, 500),
          isCancelled: () => ++calls > 2,
        );
        expect(cancelled.finished, 'cancelled');
        expect(cancelled.requests, lessThanOrEqualTo(2));
      },
    );

    test(
      'preloadRegion: AP cap, no seeds, unknown seed, server errors',
      () async {
        final apCap = await resolver.preloadRegion(
          GeoBounds.around(lat0, lon0, 500),
          seeds: [apple.macAt(0, 0)],
          maxAps: 50,
        );
        expect(apCap.finished, 'apCap');
        expect(apCap.requests, 1);

        final db2 = LocationDb.inMemory();
        final r2 = OnlineResolver(
          db2,
          apple: AppleWps(client: MockClient(apple.handle)),
          beaconDb: BeaconDb(
            client: MockClient((_) async => http.Response('', 404)),
          ),
          minInterval: Duration.zero,
        );
        expect(
          (await r2.preloadRegion(GeoBounds.around(lat0, lon0, 500))).finished,
          'noSeeds',
        );
        final unknownSeed = await r2.preloadRegion(
          GeoBounds.around(lat0, lon0, 500),
          seeds: ['aa:aa:aa:00:00:01'],
        );
        expect(unknownSeed.finished, 'complete');
        expect(unknownSeed.stored, 0);

        apple.failNext = 100;
        final failing = await r2.preloadRegion(
          GeoBounds.around(lat0, lon0, 500),
          seeds: [
            apple.macAt(0, 0),
            apple.macAt(50, 0),
            apple.macAt(100, 0),
            apple.macAt(150, 0),
          ],
        );
        expect(failing.finished, 'errors');
        expect(failing.requests, 3);
        db2.close();
      },
    );

    test('requests are rate limited', () async {
      final slow = OnlineResolver(
        db,
        apple: AppleWps(client: MockClient(apple.handle)),
        beaconDb: BeaconDb(
          client: MockClient((_) async => http.Response('', 404)),
        ),
        minInterval: const Duration(milliseconds: 120),
      );
      final sw = Stopwatch()..start();
      await slow.preloadRegion(
        GeoBounds.around(lat0, lon0, 500),
        seeds: [apple.macAt(0, 0)],
        maxRequests: 4,
      );
      // 4 requests -> at least 3 gaps.
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(330));
    });
  });

  test('GeoBounds.around', () {
    final b = GeoBounds.around(lat0, lon0, 1000);
    expect(haversineM(b.south, lon0, b.north, lon0), closeTo(2000, 1));
    expect(haversineM(lat0, b.west, lat0, b.east), closeTo(2000, 5));
    expect(b.contains(lat0, lon0), isTrue);
    expect(b.contains(lat0 + 0.02, lon0), isFalse);
  });
}
