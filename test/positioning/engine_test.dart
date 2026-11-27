import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/positioning/positioning.dart';

const lat0 = 59.92, lon0 = 30.65;
final proj = LocalProjection(lat0, lon0);

class FakeWifi implements WifiScanner {
  List<WifiObservation> scan = [];
  int scansRequested = 0;
  bool closed = false;
  @override
  String get backend => 'fake';
  @override
  bool get reportsDbm => true;
  @override
  Future<bool> requestScan() async {
    scansRequested++;
    return true;
  }

  @override
  Future<List<WifiObservation>> getObservations({
    Duration maxAge = const Duration(seconds: 30),
  }) async => scan;
  @override
  Future<void> close() async => closed = true;
}

class FakeCells implements CellSource {
  List<CellObservation> cells = [];
  @override
  String get backend => 'fake';
  @override
  Future<List<CellObservation>> getCells() async => cells;
  @override
  Future<void> close() async {}
}

class FakeGnss implements GnssSource {
  final controller = StreamController<GnssFix>.broadcast(sync: true);
  bool started = false;
  @override
  Stream<GnssFix> get fixes => controller.stream;
  @override
  bool get connected => started;
  @override
  Future<void> start() async => started = true;
  @override
  Future<void> stop() async => started = false;
}

String mac(int i) => 'aa:bb:cc:00:00:${i.toRadixString(16).padLeft(2, '0')}';

const servingCell = CellObservation(
  radio: RadioType.lte,
  mcc: 250,
  mnc: 20,
  area: 8000,
  cellId: 27440068,
  serving: true,
);

const sky = [47.0, 44.0, 41.0, 39.0, 36.0, 33.0, 30.0, 27.0];

void main() {
  late LocationDb db;
  late FakeWifi wifi;
  late FakeCells cells;
  late FakeGnss gnss;
  late DateTime clock;
  late PositioningEngine engine;

  GnssFix fix(double east, double north, {double speed = 0}) => GnssFix(
    valid: true,
    receivedAt: clock,
    lat: proj.lat(north),
    lon: proj.lon(east),
    accuracyM: 5,
    speedMps: speed,
    time: clock,
    satellitesUsed: sky.length,
    satellites: [
      for (var i = 0; i < sky.length; i++)
        GnssSatellite(
          system: GnssSystem.gps,
          prn: i + 1,
          cn0: sky[i],
          used: true,
        ),
    ],
  );

  void tick([int seconds = 1]) => clock = clock.add(Duration(seconds: seconds));

  setUp(() {
    db = LocationDb.inMemory();
    wifi = FakeWifi();
    cells = FakeCells();
    gnss = FakeGnss();
    clock = DateTime.utc(2026, 11, 26, 12);
    engine = PositioningEngine(
      db: db,
      wifi: wifi,
      cells: cells,
      gnss: gnss,
      now: () => clock,
      // Long timer periods: the test drives the engine by hand.
      config: const PositioningConfig(
        wifiScanInterval: Duration(hours: 1),
        cellPollInterval: Duration(hours: 1),
        outputInterval: Duration(hours: 1),
        // Not about the wait before a new track may teach the database.
        sanity: GnssSanityConfig(settleAfter: Duration.zero),
      ),
    );
    // Four known APs around the origin and the serving cell 400 m away.
    db.upsertExternal([
      for (final (i, e, n) in [
        (1, -40.0, 0.0),
        (2, 40.0, 0.0),
        (3, 0.0, 40.0),
        (4, 0.0, -40.0),
      ])
        TransmitterRecord(
          kind: TransmitterKind.wifi,
          id: mac(i),
          lat: proj.lat(n),
          lon: proj.lon(e),
          accuracyM: 20,
          source: TransmitterSource.apple,
          updated: clock,
        ),
      TransmitterRecord(
        kind: TransmitterKind.cell,
        id: servingCell.key!,
        lat: proj.lat(300),
        lon: proj.lon(260),
        accuracyM: 968,
        source: TransmitterSource.beacondb,
        updated: clock,
      ),
    ]);
  });

  tearDown(() async {
    await engine.dispose();
    await gnss.controller.close();
  });

  test('idle engine has no estimate', () async {
    expect(engine.current, isNull);
    expect(engine.status.running, isFalse);
    expect(engine.status.source, isNull);
    await engine.start();
    expect(engine.isRunning, isTrue);
    expect(gnss.started, isTrue);
    await engine.pollNow();
    expect(engine.current, isNull);
    expect(engine.status.wifiVisible, 0);
    expect(engine.status.gnssHealth.verdict, GnssVerdict.noFix);
  });

  test('cell only -> coarse fix; Wi-Fi refines it; counters follow', () async {
    await engine.start();
    cells.cells = [servingCell];
    await engine.pollNow();
    var e = engine.current!;
    expect(e.source, PositionSource.cell);
    expect(e.accuracyM, greaterThan(400));
    expect(engine.status.cellsVisible, 1);
    expect(engine.status.cellsKnown, 1);

    tick(5);
    wifi.scan = [
      for (var i = 1; i <= 4; i++)
        WifiObservation(bssid: mac(i), signalDbm: -60),
      const WifiObservation(bssid: 'aa:bb:cc:00:00:99', signalDbm: -70),
    ];
    final seen = <PositionEstimate>[];
    final sub = engine.estimates.listen(seen.add);
    await engine.pollNow();
    await Future<void>.delayed(Duration.zero);
    e = engine.current!;
    expect(e.source, PositionSource.wifi);
    expect(haversineM(e.lat, e.lon, lat0, lon0), lessThan(40));
    expect(e.accuracyM, lessThan(100));
    final s = engine.status;
    expect(s.wifiVisible, 5);
    expect(s.wifiKnown, 4);
    expect(s.wifiUsed, 4);
    expect(s.wifiBackend, 'fake');
    expect(s.wifiReportsDbm, isTrue);
    expect(s.estimate, same(e));
    expect(seen.last, same(e));
    expect(wifi.scansRequested, greaterThan(0));
    expect(engine.lastRadioEstimate.cell, isNotNull);
    await sub.cancel();
  });

  test('healthy GNSS takes over and wardriving learns new APs', () async {
    engine.wardriving = true;
    await engine.start();
    expect(engine.status.wardriving, isTrue);
    for (var t = 0; t < 5; t++) {
      gnss.controller.add(fix(0, 0));
      tick();
    }
    wifi.scan = const [
      WifiObservation(bssid: 'aa:bb:cc:00:00:77', signalDbm: -55),
    ];
    cells.cells = [servingCell];
    await engine.pollNow();
    expect(engine.lastSourceError, isNull);
    final e = engine.current!;
    expect(haversineM(e.lat, e.lon, lat0, lon0), lessThan(5));
    expect(e.accuracyM, lessThan(10));
    expect(engine.status.gnssHealth.usable, isTrue);
    expect(engine.status.satellitesInView, 8);
    expect(engine.status.satellitesUsed, 8);
    expect(engine.status.spoofingSuspected, isFalse);

    // The previously unknown AP and the cell were recorded at our position.
    final learnt = db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:77')!;
    expect(learnt.source, TransmitterSource.wardriving);
    expect(haversineM(learnt.lat, learnt.lon, lat0, lon0), lessThan(5));
    expect(engine.status.wardrivingSamples, greaterThanOrEqualTo(2));
    expect(
      db.get(TransmitterKind.cell, servingCell.key!)!.source,
      TransmitterSource.wardriving,
    );
    expect(engine.dbStats().bySource[TransmitterSource.wardriving], 2);

    engine.wardriving = false;
    expect(engine.status.wardriving, isFalse);
  });

  test(
    'spoofed GNSS is flagged, excluded from fusion and from wardriving',
    () async {
      engine.wardriving = true;
      await engine.start();
      wifi.scan = [
        for (var i = 1; i <= 4; i++)
          WifiObservation(bssid: mac(i), signalDbm: -60),
        const WifiObservation(bssid: 'aa:bb:cc:00:00:88', signalDbm: -50),
      ];
      await engine.pollNow();
      expect(engine.current!.source, PositionSource.wifi);

      // The receiver "sees" a perfectly stable fix 6 km away.
      // The contradiction has to last ten seconds.
      for (var t = 0; t < 13; t++) {
        tick();
        gnss.controller.add(fix(6000, 0));
      }
      expect(engine.status.spoofingSuspected, isTrue);
      expect(
        engine.status.gnssHealth.anomalies,
        contains(GnssAnomaly.radioMismatch),
      );
      tick();
      await engine.pollNow();
      final e = engine.current!;
      // Position stays with the radio estimate.
      expect(haversineM(e.lat, e.lon, lat0, lon0), lessThan(60));
      expect(e.source, isNot(PositionSource.gnss));
      // Nothing was learnt at the spoofed location.
      expect(db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:88'), isNull);
      expect(
        db.get(TransmitterKind.wifi, mac(1))!.source,
        TransmitterSource.apple,
      );
    },
  );

  test('with the spoofing check off the receiver is taken at its word, '
      'and nothing is learnt from it', () async {
    engine.wardriving = true;
    engine.spoofingCheck = false;
    await engine.start();
    wifi.scan = [
      for (var i = 1; i <= 4; i++)
        WifiObservation(bssid: mac(i), signalDbm: -60),
      const WifiObservation(bssid: 'aa:bb:cc:00:00:88', signalDbm: -50),
    ];
    await engine.pollNow();
    for (var t = 0; t < 60; t++) {
      tick();
      gnss.controller.add(fix(6000, 0));
    }
    await engine.pollNow();
    expect(engine.status.spoofingCheck, isFalse);
    // The check still has its opinion, for the screen.
    expect(engine.status.spoofingSuspected, isTrue);
    final e = engine.current!;
    expect(haversineM(e.lat, e.lon, lat0, lon0), greaterThan(5000));
    expect(db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:88'), isNull);

    // Switched back on: the satellites are dropped again.
    engine.spoofingCheck = true;
    for (var t = 0; t < 3; t++) {
      tick();
      gnss.controller.add(fix(6000, 0));
    }
    await engine.pollNow();
    final back = engine.current!;
    expect(haversineM(back.lat, back.lon, lat0, lon0), lessThan(100));
  });

  test('external speed input is accepted', () async {
    await engine.start();
    for (var t = 0; t < 5; t++) {
      gnss.controller.add(fix(0, 20.0 * t, speed: 20));
      tick();
    }
    // GNSS gone, OBD keeps reporting 20 m/s.
    for (var t = 0; t < 5; t++) {
      engine.addSpeedSample(20);
      tick();
    }
    await engine.pollNow();
    final e = engine.current!;
    expect(e.source, PositionSource.deadReckoning);
    expect(haversineM(e.lat, e.lon, proj.lat(20.0 * 9), lon0), lessThan(30));
  });

  test('stop / restart / dispose', () async {
    await engine.start();
    await engine.stop();
    expect(engine.isRunning, isFalse);
    expect(gnss.started, isFalse);
    expect(engine.status.running, isFalse);
    await engine.start();
    expect(gnss.started, isTrue);
    await engine.dispose();
    expect(wifi.closed, isTrue);
    await engine.start(); // no-op after dispose
    expect(engine.isRunning, isFalse);
  });

  test('status stream and ChangeNotifier adapter fire on changes', () async {
    final notifier = PositioningNotifier(engine);
    var notified = 0;
    notifier.addListener(() => notified++);
    final statuses = <PositioningStatus>[];
    final sub = engine.statusStream.listen(statuses.add);
    await notifier.start();
    cells.cells = [servingCell];
    await engine.pollNow();
    await Future<void>.delayed(Duration.zero);
    expect(statuses, isNotEmpty);
    expect(statuses.last.cellsKnown, 1);
    expect(notified, statuses.length);
    expect(notifier.estimate, isNotNull);
    expect(notifier.status.running, isTrue);
    engine.onlineLookups = true; // no resolver configured: harmless
    expect(engine.status.onlineLookups, isTrue);
    await sub.cancel();
    notifier.dispose();
  });

  test('preloadRegion without a resolver reports it', () async {
    final p = await engine.preloadRegion(GeoBounds.around(lat0, lon0, 500));
    expect(p.finished, 'noResolver');
  });
}
