// Schema version 2 (seed source), paged reading and deletion by area.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/positioning/geo.dart';
import 'package:mapsoly/positioning/location_db.dart';
import 'package:mapsoly/positioning/models.dart';
import 'package:sqlite3/sqlite3.dart';

final t0 = DateTime.utc(2026, 11, 26, 12);
const lat0 = 59.92, lon0 = 30.65;
final proj = LocalProjection(lat0, lon0);

String mac(int i) => 'aa:bb:cc:00:00:${i.toRadixString(16).padLeft(2, '0')}';

TransmitterRecord rec(
  String id,
  double east,
  double north, {
  TransmitterKind kind = TransmitterKind.wifi,
  TransmitterSource source = TransmitterSource.apple,
}) => TransmitterRecord(
  kind: kind,
  id: id,
  lat: proj.lat(north),
  lon: proj.lon(east),
  accuracyM: 30,
  source: source,
  updated: t0,
);

TransmitterSample smp(
  String id,
  double east,
  double north, {
  TransmitterKind kind = TransmitterKind.wifi,
}) => TransmitterSample(
  kind: kind,
  id: id,
  lat: proj.lat(north),
  lon: proj.lon(east),
  weight: 1,
  fixAccuracyM: 5,
  signalDbm: -60,
  time: t0,
);

void main() {
  group('seed source', () {
    late LocationDb db;
    setUp(() => db = LocationDb.inMemory());
    tearDown(() => db.close());

    test('own, seeded and external records are told apart', () {
      db.upsertExternal([
        rec(mac(1), 0, 0),
        rec(mac(2), 100, 0, source: TransmitterSource.beacondb),
        rec(mac(3), 200, 0, source: TransmitterSource.wigle),
        rec(mac(4), 300, 0),
      ]);
      db.addSamples([
        smp(mac(1), 5, 0),
        smp(mac(2), 105, 0),
        smp(mac(3), 205, 0),
        smp(mac(5), 400, 0),
      ]);
      TransmitterRecord get(int i) => db.get(TransmitterKind.wifi, mac(i))!;

      expect(get(1).source, TransmitterSource.wardriving);
      expect(get(1).seedSource, TransmitterSource.apple);
      expect(get(1).isOwn, isFalse);
      expect(get(2).seedSource, TransmitterSource.beacondb);
      expect(get(2).isOwn, isFalse);
      // A prior from the user's own import does not make it foreign.
      expect(get(3).seedSource, TransmitterSource.wigle);
      expect(get(3).isOwn, isTrue);
      expect(get(4).source, TransmitterSource.apple);
      expect(get(4).seedSource, isNull);
      expect(get(4).isOwn, isFalse);
      expect(get(5).seedSource, isNull);
      expect(get(5).isOwn, isTrue);

      // The seed is remembered through later samples...
      db.addSamples([smp(mac(1), 6, 1), smp(mac(1), 4, -1)]);
      expect(get(1).samples, 4);
      expect(get(1).seedSource, TransmitterSource.apple);
      // ...and forgotten when the estimate restarts (the AP has moved).
      db.addSamples([smp(mac(1), 3000, 0)]);
      expect(get(1).samples, 1);
      expect(get(1).seedSource, isNull);
      expect(get(1).isOwn, isTrue);
    });
  });

  group('migration', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('mapsoly-db-'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('a version 1 database stays readable and gains the column', () {
      final path = '${dir.path}/positioning.sqlite';
      LocationDb.inMemory().close(); // sets up the SQLite library loader
      // Exactly what schema version 1 created.
      final old = sqlite3.open(path);
      old.execute('''
        CREATE TABLE transmitter(
          kind INTEGER NOT NULL, id TEXT NOT NULL, lat REAL NOT NULL,
          lon REAL NOT NULL, accuracy REAL NOT NULL,
          samples INTEGER NOT NULL DEFAULT 1, wsum REAL NOT NULL DEFAULT 0,
          scatter REAL NOT NULL DEFAULT 0, best_signal REAL, best_range REAL,
          source INTEGER NOT NULL, updated INTEGER NOT NULL,
          PRIMARY KEY(kind, id)
        ) WITHOUT ROWID''');
      old.execute('CREATE INDEX transmitter_pos ON transmitter(lat, lon)');
      old.execute('''
        CREATE TABLE sample(kind INTEGER NOT NULL, id TEXT NOT NULL,
          lat REAL NOT NULL, lon REAL NOT NULL, fix_accuracy REAL NOT NULL,
          signal REAL, time INTEGER NOT NULL)''');
      old.execute('CREATE INDEX sample_id ON sample(kind, id)');
      old.execute('''
        CREATE TABLE unknown(kind INTEGER NOT NULL, id TEXT NOT NULL,
          checked INTEGER NOT NULL, PRIMARY KEY(kind, id)) WITHOUT ROWID''');
      final stamp = t0.millisecondsSinceEpoch ~/ 1000;
      old.execute(
        'INSERT INTO transmitter VALUES(0, ?, ?, ?, 12.5, 7, 3.5, 40.0, -48, '
        '9.0, 0, ?)',
        [mac(1), lat0, lon0, stamp],
      );
      old.execute(
        'INSERT INTO transmitter VALUES(0, ?, ?, ?, 25, 1, 0, 0, NULL, NULL, '
        '4, ?)',
        [mac(2), proj.lat(50), lon0, stamp],
      );
      old.execute('INSERT INTO sample VALUES(0, ?, ?, ?, 5, -48, ?)', [
        mac(1),
        lat0,
        lon0,
        stamp,
      ]);
      old.execute('INSERT INTO unknown VALUES(0, ?, ?)', [mac(9), stamp]);
      old.execute('PRAGMA user_version = 1');
      old.dispose();

      var db = LocationDb.open(path);
      final own = db.get(TransmitterKind.wifi, mac(1))!;
      expect(own.lat, lat0);
      expect(own.accuracyM, 12.5);
      expect(own.samples, 7);
      expect(own.bestSignalDbm, -48);
      expect(own.source, TransmitterSource.wardriving);
      expect(own.updated, t0);
      // Not recorded before version 2: taken as the user's own.
      expect(own.seedSource, isNull);
      expect(own.isOwn, isTrue);
      expect(
        db.get(TransmitterKind.wifi, mac(2))!.source,
        TransmitterSource.apple,
      );
      expect(db.stats().rawSamples, 1);
      expect(db.recentlyUnknown(TransmitterKind.wifi, [mac(9)], t0), {mac(9)});
      // Writing works, old running state included.
      db.addSamples([smp(mac(1), 2, 0), smp(mac(2), 3, 50)]);
      expect(db.get(TransmitterKind.wifi, mac(1))!.samples, 8);
      expect(
        db.get(TransmitterKind.wifi, mac(2))!.seedSource,
        TransmitterSource.apple,
      );
      db.close();

      // Opening again does not migrate twice.
      db = LocationDb.open(path);
      expect(db.stats().total, 2);
      db.close();
      final raw = sqlite3.open(path);
      expect(raw.select('PRAGMA user_version').first.values.first, 2);
      expect(
        raw
            .select('PRAGMA table_info(transmitter)')
            .where((r) => r['name'] == 'seed_source'),
        hasLength(1),
      );
      raw.dispose();
    });
  });

  group('records()', () {
    late LocationDb db;
    setUp(() => db = LocationDb.inMemory());
    tearDown(() => db.close());

    test('pages through everything exactly once, optionally by source', () {
      db.upsertExternal([
        for (var i = 0; i < 95; i++) rec(mac(i), i * 10.0, 0),
        for (var i = 0; i < 7; i++)
          rec('lte:999:7:1:$i', 0, i * 10.0, kind: TransmitterKind.cell),
      ]);
      db.addSamples([
        for (var i = 100; i < 131; i++) smp(mac(i), i * 10.0, 0),
        smp(mac(200), 0, 0, kind: TransmitterKind.ble),
      ]);
      for (final pageSize in [1, 7, 10, 134, 135, 5000]) {
        final all = db.records(pageSize: pageSize).toList();
        expect(all, hasLength(134), reason: 'page $pageSize');
        expect({
          for (final r in all) '${r.kind.index}|${r.id}',
        }, hasLength(134));
        expect(
          db
              .records(source: TransmitterSource.wardriving, pageSize: pageSize)
              .length,
          32,
        );
      }
      expect(db.records(source: TransmitterSource.csv), isEmpty);
    });
  });

  group('deleteWithin', () {
    late LocationDb db;
    setUp(() => db = LocationDb.inMemory());
    tearDown(() => db.close());

    (double, double, double) circle(double east, double north, double r) =>
        (proj.lat(north), proj.lon(east), r);

    test('by exact distance, by source, raw samples included', () {
      db.upsertExternal([rec(mac(1), 50, 0), rec(mac(2), 0, 400)]);
      db.addSamples([
        smp(mac(3), 0, 0),
        smp(mac(4), 290, 0),
        smp(mac(5), 310, 0),
        // Inside the bounding box of the circle, outside the circle.
        smp(mac(6), 250, 250),
        smp('lte:999:7:1:1', -100, 100, kind: TransmitterKind.cell),
      ], keepRawSamples: true);
      final zone = [circle(0, 0, 300)];
      const own = {TransmitterSource.wardriving};

      expect(db.deleteWithin(zone, sources: own, dryRun: true), (3, 3));
      expect(db.deleteWithin(zone, dryRun: true), (4, 3));
      expect(db.stats().total, 7);
      expect(db.stats().rawSamples, 5);
      // Only the Apple record: raw samples are wardriving data.
      expect(
        db.deleteWithin(zone, sources: {TransmitterSource.apple}, dryRun: true),
        (1, 0),
      );

      expect(db.deleteWithin(zone, sources: own), (3, 3));
      expect(db.get(TransmitterKind.wifi, mac(3)), isNull);
      expect(db.get(TransmitterKind.wifi, mac(4)), isNull);
      expect(db.get(TransmitterKind.cell, 'lte:999:7:1:1'), isNull);
      expect(db.get(TransmitterKind.wifi, mac(1)), isNotNull);
      expect(db.get(TransmitterKind.wifi, mac(5)), isNotNull);
      expect(db.get(TransmitterKind.wifi, mac(6)), isNotNull);
      expect(db.stats().rawSamples, 2);
      expect(db.deleteWithin(zone, sources: own), (0, 0));
      expect(db.deleteWithin(const []), (0, 0));
    });

    test('overlapping circles count once; the antimeridian is handled', () {
      db.addSamples([smp(mac(1), 0, 0), smp(mac(2), 500, 0)]);
      expect(
        db.deleteWithin([
          circle(0, 0, 100),
          circle(30, 0, 100),
          circle(480, 0, 100),
        ], dryRun: true),
        (2, 0),
      );
      db.upsertExternal([
        TransmitterRecord(
          kind: TransmitterKind.wifi,
          id: mac(7),
          lat: 10,
          lon: -179.9995,
          accuracyM: 20,
          source: TransmitterSource.csv,
          updated: t0,
        ),
      ]);
      expect(db.deleteWithin([(10.0, 179.9995, 200.0)]), (1, 0));
    });
  });
}
