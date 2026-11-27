/// GNSS plausibility checks: detects likely spoofing / jamming so the fusion
/// filter and the wardriving collector can ignore a lying receiver.
///
/// The checker follows the receiver's *track*. A real receiver moves the way
/// a vehicle can: no teleports, no 150 degree turns at motorway speed, no
/// 120 km/h while the device lies on a table. A spoofer breaks one of these
/// sooner or later, and the moment it stops the receiver comes back to where
/// the device could have got to meanwhile. Rationale and the field data
/// behind the numbers: docs/positioning.md.
library;

import 'dart:math' as math;

import 'geo.dart';
import 'models.dart';

/// Individual findings.
enum GnssAnomaly {
  /// GNSS position contradicts the Wi-Fi/cell estimate.
  radioMismatch,

  /// All satellites have nearly the same C/N0 (single transmitter).
  uniformCn0,

  /// The position teleported: further than the device could have travelled
  /// from the last place it was trusted at.
  positionJump,

  /// GNSS time stepped against the system clock together with the position.
  timeJump,

  /// Satellites are tracked but all are very weak, or the fix was lost
  /// abruptly: possible jamming (or simply indoors).
  weakSignal,

  /// A turn or a change of speed no vehicle can make.
  impossibleMotion,

  /// The receiver reports a speed the device itself contradicts: it lies
  /// still, or the vehicle's own speed sensor says otherwise.
  motionMismatch,
}

/// Overall verdict.
enum GnssVerdict {
  /// No usable position.
  noFix,

  /// Position looks genuine.
  ok,

  /// Likely spoofed: must not be used for fusion or wardriving.
  suspect,
}

/// Result of one check.
class GnssHealth {
  const GnssHealth({
    required this.verdict,
    this.anomalies = const {},
    this.cn0Mean,
    this.cn0StdDev,
    this.satellitesWithSignal = 0,
    this.unconfirmed = false,
    this.settled = false,
    this.contaminated = false,
    this.fallback,
  });

  final GnssVerdict verdict;

  /// Anomalies currently active (including those being held).
  final Set<GnssAnomaly> anomalies;
  final double? cn0Mean;
  final double? cn0StdDev;
  final int satellitesWithSignal;

  /// True when this very epoch is doubtful but the doubt has not lasted
  /// long enough to call it spoofing (the first seconds after a jump, a
  /// fresh track the radio estimate disagrees with). Such an epoch is
  /// withheld from fusion so one bad fix cannot drag the position.
  final bool unconfirmed;

  /// True when the track has been trusted long enough to teach the
  /// database from it. Stricter than [usable]: a spoofer is typically
  /// recognised within half a minute, and nothing may be learnt meanwhile.
  final bool settled;

  /// Set on the epoch suspicion starts when fixes of this same track were
  /// already handed out as [usable]: whoever followed them was misled and
  /// should start again from [fallback] or from the radio estimate.
  final bool contaminated;

  /// Where the receiver was last trusted before the suspected track began,
  /// with an accuracy that covers the time gone by. Only with
  /// [contaminated]; null when there is no such place.
  final PositionEstimate? fallback;

  /// True when the fix may be used for positioning.
  bool get usable => verdict == GnssVerdict.ok && !unconfirmed;

  /// True when spoofing is suspected.
  bool get spoofingSuspected => verdict == GnssVerdict.suspect;

  /// True when jamming is a plausible explanation for a missing/weak fix.
  bool get jammingSuspected => anomalies.contains(GnssAnomaly.weakSignal);

  @override
  String toString() =>
      'GnssHealth(${verdict.name} ${anomalies.map((a) => a.name).toList()} '
      'cn0 ${cn0Mean?.toStringAsFixed(1)}±${cn0StdDev?.toStringAsFixed(1)})';
}

/// Tunables; rationale in docs/positioning.md.
class GnssSanityConfig {
  const GnssSanityConfig({
    this.radioMismatchFactor = 3.0,
    this.radioMismatchMarginM = 300,
    this.radioLagAllowance = const Duration(seconds: 10),
    this.cellMismatchFactor = 5.0,
    this.cellMismatchMinM = 5000,
    this.radioMismatchFor = const Duration(seconds: 10),
    this.maxRadioAge = const Duration(seconds: 45),
    this.confirmAccuracyM = 150,
    this.uniformCn0StdDev = 1.5,
    this.uniformCn0MinSats = 6,
    this.uniformCn0Count = 3,
    this.jumpMarginM = 30,
    this.jumpMinSpeedMps = 15,
    this.trackGap = const Duration(seconds: 10),
    this.reachAccel = 4,
    this.reachMaxSpeedMps = 60,
    this.reachMarginM = 100,
    this.waryReachFactor = 1.5,
    this.waryReachExtraMps = 15,
    this.maxLateralAccel = 15,
    this.maxLinearAccel = 12,
    this.turnMinSpeedMps = 8,
    this.stillFor = const Duration(seconds: 8),
    this.stillMinSpeedMps = 5,
    this.speedMismatchMps = 8,
    this.speedMismatchFraction = 0.4,
    this.speedMismatchCount = 5,
    this.timeJump = const Duration(seconds: 5),
    this.weakCn0 = 22,
    this.jumpGrace = const Duration(seconds: 4),
    this.minProbation = const Duration(seconds: 30),
    this.maxProbation = const Duration(minutes: 5),
    this.settleAfter = const Duration(seconds: 45),
    this.rollbackWithin = const Duration(minutes: 5),
    this.radioHold = const Duration(seconds: 60),
    this.motionHold = const Duration(seconds: 45),
    this.shortHold = const Duration(seconds: 20),
  });

  /// Wi-Fi-grade estimate: mismatch when the distance exceeds
  /// factor * (accGnss + accRadio) + margin + speed * lag.
  final double radioMismatchFactor;
  final double radioMismatchMarginM;

  /// Extra age credited to a radio estimate: scans are older than they say.
  final Duration radioLagAllowance;

  /// Coarse estimate (cells, a single access point): only a gross
  /// contradiction counts, at least [cellMismatchMinM]. Open cell databases
  /// are too optimistic about their own accuracy to argue over less.
  final double cellMismatchFactor;
  final double cellMismatchMinM;

  /// The contradiction must last this long without a single agreement.
  final Duration radioMismatchFor;
  final Duration maxRadioAge;

  /// A radio estimate at least this accurate that agrees with GNSS settles
  /// a doubtful track at once.
  final double confirmAccuracyM;

  /// Real skies show 4-10 dB-Hz of spread (elevation, obstruction); a single
  /// spoofing transmitter gives every PRN about the same level.
  final double uniformCn0StdDev;
  final int uniformCn0MinSats;
  final int uniformCn0Count;

  /// Slack on top of speed * dt and 3 * accuracies before two consecutive
  /// fixes are called a break of the track.
  final double jumpMarginM;

  /// Breaks slower than this implied speed are treated as normal wander.
  final double jumpMinSpeedMps;

  /// Silence longer than this starts a new track too (a tunnel).
  final Duration trackGap;

  /// How far the device may have got from the last trusted fix: it speeds
  /// up by at most [reachAccel] m/s^2 to at most [reachMaxSpeedMps].
  final double reachAccel;
  final double reachMaxSpeedMps;
  final double reachMarginM;

  /// While spoofing is suspected: the device is assumed to have kept to at
  /// most the larger of factor * its last speed and that speed + extra.
  final double waryReachFactor;
  final double waryReachExtraMps;

  /// Sideways / lengthwise acceleration no road vehicle reaches (m/s^2).
  final double maxLateralAccel;
  final double maxLinearAccel;

  /// Course is only meaningful (and a turn only checked) above this speed.
  final double turnMinSpeedMps;

  /// The device lying still this long contradicts a reported speed of at
  /// least [stillMinSpeedMps].
  final Duration stillFor;
  final double stillMinSpeedMps;

  /// Disagreement with the vehicle's own speed: more than the larger of
  /// [speedMismatchMps] and [speedMismatchFraction] of it, this many epochs
  /// in a row.
  final double speedMismatchMps;
  final double speedMismatchFraction;
  final int speedMismatchCount;
  final Duration timeJump;

  /// Strongest satellite below this (dB-Hz) = unusably weak signal.
  final double weakCn0;

  /// A teleported track is withheld silently this long before it is
  /// reported as spoofing (a one-off multipath glitch is back by then).
  final Duration jumpGrace;

  /// A teleported track that shows nothing else wrong is believed after it
  /// has lasted as long as the track it replaced, within these bounds.
  final Duration minProbation;
  final Duration maxProbation;

  /// See [GnssHealth.settled].
  final Duration settleAfter;

  /// A track flagged this soon after it began is disowned from its start.
  final Duration rollbackWithin;

  /// How long each kind of finding is kept after it was last seen.
  final Duration radioHold;
  final Duration motionHold;
  final Duration shortHold;
}

class _Anchor {
  _Anchor(this.fix, this.clockOffset, this.trackAge);
  final GnssFix fix;
  final Duration? clockOffset;

  /// How long its track had been trusted when this fix was taken.
  final Duration trackAge;
}

class _Track {
  _Track(this.startedAt, this.before);
  final DateTime startedAt;

  /// The last trusted fix of the track before this one.
  final _Anchor? before;

  /// Began with a teleport: not believed until corroborated.
  bool candidate = false;
  bool timeStepped = false;
  bool corroborated = false;

  /// Some of its fixes were handed out as usable.
  bool fed = false;
}

/// Stateful checker; feed it every epoch in order.
class GnssSanityChecker {
  GnssSanityChecker({this.config = const GnssSanityConfig()});

  final GnssSanityConfig config;

  GnssFix? _prev;
  _Track? _track;
  _Anchor? _anchor;
  Duration? _clockOffset;
  DateTime? _mismatchSince;
  int _uniformRun = 0;
  int _speedRun = 0;
  DateTime? _lastFixAt;
  DateTime? _stillSince, _stillAt;
  double? _externalSpeed;
  DateTime? _externalSpeedAt;
  bool _wasSuspect = false;
  final List<GnssFix> _history = [];
  final Map<GnssAnomaly, DateTime> _active = {};

  /// Latest verdict.
  GnssHealth health = const GnssHealth(verdict: GnssVerdict.noFix);

  void reset() {
    _prev = null;
    _track = null;
    _anchor = null;
    _clockOffset = null;
    _mismatchSince = null;
    _uniformRun = 0;
    _speedRun = 0;
    _lastFixAt = null;
    _stillSince = _stillAt = null;
    _externalSpeed = null;
    _externalSpeedAt = null;
    _wasSuspect = false;
    _history.clear();
    _active.clear();
    health = const GnssHealth(verdict: GnssVerdict.noFix);
  }

  /// The device's motion sensors show it lying still at [time]. Call about
  /// once a second for as long as that holds.
  void noteStill(DateTime time) {
    final last = _stillAt;
    if (last == null ||
        time.difference(last).abs() > const Duration(seconds: 3)) {
      _stillSince = time;
    }
    _stillAt = time;
  }

  /// The vehicle's own speed (OBD, wheel sensor) at [time].
  void noteSpeed(double speedMps, DateTime time) {
    _externalSpeed = speedMps;
    _externalSpeedAt = time;
  }

  Duration _hold(GnssAnomaly a) => switch (a) {
    GnssAnomaly.radioMismatch => config.radioHold,
    GnssAnomaly.impossibleMotion => config.motionHold,
    _ => config.shortHold,
  };

  static double _seconds(Duration d) => d.inMicroseconds / 1e6;

  /// Time between two epochs: by the receiver's own clock when both carry
  /// it (arrival times bunch up when the app is busy), else by arrival.
  static double _dt(GnssFix a, GnssFix b) {
    final arrival = _seconds(b.receivedAt.difference(a.receivedAt));
    final ta = a.time, tb = b.time;
    if (ta != null && tb != null) {
      final own = _seconds(tb.difference(ta));
      if (own > 0 && own <= 30 && own > arrival) return own;
    }
    return arrival;
  }

  /// Whether the device could have got from [from] to [fix] by [now].
  ///
  /// With nothing suspected the bound is generous: flat out, as after a
  /// tunnel. While a spoofer is at work ([wary]) the next place it throws
  /// the receiver to must not pass just because time has gone by, so the
  /// device is assumed to have carried on about as fast as it was going.
  bool _reachable(
    _Anchor from,
    GnssFix fix,
    DateTime now, {
    required bool wary,
  }) {
    final cfg = config;
    final age = math.max(0.0, _seconds(now.difference(from.fix.receivedAt)));
    final v0 = from.fix.speedMps ?? 0;
    final double travel;
    final stillAt = _stillAt, stillSince = _stillSince;
    if (stillAt != null &&
        stillSince != null &&
        now.difference(stillAt).abs() <= const Duration(seconds: 3) &&
        !stillSince.isAfter(from.fix.receivedAt)) {
      // It has not moved since.
      travel = 0;
    } else if (wary) {
      travel =
          math.min(
            cfg.reachMaxSpeedMps,
            math.max(cfg.waryReachFactor * v0, v0 + cfg.waryReachExtraMps),
          ) *
          age;
    } else {
      // Speeding up at reachAccel until reachMaxSpeed, then holding it.
      final tUp = math.max(0.0, (cfg.reachMaxSpeedMps - v0) / cfg.reachAccel);
      final t1 = math.min(age, tUp);
      travel =
          v0 * t1 +
          cfg.reachAccel * t1 * t1 / 2 +
          cfg.reachMaxSpeedMps * (age - t1);
    }
    final reach =
        travel +
        3 * ((from.fix.accuracyM ?? 10) + (fix.accuracyM ?? 10)) +
        cfg.reachMarginM;
    return haversineM(from.fix.lat!, from.fix.lon!, fix.lat!, fix.lon!) <=
        reach;
  }

  /// Checks [fix]. [radio] is the current Wi-Fi/cell estimate if any; it
  /// must be independent of GNSS (it is: it only uses the database).
  GnssHealth check(GnssFix fix, {PositionEstimate? radio}) {
    final now = fix.receivedAt;
    final cfg = config;

    // --- C/N0 statistics -------------------------------------------------
    var signals = [
      for (final s in fix.satellites)
        if (s.used && s.cn0 != null && s.cn0! > 0) s.cn0!,
    ];
    if (signals.length < cfg.uniformCn0MinSats) {
      signals = [
        for (final s in fix.satellites)
          if (s.cn0 != null && s.cn0! > 0) s.cn0!,
      ];
    }
    double? mean, std;
    if (signals.isNotEmpty) {
      mean = signals.reduce((a, b) => a + b) / signals.length;
      var v = 0.0;
      for (final s in signals) {
        v += (s - mean) * (s - mean);
      }
      std = math.sqrt(v / signals.length);
    }
    if (signals.length >= cfg.uniformCn0MinSats &&
        std! < cfg.uniformCn0StdDev) {
      if (++_uniformRun >= cfg.uniformCn0Count) {
        _active[GnssAnomaly.uniformCn0] = now;
      }
    } else if (signals.isNotEmpty) {
      _uniformRun = 0;
    }

    // --- weak signal / abrupt loss (jamming hint) ------------------------
    final maxCn0 = signals.isEmpty ? null : signals.reduce(math.max);
    final lostAbruptly =
        !fix.hasPosition &&
        _lastFixAt != null &&
        now.difference(_lastFixAt!) < const Duration(seconds: 30) &&
        (maxCn0 == null || maxCn0 < cfg.weakCn0);
    if (lostAbruptly ||
        (fix.satellites.length >= 4 &&
            maxCn0 != null &&
            maxCn0 < cfg.weakCn0)) {
      _active[GnssAnomaly.weakSignal] = now;
    } else {
      _active.remove(GnssAnomaly.weakSignal);
    }

    var unconfirmed = false;
    var settled = false;
    var suspect = false;
    var contaminated = false;
    PositionEstimate? fallback;

    if (fix.hasPosition) {
      _lastFixAt = now;
      final offset = fix.time?.difference(now.toUtc());

      // --- is this still the same track? ---------------------------------
      final p = _prev;
      var track = _track;
      var broke = track == null || p == null;
      if (!broke) {
        final dt = _dt(p, fix);
        if (dt > _seconds(cfg.trackGap)) {
          broke = true;
        } else if (dt > 0) {
          final d = haversineM(p.lat!, p.lon!, fix.lat!, fix.lon!);
          final v = math.max(p.speedMps ?? 0, fix.speedMps ?? 0);
          final allowed =
              1.5 * v * dt +
              3 * ((p.accuracyM ?? 10) + (fix.accuracyM ?? 10)) +
              cfg.jumpMarginM;
          if (d > allowed && d / dt > cfg.jumpMinSpeedMps) broke = true;
        }
      }

      if (broke) {
        // A new track is believed when the device could have got here from
        // where it was last trusted: the way back from a spoofer, the far
        // end of a tunnel. Anywhere else is a teleport.
        final before = _anchor;
        final wary =
            (track != null && track.candidate) ||
            _active.keys.any((a) => a != GnssAnomaly.weakSignal);
        track = _track = _Track(now, before);
        _mismatchSince = null;
        _speedRun = 0;
        if (before != null) {
          if (!_reachable(before, fix, now, wary: wary)) {
            track.candidate = true;
          }
          final was = before.clockOffset;
          if (offset != null &&
              was != null &&
              (offset - was).abs() > cfg.timeJump) {
            track.candidate = true;
            track.timeStepped = true;
          }
          // Back where the device could be: what the previous track did
          // (its corners, its speed) is not held against this one.
          if (!track.candidate) {
            _active.remove(GnssAnomaly.impossibleMotion);
            _active.remove(GnssAnomaly.motionMismatch);
          }
        }
      } else if (p != null) {
        // --- can a vehicle move like this? -------------------------------
        final dt = _dt(p, fix);
        final v1 = p.speedMps, v2 = fix.speedMps;
        if (dt > 0 && dt <= 3 && v1 != null && v2 != null) {
          // Receivers report at 1-2 Hz; a shorter interval is a late epoch.
          final step = math.max(dt, 0.5);
          var impossible = (v2 - v1).abs() / step > cfg.maxLinearAccel;
          final c1 = p.courseDeg, c2 = fix.courseDeg;
          if (c1 != null &&
              c2 != null &&
              v1 >= cfg.turnMinSpeedMps &&
              v2 >= cfg.turnMinSpeedMps) {
            final turn = degToRad(((c2 - c1 + 540) % 360 - 180).abs());
            if (math.min(v1, v2) * turn / step > cfg.maxLateralAccel) {
              impossible = true;
            }
          }
          if (impossible) _active[GnssAnomaly.impossibleMotion] = now;
        }
      }
      track!;
      _clockOffset = offset ?? _clockOffset;

      // --- does the device itself agree about the speed? -----------------
      final speed = fix.speedMps;
      final stillAt = _stillAt, stillSince = _stillSince;
      if (speed != null &&
          speed >= cfg.stillMinSpeedMps &&
          stillAt != null &&
          stillSince != null &&
          now.difference(stillAt).abs() <= const Duration(seconds: 3) &&
          stillAt.difference(stillSince) >= cfg.stillFor) {
        _active[GnssAnomaly.motionMismatch] = now;
      }
      final ext = _externalSpeed, extAt = _externalSpeedAt;
      if (speed != null &&
          ext != null &&
          extAt != null &&
          now.difference(extAt).abs() <= const Duration(seconds: 3)) {
        final limit = math.max(
          cfg.speedMismatchMps,
          cfg.speedMismatchFraction * ext,
        );
        if ((speed - ext).abs() > limit) {
          if (++_speedRun >= cfg.speedMismatchCount) {
            _active[GnssAnomaly.motionMismatch] = now;
          }
        } else {
          _speedRun = 0;
        }
      }

      // --- disagreement with radio positioning ---------------------------
      _history.add(fix);
      while (_history.length > 1 &&
          now.difference(_history.first.receivedAt) > cfg.maxRadioAge) {
        _history.removeAt(0);
      }
      if (radio != null &&
          now.difference(radio.timestamp).abs() <= cfg.maxRadioAge) {
        // Compare with where the receiver was when the scan was taken.
        var ref = fix;
        var lag = now.difference(radio.timestamp).abs();
        for (final h in _history) {
          final l = h.receivedAt.difference(radio.timestamp).abs();
          if (l < lag) {
            lag = l;
            ref = h;
          }
        }
        final d = haversineM(ref.lat!, ref.lon!, radio.lat, radio.lon);
        final coarse =
            radio.source == PositionSource.cell ||
            radio.transmittersUsed == 1 ||
            radio.accuracyM > cfg.confirmAccuracyM;
        final moved =
            math.max(ref.speedMps ?? 0, speed ?? 0) *
            _seconds(lag + cfg.radioLagAllowance);
        final acc = (ref.accuracyM ?? 10) + radio.accuracyM;
        final limit = coarse
            ? math.max(
                    cfg.cellMismatchFactor * radio.accuracyM,
                    cfg.cellMismatchMinM,
                  ) +
                  moved
            : cfg.radioMismatchFactor * acc + cfg.radioMismatchMarginM + moved;
        if (d > limit) {
          final since = _mismatchSince ??= now;
          if (now.difference(since) >= cfg.radioMismatchFor) {
            _active[GnssAnomaly.radioMismatch] = now;
          }
        } else {
          _mismatchSince = null;
          _active.remove(GnssAnomaly.radioMismatch);
          // A Wi-Fi-grade estimate confirming the position settles a
          // doubtful track (typically the way back when a spoofer stops).
          // A coarse cell estimate is too weak evidence for that.
          if (!coarse) {
            track.candidate = false;
            track.corroborated = true;
          }
        }
      } else {
        // No current radio evidence either way.
        _mismatchSince = null;
      }
      _prev = fix;
    }

    // Expire held anomalies.
    _active.removeWhere(
      (a, at) => a != GnssAnomaly.weakSignal && now.difference(at) > _hold(a),
    );
    final signature = _active.keys.any((a) => a != GnssAnomaly.weakSignal);
    final anomalies = Set.of(_active.keys);

    final track = _track;
    if (fix.hasPosition && track != null) {
      final age = now.difference(track.startedAt);
      if (track.candidate && !signature) {
        // Nothing else wrong for as long as the previous track had lasted:
        // then that one was the lie (the app was started under a spoofer).
        final was = track.before?.trackAge ?? Duration.zero;
        final probation = was < cfg.minProbation
            ? cfg.minProbation
            : (was > cfg.maxProbation ? cfg.maxProbation : was);
        if (age >= probation) track.candidate = false;
      }
      if (track.candidate) {
        anomalies.add(GnssAnomaly.positionJump);
        if (track.timeStepped) anomalies.add(GnssAnomaly.timeJump);
        if (age < cfg.jumpGrace && !signature) {
          unconfirmed = true;
        } else {
          suspect = true;
        }
      }
      if (signature) suspect = true;
      // A fresh track the radio estimate disagrees with waits for the
      // answer; an established one keeps going until it is settled.
      if (!suspect && _mismatchSince != null && age < cfg.settleAfter) {
        unconfirmed = true;
      }

      if (suspect) {
        if (!_wasSuspect &&
            track.fed &&
            (age <= cfg.rollbackWithin ||
                anomalies.contains(GnssAnomaly.radioMismatch))) {
          contaminated = true;
          final before = track.before;
          _anchor = before;
          if (before != null) {
            final gone = _seconds(now.difference(before.fix.receivedAt));
            final radius =
                (before.fix.accuracyM ?? 10) +
                50 +
                math.max(before.fix.speedMps ?? 0, 15) * gone;
            if (radius <= 3000) {
              fallback = PositionEstimate(
                lat: before.fix.lat!,
                lon: before.fix.lon!,
                accuracyM: radius,
                source: PositionSource.deadReckoning,
                timestamp: now,
              );
            }
          }
        }
      } else if (!unconfirmed) {
        track.fed = true;
        _anchor = _Anchor(fix, _clockOffset, age);
        settled = track.corroborated || age >= cfg.settleAfter;
      }
    }
    _wasSuspect = suspect;

    final verdict = !fix.hasPosition
        ? GnssVerdict.noFix
        : (suspect ? GnssVerdict.suspect : GnssVerdict.ok);
    return health = GnssHealth(
      verdict: verdict,
      anomalies: anomalies,
      cn0Mean: mean,
      cn0StdDev: std,
      satellitesWithSignal: signals.length,
      unconfirmed: unconfirmed,
      settled: settled,
      contaminated: contaminated,
      fallback: fallback,
    );
  }
}
