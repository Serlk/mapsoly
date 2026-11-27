// The privacy zone promises, with the Android radio sources in place of the
// fakes: what Android's Wi-Fi scan and cell list report inside a zone is
// neither stored nor sent anywhere. The platform side is a scripted method
// channel; the engine, database, collector, resolver and guard are real.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mapsoly/positioning/positioning.dart';
import 'package:mapsoly/user/privacy_guard.dart';
import 'package:mapsoly/user/privacy_zones.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/android/privacy');

  late LocationDb db;
  late FakeGnss gnss;
  late DateTime clock;
  late PrivacyZones zones;
  late PrivacyGuard guard;
  late PositioningEngine engine;
  late List<Object?> wifiRows, cellEntries;
  late List<String> sent;

  /// Stands still at [east], [north] for a few seconds of good GNSS.
  void park(double east, double north) {
    for (var t = 0; t < 5; t++) {
      gnss.controller.add(fixAt(clock, east, north));
      clock = clock.add(const Duration(seconds: 1));
    }
  }

  /// What the tablet hears: two access points and the serving cell, none of
  /// them in the database.
  void hear() {
    wifiRows = [
      [mac(1).toUpperCase(), -52, 2437, 400, 'Home'],
      [mac(2).toUpperCase(), -67, 5180, 400, null],
    ];
    cellEntries = [
      {
        'radio': 'lte',
        'serving': true,
        'mcc': 999,
        'mnc': 7,
        'area': 4242,
        'cid': 101,
        'pci': 5,
        'arfcn': 1850,
        'dbm': -80,
        'rsrq': -9,
        'ta': 0x7fffffff,
      },
    ];
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  setUp(() async {
    db = LocationDb.inMemory();
    gnss = FakeGnss();
    clock = DateTime.utc(2026, 11, 27, 12);
    zones = PrivacyZones.inMemory();
    guard = PrivacyGuard(zones);
    wifiRows = [];
    cellEntries = [];
    sent = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'wifiScan':
              return wifiRows;
            case 'wifiRequestScan':
              return true;
            case 'cells':
              return cellEntries;
          }
          return null;
        });
    http.Client service(String name) => MockClient((request) async {
      sent.add(name);
      return http.Response('{}', 404);
    });
    engine = PositioningEngine(
      db: db,
      wifi: AndroidWifiScanner(channel: channel, now: () => clock),
      cells: AndroidCellSource(channel: channel),
      gnss: gnss,
      resolver: OnlineResolver(
        db,
        apple: AppleWps(client: service('apple')),
        beaconDb: BeaconDb(client: service('beacondb')),
        minInterval: Duration.zero,
        now: () => clock,
      ),
      now: () => clock,
      config: PositioningConfig(
        wifiScanInterval: const Duration(hours: 1),
        cellPollInterval: const Duration(hours: 1),
        outputInterval: const Duration(hours: 1),
        // Not about the wait before a new track may teach the database.
        sanity: const GnssSanityConfig(settleAfter: Duration.zero),
        onlineLookups: true,
        wardriving: true,
        estimator: androidPositioningConfig.estimator,
        wardrivingConfig: const WardrivingConfig(keepRawSamples: true),
      ),
    );
    guard.attach(engine);
    await engine.start();
  });

  tearDown(() async {
    await settle();
    guard.detach();
    await engine.dispose();
    await gnss.controller.close();
  });

  test('inside a zone: an Android scan is not stored and not sent', () async {
    zones.add(PrivacyZone(name: 'Дом', center: origin, radiusM: 300));
    park(40, -60); // 72 m from the centre
    hear();
    await engine.pollNow();
    await settle();
    await engine.pollNow();
    await settle();

    // The sources did deliver: this is not an empty scan passing by default.
    expect(engine.status.wifiVisible, 2);
    expect(engine.status.cellsVisible, 1);
    expect(engine.status.gnssHealth.usable, isTrue);
    expect(engine.status.wardriving, isTrue);
    expect(engine.status.onlineLookups, isTrue);
    expect(engine.status.privateArea, isTrue);

    expect(db.get(TransmitterKind.wifi, mac(1)), isNull);
    expect(db.get(TransmitterKind.wifi, mac(2)), isNull);
    expect(db.get(TransmitterKind.cell, 'lte:999:7:4242:101'), isNull);
    expect(db.stats().total, 0);
    expect(db.stats().rawSamples, 0);
    expect(engine.status.wardrivingSamples, 0);
    expect(sent, isEmpty);
  });

  test('control: the same scan outside every zone is stored and looked up, '
      'so the test above can fail', () async {
    zones.add(PrivacyZone(name: 'Дом', center: at(5000, 0), radiusM: 300));
    park(40, -60);
    hear();
    await engine.pollNow();
    await settle();

    expect(engine.status.privateArea, isFalse);
    expect(db.get(TransmitterKind.wifi, mac(1)), isNotNull);
    expect(db.get(TransmitterKind.wifi, mac(2)), isNotNull);
    expect(db.get(TransmitterKind.cell, 'lte:999:7:4242:101'), isNotNull);
    expect(engine.status.wardrivingSamples, 3);
    // Wardriving has just made them known, so nothing is left to ask about;
    // a transmitter heard after the fix was lost is.
    wifiRows = [
      ...wifiRows,
      [mac(3), -60, 2462, 0, 'New'],
    ];
    clock = clock.add(const Duration(seconds: 30));
    await engine.pollNow();
    await settle();
    expect(sent, isNotEmpty);
  });

  test('driving into a zone stops both at once', () async {
    zones.add(PrivacyZone(name: 'Дом', center: origin, radiusM: 300));
    // Parked well outside first.
    park(2000, 0);
    hear();
    await engine.pollNow();
    await settle();
    final storedOutside = db.stats().total;
    expect(storedOutside, 3);
    final sentOutside = sent.length;

    // Then at home, hearing other transmitters. The jump between the two
    // parkings is slow enough for the spoofing check.
    for (var east = 2000.0; east > 0; east -= 20) {
      gnss.controller.add(fixAt(clock, east, 0, speed: 20));
      clock = clock.add(const Duration(seconds: 1));
    }
    park(0, 0);
    wifiRows = [
      [mac(0x21), -50, 2437, 300, 'Home'],
      [mac(0x22), -58, 5500, 300, 'Home-5G'],
    ];
    cellEntries = [
      {...(cellEntries.single! as Map), 'cid': 202},
    ];
    await engine.pollNow();
    await settle();
    await engine.pollNow();
    await settle();

    expect(engine.status.privateArea, isTrue);
    expect(engine.status.wifiVisible, 2);
    expect(db.stats().total, storedOutside);
    expect(db.get(TransmitterKind.wifi, mac(0x21)), isNull);
    expect(db.get(TransmitterKind.cell, 'lte:999:7:4242:202'), isNull);
    expect(sent.length, sentOutside);
  });
}
