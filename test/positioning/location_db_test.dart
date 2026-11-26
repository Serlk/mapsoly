import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/positioning/geo.dart';
import 'package:mapsoly/positioning/importers.dart';
import 'package:mapsoly/positioning/location_db.dart';
import 'package:mapsoly/positioning/models.dart';
import 'package:mapsoly/positioning/wardriving.dart';

final t0 = DateTime.utc(2026, 11, 26, 12);
const lat0 = 59.92, lon0 = 30.65;
final proj = LocalProjection(lat0, lon0);

TransmitterRecord rec(
  String id, {
  TransmitterKind kind = TransmitterKind.wifi,
  double lat = lat0,
  double lon = lon0,
  double acc = 30,
  TransmitterSource source = TransmitterSource.apple,
}) => TransmitterRecord(
  kind: kind,
  id: id,
  lat: lat,
  lon: lon,
  accuracyM: acc,
  source: source,
  updated: t0,
);

void main() {
  late LocationDb db;
  setUp(() => db = LocationDb.inMemory());
  tearDown(() => db.close());

  group('LocationDb', () {
    test('round trip, bulk lookup and stats', () {
      final n = db.upsertExternal([
        rec('aa:bb:cc:00:00:01'),
        rec('aa:bb:cc:00:00:02', lat: 59.93, acc: 55),
        rec(
          'lte:250:20:8000:27440068',
          kind: TransmitterKind.cell,
          acc: 968,
          source: TransmitterSource.beacondb,
        ),
        rec('c0:ff:ee:00:00:01', kind: TransmitterKind.ble),
      ]);
      expect(n, 4);
      final got = db.lookup(TransmitterKind.wifi, [
        'aa:bb:cc:00:00:01',
        'aa:bb:cc:00:00:02',
        'aa:bb:cc:00:00:03',
        'lte:250:20:8000:27440068', // wrong kind: must not match
      ]);
      expect(
        got.keys,
        unorderedEquals(['aa:bb:cc:00:00:01', 'aa:bb:cc:00:00:02']),
      );
      final r = got['aa:bb:cc:00:00:02']!;
      expect(r.lat, 59.93);
      expect(r.lon, lon0);
      expect(r.accuracyM, 55);
      expect(r.source, TransmitterSource.apple);
      expect(r.updated, t0);
      expect(
        db.get(TransmitterKind.cell, 'lte:250:20:8000:27440068')!.accuracyM,
        968,
      );
      final s = db.stats();
      expect(s.wifi, 2);
      expect(s.cells, 1);
      expect(s.ble, 1);
      expect(s.total, 4);
      expect(s.bySource[TransmitterSource.apple], 3);
      expect(s.bySource[TransmitterSource.beacondb], 1);
    });

    test('lookup of thousands of ids is chunked', () {
      db.upsertExternal([
        for (var i = 0; i < 3000; i++)
          rec(
            '02:00:00:${(i >> 8).toRadixString(16).padLeft(2, '0')}:'
            '${(i & 255).toRadixString(16).padLeft(2, '0')}:00',
          ),
      ]);
      final ids = [
        for (var i = 0; i < 4000; i++)
          '02:00:00:${(i >> 8).toRadixString(16).padLeft(2, '0')}:'
              '${(i & 255).toRadixString(16).padLeft(2, '0')}:00',
      ];
      expect(db.lookup(TransmitterKind.wifi, ids).length, 3000);
    });

    test('implausible coordinates are refused', () {
      expect(
        db.upsertExternal([
          rec('aa:bb:cc:00:00:01', lat: 0, lon: 0),
          rec('aa:bb:cc:00:00:02', lat: -180, lon: -180),
          rec('aa:bb:cc:00:00:03', lat: double.nan),
        ]),
        0,
      );
      expect(db.stats().total, 0);
    });

    test('source priority: wardriving beats imports beats online', () {
      const id = 'aa:bb:cc:00:00:01';
      db.upsertExternal([rec(id, lat: 59.0, source: TransmitterSource.wigle)]);
      // A less trusted source does not overwrite.
      expect(db.upsertExternal([rec(id, lat: 58.0)]), 0);
      expect(db.get(TransmitterKind.wifi, id)!.lat, 59.0);
      // The same or a more trusted one does.
      expect(
        db.upsertExternal([
          rec(id, lat: 57.0, source: TransmitterSource.wigle),
        ]),
        1,
      );
      expect(db.get(TransmitterKind.wifi, id)!.lat, 57.0);
      expect(db.deleteBySource(TransmitterSource.wigle), 1);
      expect(db.get(TransmitterKind.wifi, id), isNull);
    });

    test('bounding box query', () {
      db.upsertExternal([
        rec('aa:bb:cc:00:00:01', lat: 59.92, lon: 30.65),
        rec('aa:bb:cc:00:00:02', lat: 59.95, lon: 30.65),
        rec('aa:bb:cc:00:00:03', lat: 59.92, lon: 30.80),
        rec(
          'lte:1:1:1:1',
          kind: TransmitterKind.cell,
          lat: 59.921,
          lon: 30.651,
        ),
      ]);
      final all = db.inBounds(
        south: 59.9,
        west: 30.6,
        north: 59.93,
        east: 30.7,
      );
      expect(
        all.map((r) => r.id),
        unorderedEquals(['aa:bb:cc:00:00:01', 'lte:1:1:1:1']),
      );
      expect(
        db
            .inBounds(
              south: 59.9,
              west: 30.6,
              north: 59.93,
              east: 30.7,
              kind: TransmitterKind.wifi,
            )
            .single
            .id,
        'aa:bb:cc:00:00:01',
      );
    });

    test('negative cache expires and is cleared by a positive answer', () {
      const ids = ['aa:bb:cc:00:00:01', 'aa:bb:cc:00:00:02'];
      db.markUnknown(TransmitterKind.wifi, ids, t0);
      expect(db.recentlyUnknown(TransmitterKind.wifi, ids, t0), ids.toSet());
      expect(db.recentlyUnknown(TransmitterKind.cell, ids, t0), isEmpty);
      expect(
        db.recentlyUnknown(
          TransmitterKind.wifi,
          ids,
          t0.add(negativeCacheTtl + const Duration(hours: 1)),
        ),
        isEmpty,
      );
      db.upsertExternal([rec(ids[0])]);
      expect(db.recentlyUnknown(TransmitterKind.wifi, ids, t0), {ids[1]});
    });

    test('file database persists across reopen', () {
      final dir = Directory.systemTemp.createTempSync('mapsoly_db_test');
      try {
        final path = '${dir.path}/pos.db';
        final a = LocationDb.open(path);
        a.upsertExternal([rec('aa:bb:cc:00:00:01')]);
        a.close();
        final b = LocationDb.open(path);
        expect(b.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:01'), isNotNull);
        expect(b.stats().fileBytes, greaterThan(0));
        b.close();
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('wardriving upsert', () {
    TransmitterSample sample(
      double east,
      double north,
      double weight, {
      String id = 'aa:bb:cc:00:00:01',
      double? dbm,
      double? range,
      TransmitterKind kind = TransmitterKind.wifi,
    }) => TransmitterSample(
      kind: kind,
      id: id,
      lat: proj.lat(north),
      lon: proj.lon(east),
      weight: weight,
      fixAccuracyM: 5,
      signalDbm: dbm,
      rangeM: range,
      time: t0,
    );

    test('running weighted mean equals the batch weighted mean', () {
      final pts = [
        (0.0, 0.0, 1.0),
        (40.0, 0.0, 4.0),
        (40.0, 30.0, 2.0),
        (10.0, 50.0, 0.5),
      ];
      for (final (e, n, w) in pts) {
        db.addSamples([sample(e, n, w)]);
      }
      var sw = 0.0, se = 0.0, sn = 0.0;
      for (final (e, n, w) in pts) {
        sw += w;
        se += w * e;
        sn += w * n;
      }
      final r = db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:01')!;
      expect(proj.x(r.lon), closeTo(se / sw, 0.01));
      expect(proj.y(r.lat), closeTo(sn / sw, 0.01));
      expect(r.samples, 4);
      expect(r.weightSum, closeTo(sw, 1e-9));
      expect(r.source, TransmitterSource.wardriving);
      // Weighted scatter of the points plus the 5 m fix accuracy.
      var s2 = 0.0;
      for (final (e, n, w) in pts) {
        s2 +=
            w * ((e - se / sw) * (e - se / sw) + (n - sn / sw) * (n - sn / sw));
      }
      expect(r.scatterM2, closeTo(s2 + sw * 25, 0.5));
      expect(r.accuracyM, closeTo(math.sqrt((s2 + sw * 25) / sw), 0.05));
    });

    test('accuracy includes the best range and has a floor', () {
      db.addSamples([sample(0, 0, 1, dbm: -80, range: 30)]);
      var r = db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:01')!;
      expect(r.accuracyM, closeTo(math.sqrt(25 + 900), 0.01));
      expect(r.bestSignalDbm, -80);
      // Walking right past the AP shrinks the range term.
      db.addSamples([sample(1, 1, 50, dbm: -45, range: 1.5)]);
      r = db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:01')!;
      expect(r.bestSignalDbm, -45);
      expect(r.accuracyM, lessThan(12));
      expect(r.accuracyM, greaterThanOrEqualTo(minWifiAccuracyM));
      // Cells have a much larger floor.
      db.addSamples([
        sample(0, 0, 1, id: 'lte:1:1:1:1', kind: TransmitterKind.cell),
      ]);
      expect(
        db.get(TransmitterKind.cell, 'lte:1:1:1:1')!.accuracyM,
        minCellAccuracyM,
      );
    });

    test('a moved AP restarts its estimate', () {
      for (var i = 0; i < 10; i++) {
        db.addSamples([sample(i.toDouble(), 0, 1)]);
      }
      db.addSamples([sample(5000, 0, 1)]);
      final r = db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:01')!;
      expect(proj.x(r.lon), closeTo(5000, 0.5));
      expect(r.samples, 1);
    });

    test('external record is only a weak prior for own measurements', () {
      db.upsertExternal([rec('aa:bb:cc:00:00:01')]); // at the origin
      db.addSamples([sample(100, 0, 1)]);
      var r = db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:01')!;
      expect(proj.x(r.lon), closeTo(50, 0.1));
      expect(r.source, TransmitterSource.wardriving);
      db.addSamples([sample(100, 0, 1), sample(100, 0, 1)]);
      r = db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:01')!;
      expect(proj.x(r.lon), closeTo(75, 0.1));
      // And Apple can no longer overwrite it.
      expect(db.upsertExternal([rec('aa:bb:cc:00:00:01')]), 0);
    });

    test('raw samples are kept only on request', () {
      db.addSamples([sample(0, 0, 1)]);
      expect(db.stats().rawSamples, 0);
      db.addSamples([sample(1, 0, 1), sample(2, 0, 1)], keepRawSamples: true);
      expect(db.stats().rawSamples, 2);
    });
  });

  group('WardrivingCollector', () {
    GnssFix fix(double t, double east, {double acc = 5, double? speed}) =>
        GnssFix(
          valid: true,
          receivedAt: t0.add(Duration(milliseconds: (t * 1000).round())),
          lat: lat0,
          lon: proj.lon(east),
          accuracyM: acc,
          speedMps: speed,
        );

    test('positions observations at their own time (interpolated)', () {
      final c = WardrivingCollector(db);
      // Driving east at 20 m/s.
      for (var t = 0; t <= 10; t++) {
        c.addFix(fix(t.toDouble(), 20.0 * t, speed: 20));
      }
      final now = t0.add(const Duration(seconds: 10));
      final n = c.addWifi([
        // Heard 4.5 s ago -> we were at x = 110 m.
        const WifiObservation(
          bssid: 'aa:bb:cc:00:00:01',
          signalDbm: -60,
          age: Duration(milliseconds: 4500),
        ),
        const WifiObservation(bssid: 'aa:bb:cc:00:00:02', signalDbm: -70),
        // Too old to place.
        const WifiObservation(
          bssid: 'aa:bb:cc:00:00:03',
          signalDbm: -50,
          age: Duration(seconds: 40),
        ),
        const WifiObservation(
          bssid: 'aa:bb:cc:00:00:04',
          signalDbm: -50,
          ssid: 'private_nomap',
        ),
      ], now);
      expect(n, 2);
      expect(
        proj.x(db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:01')!.lon),
        closeTo(110, 0.5),
      );
      expect(
        proj.x(db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:02')!.lon),
        closeTo(200, 0.5),
      );
      expect(db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:03'), isNull);
      expect(db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:04'), isNull);
      expect(c.samplesWritten, 2);
    });

    test('strong samples dominate the estimate (AP at x = 100)', () {
      final c = WardrivingCollector(db);
      // Drive past an AP at x = 100 m, 10 m off the road.
      for (var t = 0; t <= 20; t++) {
        final x = 10.0 * t;
        c.addFix(fix(t.toDouble(), x, speed: 10));
        final d = math.sqrt((x - 100) * (x - 100) + 100);
        final dbm = -40 - 27 * math.log(d) / math.ln10;
        c.addWifi([
          WifiObservation(bssid: 'aa:bb:cc:00:00:01', signalDbm: dbm),
        ], t0.add(Duration(seconds: t)));
      }
      final r = db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:01')!;
      expect(proj.x(r.lon), closeTo(100, 8));
      expect(r.samples, 21);
      expect(r.accuracyM, lessThan(40));
    });

    test('no trusted fix -> nothing is recorded', () {
      final c = WardrivingCollector(db);
      const scan = [
        WifiObservation(bssid: 'aa:bb:cc:00:00:01', signalDbm: -60),
      ];
      expect(c.addWifi(scan, t0), 0);
      c.addFix(fix(0, 0, acc: 80)); // too inaccurate
      c.addFix(GnssFix(valid: false, receivedAt: t0));
      expect(c.addWifi(scan, t0), 0);
      c.addFix(fix(0, 0));
      // Fix is 30 s old by the time of the scan.
      expect(c.addWifi(scan, t0.add(const Duration(seconds: 30))), 0);
      expect(c.addWifi(scan, t0.add(const Duration(seconds: 1))), 1);
      // Standing still: the same AP is not sampled again...
      expect(c.addWifi(scan, t0.add(const Duration(seconds: 2))), 0);
      // ...unless it got clearly stronger.
      expect(
        c.addWifi(const [
          WifiObservation(bssid: 'aa:bb:cc:00:00:01', signalDbm: -50),
        ], t0.add(const Duration(seconds: 2))),
        1,
      );
      c.reset();
      expect(c.addWifi(scan, t0.add(const Duration(seconds: 2))), 0);
      expect(db.stats().wifi, 1);
    });

    test('cells need a full identity', () {
      final c = WardrivingCollector(db)..addFix(fix(0, 0));
      final n = c.addCells(const [
        CellObservation(
          radio: RadioType.lte,
          mcc: 250,
          mnc: 20,
          area: 8000,
          cellId: 27440068,
          serving: true,
          signalDbm: -95,
          timingAdvance: 4,
        ),
        CellObservation(
          radio: RadioType.lte,
          pci: 26,
          arfcn: 3048,
          signalDbm: -108,
        ),
      ], t0);
      expect(n, 1);
      final r = db.get(TransmitterKind.cell, 'lte:250:20:8000:27440068')!;
      // range 4 * 78.12 = 312 m dominates the accuracy
      expect(r.accuracyM, closeTo(312.5, 1));
    });
  });

  group('WiGLE CSV import', () {
    // Layout of the WiGLE Android app export, format 1.4 (one row per
    // observation), including the things that make naive parsers trip:
    // a comma inside an SSID (unquoted, as the app writes it), a quoted
    // SSID, an empty SSID, GSM/LTE rows and a BT row.
    const wigle14 = '''
WigleWifi-1.4,appRelease=2.53,model=Pixel 4a,release=11,device=sunfish,display=RQ3A.210805.001,board=sunfish,brand=google
MAC,SSID,AuthMode,FirstSeen,Channel,RSSI,CurrentLatitude,CurrentLongitude,AltitudeMeters,AccuracyMeters,Type
AA:BB:CC:00:00:01,HomeNet,[WPA2-PSK-CCMP][ESS],2021-05-01 10:00:00,6,-80,59.920000,30.650000,12,4,WIFI
AA:BB:CC:00:00:01,HomeNet,[WPA2-PSK-CCMP][ESS],2021-05-01 10:00:05,6,-50,59.920300,30.650000,12,4,WIFI
AA:BB:CC:00:00:01,HomeNet,[WPA2-PSK-CCMP][ESS],2021-05-01 10:00:10,6,-82,59.920600,30.650000,12,4,WIFI
AA:BB:CC:00:00:02,Cafe, free wifi,[ESS],2021-05-01 10:00:10,36,-70,59.921000,30.651000,12,6,WIFI
AA:BB:CC:00:00:03,"Quoted, ""SSID""",[WPA2-PSK-CCMP][ESS],2021-05-01 10:00:11,11,-71,59.922000,30.652000,12,6,WIFI
AA:BB:CC:00:00:04,,[ESS],2021-05-01 10:00:12,1,-90,59.923000,30.653000,12,120,WIFI
AA:BB:CC:00:00:05,hidden_nomap,[ESS],2021-05-01 10:00:12,1,-60,59.923000,30.653000,12,5,WIFI
AA:BB:CC:00:00:06,ZeroIsland,[ESS],2021-05-01 10:00:12,1,-60,0.0,0.0,0,5,WIFI
25020_8000_27440068,t2 rus,LTE;25020,2021-05-01 10:00:13,1300,-97,59.920000,30.650000,12,5,LTE
25020_8000_27440068,t2 rus,LTE;25020,2021-05-01 10:01:13,1300,-99,59.924000,30.650000,12,5,LTE
310260_8000_11111,T-Mobile,GSM;310260,2021-05-01 10:00:13,62,-85,59.920000,30.650000,12,5,GSM
C0:FF:EE:00:00:01,Beacon,Misc [LE],2021-05-01 10:00:14,0,-75,59.920100,30.650100,12,5,BLE
11:22:33:44:55:66,Headset,Audio/Video [BT],2021-05-01 10:00:14,0,-60,59.920100,30.650100,12,5,BT
broken line
''';

    test('1.4 layout', () async {
      final r = await importWigleCsv(
        db,
        Stream.fromIterable(wigle14.trim().split('\n')),
        now: t0,
      );
      expect(r.rows, 14);
      // accuracy 120 m, _nomap, 0/0, BT, broken line
      expect(r.skipped, 5);
      expect(r.transmitters, 6);
      expect(r.written, 6);

      final a = db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:01')!;
      expect(a.samples, 3);
      expect(a.source, TransmitterSource.wigle);
      expect(a.bestSignalDbm, -50);
      // The -50 dBm row (2.3 m away) outweighs the two -80 dBm rows.
      expect(a.lat, closeTo(59.9203, 0.00005));
      expect(a.accuracyM, lessThan(25));

      expect(db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:02')!.lat, 59.921);
      expect(db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:03')!.lon, 30.652);
      expect(db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:04'), isNull);
      expect(db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:05'), isNull);
      expect(db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:06'), isNull);

      final cell = db.get(TransmitterKind.cell, 'lte:250:20:8000:27440068')!;
      expect(cell.samples, 2);
      expect(cell.lat, closeTo(59.922, 1e-6)); // unweighted centroid
      expect(cell.accuracyM, greaterThanOrEqualTo(minCellAccuracyM));
      expect(db.get(TransmitterKind.cell, 'gsm:310:260:8000:11111'), isNotNull);
      expect(db.get(TransmitterKind.ble, 'c0:ff:ee:00:00:01'), isNotNull);
      expect(db.stats().total, 6);
    });

    test('1.6 layout (Frequency, RCOIs, MfgrId columns)', () async {
      const csv = '''
WigleWifi-1.6,appRelease=2.86,model=Pixel 8,release=14,device=shiba,display=UQ1A,board=shiba,brand=google,star=Sol,body=3,subBody=0
MAC,SSID,AuthMode,FirstSeen,Channel,Frequency,RSSI,CurrentLatitude,CurrentLongitude,AltitudeMeters,AccuracyMeters,RCOIs,MfgrId,Type
aa:bb:cc:00:00:01,Net5,[WPA2-PSK-CCMP][ESS],2024-05-01 10:00:00,36,5180,-60,59.920000,30.650000,12,4,,,WIFI
c0:ff:ee:00:00:01,Tag,Misc [LE],2024-05-01 10:00:00,0,,-80,59.920000,30.650000,12,4,,76,BLE
250020_8000_27440068,t2,LTE;25020,2024-05-01 10:00:13,1300,,-97,59.920000,30.650000,12,5,,,LTE
''';
      final r = await importWigleCsv(
        db,
        Stream.fromIterable(csv.trim().split('\n')),
      );
      expect(r.rows, 3);
      expect(r.skipped, 0);
      expect(
        db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:01')!.bestSignalDbm,
        -60,
      );
      expect(db.get(TransmitterKind.ble, 'c0:ff:ee:00:00:01'), isNotNull);
      // 6-digit operator: MCC 250, MNC 020.
      expect(
        db.get(TransmitterKind.cell, 'lte:250:20:8000:27440068'),
        isNotNull,
      );
    });

    test('does not overwrite own wardriving data', () async {
      db.addSamples([
        TransmitterSample(
          kind: TransmitterKind.wifi,
          id: 'aa:bb:cc:00:00:01',
          lat: 10,
          lon: 10,
          weight: 1,
          fixAccuracyM: 5,
          time: t0,
        ),
      ]);
      final r = await importWigleCsv(
        db,
        Stream.fromIterable(wigle14.trim().split('\n')),
      );
      expect(r.transmitters, 6);
      expect(r.written, 5);
      expect(db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:01')!.lat, 10);
    });

    test('rejects files that are not WiGLE exports', () async {
      await expectLater(
        importWigleCsv(db, Stream.fromIterable(['a,b,c', '1,2,3'])),
        throwsFormatException,
      );
      await expectLater(
        importWigleCsv(db, const Stream.empty()),
        throwsFormatException,
      );
    });

    test('reads from a file', () async {
      final dir = Directory.systemTemp.createTempSync('mapsoly_wigle_test');
      try {
        final f = File('${dir.path}/w.csv')..writeAsStringSync(wigle14.trim());
        final r = await importWigleCsv(db, csvLines(f));
        expect(r.written, 6);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('generic CSV import', () {
    test('Wi-Fi / BLE positions', () async {
      final r = await importGenericCsv(
        db,
        Stream.fromIterable([
          'BSSID,Lat,Lon,Accuracy,Type',
          'AA-BB-CC-00-00-01,59.92,30.65,25,wifi',
          'aabbcc000002,59.93,30.66,,',
          'c0:ff:ee:00:00:01,59.94,30.67,8,ble',
          'not-a-mac,59.94,30.67,8,wifi',
          'aa:bb:cc:00:00:09,,30.67,8,wifi',
        ]),
      );
      expect(r.rows, 5);
      expect(r.skipped, 2);
      expect(r.written, 3);
      expect(db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:01')!.accuracyM, 25);
      final b = db.get(TransmitterKind.wifi, 'aa:bb:cc:00:00:02')!;
      expect(b.accuracyM, 50); // default
      expect(b.source, TransmitterSource.csv);
      expect(db.get(TransmitterKind.ble, 'c0:ff:ee:00:00:01')!.accuracyM, 8);
    });

    test('MLS / OpenCelliD cell export layout', () async {
      final r = await importGenericCsv(
        db,
        Stream.fromIterable([
          'radio,mcc,net,area,cell,unit,lon,lat,range,samples,changeable,created,updated,averageSignal',
          'LTE,250,20,8000,27440068,301,30.65,59.92,968,14,1,1700000000,1700000000,0',
          'GSM,250,1,8000,11111,,30.60,59.90,2500,3,1,1700000000,1700000000,0',
          'CDMA,310,1,1,1,,30.60,59.90,2500,3,1,1700000000,1700000000,0',
        ]),
      );
      expect(r.written, 2);
      expect(r.skipped, 1);
      final c = db.get(TransmitterKind.cell, 'lte:250:20:8000:27440068')!;
      expect(c.lat, 59.92);
      expect(c.lon, 30.65);
      expect(c.accuracyM, 968);
      expect(c.samples, 14);
    });
  });

  test('splitCsvLine', () {
    expect(splitCsvLine('a,b,,d'), ['a', 'b', '', 'd']);
    expect(splitCsvLine('a,"b,c",d'), ['a', 'b,c', 'd']);
    expect(splitCsvLine('a,"say ""hi""",d'), ['a', 'say "hi"', 'd']);
    expect(splitCsvLine(''), ['']);
  });
}
