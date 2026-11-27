import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../routing/route_models.dart';

/// Smallest angle between two compass directions, 0..180.
double headingDifference(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

/// The road the car is most likely on: the nearest of those that run the
/// way the car is heading. Without a heading, simply the nearest.
NearbyEdge? pickDrivenEdge(
  List<NearbyEdge> edges, {
  double? headingDeg,
  double toleranceDeg = 40,
}) {
  NearbyEdge? best;
  for (final e in edges) {
    if (headingDeg != null &&
        headingDifference(e.headingDeg, headingDeg) > toleranceDeg) {
      continue;
    }
    if (best == null || e.distanceM < best.distanceM) best = e;
  }
  return best;
}

/// Looks up the roads around a point; null when routing data is missing.
typedef NearbyEdgesLookup = Future<List<NearbyEdge>?> Function(LatLng point);

/// Keeps the speed limit of the road being driven, asking the routing
/// graph of the installed maps again every few dozen metres.
///
/// Only limits that are in the map data are shown: a guess from the road
/// class would look just as certain on the screen and be wrong too often.
class SpeedLimitTracker extends ChangeNotifier {
  SpeedLimitTracker(this._lookup);

  final NearbyEdgesLookup _lookup;

  /// A new lookup after the car moved this far or turned this much.
  static const stepM = 25.0, turnDeg = 25.0;

  /// A limit stays on screen this far past the last road that had one
  /// (junctions and gaps in the data), then goes away.
  static const keepM = 120.0;

  static const _distance = Distance();

  int? _limit;
  LatLng? _asked, _confirmed;
  double? _askedHeading;
  bool _busy = false;
  bool _disposed = false;

  /// Limit of the current road in km/h, or null when unknown.
  int? get limitKmh => _limit;

  /// Feeds the position and the direction of travel. Call it only while
  /// moving: standing still the heading means nothing.
  void update(LatLng p, double? headingDeg) {
    if (_busy) return;
    final asked = _asked;
    if (asked != null &&
        _distance.as(LengthUnit.Meter, asked, p) < stepM &&
        (headingDeg == null ||
            _askedHeading == null ||
            headingDifference(headingDeg, _askedHeading!) < turnDeg)) {
      return;
    }
    _asked = p;
    _askedHeading = headingDeg;
    _busy = true;
    _lookup(p)
        .then((edges) => _apply(p, headingDeg, edges))
        .catchError((Object e) {
          debugPrint('Speed limit lookup failed: $e');
        })
        .whenComplete(() => _busy = false);
  }

  void _apply(LatLng p, double? headingDeg, List<NearbyEdge>? edges) {
    if (_disposed) return;
    final found = edges == null
        ? null
        : pickDrivenEdge(edges, headingDeg: headingDeg)?.speedLimitKmh;
    int? next;
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
