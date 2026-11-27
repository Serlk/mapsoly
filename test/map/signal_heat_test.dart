import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/map/signal_heat.dart';
import 'package:mapsoly/positioning/location_db.dart';
import 'package:mapsoly/positioning/models.dart';

final t0 = DateTime.utc(2026, 11, 27, 12);
const view = Size(400, 800);
const here = LatLng(10.5, 20.5);

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

String mac(int i) =>
    'aa:bb:cc:${(i >> 16 & 0xff).toRadixString(16).padLeft(2, '0')}:'
    '${(i >> 8 & 0xff).toRadixString(16).padLeft(2, '0')}:'
    '${(i & 0xff).toRadixString(16).padLeft(2, '0')}';

void main() {
  group('signalHeatWeight', () {
    double w({
      int wifi = 0,
      int cells = 0,
      int ble = 0,
      double? wifiDbm,
      double? cellDbm,
      double? bleDbm,
    }) => signalHeatWeight(
      TransmitterCell(
        lat: 0,
        lon: 0,
        wifi: wifi,
        cells: cells,
        ble: ble,
        bestWifiDbm: wifiDbm,
        bestCellDbm: cellDbm,
        bestBleDbm: bleDbm,
      ),
    );

    test('stronger and more is hotter, within 0..1', () {
      expect(w(), 0);
      expect(w(wifi: 1, wifiDbm: -40), closeTo(0.316, 0.001));
      expect(w(wifi: 1, wifiDbm: -90), closeTo(0.316 / 6, 0.001));
      expect(w(wifi: 1, wifiDbm: -70), closeTo(0.158, 0.001));
      expect(w(wifi: 10, wifiDbm: -40), 1);
      expect(w(wifi: 500, wifiDbm: -20), 1);
      expect(w(wifi: 4, wifiDbm: -60), greaterThan(w(wifi: 2, wifiDbm: -60)));
      expect(w(wifi: 2, wifiDbm: -50), greaterThan(w(wifi: 2, wifiDbm: -80)));
      // Nothing is ever invisible, however weak.
      expect(w(wifi: 1, wifiDbm: -120), greaterThan(0.04));
      // An unknown signal counts as a middling one.
      expect(w(wifi: 10), closeTo(0.4, 1e-9));
    });

    test('a cell counts less than Bluetooth, that less than Wi-Fi', () {
      final wifi = w(wifi: 3, wifiDbm: -60);
      final ble = w(ble: 3, bleDbm: -60);
      final cell = w(cells: 3, cellDbm: -60);
      expect(wifi, greaterThan(ble));
      expect(ble, greaterThan(cell));
      expect(cell, closeTo(wifi * 0.35, 1e-9));
    });

    test('the kinds add up, capped at 1', () {
      expect(
        w(wifi: 2, wifiDbm: -60, cells: 1, cellDbm: -90),
        closeTo(w(wifi: 2, wifiDbm: -60) + w(cells: 1, cellDbm: -90), 1e-9),
      );
      expect(w(wifi: 10, wifiDbm: -40, ble: 10, bleDbm: -40, cells: 10), 1);
    });
  });

  test('signalHeatColor runs from blue to red', () {
    expect(signalHeatColor(0), const Color(0xFF4169E1));
    expect(signalHeatColor(1), const Color(0xFFFF3B30));
    expect(signalHeatColor(7), const Color(0xFFFF3B30));
    final mid = signalHeatColor(0.55);
    expect(mid.g, greaterThan(mid.r));
    expect(mid.g, greaterThan(mid.b));
  });

  group('SignalHeatArea', () {
    test('a square twice the longer side of the view around the camera', () {
      final a = SignalHeatArea.of(here, 14, view);
      const degPerPx = 360 / (256 * 16384);
      expect(a.halfLon, closeTo(800 * degPerPx, 1e-12));
      expect(a.east - a.west, closeTo(1600 * degPerPx, 1e-9));
      // The same distance on the ground north to south.
      expect(a.halfLat, closeTo(a.halfLon * 0.9833, 1e-4));
      expect((a.south + a.north) / 2, closeTo(here.latitude, 1e-9));
    });

    test('grid cells are 20..40 px wide at any zoom', () {
      for (var zoom = 3.0; zoom <= 19; zoom += 0.37) {
        final a = SignalHeatArea.of(here, zoom, view);
        final px = a.lonStep / (360 / (256 * math.pow(2, zoom)));
        expect(px, inInclusiveRange(20 - 1e-9, 40 + 1e-9), reason: '$zoom');
      }
    });

    test('cells stay about square on the ground far from the equator', () {
      final a = SignalHeatArea.of(const LatLng(60, 20), 14, view);
      expect(a.latDivisor, 2);
      expect(a.latStep, a.lonStep / 2);
      expect(SignalHeatArea.of(here, 14, view).latDivisor, 1);
    });

    test('coarser doubles the step', () {
      final a = SignalHeatArea.of(here, 14, view);
      final b = SignalHeatArea.of(here, 14, view, coarser: 2);
      expect(b.lonStep, a.lonStep * 4);
      expect(b.halfLon, a.halfLon);
    });

    test('serves a view nearby on the same grid, not a far or zoomed one', () {
      final a = SignalHeatArea.of(here, 14, view);
      SignalHeatArea at(double dLat, double dLon, [double zoom = 14]) =>
          SignalHeatArea.of(
            LatLng(here.latitude + dLat, here.longitude + dLon),
            zoom,
            view,
          );
      expect(a.serves(at(0, 0)), isTrue);
      expect(a.serves(at(a.halfLat * 0.25, -a.halfLon * 0.25)), isTrue);
      expect(a.serves(at(0, a.halfLon * 0.35)), isFalse);
      expect(a.serves(at(-a.halfLat * 0.35, 0)), isFalse);
      expect(a.serves(at(0, 0, 15)), isFalse);
      expect(a.serves(at(0, 0, 12.9)), isFalse);
    });

    test('the whole world and the poles stay within bounds', () {
      final a = SignalHeatArea.of(const LatLng(89, 179), 1, view);
      expect(a.south, greaterThanOrEqualTo(-90));
      expect(a.north, lessThanOrEqualTo(90));
      expect(a.west, greaterThanOrEqualTo(-180));
      expect(a.east, lessThanOrEqualTo(180));
      expect(a.level, greaterThanOrEqualTo(1));
    });
  });

  group('querySignalHeat', () {
    late LocationDb db;
    setUp(() => db = LocationDb.inMemory());
    tearDown(() => db.close());

    test('points with weights, only around the view', () {
      db.addSamples([
        seen(mac(1), 10.5, 20.5, dbm: -40),
        seen(mac(2), 10.5001, 20.5001, dbm: -40),
        seen(mac(3), 10.51, 20.51, kind: TransmitterKind.cell, dbm: -100),
        seen(mac(4), 14, 20.5),
      ]);
      final points = querySignalHeat(db, here, 14, view)!
        ..sort((a, b) => b.weight.compareTo(a.weight));
      expect(points, hasLength(2));
      expect(points.first.weight, closeTo(0.447, 0.001));
      expect(points.first.point.latitude, closeTo(10.50005, 1e-6));
      expect(points.last.weight, closeTo(0.35 * 0.316 * 0.15, 0.001));
      expect(points.last.point.longitude, closeTo(20.51, 1e-6));
    });

    test('too many cells: a coarser grid over the whole area, not a part '
        'of it', () {
      // A field of 60 x 60 transmitters across the area, one per fine cell.
      final area = SignalHeatArea.of(here, 14, view);
      db.addSamples([
        for (var y = 0; y < 60; y++)
          for (var x = 0; x < 60; x++)
            seen(
              mac(y * 256 + x),
              area.south + (y + 0.5) * (area.north - area.south) / 60,
              area.west + (x + 0.5) * (area.east - area.west) / 60,
            ),
      ]);
      final all = querySignalHeat(db, here, 14, view)!;
      expect(all.length, greaterThan(2000));
      final capped = querySignalHeat(db, here, 14, view, maxPoints: 1000)!;
      expect(capped.length, inInclusiveRange(200, 1000));
      // Still from edge to edge.
      final lats = capped.map((p) => p.point.latitude);
      final lons = capped.map((p) => p.point.longitude);
      final dLat = area.north - area.south, dLon = area.east - area.west;
      expect(
        lats.reduce((a, b) => a < b ? a : b),
        lessThan(area.south + dLat * 0.1),
      );
      expect(
        lats.reduce((a, b) => a > b ? a : b),
        greaterThan(area.north - dLat * 0.1),
      );
      expect(
        lons.reduce((a, b) => a < b ? a : b),
        lessThan(area.west + dLon * 0.1),
      );
      expect(
        lons.reduce((a, b) => a > b ? a : b),
        greaterThan(area.east - dLon * 0.1),
      );
    });

    test('never more than the cap', () {
      final area = SignalHeatArea.of(here, 14, view);
      db.addSamples([
        for (var y = 0; y < 60; y++)
          for (var x = 0; x < 60; x++)
            seen(
              mac(y * 256 + x),
              area.south + (y + 0.5) * (area.north - area.south) / 60,
              area.west + (x + 0.5) * (area.east - area.west) / 60,
            ),
      ]);
      expect(querySignalHeat(db, here, 14, view, maxPoints: 5), hasLength(5));
    });
  });

  test('an area with too many records is not read at all', () {
    final db = LocationDb.inMemory();
    addTearDown(db.close);
    db.addSamples([seen(mac(1), 10.5, 20.5), seen(mac(2), 10.501, 20.5)]);
    // Records of other sources count: they cost as much to pass over.
    db.upsertExternal([
      TransmitterRecord(
        kind: TransmitterKind.wifi,
        id: mac(3),
        lat: 10.502,
        lon: 20.5,
        accuracyM: 30,
        source: TransmitterSource.apple,
        updated: t0,
      ),
    ]);
    expect(querySignalHeat(db, here, 14, view, maxRecords: 3), hasLength(1));
    expect(querySignalHeat(db, here, 14, view, maxRecords: 2), isNull);
    // Zoomed in on one of them it is read again.
    expect(querySignalHeat(db, here, 21, view, maxRecords: 2), hasLength(1));
    final c = SignalHeatController(database: () => db)..enabled = true;
    addTearDown(c.dispose);
    c.viewChanged(here, 14, view);
    expect(c.tooMuch, isFalse);
    expect(c.points, hasLength(1));
  });

  group('SignalHeatController', () {
    late LocationDb db;
    LocationDb? available;
    setUp(() {
      db = LocationDb.inMemory();
      available = db;
      db.addSamples([seen(mac(1), 10.5, 20.5)]);
    });
    tearDown(() => db.close());

    SignalHeatController make() {
      return SignalHeatController(database: () => available);
    }

    testWidgets('off: no points, no reads, no timers', (tester) async {
      final c = make();
      c.viewChanged(here, 14, view);
      await tester.pump(const Duration(minutes: 1));
      expect(c.points, isNull);
      expect(c.queries, 0);
      c.dispose();
    });

    testWidgets('on: reads at once, and tells its listeners', (tester) async {
      final c = make();
      var told = 0;
      c.addListener(() => told++);
      c.viewChanged(here, 14, view);
      c.enabled = true;
      expect(c.queries, 1);
      expect(c.points, hasLength(1));
      expect(c.points!.single.weight, closeTo(0.316 * 40 / 60, 0.001));
      expect(c.points!.single.point.latitude, closeTo(10.5, 1e-6));
      expect(told, greaterThanOrEqualTo(1));
      c.enabled = false;
      expect(c.points, isNull);
      await tester.pump(const Duration(minutes: 1));
      expect(c.queries, 1);
      c.dispose();
    });

    testWidgets('small camera moves read nothing; a far one or a zoom does', (
      tester,
    ) async {
      final c = make()..enabled = true;
      c.viewChanged(here, 14, view);
      expect(c.queries, 1);
      await tester.pump(const Duration(seconds: 2));
      final a = SignalHeatArea.of(here, 14, view);
      c.viewChanged(LatLng(10.5, 20.5 + a.halfLon * 0.2), 14, view);
      c.viewChanged(here, 14.01, view);
      expect(c.queries, 1);
      c.viewChanged(LatLng(10.5, 20.5 + a.halfLon * 0.5), 14, view);
      expect(c.queries, 2);
      await tester.pump(const Duration(seconds: 2));
      c.viewChanged(LatLng(10.5, 20.5 + a.halfLon * 0.5), 16, view);
      expect(c.queries, 3);
      c.dispose();
    });

    testWidgets('a moving camera reads at most once a second', (tester) async {
      final c = make()..enabled = true;
      // Flying east fast: every step needs new data.
      for (var i = 0; i < 100; i++) {
        c.viewChanged(LatLng(10.5, 20.5 + i * 0.05), 14, view);
        await tester.pump(const Duration(milliseconds: 50));
      }
      // Five seconds: the first read and one for every second after.
      expect(c.queries, inInclusiveRange(5, 6));
      // The last position is read once the pause is over.
      final before = c.queries;
      await tester.pump(const Duration(milliseconds: 1100));
      expect(c.queries, inInclusiveRange(before, before + 1));
      c.viewChanged(const LatLng(10.5, 20.5 + 99 * 0.05), 14, view);
      expect(c.queries, inInclusiveRange(before, before + 1));
      c.dispose();
    });

    testWidgets('what was collected meanwhile appears within ten seconds', (
      tester,
    ) async {
      final c = make()..enabled = true;
      c.viewChanged(here, 14, view);
      expect(c.points, hasLength(1));
      var told = 0;
      c.addListener(() => told++);
      await tester.pump(const Duration(seconds: 25));
      // Refreshed twice, nothing new: the listeners were not disturbed.
      expect(c.queries, 3);
      expect(told, 0);
      db.addSamples([seen(mac(2), 10.52, 20.52)]);
      await tester.pump(const Duration(seconds: 10));
      expect(c.points, hasLength(2));
      expect(told, 1);
      c.dispose();
    });

    testWidgets('no database yet: empty, then filled when it is there', (
      tester,
    ) async {
      available = null;
      final c = make()..enabled = true;
      c.viewChanged(here, 14, view);
      expect(c.points, isEmpty);
      expect(c.queries, 0);
      available = db;
      c.viewChanged(here, 14, view);
      expect(c.points, hasLength(1));
      c.dispose();
    });

    testWidgets('a view without a size is ignored', (tester) async {
      final c = make()..enabled = true;
      c.viewChanged(here, 14, Size.zero);
      expect(c.queries, 0);
      c.dispose();
    });
  });
}
