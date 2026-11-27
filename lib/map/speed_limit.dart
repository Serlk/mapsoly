import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../routing/route_models.dart';

/// Smallest angle between two compass directions, 0..180.
double headingDifference(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

/// A speed limit for the road being driven.
@immutable
class RoadLimit {
  const RoadLimit(this.kmh, {this.posted = true});

  final int kmh;

  /// True when the limit is in the map data; false when it is the general
  /// rule for this kind of road, which a sign on the spot may override.
  final bool posted;

  @override
  bool operator ==(Object other) =>
      other is RoadLimit && other.kmh == kmh && other.posted == posted;

  @override
  int get hashCode => Object.hash(kmh, posted);

  @override
  String toString() => 'RoadLimit($kmh${posted ? '' : ', by rule'})';
}

/// The limit of [edge]: the mapped one, or else the general rule of the
/// Russian traffic code — 60 in built-up areas, 20 in living streets, 110
/// on motorways and 90 on other roads outside towns. Most city streets
/// carry no limit in OpenStreetMap precisely because the rule applies.
///
/// Null for driveways, parking aisles and the like, and when nothing is
/// known about the road.
RoadLimit? limitOf(DrivenEdge edge) {
  final posted = edge.speedLimitKmh;
  if (posted != null) return RoadLimit(posted);
  if (edge.use == 'living_street') return const RoadLimit(20, posted: false);
  if (edge.use != 'road' && edge.use != 'ramp' && edge.use != 'turn_channel') {
    return null;
  }
  final cls = edge.roadClass;
  if (cls == null || cls == 'service_other') return null;
  final density = edge.density;
  if (density == null) return null;
  // Valhalla's own line between rural and urban roads.
  if (density > 8) return const RoadLimit(60, posted: false);
  return RoadLimit(cls == 'motorway' ? 110 : 90, posted: false);
}

/// The point [metres] behind [p] for a car heading [headingDeg].
LatLng pointBehind(LatLng p, double headingDeg, double metres) {
  final h = headingDeg * math.pi / 180;
  const mPerDeg = 111320.0;
  final cosLat = math.cos(p.latitude * math.pi / 180);
  return LatLng(
    p.latitude - metres * math.cos(h) / mPerDeg,
    p.longitude - metres * math.sin(h) / (mPerDeg * cosLat),
  );
}

/// Finds the road driven between two points; null when there is no
/// routing data or no road there.
typedef DrivenEdgeLookup = Future<DrivenEdge?> Function(LatLng from, LatLng to);

/// Keeps the speed limit of the road being driven, asking the routing
/// graph of the installed maps again every few dozen metres.
class SpeedLimitTracker extends ChangeNotifier {
  SpeedLimitTracker(this._lookup);

  final DrivenEdgeLookup _lookup;

  /// A new lookup after the car moved this far or turned this much.
  static const stepM = 25.0, turnDeg = 25.0;

  /// A limit stays on screen this far past the last road that had one
  /// (junctions, a short gap in matching), then goes away.
  static const keepM = 120.0;

  /// Length of the stretch behind the car that is matched to a road.
  static const traceM = 30.0;

  static const _distance = Distance();

  RoadLimit? _limit;
  LatLng? _asked, _confirmed;
  double? _askedHeading;
  bool _busy = false;
  bool _disposed = false;

  /// Limit of the current road, or null when unknown.
  RoadLimit? get limit => _limit;

  /// Feeds the position and the direction of travel. Call it only while
  /// moving: standing still the heading means nothing.
  void update(LatLng p, double? headingDeg) {
    if (_busy || headingDeg == null) return;
    final asked = _asked;
    if (asked != null &&
        _distance.as(LengthUnit.Meter, asked, p) < stepM &&
        (_askedHeading == null ||
            headingDifference(headingDeg, _askedHeading!) < turnDeg)) {
      return;
    }
    _asked = p;
    _askedHeading = headingDeg;
    _busy = true;
    _lookup(pointBehind(p, headingDeg, traceM), p)
        .then((edge) => _apply(p, edge))
        .catchError((Object e) {
          debugPrint('Speed limit lookup failed: $e');
        })
        .whenComplete(() => _busy = false);
  }

  void _apply(LatLng p, DrivenEdge? edge) {
    if (_disposed) return;
    final found = edge == null ? null : limitOf(edge);
    RoadLimit? next;
    if (found != null) {
      _confirmed = p;
      next = found;
    } else {
      final confirmed = _confirmed;
      final near =
          confirmed != null &&
          _distance.as(LengthUnit.Meter, confirmed, p) < keepM;
      next = near ? _limit : null;
    }
    if (next != _limit) {
      _limit = next;
      notifyListeners();
    }
  }

  /// Forgets the limit (the car stopped being tracked).
  void reset() {
    _asked = null;
    _confirmed = null;
    if (_limit != null) {
      _limit = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
