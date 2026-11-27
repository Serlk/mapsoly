import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/positioning/location_db.dart';
import 'package:mapsoly/positioning/models.dart';

final t0 = DateTime.utc(2026, 11, 27, 12);

/// One own observation of a transmitter: it becomes a wardriving record.
TransmitterSample seen(
  String id,
  double lat,
  double lon, {
  TransmitterKind kind = TransmitterKind.wifi,
  double? dbm = -60,
}) => TransmitterSample(
  kind: kind,
  id: id,
  lat: lat,
  lon: lon,
  weight: 1,
  fixAccuracyM: 5,
  signalDbm: dbm,
  time: t0,
);

void main() {
  late LocationDb db;
  setUp(() => db = LocationDb.inMemory());
  tearDown(() => db.close());

  List<TransmitterCell> grid({
    double south = 10,
    double west = 20,
    double north = 11,
    double east = 21,
    double step = 0.01,
    int limit = 4000,
  }) => db.wardrivingGrid(
    south: south,
    west: west,
    north: north,
    east: east,
    latStep: step,
    lonStep: step,
    limit: limit,
  );

  group('wardrivingGrid', () {
    test('an empty database gives nothing', () {
      expect(grid(), isEmpty);
    });

    test('transmitters of one cell are gathered, by kind', () {
      db.addSamples([
        seen('aa:bb:cc:00:00:01', 10.5001, 20.5001, dbm: -70),
        seen('aa:bb:cc:00:00:02', 10.5003, 20.5003, dbm: -45),
        seen(
          'lte:999:99:100:1',
          10.5002,
          20.5002,
          kind: TransmitterKind.cell,
          dbm: -95,
        ),
        seen('c0:ff:ee:00:00:01', 10.5002, 20.5002, kind: TransmitterKind.ble),
        // Another cell of the grid, two steps east.
        seen('aa:bb:cc:00:00:03', 10.5001, 20.5201, dbm: null),
      ]);
      final cells = grid()..sort((a, b) => a.lon.compareTo(b.lon));
      expect(cells, hasLength(2));
      final c = cells.first;
      expect((c.wifi, c.cells, c.ble), (2, 1, 1));
      expect(c.bestWifiDbm, -45);
      expect(c.bestCellDbm, -95);
      expect(c.bestBleDbm, -60);
      // At the mean position of its four transmitters.
      expect(c.lat, closeTo(10.5002, 1e-6));
      expect(c.lon, closeTo(20.5002, 1e-6));
      final other = cells.last;
      expect((other.wifi, other.cells, other.ble), (1, 0, 0));
      expect(other.bestWifiDbm, isNull);
      expect(other.lon, closeTo(20.5201, 1e-6));
    });

    test('a coarser grid merges cells; the counts stay', () {
      db.addSamples([
        for (var i = 0; i < 40; i++)
          seen(
            'aa:bb:cc:00:01:${i.toRadixString(16).padLeft(2, '0')}',
            10.2 + i * 0.01,
            20.2 + i * 0.01,
          ),
      ]);
      final fine = grid();
      expect(fine, hasLength(40));
      final coarse = grid(step: 0.1);
      expect(coarse.length, inInclusiveRange(4, 8));
      expect(coarse.fold(0, (n, c) => n + c.wifi), 40);
    });

    test('only what lies in the box', () {
      db.addSamples([
        seen('aa:bb:cc:00:00:01', 10.5, 20.5),
        seen('aa:bb:cc:00:00:02', 12.5, 20.5),
        seen('aa:bb:cc:00:00:03', 10.5, 22.5),
      ]);
      expect(grid().single.wifi, 1);
      expect(grid(north: 13, east: 23), hasLength(3));
    });

    test('only the own collection, not imported records', () {
      db.upsertExternal([
        for (final source in [
          TransmitterSource.apple,
          TransmitterSource.beacondb,
          TransmitterSource.wigle,
          TransmitterSource.csv,
        ])
          TransmitterRecord(
            kind: TransmitterKind.wifi,
            id: 'aa:bb:cc:00:02:0${source.index}',
            lat: 10.5,
            lon: 20.5,
            accuracyM: 30,
            source: source,
            updated: t0,
          ),
      ]);
      expect(grid(), isEmpty);
      db.addSamples([seen('aa:bb:cc:00:00:01', 10.7, 20.7)]);
      expect(grid().single.wifi, 1);
    });

    test('the limit caps the number of cells', () {
      db.addSamples([
        for (var i = 0; i < 30; i++)
          seen(
            'aa:bb:cc:00:03:${i.toRadixString(16).padLeft(2, '0')}',
            10.1 + i * 0.02,
            20.5,
          ),
      ]);
      expect(grid(limit: 7), hasLength(7));
    });

    test('countInBounds: every source, in the box, up to the limit', () {
      db.addSamples([
        seen('aa:bb:cc:00:00:01', 10.5, 20.5),
        seen('aa:bb:cc:00:00:02', 10.6, 20.6, kind: TransmitterKind.ble),
        seen('aa:bb:cc:00:00:03', 12.5, 20.5),
      ]);
      db.upsertExternal([
        TransmitterRecord(
          kind: TransmitterKind.cell,
          id: 'lte:999:99:100:2',
          lat: 10.7,
          lon: 20.7,
          accuracyM: 900,
          source: TransmitterSource.beacondb,
          updated: t0,
        ),
      ]);
      int count(int limit, {double north = 11}) => db.countInBounds(
        south: 10,
        west: 20,
        north: north,
        east: 21,
        limit: limit,
      );
      expect(count(100), 3);
      expect(count(100, north: 13), 4);
      expect(count(2), 2);
    });

    test('does not write to the database', () {
      db.addSamples([seen('aa:bb:cc:00:00:01', 10.5, 20.5)]);
      final before = db.stats().toString();
      grid();
      expect(db.stats().toString(), before);
    });
  });
}
