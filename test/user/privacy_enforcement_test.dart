// The four promises of a privacy zone, each driven through the real engine,
// database, collector, resolver and OBD session with fake sources:
//  a. wardriving stores nothing collected inside a zone;
//  b. no online lookup is sent from inside a zone (local positioning works);
//  c. trip-log rows written inside a zone carry no coordinates;
//  d. exports filter again (see also data_export_test.dart).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/obd/obd_session.dart';
import 'package:mapsoly/positioning/positioning.dart';
import 'package:mapsoly/user/data_export.dart';
import 'package:mapsoly/user/privacy_guard.dart';
import 'package:mapsoly/user/privacy_zones.dart';

import '../obd/fake_elm.dart';
import 'fakes.dart';

void main() {
  late LocationDb db;
  late FakeWifi wifi;
  late FakeCells cells;
  late FakeGnss gnss;
  late DateTime clock;
  late PrivacyZones zones;
  late PrivacyGuard guard;
  late int appleRequests, beaconRequests;
  PositioningEngine? engine;

  void tick([int seconds = 1]) => clock = clock.add(Duration(seconds: seconds));

  /// Stands still at [east], [north] for a few seconds of good GNSS.
  void park(double east, double north) {
    for (var t = 0; t < 5; t++) {
      gnss.controller.add(fixAt(clock, east, north));
      tick();
    }
  }

  PositioningEngine build({bool online = false, bool rawSamples = false}) {
    final resolver = OnlineResolver(
      db,
      // Both services are reachable but know nothing: every request counts.
      apple: AppleWps(
        client: MockClient((_) async {
          appleRequests++;
          return http.Response('busy', 503);
        }),
      ),
      beaconDb: BeaconDb(
        client: MockClient((_) async {
          beaconRequests++;
          return http.Response('{}', 404);
        }),
      ),
      minInterval: Duration.zero,
      now: () => clock,
    );
    return engine = PositioningEngine(
      db: db,
      wifi: wifi,
      cells: cells,
      gnss: gnss,
      resolver: resolver,
      now: () => clock,
      // Long timer periods: the tests drive the engine by hand.
      config: PositioningConfig(
        wifiScanInterval: const Duration(hours: 1),
        cellPollInterval: const Duration(hours: 1),
        outputInterval: const Duration(hours: 1),
        onlineLookups: online,
        wardriving: true,
        wardrivingConfig: WardrivingConfig(keepRawSamples: rawSamples),
      ),
    );
  }

  /// Lets the fire-and-forget online round of the last poll finish.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  setUp(() {
    db = LocationDb.inMemory();
    wifi = FakeWifi();
    cells = FakeCells();
    gnss = FakeGnss();
    clock = DateTime.utc(2026, 11, 26, 12);
    zones = PrivacyZones.inMemory();
    guard = PrivacyGuard(zones);
    appleRequests = beaconRequests = 0;
    engine = null;
  });

  tearDown(() async {
    await settle();
    guard.detach();
    await engine?.dispose(); // closes the database too
    if (engine == null) db.close();
    await gnss.controller.close();
  });

  group('a. wardriving', () {
    test('nothing observed inside a zone is stored', () async {
      zones.add(PrivacyZone(name: 'Дом', center: origin, radiusM: 300));
      final e = build(rawSamples: true);
      guard.attach(e);
      await e.start();
      park(40, -60); // 72 m from the centre
      wifi.scan = [WifiObservation(bssid: mac(1), signalDbm: -50)];
      cells.cells = [cell(101, signalDbm: -80)];
      await e.pollNow();

      expect(e.status.gnssHealth.usable, isTrue);
      expect(e.status.wardriving, isTrue);
      expect(e.status.privateArea, isTrue);
      expect(db.get(TransmitterKind.wifi, mac(1)), isNull);
      expect(db.get(TransmitterKind.cell, cell(101).key!), isNull);
      expect(db.stats().total, 0);
      expect(db.stats().rawSamples, 0);
      expect(e.status.wardrivingSamples, 0);
      // The position itself still works inside the zone.
      expect(
        haversineM(
          e.current!.lat,
          e.current!.lon,
          at(40, -60).latitude,
          at(40, -60).longitude,
        ),
        lessThan(10),
      );
    });

    test('the same drive outside a zone is stored', () async {
      zones.add(PrivacyZone(name: 'Дом', center: at(2000, 0), radiusM: 300));
      final e = build(rawSamples: true);
      guard.attach(e);
      await e.start();
      park(40, -60);
      wifi.scan = [WifiObservation(bssid: mac(1), signalDbm: -50)];
      cells.cells = [cell(101, signalDbm: -80)];
      await e.pollNow();

      expect(e.status.privateArea, isFalse);
      final ap = db.get(TransmitterKind.wifi, mac(1))!;
      expect(ap.source, TransmitterSource.wardriving);
      expect(db.get(TransmitterKind.cell, cell(101).key!), isNotNull);
      expect(db.stats().rawSamples, 2);
    });

    test(
      'a zone change applies at once and deletes nothing by itself',
      () async {
        final e = build(rawSamples: true);
        guard.attach(e);
        await e.start();

        park(0, 0);
        wifi.scan = [WifiObservation(bssid: mac(1), signalDbm: -50)];
        await e.pollNow();
        expect(db.get(TransmitterKind.wifi, mac(1)), isNotNull);

        // The user draws a zone around where the car is standing.
        final home = zones.add(
          PrivacyZone(name: 'Дом', center: origin, radiusM: 200),
        );
        park(0, 0);
        wifi.scan = [
          WifiObservation(bssid: mac(1), signalDbm: -40), // stronger: resampled
          WifiObservation(bssid: mac(2), signalDbm: -50),
        ];
        cells.cells = [cell(102)];
        await e.pollNow();
        expect(e.status.privateArea, isTrue);
        expect(db.get(TransmitterKind.wifi, mac(2)), isNull);
        expect(db.get(TransmitterKind.cell, cell(102).key!), isNull);
        // What was stored before the zone existed is still there, unchanged...
        final before = db.get(TransmitterKind.wifi, mac(1))!;
        expect(before.samples, 1);
        expect(db.stats().rawSamples, 1);
        // ...and is offered for deletion, counted first.
        expect(purgeWardrivingInside(db, zones, dryRun: true), 2);
        expect(purgeDetails(db, zones, dryRun: true), (
          transmitters: 1,
          rawSamples: 1,
        ));
        expect(db.get(TransmitterKind.wifi, mac(1)), isNotNull);

        // The zone is removed again: collection resumes.
        zones.remove(home.id);
        park(0, 0);
        wifi.scan = [WifiObservation(bssid: mac(3), signalDbm: -50)];
        await e.pollNow();
        expect(e.status.privateArea, isFalse);
        expect(db.get(TransmitterKind.wifi, mac(3)), isNotNull);
      },
    );

    test('collector: Wi-Fi, cells and BLE, by the fix of the observation', () {
      zones.add(PrivacyZone(name: 'Дом', center: origin, radiusM: 300));
      final collector = WardrivingCollector(db)..privacyFilter = guard.filter;
      // Driving east out of the zone at 20 m/s, a fix every second.
      for (var s = 0; s <= 30; s++) {
        collector.addFix(
          fixAt(clock.add(Duration(seconds: s)), 20.0 * s, 0, speed: 20),
        );
      }
      DateTime t(int s) => clock.add(Duration(seconds: s));

      // t = 5 s: 100 m from the centre.
      expect(collector.addWifi([WifiObservation(bssid: mac(1))], t(5)), 0);
      expect(collector.addCells([cell(1)], t(5)), 0);
      expect(collector.addBle([BleObservation(address: mac(0x51))], t(5)), 0);
      // A scan read outside the zone but heard 10 s earlier, inside it.
      expect(
        collector.addWifi([
          WifiObservation(bssid: mac(2), age: const Duration(seconds: 10)),
        ], t(20)),
        0,
      );
      // 302 m with a 5 m fix: the accuracy circle still touches the zone.
      expect(
        collector.addWifi([
          WifiObservation(bssid: mac(3)),
        ], clock.add(const Duration(milliseconds: 15100))),
        0,
      );
      expect(db.stats().total, 0);
      expect(collector.samplesWritten, 0);
      expect(collector.samplesWithheld, 5);

      // t = 20 s: 400 m from the centre, clearly outside.
      expect(collector.addWifi([WifiObservation(bssid: mac(4))], t(20)), 1);
      expect(collector.addCells([cell(2)], t(20)), 1);
      expect(collector.addBle([BleObservation(address: mac(0x52))], t(20)), 1);
      expect(db.stats().total, 3);
      expect(collector.samplesWithheld, 5);
      for (final r in db.records()) {
        expect(zones.contains(LatLng(r.lat, r.lon)), isFalse);
      }
    });

    test('a damaged zone file stops collection everywhere', () async {
      final dir = Directory.systemTemp.createTempSync('mapsoly-user-');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/privacy_zones.json').writeAsStringSync('{"zones":');
      zones = PrivacyZones.load(dir);
      guard = PrivacyGuard.load(dir, zones);
      final e = build();
      guard.attach(e);
      await e.start();
      park(5000, 5000);
      wifi.scan = [WifiObservation(bssid: mac(1), signalDbm: -50)];
      await e.pollNow();
      expect(db.stats().total, 0);
      expect(e.status.privateArea, isTrue);
      // Deleting "everything inside the zones" must not mean everything.
      db.addSamples([sample(TransmitterKind.wifi, mac(9), at(9000, 0))]);
      expect(purgeWardrivingInside(db, zones), 0);

      zones.confirmZones();
      park(5000, 5000);
      wifi.scan = [WifiObservation(bssid: mac(2), signalDbm: -50)];
      await e.pollNow();
      expect(db.get(TransmitterKind.wifi, mac(2)), isNotNull);
    });
  });

  group('b. online lookups', () {
    /// Four access points around the origin that the local database knows.
    void knownAps() => db.upsertExternal([
      for (final (i, e, n) in [
        (1, -40.0, 0.0),
        (2, 40.0, 0.0),
        (3, 0.0, 40.0),
        (4, 0.0, -40.0),
      ])
        record(TransmitterKind.wifi, mac(i), at(e, n)),
    ]);

    List<WifiObservation> scanWithUnknown() => [
      for (var i = 1; i <= 4; i++)
        WifiObservation(bssid: mac(i), signalDbm: -60),
      WifiObservation(bssid: mac(0x70), signalDbm: -55),
      WifiObservation(bssid: mac(0x71), signalDbm: -65),
    ];

    test(
      'control: without a zone the unknown transmitters are looked up',
      () async {
        knownAps();
        final e = build(online: true);
        guard.attach(e);
        await e.start();
        wifi.scan = scanWithUnknown();
        cells.cells = [cell(201)];
        // Two rounds: the engine's own first poll at start() saw an empty
        // scan, and rounds are at least 20 s apart.
        for (var i = 0; i < 2; i++) {
          tick(60);
          await e.pollNow();
          await settle();
        }
        expect(appleRequests, greaterThanOrEqualTo(1));
        expect(beaconRequests, greaterThanOrEqualTo(1));
      },
    );

    test('inside a zone nothing is sent; the local fix still works', () async {
      knownAps();
      zones.add(PrivacyZone(name: 'Дом', center: origin, radiusM: 250));
      final e = build(online: true);
      guard.attach(e);
      await e.start();
      wifi.scan = scanWithUnknown();
      cells.cells = [cell(201)];
      for (var i = 0; i < 5; i++) {
        await e.pollNow();
        await settle();
        tick(60); // well past the minimum interval between rounds
      }
      expect(appleRequests, 0);
      expect(beaconRequests, 0);
      expect(e.status.onlineLookups, isTrue);
      expect(e.status.privateArea, isTrue);
      // Positioned from the local database, inside the zone.
      final fix = e.current!;
      expect(fix.source, PositionSource.wifi);
      expect(haversineM(fix.lat, fix.lon, lat0, lon0), lessThan(40));
      expect(e.status.wifiKnown, 4);
      // Nothing went to the negative cache either.
      expect(
        db.recentlyUnknown(TransmitterKind.wifi, [mac(0x70)], clock),
        isEmpty,
      );

      // Leaving the zone (here: the zone is removed) lets lookups resume.
      zones.remove(zones.zones.single.id);
      await e.pollNow();
      await settle();
      expect(appleRequests, 1);
      expect(e.status.privateArea, isFalse);
    });

    test(
      'an uncertain position whose circle touches a zone counts as inside',
      () async {
        // Only a cell is known: its coverage circle is hundreds of metres.
        db.upsertExternal([
          record(
            TransmitterKind.cell,
            cell(201).key!,
            at(900, 0),
            source: TransmitterSource.beacondb,
            accuracyM: 800,
          ),
        ]);
        zones.add(PrivacyZone(name: 'Дом', center: origin, radiusM: 200));
        final e = build(online: true);
        guard.attach(e);
        await e.start();
        wifi.scan = [
          WifiObservation(bssid: mac(0x70), signalDbm: -55),
          WifiObservation(bssid: mac(0x71), signalDbm: -65),
        ];
        cells.cells = [cell(201)];
        for (var i = 0; i < 3; i++) {
          tick(60);
          await e.pollNow();
          await settle();
        }
        final fix = e.current!;
        expect(fix.source, PositionSource.cell);
        expect(zones.contains(LatLng(fix.lat, fix.lon)), isFalse);
        expect(
          zones.intersects(LatLng(fix.lat, fix.lon), fix.accuracyM),
          isTrue,
        );
        expect(appleRequests, 0);
        expect(beaconRequests, 0);
        expect(e.status.privateArea, isTrue);

        // The same estimate far from any zone: lookups go out.
        zones.update(zones.zones.single.copyWith(center: at(0, 20000)));
        tick(60);
        await e.pollNow();
        await settle();
        expect(appleRequests, 1);
      },
    );

    test('GNSS position inside a zone blocks lookups too', () async {
      zones.add(PrivacyZone(name: 'Дом', center: origin, radiusM: 250));
      final e = build(online: true);
      guard.attach(e);
      await e.start();
      // Otherwise the collector would learn the scan itself once the zone
      // is gone, leaving nothing to look up.
      e.wardriving = false;
      wifi.scan = scanWithUnknown(); // nothing of it is in the database
      for (var i = 0; i < 3; i++) {
        tick(60);
        park(30, 30);
        await e.pollNow();
        await settle();
      }
      expect(e.current!.source, PositionSource.gnss);
      expect(appleRequests + beaconRequests, 0);
      // The same without the zone: the lookup goes out.
      zones.remove(zones.zones.single.id);
      tick(60);
      park(30, 30);
      await e.pollNow();
      await settle();
      expect(appleRequests, 1);
    });

    test('cold start after a session that ended in a zone: held until '
        'a position is known', () async {
      final dir = Directory.systemTemp.createTempSync('mapsoly-user-');
      addTearDown(() => dir.deleteSync(recursive: true));
      zones.add(PrivacyZone(name: 'Дом', center: origin, radiusM: 250));

      // Session 1 ends at home.
      guard = PrivacyGuard.load(dir, zones);
      expect(guard.lastKnownInside, isFalse);
      var e = build(online: true);
      guard.attach(e);
      await e.start();
      park(0, 0);
      await e.pollNow();
      await Future<void>.delayed(Duration.zero);
      expect(guard.lastKnownInside, isTrue);
      guard.detach();
      await e.stop();
      final firstGnss = gnss;

      // Session 2: same place, no GNSS yet, nothing known locally.
      gnss = FakeGnss();
      addTearDown(firstGnss.controller.close);
      final db1 = db;
      addTearDown(e.dispose);
      db = LocationDb.inMemory();
      guard = PrivacyGuard.load(dir, zones);
      expect(guard.lastKnownInside, isTrue);
      e = build(online: true);
      guard.attach(e);
      await e.start();
      wifi.scan = scanWithUnknown();
      cells.cells = [cell(201)];
      for (var i = 0; i < 3; i++) {
        tick(60);
        await e.pollNow();
        await settle();
      }
      expect(e.current, isNull);
      expect(e.status.privateArea, isTrue);
      expect(appleRequests + beaconRequests, 0);
      expect(db1, isNot(same(db)));

      // The user says "I am not at home": lookups resume.
      guard.releaseHold();
      tick(60);
      await e.pollNow();
      await settle();
      expect(appleRequests, 1);
      expect(guard.lastKnownInside, isFalse);
      expect(PrivacyGuard.load(dir, zones).lastKnownInside, isFalse);
    });

    test(
      'without the hold a cold start does look up (documented gap)',
      () async {
        zones.add(PrivacyZone(name: 'Дом', center: origin, radiusM: 250));
        final e = build(online: true);
        guard.attach(e); // fresh guard: last session did not end in a zone
        await e.start();
        wifi.scan = scanWithUnknown();
        for (var i = 0; i < 2; i++) {
          tick(60);
          await e.pollNow();
          await settle();
        }
        expect(e.current, isNull);
        expect(appleRequests, greaterThanOrEqualTo(1));
      },
    );

    test(
      'preloading a region from a zone does not offer the current scan',
      () async {
        knownAps();
        zones.add(PrivacyZone(name: 'Дом', center: origin, radiusM: 250));
        final e = build();
        guard.attach(e);
        await e.start();
        wifi.scan = scanWithUnknown();
        await e.pollNow();
        // A region elsewhere, with nothing known in it: no seeds, no request.
        final far = at(30000, 0);
        final p = await e.preloadRegion(
          GeoBounds.around(far.latitude, far.longitude, 300),
        );
        expect(p.finished, 'noSeeds');
        expect(appleRequests, 0);
      },
    );

    test(
      'preloading a region never names a transmitter stored in a zone',
      () async {
        // Known access points every 100 m along a street through the zone.
        db.upsertExternal([
          for (var i = 0; i < 12; i++)
            record(TransmitterKind.wifi, mac(i), at(-550 + i * 100.0, 0)),
        ]);
        zones.add(PrivacyZone(name: 'Дом', center: origin, radiusM: 200));
        final asked = <String>[];
        final resolver = OnlineResolver(
          db,
          apple: AppleWps(
            client: MockClient((request) async {
              // The BSSIDs are plain text inside the protobuf body.
              final body = latin1.decode(request.bodyBytes);
              asked.addAll(
                RegExp(
                  '(?:[0-9a-f]{1,2}:){5}[0-9a-f]{1,2}',
                ).allMatches(body).map((m) => normalizeMac(m[0]!)!),
              );
              return http.Response('busy', 503);
            }),
          ),
          minInterval: Duration.zero,
          now: () => clock,
        )..privacyFilter = guard.filter;
        addTearDown(resolver.close);
        await resolver.preloadRegion(
          GeoBounds.around(lat0, lon0, 700),
          maxConsecutiveErrors: 100,
        );
        expect(asked, isNotEmpty);
        for (final id in asked) {
          final r = db.get(TransmitterKind.wifi, id)!;
          expect(zones.contains(LatLng(r.lat, r.lon)), isFalse, reason: id);
        }
        // Without the filter the same run does name transmitters in the zone
        // (one seed per grid cell, so not every one of them).
        bool inZone(String id) {
          final r = db.get(TransmitterKind.wifi, id)!;
          return zones.contains(LatLng(r.lat, r.lon));
        }

        asked.clear();
        resolver.privacyFilter = null;
        await resolver.preloadRegion(
          GeoBounds.around(lat0, lon0, 700),
          maxConsecutiveErrors: 100,
        );
        expect(asked.where(inZone), isNotEmpty);
      },
    );

    test('shareable: a position for an online search hint', () {
      zones.add(PrivacyZone(name: 'Дом', center: origin, radiusM: 200));
      expect(guard.shareable(null), isNull);
      expect(guard.shareable(at(50, 0)), isNull);
      expect(guard.shareable(at(500, 0)), at(500, 0));
      expect(guard.shareable(at(500, 0), accuracyM: 400), isNull);
    });

    test('unreadable guard state is taken as "inside"', () {
      final dir = Directory.systemTemp.createTempSync('mapsoly-user-');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/privacy_state.json').writeAsStringSync('{"ins');
      expect(PrivacyGuard.load(dir, zones).lastKnownInside, isTrue);
    });
  });

  group('c. trip log', () {
    test(
      'rows written inside a zone have vehicle data but no coordinates',
      () async {
        final dir = Directory.systemTemp.createTempSync('mapsoly-obd-');
        addTearDown(() => dir.deleteSync(recursive: true));
        zones.add(PrivacyZone(name: 'Дом', center: origin, radiusM: 300));

        // The car starts at home and is outside the zone a little later.
        var position = at(50, 50);
        final session = ObdSession(
          () async => FakeElm(speedKmh: 50, pids: {0x5E}),
          options: ObdOptions(
            fuel: true,
            logDirectory: dir,
            position: guard.tripLogPosition(
              () => (lat: position.latitude, lon: position.longitude),
            ),
          ),
          pollInterval: const Duration(milliseconds: 2),
        );
        session.start();
        await session.states.firstWhere((s) => s == ObdState.connected);
        await Future<void>.delayed(const Duration(milliseconds: 1300));
        position = at(900, 50);
        await Future<void>.delayed(const Duration(milliseconds: 1300));
        await session.dispose();

        final log = dir.listSync().whereType<File>().single;
        final lines = log.readAsLinesSync();
        expect(lines.first, endsWith(',lat,lon'));
        final rows = [for (final l in lines.skip(1)) l.split(',')];
        expect(rows.length, greaterThanOrEqualTo(3));
        final inside = rows.where((r) => r[9].isEmpty).toList();
        final outside = rows.where((r) => r[9].isNotEmpty).toList();
        expect(inside, isNotEmpty);
        expect(outside, isNotEmpty);
        // In order: blank first, coordinates only after leaving.
        expect(rows.indexOf(outside.first), inside.length);
        for (final r in inside) {
          expect(r[10], isEmpty);
          expect(r[1], '50'); // speed is still logged
          expect(r[7], isNotEmpty); // and the distance
        }
        for (final r in outside) {
          final p = LatLng(double.parse(r[9]), double.parse(r[10]));
          expect(zones.contains(p), isFalse);
          expect(
            haversineM(
              p.latitude,
              p.longitude,
              at(900, 50).latitude,
              at(900, 50).longitude,
            ),
            lessThan(1),
          );
        }

        // d. A zone drawn later still removes those coordinates on export.
        zones.add(
          PrivacyZone(name: 'Работа', center: at(900, 0), radiusM: 200),
        );
        final out = Directory('${dir.path}/export');
        final result = await exportTripLogs([log], zones, out);
        expect(
          result.files.single.path,
          '${out.path}/${log.uri.pathSegments.last}',
        );
        expect(result.rows, rows.length);
        expect(result.rowsBlanked, outside.length);
        final exported = result.files.single.readAsLinesSync();
        expect(exported.first, lines.first);
        for (final l in exported.skip(1)) {
          expect(l, endsWith(',,'));
          expect(l.split(',')[1], '50');
        }
        // The original is untouched.
        expect(log.readAsLinesSync(), lines);
      },
    );

    test(
      'an uncertain position is blanked when its circle touches a zone',
      () async {
        zones.add(PrivacyZone(name: 'Дом', center: origin, radiusM: 300));
        final e = build();
        guard.attach(e);
        final position = guard.enginePosition(e);
        expect(position(), isNull); // no estimate yet

        // A coarse cell fix 700 m away with an 800 m circle.
        db.upsertExternal([
          record(
            TransmitterKind.cell,
            cell(201).key!,
            at(700, 0),
            source: TransmitterSource.beacondb,
            accuracyM: 800,
          ),
        ]);
        await e.start();
        cells.cells = [cell(201)];
        await e.pollNow();
        expect(e.current, isNotNull);
        expect(zones.contains(LatLng(e.current!.lat, e.current!.lon)), isFalse);
        expect(position(), isNull);

        zones.update(zones.zones.single.copyWith(center: at(0, 30000)));
        final p = position()!;
        expect(p.lat, e.current!.lat);
        expect(p.lon, e.current!.lon);
      },
    );
  });
}
