/// Keeps the position marker on the road while driving.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'speed_limit.dart' show headingDifference;

/// A position put onto a road, with the direction of the road there.
typedef SnappedPosition = ({LatLng point, double bearing});

/// Puts [p] onto [road] — the stretch the car was last matched to, in
/// driving order — or returns null when the car is not on it.
///
/// The matched stretch ends where the car was when it was asked for, and
/// the next answer comes a few dozen metres later; in between the car is
/// ahead of the stretch, so its last segment is continued straight for up
/// to [aheadM].
///
/// Not on the road means: further than [maxOffsetM] to the side (a car
/// park, a yard, a road the maps do not have), or heading more than
/// [maxTurnDeg] away from the road (it has turned off, and the next match
/// will say onto what).
SnappedPosition? snapToRoad(
  List<LatLng> road,
  LatLng p,
  double? headingDeg, {
  double maxOffsetM = 20,
  double maxTurnDeg = 45,
  double aheadM = 80,
}) {
  if (road.length < 2) return null;
  // Flat metres around the point: plenty over a few hundred metres.
  const mPerDeg = 111320.0;
  final cosLat = math.cos(p.latitude * math.pi / 180);
  double x(LatLng q) => (q.longitude - p.longitude) * mPerDeg * cosLat;
  double y(LatLng q) => (q.latitude - p.latitude) * mPerDeg;

  double? bestOffset;
  late double bestX, bestY, bestBearing;
  for (var i = 0; i + 1 < road.length; i++) {
    final ax = x(road[i]), ay = y(road[i]);
    final dx = x(road[i + 1]) - ax, dy = y(road[i + 1]) - ay;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length < 0.5) continue;
    // Where along the segment the car is, in metres from its start.
    var along = -(ax * dx + ay * dy) / length;
    final last = i + 2 == road.length;
    along = along.clamp(0.0, last ? length + aheadM : length);
    final px = ax + dx / length * along, py = ay + dy / length * along;
    final offset = math.sqrt(px * px + py * py);
    if (bestOffset == null || offset < bestOffset) {
      bestOffset = offset;
      bestX = px;
      bestY = py;
      bestBearing = (math.atan2(dx, dy) * 180 / math.pi + 360) % 360;
    }
  }
  if (bestOffset == null || bestOffset > maxOffsetM) return null;
  if (headingDeg != null &&
      headingDifference(headingDeg, bestBearing) > maxTurnDeg) {
    return null;
  }
  return (
    point: LatLng(
      p.latitude + bestY / mPerDeg,
      p.longitude + bestX / (mPerDeg * cosLat),
    ),
    bearing: bestBearing,
  );
}
