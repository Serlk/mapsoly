/// Geometry helpers for the places module (spherical Earth, metres/degrees).
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

const double _earthR = 6371008.8;
const double _d2r = math.pi / 180.0;

/// Great-circle distance in metres.
double distanceM(LatLng a, LatLng b) {
  final p1 = a.latitude * _d2r, p2 = b.latitude * _d2r;
  final dp = p2 - p1, dl = (b.longitude - a.longitude) * _d2r;
  final h =
      math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * _earthR * math.asin(math.min(1.0, math.sqrt(h)));
}

/// Initial bearing a → b in degrees, 0 = north, clockwise, in [0, 360).
double bearingDeg(LatLng a, LatLng b) {
  final p1 = a.latitude * _d2r, p2 = b.latitude * _d2r;
  final dl = (b.longitude - a.longitude) * _d2r;
  final y = math.sin(dl) * math.cos(p2);
  final x =
      math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
  return (math.atan2(y, x) / _d2r + 360.0) % 360.0;
}

/// Smallest absolute difference between two bearings, in [0, 180].
double angleDiff(double a, double b) {
  final d = (a - b).abs() % 360.0;
  return d > 180.0 ? 360.0 - d : d;
}

/// Metres per degree of latitude / of longitude at [lat].
const double mPerDegLat = _earthR * _d2r;
double mPerDegLon(double lat) => _earthR * _d2r * math.cos(lat * _d2r);

/// Result of projecting a point onto a segment.
class SegmentProjection {
  const SegmentProjection(this.distanceM, this.t);

  /// Distance from the point to the nearest point of the segment.
  final double distanceM;

  /// Position of that nearest point along the segment, 0..1.
  final double t;
}

/// Projects [p] onto segment [a]–[b] (local flat approximation, fine for
/// segments up to a few km).
SegmentProjection projectOnSegment(LatLng p, LatLng a, LatLng b) {
  final kx = mPerDegLon(p.latitude);
  final ax = (a.longitude - p.longitude) * kx;
  final ay = (a.latitude - p.latitude) * mPerDegLat;
  final bx = (b.longitude - p.longitude) * kx;
  final by = (b.latitude - p.latitude) * mPerDegLat;
  final dx = bx - ax, dy = by - ay;
  final l2 = dx * dx + dy * dy;
  var t = l2 > 0 ? -(ax * dx + ay * dy) / l2 : 0.0;
  t = t.clamp(0.0, 1.0);
  final x = ax + t * dx, y = ay + t * dy;
  return SegmentProjection(math.sqrt(x * x + y * y), t);
}
