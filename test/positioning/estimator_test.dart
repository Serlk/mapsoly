import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/positioning/estimator.dart';
import 'package:mapsoly/positioning/geo.dart';
import 'package:mapsoly/positioning/location_db.dart';
import 'package:mapsoly/positioning/models.dart';
import 'package:mapsoly/positioning/signal_model.dart';

const lat0 = 59.92, lon0 = 30.65;
final t0 = DateTime.utc(2026, 11, 26, 12);
const model = PathLossModel();

String mac(int i) => '02:00:00:00:00:${i.toRadixString(16).padLeft(2, '0')}';

TransmitterRecord ap(int i, double east, double north, {double acc = 20}) {
  final p = LocalProjection(lat0, lon0);
  return TransmitterRecord(
    kind: TransmitterKind.wifi,
    id: mac(i),
    lat: p.lat(north),
    lon: p.lon(east),
    accuracyM: acc,
    source: TransmitterSource.wardriving,
    updated: t0,
  );
}

/// dBm the model predicts at [d] metres (inverse of wifiDistanceM).
double rssiAt(double d) =>
    model.p0At2400 - 10 * model.exponent * math.log(d) / math.ln10;

/// Observation of AP [rec] from a user standing at (east, north).
WifiObservation see(TransmitterRecord rec, double east, double north) {
  final p = LocalProjection(lat0, lon0);
  final d = math.max(
    1.0,
    haversineM(rec.lat, rec.lon, p.lat(north), p.lon(east)),
  );
  return WifiObservation(
    bssid: rec.id,
    frequencyMhz: 2437,
    signalDbm: rssiAt(d),
    age: const Duration(seconds: 2),
  );
}

double errorM(PositionEstimate e, double east, double north) {
  final p = LocalProjection(lat0, lon0);
  return haversineM(e.lat, e.lon, p.lat(north), p.lon(east));
}

void main() {
  const est = RadioEstimator();

  test('path-loss model: sane distances and 5 GHz correction', () {
    expect(model.wifiDistanceM(-40), closeTo(1, 1e-9));
    expect(model.wifiDistanceM(-67), closeTo(10, 0.01));
    expect(model.wifiDistanceM(-94), closeTo(100, 0.1));
    expect(model.wifiDistanceM(-120), 300); // clamped
    // Same level on 5 GHz means a closer AP.
    expect(
      model.wifiDistanceM(-70, frequencyMhz: 5180),
      lessThan(model.wifiDistanceM(-70, frequencyMhz: 2437)),
    );
    expect(percentToDbm(100), -40);
    expect(percentToDbm(37).round(), -78); // captured on the phone
    expect(percentToDbm(17).round(), -90);
  });

  test('symmetric ring of APs -> position within a few metres', () {
    final recs = [
      for (var i = 0; i < 8; i++)
        ap(i, 60 * math.cos(i * math.pi / 4), 60 * math.sin(i * math.pi / 4)),
    ];
    final known = {for (final r in recs) r.id: r};
    final e = est.estimateWifi(
      [for (final r in recs) see(r, 0, 0)],
      known,
      t0,
    )!;
    expect(errorM(e, 0, 0), lessThan(1));
    expect(e.source, PositionSource.wifi);
    expect(e.transmittersUsed, 8);
    expect(e.accuracyM, inInclusiveRange(15, 60));
    expect(e.timestamp, t0.subtract(const Duration(seconds: 2)));
  });

  test('user off-centre: estimate is pulled towards the strong APs', () {
    // 5 x 5 grid of APs every 40 m; user at (50, -30).
    final recs = [
      for (var i = 0; i < 25; i++)
        ap(i, (i % 5 - 2) * 40.0, (i ~/ 5 - 2) * 40.0),
    ];
    final known = {for (final r in recs) r.id: r};
    final e = est.estimateWifi(
      [for (final r in recs) see(r, 50, -30)],
      known,
      t0,
    )!;
    final err = errorM(e, 50, -30);
    expect(err, lessThan(30));
    // An unweighted centroid would sit at the grid centre, 58 m away.
    expect(err, lessThan(errorM(e, 0, 0)));
    // The claimed accuracy must cover the actual error.
    expect(e.accuracyM, greaterThanOrEqualTo(err * 0.8));
  });

  test('a travelling hotspot far from the cluster is rejected', () {
    final recs = [
      ap(1, -30, 0),
      ap(2, 30, 0),
      ap(3, 0, 30),
      ap(4, 0, -30),
      ap(9, 4000, 2500), // database says it lives 4.7 km away
    ];
    final known = {for (final r in recs) r.id: r};
    final scan = [
      for (final r in recs.take(4)) see(r, 5, 5),
      // ...but it is heard right here, loud and clear.
      WifiObservation(bssid: mac(9), frequencyMhz: 2412, signalDbm: -45),
    ];
    final r = est.estimateWith(wifi: scan, wifiDb: known, now: t0);
    expect(r.wifiKnown, 5);
    expect(r.wifiRejected, 1);
    expect(r.wifiUsed, 4);
    expect(errorM(r.best!, 5, 5), lessThan(15));
  });

  test('two contradicting APs give no fix; a single AP gives a wide one', () {
    final a = ap(1, 0, 0), b = ap(2, 3000, 0);
    final known = {a.id: a, b.id: b};
    expect(
      est.estimateWifi(
        [
          WifiObservation(bssid: a.id, signalDbm: -60),
          WifiObservation(bssid: b.id, signalDbm: -60),
        ],
        known,
        t0,
      ),
      isNull,
    );
    final single = est.estimateWifi(
      [WifiObservation(bssid: a.id, signalDbm: -80)],
      known,
      t0,
    )!;
    expect(errorM(single, 0, 0), lessThan(0.01));
    // d(-80 dBm) = 30 m, AP accuracy 20 m, model noise 20 m, factor 1.5.
    expect(single.accuracyM, closeTo(1.5 * math.sqrt(900 + 400 + 400), 1.5));
  });

  test('stale, unknown and opted-out APs are ignored', () {
    final a = ap(1, 0, 0), b = ap(2, 200, 0), c = ap(3, 0, 200);
    final known = {a.id: a, b.id: b, c.id: c};
    final e = est.estimateWifi(
      [
        WifiObservation(bssid: a.id, signalDbm: -50),
        WifiObservation(
          bssid: b.id,
          signalDbm: -40,
          age: const Duration(seconds: 90),
        ),
        WifiObservation(bssid: c.id, signalDbm: -40, ssid: 'cafe_nomap'),
        WifiObservation(bssid: mac(77), signalDbm: -40),
      ],
      known,
      t0,
    )!;
    expect(e.transmittersUsed, 1);
    expect(errorM(e, 0, 0), lessThan(0.01));
  });

  test('percent-only observations (NetworkManager) still weight by signal', () {
    final a = ap(1, 0, 0), b = ap(2, 100, 0);
    final e = est.estimateWifi(
      [
        WifiObservation(bssid: a.id, signalPercent: 90),
        WifiObservation(bssid: b.id, signalPercent: 20),
      ],
      {a.id: a, b.id: b},
      t0,
    )!;
    expect(errorM(e, 0, 0), lessThan(35));
    expect(errorM(e, 0, 0), lessThan(errorM(e, 100, 0)));
  });

  group('cells', () {
    TransmitterRecord cellRec(
      String key,
      double east,
      double north,
      double acc,
    ) {
      final p = LocalProjection(lat0, lon0);
      return TransmitterRecord(
        kind: TransmitterKind.cell,
        id: key,
        lat: p.lat(north),
        lon: p.lon(east),
        accuracyM: acc,
        source: TransmitterSource.beacondb,
        updated: t0,
      );
    }

    const serving = CellObservation(
      radio: RadioType.lte,
      mcc: 250,
      mnc: 20,
      area: 8000,
      cellId: 27440068,
      serving: true,
    );

    test('serving cell without TA: its position and coverage radius', () {
      final rec = cellRec(serving.key!, 0, 0, 968);
      final e = est.estimateCells([serving], {rec.id: rec}, t0)!;
      expect(errorM(e, 0, 0), lessThan(0.01));
      expect(e.source, PositionSource.cell);
      expect(e.accuracyM, closeTo(968, 1e-6));
    });

    test('timing advance tightens (or widens) the radius', () {
      final rec = cellRec(serving.key!, 0, 0, 968);
      CellObservation withTa(int ta) => CellObservation(
        radio: RadioType.lte,
        mcc: 250,
        mnc: 20,
        area: 8000,
        cellId: 27440068,
        serving: true,
        timingAdvance: ta,
      );
      // TA 2 = 156 m from the mast; mast-to-centroid offset radius/2.
      final near = est.estimateCells([withTa(2)], {rec.id: rec}, t0)!;
      expect(
        near.accuracyM,
        closeTo(math.sqrt(156.24 * 156.24 + 484 * 484) + 39.06, 0.5),
      );
      expect(near.accuracyM, lessThan(968));
      // TA 40 = 3.1 km: the stored radius was too optimistic.
      final far = est.estimateCells([withTa(40)], {rec.id: rec}, t0)!;
      expect(far.accuracyM, greaterThan(3000));
      expect(timingAdvanceMeters(RadioType.lte, 1), closeTo(78.12, 1e-9));
      expect(timingAdvanceMeters(RadioType.gsm, 1), closeTo(553.46, 1e-9));
      expect(timingAdvanceMeters(RadioType.umts, 1), isNull);
      expect(timingAdvanceMeters(RadioType.lte, null), isNull);
    });

    test('two operators: weighted towards the tighter cell', () {
      const other = CellObservation(
        radio: RadioType.lte,
        mcc: 250,
        mnc: 2,
        area: 10795,
        cellId: 45335765,
        serving: true,
      );
      final a = cellRec(serving.key!, 0, 0, 500);
      final b = cellRec(other.key!, 1000, 0, 1000);
      final e = est.estimateCells([serving, other], {a.id: a, b.id: b}, t0)!;
      // weights 1/500^2 : 1/1000^2 = 4 : 1 -> 200 m east of the first cell
      expect(errorM(e, 200, 0), lessThan(1));
      expect(e.accuracyM, inInclusiveRange(300, 500));
      expect(e.transmittersUsed, 2);
    });

    test('neighbour without identity is ignored, not treated as id 0', () {
      const neighbour = CellObservation(
        radio: RadioType.lte,
        pci: 301,
        arfcn: 1300,
        signalDbm: -101,
      );
      expect(neighbour.key, isNull);
      final rec = cellRec(serving.key!, 0, 0, 968);
      final e = est.estimateCells([neighbour, serving], {rec.id: rec}, t0)!;
      expect(e.transmittersUsed, 1);
    });

    test('Wi-Fi contradicting the cell is discarded in favour of the cell', () {
      final rec = cellRec(serving.key!, 0, 0, 968);
      final far = [ap(1, 30000, 0), ap(2, 30040, 0), ap(3, 30020, 30)];
      final r = est.estimateWith(
        wifi: [
          for (final a in far) WifiObservation(bssid: a.id, signalDbm: -60),
        ],
        cells: [serving],
        wifiDb: {for (final a in far) a.id: a},
        cellDb: {rec.id: rec},
        now: t0,
      );
      expect(r.wifi, isNotNull);
      expect(r.wifiCellConflict, isTrue);
      expect(r.best!.source, PositionSource.cell);

      final near = [ap(1, 300, 0), ap(2, 340, 0), ap(3, 320, 30)];
      final ok = est.estimateWith(
        wifi: [
          for (final a in near) WifiObservation(bssid: a.id, signalDbm: -60),
        ],
        cells: [serving],
        wifiDb: {for (final a in near) a.id: a},
        cellDb: {rec.id: rec},
        now: t0,
      );
      expect(ok.wifiCellConflict, isFalse);
      expect(ok.best!.source, PositionSource.wifi);
    });
  });
}
