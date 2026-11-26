import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/positioning/fusion.dart';
import 'package:mapsoly/positioning/geo.dart';
import 'package:mapsoly/positioning/models.dart';

const lat0 = 59.92, lon0 = 30.65;
final t0 = DateTime.utc(2026, 11, 26, 12);
final proj = LocalProjection(lat0, lon0);

DateTime at(double seconds) =>
    t0.add(Duration(microseconds: (seconds * 1e6).round()));

GnssFix gnss(
  double t,
  double east,
  double north, {
  double? speed,
  double? course,
  double acc = 5,
}) => GnssFix(
  valid: true,
  receivedAt: at(t),
  lat: proj.lat(north),
  lon: proj.lon(east),
  accuracyM: acc,
  speedMps: speed,
  courseDeg: course,
);

PositionEstimate radio(
  double t,
  double east,
  double north, {
  double acc = 40,
  PositionSource source = PositionSource.wifi,
}) => PositionEstimate(
  lat: proj.lat(north),
  lon: proj.lon(east),
  accuracyM: acc,
  source: source,
  timestamp: at(t),
  transmittersUsed: 5,
);

double err(PositionEstimate e, double east, double north) =>
    haversineM(e.lat, e.lon, proj.lat(north), proj.lon(east));

/// Deterministic pseudo-Gaussian noise.
class Noise {
  Noise(int seed) : _r = math.Random(seed);
  final math.Random _r;
  double next(double sigma) {
    final u1 = 1 - _r.nextDouble(), u2 = _r.nextDouble();
    return sigma * math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }
}

void main() {
  test('no estimate before the first fix', () {
    final f = FusionFilter();
    expect(f.initialized, isFalse);
    expect(f.estimateAt(t0), isNull);
    f.addSpeed(10, t0); // ignored without a position
    expect(f.estimateAt(t0), isNull);
  });

  test('stationary: noisy GNSS converges and reports ~zero speed', () {
    final f = FusionFilter();
    final n = Noise(1);
    for (var t = 0; t < 60; t++) {
      f.addGnss(gnss(t.toDouble(), n.next(3.5), n.next(3.5), speed: 0.05));
    }
    final e = f.estimateAt(at(59))!;
    expect(err(e, 0, 0), lessThan(3));
    expect(e.accuracyM, lessThan(5));
    expect(e.speedMps, lessThan(0.2));
    expect(e.courseDeg, isNull); // no course while standing
    expect(e.source, PositionSource.gnss);
  });

  test('stationary on Wi-Fi only: follows fixes, never extrapolates', () {
    final f = FusionFilter();
    final n = Noise(2);
    PositionEstimate? e;
    var maxErr = 0.0, sumFix2 = 0.0, sumEst2 = 0.0;
    var count = 0;
    for (var t = 0; t <= 600; t += 10) {
      final fe = n.next(20), fn = n.next(20);
      f.addPosition(radio(t.toDouble(), fe, fn));
      sumFix2 += fe * fe + fn * fn;
      final held = f.estimateAt(at(t.toDouble()))!;
      for (var k = 0; k < 10; k++) {
        e = f.estimateAt(at(t + k.toDouble()))!;
        maxErr = math.max(maxErr, err(e, 0, 0));
        // Between scans the position is held: there is no trustworthy
        // velocity to extrapolate with, and no speed is claimed.
        expect(haversineM(e.lat, e.lon, held.lat, held.lon), lessThan(1e-6));
        expect(e.speedMps, isNull);
        expect(e.courseDeg, isNull);
      }
      sumEst2 += math.pow(err(held, 0, 0), 2);
      count++;
    }
    // The filter must not amplify the fix noise.
    expect(math.sqrt(sumEst2 / count), lessThan(math.sqrt(sumFix2 / count)));
    expect(maxErr, lessThan(90));
    expect(e!.source, PositionSource.wifi);
    // Correlated radio fixes: never claim better than half a single fix.
    expect(e.accuracyM, greaterThanOrEqualTo(20));
    expect(e.transmittersUsed, 5);
  });

  test('constant speed: tracks position, speed and course', () {
    final f = FusionFilter();
    final n = Noise(3);
    // 20 m/s heading 60 degrees.
    const v = 20.0, crs = 60.0;
    final ve = v * math.sin(degToRad(crs)), vn = v * math.cos(degToRad(crs));
    for (var t = 0; t <= 40; t++) {
      f.addGnss(
        gnss(
          t.toDouble(),
          ve * t + n.next(3),
          vn * t + n.next(3),
          speed: v + n.next(0.2),
          course: crs + n.next(1),
        ),
      );
    }
    final e = f.estimateAt(at(40))!;
    expect(err(e, ve * 40, vn * 40), lessThan(4));
    expect(e.speedMps, closeTo(v, 0.5));
    expect(e.courseDeg, closeTo(crs, 2));
  });

  test('speed is inferred from positions alone (no Doppler)', () {
    final f = FusionFilter();
    final n = Noise(4);
    for (var t = 0; t <= 60; t++) {
      f.addGnss(gnss(t.toDouble(), 15.0 * t + n.next(2), n.next(2)));
    }
    final e = f.estimateAt(at(60))!;
    expect(e.speedMps, closeTo(15, 1.5));
    expect(e.courseDeg, closeTo(90, 5));
  });

  test('GNSS dropout: dead reckoning continues, uncertainty grows', () {
    final f = FusionFilter();
    for (var t = 0; t <= 20; t++) {
      f.addGnss(gnss(t.toDouble(), 0, 25.0 * t, speed: 25, course: 0));
    }
    final before = f.estimateAt(at(20))!;
    expect(before.source, PositionSource.gnss);

    // 2 s into the outage: still labelled GNSS, speed still reported.
    final e2 = f.estimateAt(at(22))!;
    expect(e2.source, PositionSource.gnss);
    expect(e2.speedMps, closeTo(25, 0.5));
    expect(e2.courseDeg, closeTo(0, 1));
    expect(err(e2, 0, 25.0 * 22), lessThan(3));

    // 10 s: dead reckoning along the last velocity, speed no longer claimed.
    final e10 = f.estimateAt(at(30))!;
    expect(e10.source, PositionSource.deadReckoning);
    expect(err(e10, 0, 25.0 * 30), lessThan(5));
    expect(e10.accuracyM, greaterThan(before.accuracyM * 5));
    expect(e10.speedMps, isNull);

    // Much later: the position stopped extrapolating after 30 s; accuracy
    // keeps growing.
    final e120 = f.estimateAt(at(140))!;
    expect(err(e120, 0, 25.0 * 50), lessThan(5));
    expect(e120.accuracyM, greaterThan(e10.accuracyM * 10));
    expect(e120.speedMps, isNull);
    // estimateAt must not have modified the filter.
    expect(err(f.estimateAt(at(20))!, 0, 500), lessThan(1));
  });

  test('dropout with external speed: OBD keeps dead reckoning honest', () {
    final f = FusionFilter();
    for (var t = 0; t <= 20; t++) {
      f.addGnss(gnss(t.toDouble(), 0, 25.0 * t, speed: 25, course: 0));
    }
    // GNSS gone; the car brakes to 10 m/s over 5 s, then cruises.
    var north = 500.0, v = 25.0;
    for (var t = 21; t <= 50; t++) {
      if (v > 10) v -= 3;
      north += v;
      f.addSpeed(v, at(t.toDouble()));
    }
    final e = f.estimateAt(at(50))!;
    expect(e.source, PositionSource.deadReckoning);
    expect(e.speedMps, closeTo(10, 0.5));
    // 30 s without any heading information: the course is not claimed.
    expect(e.courseDeg, isNull);
    expect(err(e, 0, north), lessThan(25));

    // Without the speed input the filter would have overshot by ~400 m.
    final blind = FusionFilter();
    for (var t = 0; t <= 20; t++) {
      blind.addGnss(gnss(t.toDouble(), 0, 25.0 * t, speed: 25, course: 0));
    }
    expect(err(blind.estimateAt(at(50))!, 0, north), greaterThan(300));

    // Standing at a light: zero speed pins the position.
    for (var t = 51; t <= 80; t++) {
      f.addSpeed(0, at(t.toDouble()));
    }
    final stopped = f.estimateAt(at(80))!;
    expect(stopped.speedMps, lessThan(0.3));
    expect(err(stopped, 0, north), lessThan(40));
  });

  test('radio fixes take over after GNSS loss and are labelled', () {
    final f = FusionFilter();
    for (var t = 0; t <= 10; t++) {
      f.addGnss(gnss(t.toDouble(), 0, 0, speed: 0));
    }
    f.addPosition(radio(12, 15, -10));
    expect(f.estimateAt(at(12))!.source, PositionSource.fused);
    f.addPosition(radio(25, 10, 5));
    final e = f.estimateAt(at(26))!;
    expect(e.source, PositionSource.wifi);
    expect(err(e, 0, 0), lessThan(20));
    f.addPosition(radio(60, 0, 0, acc: 900, source: PositionSource.cell));
    expect(f.estimateAt(at(70))!.source, PositionSource.cell);
    expect(f.estimateAt(at(200))!.source, PositionSource.deadReckoning);
  });

  test('a single wild radio fix is gated out; persistent ones win', () {
    final f = FusionFilter();
    for (var t = 0; t <= 30; t += 10) {
      expect(f.addPosition(radio(t.toDouble(), 0, 0, acc: 30)), isTrue);
    }
    expect(f.addPosition(radio(40, 5000, 0, acc: 30)), isFalse);
    expect(err(f.estimateAt(at(40))!, 0, 0), lessThan(10));
    expect(f.addPosition(radio(50, 0, 0, acc: 30)), isTrue);
    expect(f.consecutiveRejections, 0);
    // We really moved (e.g. after a tunnel): three fixes in a row re-seat.
    expect(f.addPosition(radio(60, 5000, 0, acc: 30)), isFalse);
    expect(f.addPosition(radio(70, 5010, 0, acc: 30)), isFalse);
    expect(f.addPosition(radio(80, 5020, 0, acc: 30)), isTrue);
    expect(err(f.estimateAt(at(80))!, 5020, 0), lessThan(1));
  });

  test('healthy GNSS overrides a wrong radio position immediately', () {
    final f = FusionFilter();
    f.addPosition(radio(0, 0, 0, acc: 30));
    f.addGnss(gnss(1, 2000, 0, speed: 0));
    final e = f.estimateAt(at(1))!;
    expect(err(e, 2000, 0), lessThan(1));
    expect(e.accuracyM, closeTo(5, 0.5));
  });

  test('precise GNSS dominates a coarse cell fix', () {
    final f = FusionFilter();
    for (var t = 0; t <= 10; t++) {
      f.addGnss(gnss(t.toDouble(), 0, 0, speed: 0));
      f.addPosition(
        radio(t.toDouble(), 600, 0, acc: 900, source: PositionSource.cell),
      );
    }
    final e = f.estimateAt(at(10))!;
    expect(err(e, 0, 0), lessThan(1));
    expect(e.source, PositionSource.fused);
  });

  test('re-centres the projection on long trips', () {
    final f = FusionFilter();
    // 40 m/s east for 20 minutes = 48 km.
    for (var t = 0; t <= 1200; t++) {
      final lon =
          lon0 + radToDeg(40.0 * t / (earthRadiusM * math.cos(degToRad(lat0))));
      f.addGnss(
        GnssFix(
          valid: true,
          receivedAt: at(t.toDouble()),
          lat: lat0,
          lon: lon,
          accuracyM: 5,
          speedMps: 40,
          courseDeg: 90,
        ),
      );
    }
    final e = f.estimateAt(at(1200))!;
    final lonEnd =
        lon0 + radToDeg(48000 / (earthRadiusM * math.cos(degToRad(lat0))));
    expect(haversineM(e.lat, e.lon, lat0, lonEnd), lessThan(5));
    expect(e.speedMps, closeTo(40, 0.5));
  });
}
