import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/positioning/geo.dart';
import 'package:mapsoly/positioning/gnss_sanity.dart';
import 'package:mapsoly/positioning/models.dart';

const lat0 = 59.92, lon0 = 30.65;
final t0 = DateTime.utc(2026, 11, 26, 12);
final proj = LocalProjection(lat0, lon0);

/// A believable sky: C/N0 spread over ~20 dB.
const realSky = [47.0, 44.0, 41.0, 39.0, 36.0, 33.0, 30.0, 27.0, 24.0];

GnssFix fix(
  int t, {
  double east = 0,
  double north = 0,
  double? speed = 0,
  List<double> cn0 = realSky,
  bool valid = true,
  DateTime? gnssTime,
}) => GnssFix(
  valid: valid,
  receivedAt: t0.add(Duration(seconds: t)),
  lat: valid ? proj.lat(north) : null,
  lon: valid ? proj.lon(east) : null,
  accuracyM: valid ? 5 : null,
  speedMps: speed,
  time: gnssTime ?? t0.add(Duration(seconds: t)),
  satellites: [
    for (var i = 0; i < cn0.length; i++)
      GnssSatellite(
        system: GnssSystem.gps,
        prn: i + 1,
        cn0: cn0[i],
        used: true,
      ),
  ],
);

PositionEstimate radio(int t, double east, double north, double acc) =>
    PositionEstimate(
      lat: proj.lat(north),
      lon: proj.lon(east),
      accuracyM: acc,
      source: PositionSource.wifi,
      timestamp: t0.add(Duration(seconds: t)),
    );

void main() {
  test('a normal drive is healthy', () {
    final c = GnssSanityChecker();
    for (var t = 0; t < 120; t++) {
      final h = c.check(
        fix(t, east: 30.0 * t, speed: 30),
        radio: radio(t, 30.0 * t + 40, 20, 50),
      );
      expect(h.verdict, GnssVerdict.ok, reason: 't=$t $h');
      expect(h.usable, isTrue);
    }
    expect(c.health.cn0StdDev, greaterThan(5));
    expect(c.health.satellitesWithSignal, 9);
  });

  test('no fix', () {
    final c = GnssSanityChecker();
    final h = c.check(fix(0, valid: false, cn0: const []));
    expect(h.verdict, GnssVerdict.noFix);
    expect(h.usable, isFalse);
    expect(h.spoofingSuspected, isFalse);
  });

  test('disagreement with the radio estimate flags spoofing', () {
    final c = GnssSanityChecker();
    // Radio says we are at the origin (within 60 m); GNSS claims 3 km away.
    expect(
      c.check(fix(0, east: 3000), radio: radio(0, 0, 0, 60)).verdict,
      GnssVerdict.ok, // one epoch is not enough
    );
    final h = c.check(fix(1, east: 3000), radio: radio(1, 0, 0, 60));
    expect(h.verdict, GnssVerdict.suspect);
    expect(h.anomalies, contains(GnssAnomaly.radioMismatch));
    expect(h.spoofingSuspected, isTrue);
    expect(h.usable, isFalse);

    // Still flagged while the disagreement lasts, however long.
    for (var t = 2; t < 200; t++) {
      expect(
        c.check(fix(t, east: 3000), radio: radio(t, 0, 0, 60)).verdict,
        GnssVerdict.suspect,
      );
    }
    // GNSS comes back to the truth: the radio confirms it and clears it.
    expect(
      c.check(fix(200, east: 10), radio: radio(200, 0, 0, 60)).verdict,
      GnssVerdict.ok,
    );
  });

  test('coarse cell-only estimate: only gross spoofing is flagged', () {
    final c = GnssSanityChecker();
    // 2 km from a cell with 968 m accuracy: plausible, not flagged.
    for (var t = 0; t < 5; t++) {
      expect(
        c.check(fix(t, east: 2000), radio: radio(t, 0, 0, 968)).verdict,
        GnssVerdict.ok,
      );
    }
    // 40 km away is not.
    c.check(fix(5, east: 40000), radio: radio(5, 0, 0, 968));
    c.check(fix(6, east: 40000), radio: radio(6, 0, 0, 968));
    expect(c.health.anomalies, contains(GnssAnomaly.radioMismatch));
  });

  test('a stale radio estimate is not used as evidence', () {
    final c = GnssSanityChecker();
    for (var t = 100; t < 105; t++) {
      expect(
        c.check(fix(t, east: 3000), radio: radio(0, 0, 0, 60)).verdict,
        GnssVerdict.ok,
      );
    }
  });

  test('uniform C/N0 (single-transmitter spoofer) is flagged', () {
    final c = GnssSanityChecker();
    const flat = [45.0, 45.0, 46.0, 45.0, 44.0, 45.0, 45.0, 46.0];
    expect(c.check(fix(0, cn0: flat)).verdict, GnssVerdict.ok);
    expect(c.check(fix(1, cn0: flat)).verdict, GnssVerdict.ok);
    final h = c.check(fix(2, cn0: flat));
    expect(h.verdict, GnssVerdict.suspect);
    expect(h.anomalies, {GnssAnomaly.uniformCn0});
    expect(h.cn0StdDev, lessThan(1.0));
    // Recovery: real sky again; the flag is held for 60 s, then cleared.
    expect(c.check(fix(3)).verdict, GnssVerdict.suspect);
    expect(c.check(fix(62)).verdict, GnssVerdict.suspect);
    expect(c.check(fix(64)).verdict, GnssVerdict.ok);
  });

  test('few satellites: uniformity cannot be judged', () {
    final c = GnssSanityChecker();
    for (var t = 0; t < 10; t++) {
      expect(
        c.check(fix(t, cn0: const [40.0, 40.0, 40.0, 40.0])).verdict,
        GnssVerdict.ok,
      );
    }
  });

  test('position jump without matching speed is flagged', () {
    final c = GnssSanityChecker();
    for (var t = 0; t < 10; t++) {
      c.check(fix(t));
    }
    // Teleport 800 m in one second while reporting standstill.
    final h = c.check(fix(10, east: 800));
    expect(h.verdict, GnssVerdict.suspect);
    expect(h.anomalies, {GnssAnomaly.positionJump});
    // Held, then released when nothing else is wrong.
    expect(c.check(fix(11, east: 800)).verdict, GnssVerdict.suspect);
    expect(c.check(fix(75, east: 800)).verdict, GnssVerdict.ok);
  });

  test('fast but consistent motion is not a jump', () {
    final c = GnssSanityChecker();
    for (var t = 0; t < 30; t++) {
      // 250 km/h train.
      expect(
        c.check(fix(t, east: 70.0 * t, speed: 70)).verdict,
        GnssVerdict.ok,
      );
    }
    // Small wander while parked is fine too.
    final d = GnssSanityChecker();
    for (var t = 0; t < 30; t++) {
      expect(d.check(fix(t, east: t.isEven ? 0 : 25)).verdict, GnssVerdict.ok);
    }
  });

  test('GNSS time stepping against the system clock is flagged', () {
    final c = GnssSanityChecker();
    for (var t = 0; t < 5; t++) {
      expect(c.check(fix(t)).verdict, GnssVerdict.ok);
    }
    final h = c.check(
      fix(5, gnssTime: t0.add(const Duration(days: 400, seconds: 5))),
    );
    expect(h.anomalies, contains(GnssAnomaly.timeJump));
    expect(h.verdict, GnssVerdict.suspect);
  });

  test('a constant clock offset (wrong system clock) is tolerated', () {
    final c = GnssSanityChecker();
    for (var t = 0; t < 10; t++) {
      expect(
        c
            .check(fix(t, gnssTime: t0.add(Duration(hours: 3, seconds: t))))
            .verdict,
        GnssVerdict.ok,
      );
    }
  });

  test('abrupt loss with dead signals hints at jamming', () {
    final c = GnssSanityChecker();
    for (var t = 0; t < 10; t++) {
      c.check(fix(t));
    }
    final h = c.check(
      fix(10, valid: false, cn0: const [14.0, 12.0, 15.0, 11.0, 13.0]),
    );
    expect(h.verdict, GnssVerdict.noFix);
    expect(h.jammingSuspected, isTrue);
    expect(h.spoofingSuspected, isFalse);
    // Signals return.
    expect(c.check(fix(20)).jammingSuspected, isFalse);
  });

  test('reset forgets everything', () {
    final c = GnssSanityChecker();
    c.check(fix(0));
    c.check(fix(1, east: 5000));
    expect(c.health.verdict, GnssVerdict.suspect);
    c.reset();
    expect(c.health.verdict, GnssVerdict.noFix);
    expect(c.check(fix(2, east: 5000)).verdict, GnssVerdict.ok);
  });
}
