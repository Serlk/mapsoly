import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/positioning/fusion.dart';
import 'package:mapsoly/positioning/heading.dart';
import 'package:mapsoly/positioning/models.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 27, 10);
  DateTime at(double seconds) =>
      t0.add(Duration(microseconds: (seconds * 1e6).round()));

  /// Feeds [seconds] of 50 Hz gyro at [rate] rad/s about the device axis
  /// that points up, with gravity along [up].
  double feed(
    HeadingEstimator h, {
    required double from,
    required double seconds,
    required double rate,
    List<double> up = const [0, 0, 9.81],
    List<double> bias = const [0, 0, 0],
  }) {
    final n = math.sqrt(up[0] * up[0] + up[1] * up[1] + up[2] * up[2]);
    for (var i = 0; i <= (seconds * 50).round(); i++) {
      h.addAccel(up[0], up[1], up[2]);
      h.addGyro(
        rate * up[0] / n + bias[0],
        rate * up[1] / n + bias[1],
        rate * up[2] / n + bias[2],
        at(from + i / 50),
      );
    }
    return from + seconds;
  }

  test('no heading until an absolute reference arrives', () {
    final h = HeadingEstimator();
    feed(h, from: 0, seconds: 1, rate: 0.1);
    expect(h.headingDeg, isNull);
    h.addReference(HeadingReference.gnss, 90);
    expect(h.headingDeg, 90);
  });

  test('a right turn increases the heading', () {
    final h = HeadingEstimator()..addReference(HeadingReference.gnss, 0);
    // Clockwise from above is a negative rotation about "up".
    feed(h, from: 0, seconds: 9, rate: -math.pi / 18); // 10 deg/s for 9 s
    expect(h.headingDeg, closeTo(90, 1));
    expect(h.turnRateDegPerSecond, closeTo(10, 0.1));
  });

  test('works with the phone standing upright in a holder', () {
    final h = HeadingEstimator()..addReference(HeadingReference.gnss, 350);
    // Gravity along the device y axis; left turn of 30 degrees.
    feed(h, from: 0, seconds: 3, rate: math.pi / 18, up: const [0, 9.81, 0]);
    expect(h.headingDeg, closeTo(320, 1));
  });

  test('gyro offset learnt at a standstill does not turn the car', () {
    const bias = [0.01, -0.02, 0.015]; // about 0.9 deg/s about up
    final drifting = HeadingEstimator()
      ..addReference(HeadingReference.gnss, 100);
    feed(drifting, from: 0, seconds: 60, rate: 0, bias: bias);
    expect((drifting.headingDeg! - 100).abs(), greaterThan(20));

    final calibrated = HeadingEstimator()
      ..addReference(HeadingReference.gnss, 100)
      ..stationary = true;
    var t = feed(calibrated, from: 0, seconds: 10, rate: 0, bias: bias);
    expect(calibrated.headingDeg, 100); // standing: heading is frozen
    calibrated.stationary = false;
    t = feed(calibrated, from: t + 0.02, seconds: 60, rate: 0, bias: bias);
    expect(calibrated.headingDeg, closeTo(100, 2));
  });

  test('uncertainty grows on gyro alone and shrinks with a reference', () {
    final h = HeadingEstimator()..addReference(HeadingReference.gnss, 0);
    final start = h.sigmaDeg;
    feed(h, from: 0, seconds: 120, rate: 0);
    expect(h.sigmaDeg, greaterThan(start + 4));
    for (var i = 0; i < 10; i++) {
      h.addReference(HeadingReference.route, 0);
    }
    expect(h.sigmaDeg, lessThan(start + 1));
  });

  test('references pull across the 0/360 seam the short way', () {
    final h = HeadingEstimator()..addReference(HeadingReference.gnss, 355);
    for (var i = 0; i < 20; i++) {
      h.addReference(HeadingReference.gnss, 5);
    }
    expect(h.headingDeg, closeTo(5, 1));
  });

  test('a compass cannot drag a well-known heading away', () {
    final h = HeadingEstimator()..addReference(HeadingReference.gnss, 90);
    for (var i = 0; i < 100; i++) {
      h.addReference(HeadingReference.compass, 150);
    }
    expect(h.headingDeg, closeTo(90, 0.01));
  });

  test('a compass gives the first guess, marked as uncertain', () {
    final h = HeadingEstimator()..addReference(HeadingReference.compass, 200);
    expect(h.headingDeg, 200);
    expect(h.sigmaDeg, greaterThanOrEqualTo(40));
  });

  test('tilt-compensated compass heading', () {
    // Phone flat, top (+y) pointing north: field has a north (+y) and a
    // downward (-z) part.
    expect(compassHeading([0, 0, 9.81], [0, 20, -40]), closeTo(0, 0.1));
    // Top pointing east: north is along the device's -x.
    expect(compassHeading([0, 0, 9.81], [-20, 0, -40]), closeTo(90, 0.1));
    // Top pointing south.
    expect(compassHeading([0, 0, 9.81], [0, -20, -40]), closeTo(180, 0.1));
    expect(compassHeading([0, 0, 0], [0, 20, -40]), isNull);
  });

  group('dead reckoning in the fusion filter', () {
    PositionEstimate fix(double lat, double lon, DateTime time) =>
        PositionEstimate(
          lat: lat,
          lon: lon,
          accuracyM: 20,
          source: PositionSource.wifi,
          timestamp: time,
        );

    test('speed and heading carry the position without fixes', () {
      final f = FusionFilter()..addPosition(fix(55.75, 37.60, at(0)));
      // 20 m/s due east for 60 s: 1200 m.
      for (var s = 1; s <= 60; s++) {
        f.addVelocity(20, 90, at(s.toDouble()), headingSigmaDeg: 3);
      }
      final e = f.estimateAt(at(60))!;
      final east = (e.lon - 37.60) * 111320 * math.cos(55.75 * math.pi / 180);
      final north = (e.lat - 55.75) * 111320;
      expect(east, closeTo(1200, 60));
      expect(north.abs(), lessThan(40));
      expect(e.speedMps, closeTo(20, 1));
      expect(e.courseDeg, closeTo(90, 3));
    });

    test('a turn is followed', () {
      final f = FusionFilter()..addPosition(fix(55.75, 37.60, at(0)));
      for (var s = 1; s <= 30; s++) {
        f.addVelocity(10, 0, at(s.toDouble()));
      }
      for (var s = 31; s <= 60; s++) {
        f.addVelocity(10, 90, at(s.toDouble()));
      }
      final e = f.estimateAt(at(60))!;
      final east = (e.lon - 37.60) * 111320 * math.cos(55.75 * math.pi / 180);
      final north = (e.lat - 55.75) * 111320;
      expect(north, closeTo(300, 40));
      expect(east, closeTo(300, 40));
    });

    test('standing still keeps the position', () {
      final f = FusionFilter()..addPosition(fix(55.75, 37.60, at(0)));
      for (var s = 1; s <= 120; s++) {
        f.addVelocity(0, 45, at(s.toDouble()));
      }
      final e = f.estimateAt(at(120))!;
      expect((e.lat - 55.75).abs() * 111320, lessThan(15));
    });
  });
}
