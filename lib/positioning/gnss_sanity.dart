/// GNSS plausibility checks: detects likely spoofing / jamming so the fusion
/// filter and the wardriving collector can ignore a lying receiver.
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

  /// Position jumped further than speed and accuracy allow.
  positionJump,

  /// GNSS time stepped against the system clock.
  timeJump,

  /// Satellites are tracked but all are very weak, or the fix was lost
  /// abruptly: possible jamming (or simply indoors).
  weakSignal,
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
  });

  final GnssVerdict verdict;

  /// Anomalies currently active (including those being held).
  final Set<GnssAnomaly> anomalies;
  final double? cn0Mean;
  final double? cn0StdDev;
  final int satellitesWithSignal;

  /// True when this very epoch contradicts the radio estimate but the
  /// contradiction has not lasted long enough to call it spoofing. Such an
  /// epoch is withheld from fusion so one bad fix cannot drag the position.
  final bool unconfirmed;

  /// True when the fix may be used for positioning and wardriving.
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
    this.radioMismatchMarginM = 100,
    this.radioMismatchCount = 2,
    this.maxRadioAge = const Duration(seconds: 45),
    this.uniformCn0StdDev = 1.5,
    this.uniformCn0MinSats = 6,
    this.uniformCn0Count = 3,
    this.jumpMarginM = 30,
    this.jumpMinSpeedMps = 15,
    this.timeJump = const Duration(seconds: 5),
    this.weakCn0 = 22,
    this.hold = const Duration(seconds: 60),
    this.confirmAccuracyM = 150,
  });

  /// Mismatch when distance > factor * (accGnss + accRadio) + margin.
  final double radioMismatchFactor;
  final double radioMismatchMarginM;

  /// Consecutive mismatching epochs needed.
  final int radioMismatchCount;
  final Duration maxRadioAge;

  /// Real skies show 4-10 dB-Hz of spread (elevation, obstruction); a single
  /// spoofing transmitter gives every PRN about the same level.
  final double uniformCn0StdDev;
  final int uniformCn0MinSats;
  final int uniformCn0Count;

  /// Slack on top of speed * dt and 3 * accuracies before calling a jump.
  final double jumpMarginM;

  /// Jumps slower than this implied speed are treated as normal wander.
  final double jumpMinSpeedMps;
  final Duration timeJump;

  /// Strongest satellite below this (dB-Hz) = unusably weak signal.
  final double weakCn0;

  /// How long a suspicion is kept after the last anomalous epoch.
  final Duration hold;

  /// A radio estimate at least this accurate that agrees with GNSS clears a
  /// held position jump immediately.
  final double confirmAccuracyM;
}

/// Stateful checker; feed it every epoch in order.
class GnssSanityChecker {
  GnssSanityChecker({this.config = const GnssSanityConfig()});

  final GnssSanityConfig config;

  GnssFix? _prev;
  Duration? _clockOffset;
  int _mismatchRun = 0;
  int _uniformRun = 0;
  DateTime? _lastFixAt;
  final Map<GnssAnomaly, DateTime> _active = {};

  /// Latest verdict.
  GnssHealth health = const GnssHealth(verdict: GnssVerdict.noFix);

  void reset() {
    _prev = null;
    _clockOffset = null;
    _mismatchRun = 0;
    _uniformRun = 0;
    _lastFixAt = null;
    _active.clear();
    health = const GnssHealth(verdict: GnssVerdict.noFix);
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

    if (fix.hasPosition) {
      _lastFixAt = now;

      // --- time step -----------------------------------------------------
      final t = fix.time;
      if (t != null) {
        final offset = t.difference(now.toUtc());
        final old = _clockOffset;
        if (old != null && (offset - old).abs() > cfg.timeJump) {
          _active[GnssAnomaly.timeJump] = now;
        }
        _clockOffset = offset;
      }

      // --- position jump -------------------------------------------------
      final p = _prev;
      if (p != null && p.hasPosition) {
        final dt = now.difference(p.receivedAt).inMilliseconds / 1000.0;
        if (dt > 0 && dt <= 10) {
          final d = haversineM(p.lat!, p.lon!, fix.lat!, fix.lon!);
          final v = math.max(p.speedMps ?? 0, fix.speedMps ?? 0);
          final allowed =
              1.5 * v * dt +
              3 * ((p.accuracyM ?? 10) + (fix.accuracyM ?? 10)) +
              cfg.jumpMarginM;
          if (d > allowed && d / dt > cfg.jumpMinSpeedMps) {
            _active[GnssAnomaly.positionJump] = now;
          }
        }
      }

      // --- disagreement with radio positioning ---------------------------
      if (radio != null &&
          now.difference(radio.timestamp).abs() <= cfg.maxRadioAge) {
        final d = haversineM(fix.lat!, fix.lon!, radio.lat, radio.lon);
        final limit =
            cfg.radioMismatchFactor *
                ((fix.accuracyM ?? 10) + radio.accuracyM) +
            cfg.radioMismatchMarginM;
        if (d > limit) {
          if (++_mismatchRun >= cfg.radioMismatchCount) {
            _active[GnssAnomaly.radioMismatch] = now;
          }
        } else {
          _mismatchRun = 0;
          _active.remove(GnssAnomaly.radioMismatch);
          // A Wi-Fi-grade estimate confirming the position also settles a
          // held jump (typically the jump back when a spoofer stops). A
          // coarse cell estimate is too weak evidence for that.
          if (radio.accuracyM <= cfg.confirmAccuracyM) {
            _active.remove(GnssAnomaly.positionJump);
          }
        }
      } else {
        // No current radio evidence either way.
        _mismatchRun = 0;
      }
      _prev = fix;
    }

    // Expire held anomalies.
    _active.removeWhere(
      (a, at) => a != GnssAnomaly.weakSignal && now.difference(at) > cfg.hold,
    );

    final spoof = _active.keys.any((a) => a != GnssAnomaly.weakSignal);
    final verdict = !fix.hasPosition
        ? GnssVerdict.noFix
        : (spoof ? GnssVerdict.suspect : GnssVerdict.ok);
    return health = GnssHealth(
      verdict: verdict,
      anomalies: Set.of(_active.keys),
      cn0Mean: mean,
      cn0StdDev: std,
      satellitesWithSignal: signals.length,
      unconfirmed: fix.hasPosition && _mismatchRun > 0,
    );
  }
}
