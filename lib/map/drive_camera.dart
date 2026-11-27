/// Where the camera should be: the pure logic behind the location button
/// modes and the camera that sits behind the car during guidance. Nothing
/// here touches a map; the screen feeds positions in and applies the result.
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart' show EdgeInsets, Size;
import 'package:latlong2/latlong.dart';

import 'guidance.dart';

/// Tilt used for the 3D view, in degrees (capped by what the engine can do).
const double tiltedPitch = 55;

/// Compass bearing from [a] to [b] in degrees clockwise from north, 0..360.
double bearingBetween(LatLng a, LatLng b) {
  const rad = math.pi / 180;
  final lat1 = a.latitude * rad, lat2 = b.latitude * rad;
  final dLon = (b.longitude - a.longitude) * rad;
  final y = math.sin(dLon) * math.cos(lat2);
  final x =
      math.cos(lat1) * math.sin(lat2) -
      math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
  return (math.atan2(y, x) / rad + 360) % 360;
}

/// Signed smallest turn from [from] to [to], -180..180 degrees.
double angleDelta(double from, double to) {
  final d = (to - from) % 360;
  return d > 180 ? d - 360 : d;
}

/// Direction of the route at [alongM] metres from its start: towards the
/// point [lookAheadM] further on, so that a bend ahead turns the view
/// gradually and GPS noise does not turn it at all. Null on a route too
/// short to have a direction there (its very end).
double? routeBearingAt(
  RouteTracker tracker,
  double alongM, {
  double lookAheadM = 40,
}) {
  final length = tracker.lengthM;
  if (tracker.shape.length < 2 || length <= 0) return null;
  var a = alongM.clamp(0.0, length), b = a + lookAheadM;
  if (b > length) {
    // At the end look back the same distance instead.
    b = length;
    a = math.max(0.0, b - lookAheadM);
  }
  if (b - a < 1) return null;
  return bearingBetween(tracker.pointAt(a), tracker.pointAt(b));
}

/// Zoom for a driving speed: close in town, further out on the motorway.
double zoomForSpeed(double speedKmh) {
  const slow = 20.0, fast = 110.0, near = 17.4, far = 15.2;
  if (speedKmh <= slow) return near;
  if (speedKmh >= fast) return far;
  return near + (far - near) * (speedKmh - slow) / (fast - slow);
}

/// Zoom while driving: by speed, tightening before a maneuver so that the
/// junction is seen in detail. [toManeuverM] null: nothing ahead.
double driveZoom(double speedKmh, double? toManeuverM) {
  final base = zoomForSpeed(speedKmh);
  if (toManeuverM == null || toManeuverM > 400) return base;
  // From 400 m the view closes in, fully by 100 m.
  final t = ((400 - toManeuverM) / 300).clamp(0.0, 1.0);
  return base + (math.max(base, 17.2) - base) * t;
}

/// Keeps an angle steady: changes within the dead band are ignored, larger
/// ones are followed part of the way each time.
class AngleSmoother {
  AngleSmoother({this.deadbandDeg = 3, this.factor = 0.35});

  final double deadbandDeg;

  /// Share of the remaining turn taken per update, 0..1.
  final double factor;
  double? _value;

  double? get value => _value;

  double update(double degrees) {
    final current = _value;
    if (current == null) return _value = degrees % 360;
    final delta = angleDelta(current, degrees);
    if (delta.abs() < deadbandDeg) return current;
    return _value = (current + delta * factor) % 360;
  }

  void reset() => _value = null;
}

/// Moves a value towards its target by at most [maxStep] per update.
class StepSmoother {
  StepSmoother(this.maxStep);

  final double maxStep;
  double? _value;

  double update(double target) {
    final current = _value;
    if (current == null) return _value = target;
    return _value = current + (target - current).clamp(-maxStep, maxStep);
  }

  void reset() => _value = null;
}

/// What the location button does: one button, cycling like other
/// navigators.
enum LocationMode {
  /// The map stays where the user left it.
  free,

  /// The map follows the position, north-up.
  centered,

  /// The map follows the position and turns so that the direction of
  /// travel (or where the device points) is up.
  heading,
}

/// The mode after a tap on the location button.
LocationMode nextLocationMode(LocationMode mode) => switch (mode) {
  LocationMode.free => LocationMode.centered,
  LocationMode.centered => LocationMode.heading,
  LocationMode.heading => LocationMode.centered,
};

/// Whether the driving camera follows the car, or waits because the driver
/// moved the map by hand.
class FollowState {
  FollowState({this.resumeAfter = const Duration(seconds: 10)});

  /// Following resumes by itself this long after the last touch, if the
  /// car is moving.
  final Duration resumeAfter;
  DateTime? _touched;

  bool get following => _touched == null;
  bool get paused => !following;

  /// The user panned or zoomed the map.
  void userMoved(DateTime now) => _touched = now;

  /// "Back to the route" was pressed, or guidance (re)started.
  void resume() => _touched = null;

  /// Call on every position update. Returns true when following resumed
  /// just now.
  bool tick(DateTime now, {required bool moving}) {
    final touched = _touched;
    if (touched == null || !moving) return false;
    if (now.difference(touched) < resumeAfter) return false;
    _touched = null;
    return true;
  }
}

/// One camera position.
class CameraFrame {
  const CameraFrame({
    required this.center,
    required this.zoom,
    required this.bearing,
    required this.pitch,
  });

  final LatLng center;
  final double zoom, bearing, pitch;
}

/// The camera behind the car: smoothed bearing along the route, zoom by
/// speed and by the distance to the next maneuver.
class DriveCamera {
  final _bearing = AngleSmoother(deadbandDeg: 2, factor: 0.6);
  final _zoom = StepSmoother(0.12);

  /// Speed above which the car counts as moving.
  static const movingKmh = 5.0;

  void reset() {
    _bearing.reset();
    _zoom.reset();
  }

  /// The frame for a matched position [point]. With [tilt] the view is
  /// turned along the route ([routeBearing], see [routeBearingAt]) and
  /// tilted (up to [maxPitch]); without it the map stays north-up and
  /// flat. [courseDeg] is used where the route has no direction.
  CameraFrame frame({
    required LatLng point,
    required double speedKmh,
    required bool tilt,
    required double maxPitch,
    double? routeBearing,
    double? toManeuverM,
    double? courseDeg,
  }) {
    final zoom = _zoom.update(driveZoom(speedKmh, toManeuverM));
    final along = routeBearing ?? courseDeg;
    final bearing = along == null
        ? (_bearing.value ?? 0)
        : _bearing.update(along);
    return CameraFrame(
      center: point,
      zoom: zoom,
      bearing: tilt ? bearing : 0,
      pitch: tilt ? math.min(tiltedPitch, maxPitch) : 0,
    );
  }
}

/// Camera insets that put the position in the lower third of the part of
/// the view that is free: under the banner ([top]) and above whatever the
/// engine already keeps clear at the bottom ([bottom], e.g. the bar).
EdgeInsets drivePadding(Size view, {required double top, double bottom = 0}) {
  final free = view.height - top - bottom;
  if (free <= 0) return EdgeInsets.zero;
  // The target is centred in what remains: to sit two thirds down the free
  // area, a third of it is given away at the top.
  return EdgeInsets.only(top: top + free / 3);
}
