/// Fusion filter: a constant-velocity Kalman filter on a local tangent plane
/// merging radio fixes, GNSS fixes (position + velocity) and an external
/// speed input into a smoothed position, speed and course.
library;

import 'dart:math' as math;

import 'geo.dart';
import 'models.dart';

/// Tunables; rationale in docs/positioning.md.
class FusionConfig {
  const FusionConfig({
    this.accelSigma = 2.0,
    this.gnssSpeedSigma = 0.5,
    this.externalSpeedSigma = 0.7,
    this.gate = 25.0,
    this.rejectionsBeforeReset = 3,
    this.stationarySpeed = 0.3,
    this.confidentVelocitySigma = 3.0,
    this.maxExtrapolation = const Duration(seconds: 30),
    this.speedHold = const Duration(seconds: 5),
    this.gnssFresh = const Duration(seconds: 3),
    this.radioFresh = const Duration(seconds: 35),
    this.speedFresh = const Duration(seconds: 3),
    this.correlatedRadioFloor = 0.5,
    this.initialSpeedSigma = 10.0,
    this.recenterDistanceM = 30000,
  });

  /// Process noise: standard deviation of the unmodelled acceleration,
  /// m/s^2. 2 m/s^2 covers normal car braking/cornering.
  final double accelSigma;

  /// Standard deviation of GNSS Doppler velocity per axis, m/s.
  final double gnssSpeedSigma;

  /// Standard deviation of the external (OBD) speed, m/s.
  final double externalSpeedSigma;

  /// Mahalanobis gate (squared) for radio position updates. 25 = 5 sigma.
  final double gate;

  /// After this many consecutive gated-out fixes the filter restarts at the
  /// new position: the fixes were right and the filter was lost.
  final int rejectionsBeforeReset;

  /// Below this measured speed a zero-velocity update is applied.
  final double stationarySpeed;

  /// Speed is only reported, and the position only extrapolated, when the
  /// along-track velocity standard deviation is below this (m/s). Course is
  /// reported when additionally the cross-track sigma is below half the
  /// speed (direction known to better than ~27 degrees).
  final double confidentVelocitySigma;

  /// Position is extrapolated at most this long past the last measurement.
  final Duration maxExtrapolation;

  /// Speed (and course) are reported at most this long past the last
  /// measurement; after that they are unknown (null), not guessed.
  final Duration speedHold;

  /// How long each kind of input counts as "current" for the source label.
  final Duration gnssFresh;
  final Duration radioFresh;
  final Duration speedFresh;

  /// Successive radio fixes share the same transmitters and therefore the
  /// same error; averaging them does not make the position better. While
  /// only radio fixes arrive, the reported accuracy is not allowed to drop
  /// below this fraction of the last radio fix's accuracy.
  final double correlatedRadioFloor;

  /// Initial velocity uncertainty per axis, m/s.
  final double initialSpeedSigma;

  /// The local projection is re-centred beyond this distance.
  final double recenterDistanceM;
}

/// The filter. Not thread-safe; call from one isolate.
class FusionFilter {
  FusionFilter({this.config = const FusionConfig()});

  final FusionConfig config;

  LocalProjection? _proj;
  // State [x, y, vx, vy] and covariance (row-major 4x4).
  final List<double> _x = List.filled(4, 0);
  final List<double> _p = List.filled(16, 0);
  DateTime? _t;

  DateTime? _lastGnss, _lastWifi, _lastCell, _lastSpeed;
  double _lastRadioAccuracy = 0;
  double? _lastCourse;
  int _rejections = 0;
  int _transmitters = 0;

  /// True once a position has been received.
  bool get initialized => _proj != null;

  /// Number of radio fixes rejected by the gate since the last accepted one.
  int get consecutiveRejections => _rejections;

  void reset() {
    _proj = null;
    _t = null;
    _lastGnss = _lastWifi = _lastCell = _lastSpeed = null;
    _lastCourse = null;
    _rejections = 0;
  }

  double _pp(int r, int c) => _p[r * 4 + c];

  void _init(double lat, double lon, double accuracyM, DateTime t) {
    _proj = LocalProjection(lat, lon);
    _x.fillRange(0, 4, 0);
    _p.fillRange(0, 16, 0);
    final s2 = accuracyM * accuracyM / 2;
    _p[0] = s2;
    _p[5] = s2;
    final v2 = config.initialSpeedSigma * config.initialSpeedSigma;
    _p[10] = v2;
    _p[15] = v2;
    _t = t;
    _rejections = 0;
  }

  /// Time update to [t] (no-op for the past).
  void _predict(DateTime t) {
    final dt = t.difference(_t!).inMicroseconds / 1e6;
    if (dt <= 0) return;
    _predictInto(_x, _p, dt);
    _t = t;
  }

  void _predictInto(List<double> x, List<double> p, double dt) {
    x[0] += x[2] * dt;
    x[1] += x[3] * dt;
    // P = F P F^T + Q with F = [I, dt*I; 0, I].
    // A = F P: rows 0,1 gain dt * rows 2,3.
    final a = List<double>.from(p);
    for (var c = 0; c < 4; c++) {
      a[0 * 4 + c] += dt * p[2 * 4 + c];
      a[1 * 4 + c] += dt * p[3 * 4 + c];
    }
    // P = A F^T: columns 0,1 gain dt * columns 2,3.
    for (var r = 0; r < 4; r++) {
      p[r * 4 + 0] = a[r * 4 + 0] + dt * a[r * 4 + 2];
      p[r * 4 + 1] = a[r * 4 + 1] + dt * a[r * 4 + 3];
      p[r * 4 + 2] = a[r * 4 + 2];
      p[r * 4 + 3] = a[r * 4 + 3];
    }
    // White-noise acceleration, independent per axis.
    final q = config.accelSigma * config.accelSigma;
    final q11 = q * dt * dt * dt * dt / 4, q12 = q * dt * dt * dt / 2;
    final q22 = q * dt * dt;
    for (var ax = 0; ax < 2; ax++) {
      final v = ax + 2;
      p[ax * 4 + ax] += q11;
      p[ax * 4 + v] += q12;
      p[v * 4 + ax] += q12;
      p[v * 4 + v] += q22;
    }
  }

  /// Generic Kalman update for an m-dimensional measurement (m = 1 or 2)
  /// with Jacobian rows [h] (each of length 4), residual [nu] and diagonal
  /// measurement variance [r]. Returns the squared Mahalanobis distance; the
  /// state is only changed when it is at most [gate] (null = always).
  double _update(
    List<List<double>> h,
    List<double> nu,
    List<double> r, {
    double? gate,
  }) {
    final m = h.length;
    // PH^T (4 x m)
    final pht = List.generate(4, (_) => List<double>.filled(m, 0));
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < m; j++) {
        var s = 0.0;
        for (var k = 0; k < 4; k++) {
          s += _pp(i, k) * h[j][k];
        }
        pht[i][j] = s;
      }
    }
    // S = H P H^T + R (m x m)
    final s = List.generate(m, (_) => List<double>.filled(m, 0));
    for (var i = 0; i < m; i++) {
      for (var j = 0; j < m; j++) {
        var v = 0.0;
        for (var k = 0; k < 4; k++) {
          v += h[i][k] * pht[k][j];
        }
        s[i][j] = v + (i == j ? r[i] : 0);
      }
    }
    // S^-1
    final List<List<double>> si;
    if (m == 1) {
      si = [
        [1 / s[0][0]],
      ];
    } else {
      final det = s[0][0] * s[1][1] - s[0][1] * s[1][0];
      si = [
        [s[1][1] / det, -s[0][1] / det],
        [-s[1][0] / det, s[0][0] / det],
      ];
    }
    var d2 = 0.0;
    for (var i = 0; i < m; i++) {
      for (var j = 0; j < m; j++) {
        d2 += nu[i] * si[i][j] * nu[j];
      }
    }
    if (gate != null && d2 > gate) return d2;
    // K = P H^T S^-1 (4 x m)
    final k = List.generate(4, (_) => List<double>.filled(m, 0));
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < m; j++) {
        var v = 0.0;
        for (var l = 0; l < m; l++) {
          v += pht[i][l] * si[l][j];
        }
        k[i][j] = v;
      }
    }
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < m; j++) {
        _x[i] += k[i][j] * nu[j];
      }
    }
    // P = P - K (P H^T)^T, then symmetrise.
    final np = List<double>.from(_p);
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 4; j++) {
        var v = 0.0;
        for (var l = 0; l < m; l++) {
          v += k[i][l] * pht[j][l];
        }
        np[i * 4 + j] -= v;
      }
    }
    for (var i = 0; i < 4; i++) {
      for (var j = i; j < 4; j++) {
        final v = (np[i * 4 + j] + np[j * 4 + i]) / 2;
        _p[i * 4 + j] = v;
        _p[j * 4 + i] = v;
      }
      if (_p[i * 4 + i] < 1e-9) _p[i * 4 + i] = 1e-9;
    }
    return d2;
  }

  void _recenterIfNeeded() {
    final proj = _proj!;
    if (_x[0].abs() + _x[1].abs() < config.recenterDistanceM) return;
    final lat = proj.lat(_x[1]), lon = proj.lon(_x[0]);
    _proj = LocalProjection(lat, lon);
    _x[0] = 0;
    _x[1] = 0;
  }

  DateTime _clampTime(DateTime t) => _t != null && t.isBefore(_t!) ? _t! : t;

  /// Feeds a position fix from the radio estimator (or any other absolute
  /// source). [fix.accuracyM] is taken as a 68 % radius, i.e. a per-axis
  /// sigma of `accuracy / sqrt(2)`. Returns false when the fix was gated
  /// out as an outlier.
  bool addPosition(PositionEstimate fix) {
    final isGnss = fix.source == PositionSource.gnss;
    final t0 = fix.timestamp;
    if (_proj == null) {
      _init(fix.lat, fix.lon, fix.accuracyM, t0);
      _mark(fix, t0);
      return true;
    }
    final t = _clampTime(t0);
    _predict(t);
    final proj = _proj!;
    final nu = [proj.x(fix.lon) - _x[0], proj.y(fix.lat) - _x[1]];
    final r = fix.accuracyM * fix.accuracyM / 2;
    final d2 = _update(
      const [
        [1, 0, 0, 0],
        [0, 1, 0, 0],
      ],
      nu,
      [r, r],
      gate: config.gate,
    );
    if (d2 > config.gate) {
      // A healthy GNSS fix always wins; radio must insist a few times.
      if (isGnss || ++_rejections >= config.rejectionsBeforeReset) {
        _init(fix.lat, fix.lon, fix.accuracyM, t);
        _mark(fix, t);
        return true;
      }
      return false;
    }
    _rejections = 0;
    _mark(fix, t);
    _recenterIfNeeded();
    return true;
  }

  void _mark(PositionEstimate fix, DateTime t) {
    switch (fix.source) {
      case PositionSource.gnss:
        _lastGnss = t;
      case PositionSource.cell:
        _lastCell = t;
        _lastRadioAccuracy = fix.accuracyM;
        _transmitters = fix.transmittersUsed;
      default:
        _lastWifi = t;
        _lastRadioAccuracy = fix.accuracyM;
        _transmitters = fix.transmittersUsed;
    }
  }

  /// Feeds a GNSS epoch that passed the sanity check: position, and Doppler
  /// velocity when speed (and course) are reported.
  void addGnss(GnssFix fix) {
    if (!fix.hasPosition) return;
    final t = fix.receivedAt;
    addPosition(
      PositionEstimate(
        lat: fix.lat!,
        lon: fix.lon!,
        accuracyM: fix.accuracyM ?? 25,
        source: PositionSource.gnss,
        timestamp: t,
      ),
    );
    final v = fix.speedMps;
    if (v == null) return;
    final s2 = config.gnssSpeedSigma * config.gnssSpeedSigma;
    final course = fix.courseDeg;
    if (v < config.stationarySpeed) {
      _zeroVelocity(s2);
    } else if (course != null) {
      final c = degToRad(course);
      _update(
        const [
          [0, 0, 1, 0],
          [0, 0, 0, 1],
        ],
        [v * math.sin(c) - _x[2], v * math.cos(c) - _x[3]],
        [s2, s2],
      );
      _lastCourse = course;
    } else {
      _speedMagnitude(v, s2);
    }
  }

  /// Feeds an external speed-over-ground measurement (OBD wheel speed).
  /// Only the magnitude is known; the heading comes from the filter state.
  void addSpeed(double speedMps, DateTime time, {double? sigma}) {
    if (_proj == null || speedMps.isNaN || speedMps < 0) return;
    _predict(_clampTime(time));
    final s = sigma ?? config.externalSpeedSigma;
    if (speedMps < config.stationarySpeed) {
      _zeroVelocity(s * s);
    } else {
      _speedMagnitude(speedMps, s * s);
    }
    _lastSpeed = _t;
  }

  void _zeroVelocity(double variance) {
    _update(
      const [
        [0, 0, 1, 0],
        [0, 0, 0, 1],
      ],
      [-_x[2], -_x[3]],
      [variance, variance],
    );
  }

  /// EKF update with h(x) = |v|. When the state has no usable heading yet
  /// the last known course is used; without one the measurement is skipped
  /// (a speed alone cannot say where we are going).
  void _speedMagnitude(double speed, double variance) {
    var vx = _x[2], vy = _x[3];
    var mag = math.sqrt(vx * vx + vy * vy);
    if (mag < 0.5) {
      final c = _lastCourse;
      if (c == null) return;
      final cr = degToRad(c);
      // Seed the direction, then update the magnitude along it.
      vx = math.sin(cr);
      vy = math.cos(cr);
      _x[2] = vx * 0.5;
      _x[3] = vy * 0.5;
      mag = 0.5;
      vx = _x[2];
      vy = _x[3];
    }
    _update(
      [
        [0, 0, vx / mag, vy / mag],
      ],
      [speed - mag],
      [variance],
    );
  }

  /// Current best estimate extrapolated to [now]; null before the first fix.
  /// Does not modify the filter.
  PositionEstimate? estimateAt(DateTime now) {
    final proj = _proj;
    if (proj == null) return null;
    final x = List<double>.from(_x);
    final p = List<double>.from(_p);
    final dt = math.max(0.0, now.difference(_t!).inMicroseconds / 1e6);
    // Confidence of the velocity as of the last update. Along-track and
    // cross-track are separated: a speed-only input (OBD) pins the magnitude
    // but leaves the direction to drift.
    final speed = math.sqrt(x[2] * x[2] + x[3] * x[3]);
    double sigmaAlong, sigmaCross;
    if (speed > 0.5) {
      final ux = x[2] / speed, uy = x[3] / speed;
      sigmaAlong = math.sqrt(
        math.max(0.0, ux * ux * p[10] + 2 * ux * uy * p[11] + uy * uy * p[15]),
      );
      sigmaCross = math.sqrt(
        math.max(0.0, uy * uy * p[10] - 2 * ux * uy * p[11] + ux * ux * p[15]),
      );
    } else {
      sigmaAlong = sigmaCross = math.sqrt((p[10] + p[15]) / 2);
    }
    final velocityOk = sigmaAlong <= config.confidentVelocitySigma;
    if (dt > 0) {
      final vx = x[2], vy = x[3];
      _predictInto(x, p, dt);
      // Position mean: extrapolate only with a trustworthy velocity and only
      // for a bounded time; the covariance always grows for the full dt.
      final lim = config.maxExtrapolation.inMicroseconds / 1e6;
      final useDt = velocityOk ? math.min(dt, lim) : 0.0;
      x[0] = _x[0] + vx * useDt;
      x[1] = _x[1] + vy * useDt;
    }
    var acc = math.sqrt(math.max(0.0, p[0] + p[5]));

    bool fresh(DateTime? t, Duration d) => t != null && now.difference(t) <= d;
    final gnss = fresh(_lastGnss, config.gnssFresh);
    final wifi = fresh(_lastWifi, config.radioFresh);
    final cell = fresh(_lastCell, config.radioFresh);
    final speedIn = fresh(_lastSpeed, config.speedFresh);
    PositionSource source;
    if (gnss) {
      source = (wifi || cell || speedIn)
          ? PositionSource.fused
          : PositionSource.gnss;
    } else if (wifi || cell) {
      source = speedIn
          ? PositionSource.fused
          : (wifi ? PositionSource.wifi : PositionSource.cell);
      final floor = config.correlatedRadioFloor * _lastRadioAccuracy;
      if (acc < floor) acc = floor;
    } else {
      source = PositionSource.deadReckoning;
    }

    // Speed is reported while the velocity is both confident and recent.
    final reportSpeed =
        velocityOk && dt <= config.speedHold.inMicroseconds / 1e6;
    double? course;
    if (reportSpeed && speed > 1.0 && sigmaCross / speed < 0.5) {
      course = normalizeCourse(radToDeg(math.atan2(x[2], x[3])));
    }
    return PositionEstimate(
      lat: proj.lat(x[1]),
      lon: proj.lon(x[0]),
      accuracyM: acc,
      source: source,
      timestamp: now,
      speedMps: reportSpeed ? speed : null,
      courseDeg: course,
      transmittersUsed: gnss ? 0 : _transmitters,
    );
  }
}
