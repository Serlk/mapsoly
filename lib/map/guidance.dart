import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Where a position falls on a route.
class RouteProgress {
  const RouteProgress({
    required this.alongM,
    required this.lateralM,
    required this.segment,
    required this.point,
  });

  /// Distance travelled from the start of the route, in metres.
  final double alongM;

  /// Distance from the position to the route, in metres.
  final double lateralM;

  /// Index of the shape segment the position was matched to.
  final int segment;

  /// The matched point on the route.
  final LatLng point;
}

/// Matches positions to a route polyline and measures distances along it.
class RouteTracker {
  RouteTracker(this.shape) : _cumulative = _measure(shape);

  final List<LatLng> shape;
  final List<double> _cumulative;
  int _last = 0;
  double _lastAlong = 0;

  static const _distance = Distance();

  /// How far ahead of the last match to look, so a route that passes the
  /// same place twice does not jump between passes.
  static const _windowM = 1500.0;

  static List<double> _measure(List<LatLng> shape) {
    final out = List<double>.filled(shape.length, 0);
    for (var i = 1; i < shape.length; i++) {
      out[i] =
          out[i - 1] + _distance.as(LengthUnit.Meter, shape[i - 1], shape[i]);
    }
    return out;
  }

  double get lengthM => _cumulative.isEmpty ? 0 : _cumulative.last;

  /// Distance from the route start to shape point [index].
  double alongOf(int index) =>
      _cumulative[index.clamp(0, _cumulative.length - 1)];

  /// Point at [alongM] metres from the start.
  LatLng pointAt(double alongM) {
    if (shape.length < 2) return shape.first;
    var i = 0;
    while (i < shape.length - 2 && _cumulative[i + 1] < alongM) {
      i++;
    }
    final len = _cumulative[i + 1] - _cumulative[i];
    final t = len <= 0 ? 0.0 : ((alongM - _cumulative[i]) / len).clamp(0, 1);
    return LatLng(
      shape[i].latitude + (shape[i + 1].latitude - shape[i].latitude) * t,
      shape[i].longitude + (shape[i + 1].longitude - shape[i].longitude) * t,
    );
  }

  /// Matches [p] to the route near the previous match; falls back to the
  /// whole route when nothing nearby is close (e.g. after a long gap).
  RouteProgress match(LatLng p) {
    final near = _search(p, _last, _windowM);
    final best = near != null && near.lateralM < 80
        ? near
        : (_search(p, 0, double.infinity) ?? near)!;
    _last = best.segment;
    _lastAlong = best.alongM;
    return best;
  }

  RouteProgress? _search(LatLng p, int from, double window) {
    if (shape.length < 2) return null;
    // Local flat projection around the position, in metres.
    final cosLat = math.cos(p.latitude * math.pi / 180);
    const mPerDeg = 111320.0;
    double x(LatLng q) => (q.longitude - p.longitude) * mPerDeg * cosLat;
    double y(LatLng q) => (q.latitude - p.latitude) * mPerDeg;

    RouteProgress? best;
    var bestScore = double.infinity;
    final start = math.max(0, from - 1);
    for (var i = start; i < shape.length - 1; i++) {
      if (_cumulative[i] - _cumulative[start] > window) break;
      final ax = x(shape[i]), ay = y(shape[i]);
      final bx = x(shape[i + 1]), by = y(shape[i + 1]);
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      final t = len2 == 0 ? 0.0 : ((-ax * dx - ay * dy) / len2).clamp(0.0, 1.0);
      final px = ax + dx * t, py = ay + dy * t;
      final lateral = math.sqrt(px * px + py * py);
      final along = _cumulative[i] + (_cumulative[i + 1] - _cumulative[i]) * t;
      // Travel goes forward: a match well behind the previous one loses to
      // an equally close match ahead (roads driven twice, U-turns).
      final score = lateral + (along < _lastAlong - 30 ? 40 : 0);
      if (score < bestScore) {
        bestScore = score;
        best = RouteProgress(
          alongM: along,
          lateralM: lateral,
          segment: i,
          point: LatLng(
            p.latitude + py / mPerDeg,
            p.longitude + px / (mPerDeg * cosLat),
          ),
        );
      }
    }
    return best;
  }
}

/// Decides when the driver has left the route: several consecutive fixes
/// further from it than the fix accuracy can explain.
class OffRouteDetector {
  OffRouteDetector({this.thresholdM = 50, this.fixesNeeded = 3});

  final double thresholdM;
  final int fixesNeeded;
  int _count = 0;

  /// Returns true once, when the position has been off the route long enough.
  bool update(double lateralM, double accuracyM) {
    if (lateralM > thresholdM + accuracyM) {
      _count++;
      if (_count == fixesNeeded) return true;
    } else {
      _count = 0;
    }
    return false;
  }

  void reset() => _count = 0;
}
