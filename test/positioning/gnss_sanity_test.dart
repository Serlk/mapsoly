import 'dart:math' as math;

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
  double? course,
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
  courseDeg: course,
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

PositionEstimate radio(
  int t,
  double east,
  double north,
  double acc, {
  PositionSource source = PositionSource.wifi,
}) => PositionEstimate(
  lat: proj.lat(north),
  lon: proj.lon(east),
  accuracyM: acc,
  source: source,
  timestamp: t0.add(Duration(seconds: t)),
  transmittersUsed: 4,
);

/// What a tablet lying on a table received for 74 seconds in November 2026:
/// a closed loop a kilometre across, driven at exactly 119 km/h, with
/// corners no car could take. Seconds, metres east and north of the first
/// fix, reported speed (m/s) and course. The place itself is not recorded.
const spoofedLoop = <(int, double, double, double, double)>[
  (0, 0, 0, 33.2, 292),
  (1, -39, 23, 33.2, 292),
  (3, -114, 62, 33.0, 287),
  (5, -175, 77, 33.0, 286),
  (6, -206, 84, 33.0, 287),
  (8, -269, 104, 33.0, 287),
  (10, -333, 122, 33.0, 287),
  (11, -364, 131, 33.0, 286),
  (13, -429, 150, 33.0, 287),
  (15, -491, 167, 33.0, 287),
  (17, -552, 182, 33.0, 287),
  (18, -583, 190, 33.0, 287),
  (20, -643, 208, 33.0, 287),
  (22, -704, 226, 33.0, 287),
  (23, -734, 234, 33.0, 287),
  (25, -766, 252, 31.8, 83),
  (27, -643, 264, 33.0, 81),
  (28, -602, 265, 33.0, 81),
  (30, -531, 274, 33.0, 81),
  (32, -465, 286, 33.0, 81),
  (33, -432, 292, 33.0, 81),
  (35, -367, 299, 33.0, 81),
  (37, -303, 310, 33.0, 81),
  (38, -269, 320, 33.0, 81),
  (40, -204, 325, 33.0, 81),
  (42, -141, 313, 32.9, 117),
  (43, -111, 295, 33.0, 117),
  (45, -53, 262, 33.1, 117),
  (47, 4, 233, 33.1, 117),
  (49, 61, 206, 33.0, 117),
  (50, 90, 191, 33.0, 117),
  (52, 150, 158, 33.0, 117),
  (54, 209, 130, 33.0, 117),
  (55, 237, 116, 32.9, 117),
  (57, 281, 88, 26.7, 121),
  (59, 157, 13, 27.9, 212),
  (60, 130, -13, 32.9, 220),
  (62, 75, -39, 32.4, 290),
  (64, 8, -3, 32.9, 292),
  (65, -23, 14, 33.1, 292),
  (67, -89, 40, 33.0, 287),
  (69, -153, 64, 33.0, 286),
  (70, -184, 74, 33.0, 286),
  (72, -246, 92, 33.0, 286),
  (74, -295, 70, 33.0, 286),
];

/// The loop as fixes, starting at second [at], shifted by [east]/[north].
Iterable<GnssFix> loopFixes({int at = 0, double east = 0, double north = 0}) =>
    spoofedLoop.map(
      (p) => fix(
        at + p.$1,
        east: east + p.$2,
        north: north + p.$3,
        speed: p.$4,
        course: p.$5,
      ),
    );

void main() {
  test('a normal drive is healthy', () {
    final c = GnssSanityChecker();
    for (var t = 0; t < 120; t++) {
      final h = c.check(
        fix(t, east: 30.0 * t, speed: 30, course: 90),
        radio: radio(t, 30.0 * t + 40, 20, 50),
      );
      expect(h.verdict, GnssVerdict.ok, reason: 't=$t $h');
      expect(h.usable, isTrue);
      expect(h.anomalies, isEmpty);
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

  group('the recorded loop', () {
    test('is recognised by its corners, whatever else is known', () {
      // The app is started under the spoofer: nothing to compare with.
      final c = GnssSanityChecker();
      int? flaggedAt;
      var contaminated = 0;
      for (final f in loopFixes()) {
        final h = c.check(f);
        final t = f.receivedAt.difference(t0).inSeconds;
        if (h.contaminated) contaminated++;
        if (h.spoofingSuspected) {
          flaggedAt ??= t;
          expect(h.anomalies, contains(GnssAnomaly.impossibleMotion));
        } else {
          expect(flaggedAt, isNull, reason: 'let go at $t s');
        }
        expect(h.settled, isFalse, reason: 'taught the database at $t s');
      }
      // The first corner is 25 s in.
      expect(flaggedAt, 25);
      // Whoever followed the first 25 s is told once to start again.
      expect(contaminated, 1);
    });

    test('is recognised at once on a device that lies still', () {
      final c = GnssSanityChecker();
      for (var t = -10; t <= 0; t++) {
        c.noteStill(t0.add(Duration(seconds: t)));
      }
      for (final f in loopFixes()) {
        c.noteStill(f.receivedAt);
        final h = c.check(f);
        expect(h.spoofingSuspected, isTrue);
        expect(h.anomalies, contains(GnssAnomaly.motionMismatch));
      }
    });

    test('is never followed when the car drives into it, and the real '
        'position is taken back the moment it returns', () {
      final c = GnssSanityChecker();
      // Two minutes of town driving east at 54 km/h.
      for (var t = 0; t < 120; t++) {
        expect(
          c.check(fix(t, east: 15.0 * t, speed: 15, course: 90)).usable,
          isTrue,
        );
      }
      // The receiver is thrown onto the loop 5 km to the north.
      for (final f in loopFixes(at: 120, east: 1800, north: 5000)) {
        final h = c.check(f);
        expect(h.usable, isFalse, reason: '${f.receivedAt}');
        // Nothing of it was ever handed out: nothing to undo.
        expect(h.contaminated, isFalse);
      }
      expect(c.health.spoofingSuspected, isTrue);
      expect(c.health.anomalies, contains(GnssAnomaly.positionJump));
      // Out of the spoofer's range: back on the road, 75 s further on.
      final h = c.check(fix(195, east: 15.0 * 195, speed: 15, course: 90));
      expect(h.verdict, GnssVerdict.ok);
      expect(h.usable, isTrue);
    });
  });

  group('teleports', () {
    test('a jump to a fixed false point is not followed', () {
      final c = GnssSanityChecker();
      for (var t = 0; t < 120; t++) {
        c.check(fix(t));
      }
      // 800 m away in one second while reporting standstill. The first
      // seconds are withheld quietly, then it is called what it is.
      var h = c.check(fix(120, east: 800));
      expect(h.usable, isFalse);
      expect(h.spoofingSuspected, isFalse);
      for (var t = 121; t < 220; t++) {
        h = c.check(fix(t, east: 800));
        expect(h.usable, isFalse);
        if (t >= 124) {
          expect(h.verdict, GnssVerdict.suspect);
          expect(h.anomalies, {GnssAnomaly.positionJump});
        }
      }
      // And from there to another one.
      for (var t = 220; t < 260; t++) {
        expect(c.check(fix(t, east: -2500, north: 900)).usable, isFalse);
      }
      // Back where the device is: believed at once.
      h = c.check(fix(260, east: 3));
      expect(h.verdict, GnssVerdict.ok);
      expect(h.usable, isTrue);
      expect(h.anomalies, isEmpty);
    });

    test('a one-off glitch costs one epoch and no alarm', () {
      final c = GnssSanityChecker();
      for (var t = 0; t < 60; t++) {
        c.check(fix(t, east: 15.0 * t, speed: 15, course: 90));
      }
      final glitch = c.check(
        fix(60, east: 900, north: 400, speed: 15, course: 90),
      );
      expect(glitch.usable, isFalse);
      expect(glitch.spoofingSuspected, isFalse);
      final back = c.check(fix(61, east: 15.0 * 61, speed: 15, course: 90));
      expect(back.usable, isTrue);
      expect(back.spoofingSuspected, isFalse);
    });

    test('started under a spoofer: the longer track wins', () {
      final c = GnssSanityChecker();
      // Ten seconds at a false point, with nothing to tell it by.
      for (var t = 0; t < 10; t++) {
        expect(c.check(fix(t, east: 20000)).usable, isTrue);
      }
      // The real position appears 20 km away and stays.
      for (var t = 10; t < 40; t++) {
        expect(c.check(fix(t)).usable, isFalse);
      }
      expect(c.check(fix(41)).usable, isTrue);
    });

    test('the far end of a tunnel is not a teleport', () {
      final c = GnssSanityChecker();
      for (var t = 0; t < 30; t++) {
        c.check(fix(t, east: 20.0 * t, speed: 20, course: 90));
      }
      // A minute without a fix, 1.2 km further on.
      final h = c.check(fix(90, east: 20.0 * 90, speed: 20, course: 90));
      expect(h.usable, isTrue);
      expect(h.anomalies, isEmpty);
    });

    test('fast but consistent motion is not a jump', () {
      final c = GnssSanityChecker();
      for (var t = 0; t < 30; t++) {
        // 250 km/h train.
        expect(
          c.check(fix(t, east: 70.0 * t, speed: 70, course: 90)).usable,
          isTrue,
        );
      }
      // Small wander while parked is fine too.
      final d = GnssSanityChecker();
      for (var t = 0; t < 30; t++) {
        expect(d.check(fix(t, east: t.isEven ? 0 : 25)).usable, isTrue);
      }
    });
  });

  group('motion a vehicle can make', () {
    test('hard braking and a sharp junction are fine', () {
      final c = GnssSanityChecker();
      var x = 0.0, v = 25.0;
      var t = 0;
      // Emergency stop at 8 m/s^2.
      for (; v > 9; t++, v -= 8) {
        x += v;
        expect(c.check(fix(t, east: x, speed: v, course: 90)).usable, isTrue);
      }
      // Right turn at 32 km/h in three seconds.
      var y = 0.0;
      for (final course in [90.0, 120.0, 150.0, 180.0, 180.0]) {
        x += 9 * 0.6;
        y -= 9 * 0.6;
        final h = c.check(
          fix(t++, east: x, north: y, speed: 9, course: course),
        );
        expect(h.usable, isTrue, reason: '$h');
      }
      // Course is noise at walking pace: a flip there means nothing.
      for (final course in [0.0, 180.0, 10.0, 200.0]) {
        final h = c.check(
          fix(t++, east: x, north: y, speed: 1.2, course: course),
        );
        expect(h.usable, isTrue, reason: '$h');
      }
    });

    test('a U-turn in a second at motorway speed is not', () {
      final c = GnssSanityChecker();
      for (var t = 0; t < 5; t++) {
        c.check(fix(t, east: 30.0 * t, speed: 30, course: 90));
      }
      final h = c.check(fix(5, east: 30.0 * 4.5, speed: 30, course: 270));
      expect(h.anomalies, contains(GnssAnomaly.impossibleMotion));
      expect(h.verdict, GnssVerdict.suspect);
    });

    test('the car\'s own speed contradicts the receiver', () {
      final c = GnssSanityChecker();
      GnssHealth? h;
      for (var t = 0; t < 8; t++) {
        final at = t0.add(Duration(seconds: t));
        c.noteSpeed(12, at); // OBD: 43 km/h
        h = c.check(fix(t, east: 33.0 * t, speed: 33, course: 90));
        expect(h.spoofingSuspected, t >= 4, reason: 't=$t');
      }
      expect(h!.anomalies, {GnssAnomaly.motionMismatch});
      // The same speeds agreeing are fine.
      final d = GnssSanityChecker();
      for (var t = 0; t < 8; t++) {
        d.noteSpeed(31, t0.add(Duration(seconds: t)));
        expect(
          d.check(fix(t, east: 33.0 * t, speed: 33, course: 90)).usable,
          isTrue,
        );
      }
    });

    test('lying still says nothing about a receiver that agrees', () {
      final c = GnssSanityChecker();
      for (var t = 0; t < 30; t++) {
        c.noteStill(t0.add(Duration(seconds: t)));
        expect(c.check(fix(t, east: t.isEven ? 0 : 3)).usable, isTrue);
      }
    });
  });

  group('radio estimate', () {
    test('a lasting contradiction flags spoofing', () {
      final c = GnssSanityChecker();
      // Radio says we are at the origin (within 60 m); GNSS claims 3 km
      // away. A track this fresh is withheld while the question is open.
      for (var t = 0; t < 10; t++) {
        final h = c.check(fix(t, east: 3000), radio: radio(t, 0, 0, 60));
        expect(h.verdict, GnssVerdict.ok, reason: 't=$t');
        expect(h.usable, isFalse);
      }
      final h = c.check(fix(10, east: 3000), radio: radio(10, 0, 0, 60));
      expect(h.verdict, GnssVerdict.suspect);
      expect(h.anomalies, contains(GnssAnomaly.radioMismatch));
      expect(h.usable, isFalse);
      expect(h.contaminated, isFalse);

      // Still flagged while the disagreement lasts, however long.
      for (var t = 11; t < 200; t++) {
        expect(
          c.check(fix(t, east: 3000), radio: radio(t, 0, 0, 60)).verdict,
          GnssVerdict.suspect,
        );
      }
      // GNSS comes back to the truth: the radio confirms it and clears it.
      final back = c.check(fix(200, east: 10), radio: radio(200, 0, 0, 60));
      expect(back.verdict, GnssVerdict.ok);
      expect(back.usable, isTrue);
      expect(back.settled, isTrue);
    });

    test('a track that was trusted is disowned when the radio insists', () {
      final c = GnssSanityChecker();
      for (var t = 0; t < 400; t++) {
        expect(c.check(fix(t), radio: radio(t, 0, 0, 60)).usable, isTrue);
      }
      // Slow drag-off: 10 m/s, no jump anywhere.
      GnssHealth? flagged;
      for (var t = 400; t < 500; t++) {
        final h = c.check(
          fix(t, east: 10.0 * (t - 400), speed: 10, course: 90),
          radio: radio(t, 0, 0, 60),
        );
        if (h.spoofingSuspected) {
          flagged = h;
          break;
        }
      }
      expect(flagged, isNotNull);
      expect(flagged!.anomalies, contains(GnssAnomaly.radioMismatch));
      expect(flagged.contaminated, isTrue);
    });

    test('a scan that lags behind a moving car is not a contradiction', () {
      final c = GnssSanityChecker();
      for (var t = 0; t < 120; t++) {
        // The estimate describes where the car was 25 s ago.
        final then = math.max(0, t - 25);
        final h = c.check(
          fix(t, east: 30.0 * t, speed: 30, course: 90),
          radio: radio(then, 30.0 * then + 60, 0, 40),
        );
        expect(h.usable, isTrue, reason: 't=$t $h');
      }
    });

    test('a passing bus hotspot does not take the satellites away', () {
      final c = GnssSanityChecker();
      for (var t = 0; t < 60; t++) {
        c.check(fix(t, east: 15.0 * t, speed: 15, course: 90));
      }
      // Eight seconds of an estimate 1.5 km off, then nothing.
      for (var t = 60; t < 90; t++) {
        final h = c.check(
          fix(t, east: 15.0 * t, speed: 15, course: 90),
          radio: t < 68 ? radio(t, 15.0 * t + 1500, 0, 40) : null,
        );
        expect(h.usable, isTrue, reason: 't=$t $h');
      }
    });

    test('a coarse cell estimate: only gross spoofing is flagged', () {
      PositionEstimate cell(int t) =>
          radio(t, 0, 0, 180, source: PositionSource.cell);
      // 3 km from a cell an open database puts within 180 m: these
      // databases are too sure of themselves to argue with.
      final c = GnssSanityChecker();
      for (var t = 0; t < 60; t++) {
        expect(c.check(fix(t, east: 3000), radio: cell(t)).usable, isTrue);
      }
      // 40 km away is another matter.
      final d = GnssSanityChecker();
      for (var t = 0; t < 12; t++) {
        d.check(fix(t, east: 40000), radio: cell(t));
      }
      expect(d.health.anomalies, contains(GnssAnomaly.radioMismatch));
    });

    test('a stale estimate is not used as evidence', () {
      final c = GnssSanityChecker();
      for (var t = 100; t < 130; t++) {
        expect(
          c.check(fix(t, east: 3000), radio: radio(0, 0, 0, 60)).usable,
          isTrue,
        );
      }
    });
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
    // Recovery: real sky again; the flag is held for 20 s, then cleared.
    expect(c.check(fix(3)).verdict, GnssVerdict.suspect);
    expect(c.check(fix(21)).verdict, GnssVerdict.suspect);
    expect(c.check(fix(23)).verdict, GnssVerdict.ok);
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

  test('the system clock being set is not spoofing', () {
    final c = GnssSanityChecker();
    for (var t = 0; t < 5; t++) {
      expect(c.check(fix(t)).usable, isTrue);
    }
    // The network corrected the phone's clock by two minutes: GNSS time
    // "steps" against it while the position carries on undisturbed.
    for (var t = 5; t < 10; t++) {
      final h = c.check(fix(t, gnssTime: t0.add(Duration(seconds: t + 120))));
      expect(h.usable, isTrue);
      expect(h.anomalies, isEmpty);
    }
  });

  test('a time step together with a teleport is reported', () {
    final c = GnssSanityChecker();
    for (var t = 0; t < 60; t++) {
      c.check(fix(t));
    }
    GnssHealth? h;
    for (var t = 60; t < 70; t++) {
      h = c.check(
        fix(t, east: 30000, gnssTime: t0.add(Duration(days: 400, seconds: t))),
      );
    }
    expect(h!.verdict, GnssVerdict.suspect);
    expect(h.anomalies, {GnssAnomaly.positionJump, GnssAnomaly.timeJump});
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

  test('a new track teaches the database only once it has settled', () {
    final c = GnssSanityChecker();
    for (var t = 0; t < 60; t++) {
      final h = c.check(fix(t, east: 10.0 * t, speed: 10, course: 90));
      expect(h.usable, isTrue);
      expect(h.settled, t >= 45, reason: 't=$t');
    }
  });

  test('reset forgets everything', () {
    final c = GnssSanityChecker();
    for (var t = 0; t < 60; t++) {
      c.check(fix(t));
    }
    for (var t = 60; t < 70; t++) {
      c.check(fix(t, east: 50000));
    }
    expect(c.health.verdict, GnssVerdict.suspect);
    c.reset();
    expect(c.health.verdict, GnssVerdict.noFix);
    expect(c.check(fix(70, east: 50000)).usable, isTrue);
  });
}
