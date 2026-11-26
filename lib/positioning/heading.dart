import 'dart:math' as math;

/// Where an absolute heading came from; each is trusted differently.
enum HeadingReference {
  /// Course over ground from satellites while moving: accurate.
  gnss,

  /// Direction of the road or route segment being driven: accurate while the
  /// position on the route is right.
  route,

  /// Magnetometer. Inside a car it can be tens of degrees off, so it only
  /// nudges the estimate and gives a first guess.
  compass,
}

/// Tracks the direction of travel from the gyroscope, corrected by whatever
/// absolute references are available.
///
/// The gyroscope gives turn rate with a slowly drifting offset; integrating
/// it follows every turn but wanders by degrees per minute. Absolute
/// references pull the estimate back. The phone may lie in any orientation:
/// the turn rate is taken about the vertical, found from the accelerometer.
class HeadingEstimator {
  HeadingEstimator();

  /// Seconds for a reference to pull the heading most of the way to itself.
  static const _timeConstant = {
    HeadingReference.gnss: 2.0,
    HeadingReference.route: 4.0,
    HeadingReference.compass: 60.0,
  };

  /// Heading drift assumed while running on the gyroscope alone, deg/s
  /// (a consumer MEMS gyro after bias removal).
  static const _driftDegPerSecond = 0.05;

  double? _heading; // degrees clockwise from north
  double _sigma = 180;
  final _bias = [0.0, 0.0, 0.0]; // rad/s
  final _gravity = [0.0, 0.0, 0.0]; // low-passed accelerometer
  bool _hasGravity = false;
  DateTime? _lastGyro;
  bool _stationary = false;

  /// Direction of travel in degrees clockwise from north; null until some
  /// absolute reference has been seen.
  double? get headingDeg => _heading;

  /// Rough one-sigma uncertainty of [headingDeg] in degrees.
  double get sigmaDeg => _sigma;

  /// Turn rate about the vertical from the last gyroscope sample, in deg/s,
  /// positive clockwise seen from above.
  double turnRateDegPerSecond = 0;

  /// Tell the estimator the vehicle is standing (wheel speed is zero): the
  /// gyroscope then reads pure offset, which is learnt and removed.
  set stationary(bool value) => _stationary = value;

  /// Accelerometer sample in m/s² (device axes).
  void addAccel(double x, double y, double z) {
    if (!_hasGravity) {
      _gravity
        ..[0] = x
        ..[1] = y
        ..[2] = z;
      _hasGravity = true;
      return;
    }
    // Heavy smoothing: braking and bumps must not tilt the vertical.
    const k = 0.02;
    _gravity[0] += k * (x - _gravity[0]);
    _gravity[1] += k * (y - _gravity[1]);
    _gravity[2] += k * (z - _gravity[2]);
  }

  /// Gyroscope sample in rad/s (device axes).
  void addGyro(double x, double y, double z, DateTime time) {
    final last = _lastGyro;
    _lastGyro = time;
    if (_stationary) {
      const k = 0.02;
      _bias[0] += k * (x - _bias[0]);
      _bias[1] += k * (y - _bias[1]);
      _bias[2] += k * (z - _bias[2]);
    }
    if (!_hasGravity || last == null) return;
    final dt = time.difference(last).inMicroseconds / 1e6;
    if (dt <= 0 || dt > 1) return; // a gap: nothing sensible to integrate
    final norm = math.sqrt(
      _gravity[0] * _gravity[0] +
          _gravity[1] * _gravity[1] +
          _gravity[2] * _gravity[2],
    );
    if (norm < 1) return;
    // At rest the accelerometer points up. A positive rotation about "up"
    // is counter-clockwise from above, i.e. the heading decreases.
    final aboutUp =
        ((x - _bias[0]) * _gravity[0] +
            (y - _bias[1]) * _gravity[1] +
            (z - _bias[2]) * _gravity[2]) /
        norm;
    turnRateDegPerSecond = _stationary ? 0 : -aboutUp * 180 / math.pi;
    final heading = _heading;
    if (heading == null || _stationary) return;
    _heading = (heading + turnRateDegPerSecond * dt) % 360;
    _sigma = math.min(180, _sigma + _driftDegPerSecond * dt);
  }

  /// An absolute heading in degrees clockwise from north, valid at the
  /// current moment; [dt] is the time since the previous reference of this
  /// kind, in seconds.
  void addReference(
    HeadingReference kind,
    double headingDeg, {
    double dt = 1,
    double sigmaDeg = 5,
  }) {
    final current = _heading;
    if (current == null) {
      _heading = headingDeg % 360;
      _sigma = kind == HeadingReference.compass ? 45 : sigmaDeg;
      return;
    }
    // A poor reference must not drag a good estimate away.
    if (kind == HeadingReference.compass && _sigma < 20) return;
    final gain = (dt / _timeConstant[kind]!).clamp(0.0, 1.0);
    final error = ((headingDeg - current + 540) % 360) - 180;
    _heading = (current + gain * error) % 360;
    final target = kind == HeadingReference.compass ? 45.0 : sigmaDeg;
    _sigma += gain * (target - _sigma);
  }
}

/// Tilt-compensated compass heading in degrees clockwise from magnetic
/// north for a device whose "forward" is its +y axis, from accelerometer and
/// magnetometer samples (device axes). Null when the vectors are degenerate.
double? compassHeading(List<double> accel, List<double> magnet) {
  // East = magnet x up; north = up x east.
  List<double> cross(List<double> a, List<double> b) => [
    a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2],
    a[0] * b[1] - a[1] * b[0],
  ];
  double norm(List<double> v) =>
      math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
  final east = cross(magnet, accel);
  final e = norm(east), u = norm(accel);
  if (e < 1e-6 || u < 1e-6) return null;
  final north = cross(accel, east);
  final n = norm(north);
  // Project the device's +y axis onto east and north.
  final deg = math.atan2(east[1] / e, north[1] / n) * 180 / math.pi;
  return (deg + 360) % 360;
}
