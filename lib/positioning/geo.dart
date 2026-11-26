/// Small geodesy helpers used by the positioning subsystem.
///
/// Everything here works on a spherical Earth; at the distances that matter
/// for radio positioning (metres to tens of kilometres) the error against
/// WGS-84 is far below the measurement noise.
library;

import 'dart:math' as math;

/// Mean Earth radius in metres (IUGG).
const double earthRadiusM = 6371008.8;

const double _deg2rad = math.pi / 180.0;
const double _rad2deg = 180.0 / math.pi;

double degToRad(double d) => d * _deg2rad;
double radToDeg(double r) => r * _rad2deg;

/// Great-circle distance in metres between two WGS-84 points.
double haversineM(double lat1, double lon1, double lat2, double lon2) {
  final p1 = lat1 * _deg2rad, p2 = lat2 * _deg2rad;
  final dp = p2 - p1, dl = (lon2 - lon1) * _deg2rad;
  final a =
      math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * earthRadiusM * math.asin(math.min(1.0, math.sqrt(a)));
}

/// Initial bearing in degrees (0 = north, clockwise) from point 1 to point 2.
double bearingDeg(double lat1, double lon1, double lat2, double lon2) {
  final p1 = lat1 * _deg2rad, p2 = lat2 * _deg2rad;
  final dl = (lon2 - lon1) * _deg2rad;
  final y = math.sin(dl) * math.cos(p2);
  final x =
      math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
  return (math.atan2(y, x) * _rad2deg + 360.0) % 360.0;
}

/// Normalises a course to [0, 360).
double normalizeCourse(double deg) => ((deg % 360.0) + 360.0) % 360.0;

/// Local tangent-plane (equirectangular) projection around an origin.
///
/// x grows east, y grows north, both in metres. Accurate to well under 1 %
/// within ~50 km of the origin, which is why the fusion filter re-centres
/// itself when it drifts further than that.
class LocalProjection {
  LocalProjection(this.lat0, this.lon0)
    : _mPerDegLat = earthRadiusM * _deg2rad,
      _mPerDegLon = earthRadiusM * _deg2rad * math.cos(lat0 * _deg2rad);

  final double lat0;
  final double lon0;
  final double _mPerDegLat;
  final double _mPerDegLon;

  double x(double lon) => (lon - lon0) * _mPerDegLon;
  double y(double lat) => (lat - lat0) * _mPerDegLat;
  double lat(double y) => lat0 + y / _mPerDegLat;
  double lon(double x) => lon0 + x / _mPerDegLon;
}

/// Moves [distanceM] metres from a point along [courseDeg]; returns (lat, lon).
(double, double) destination(
  double lat,
  double lon,
  double courseDeg,
  double distanceM,
) {
  final p = LocalProjection(lat, lon);
  final c = courseDeg * _deg2rad;
  return (p.lat(distanceM * math.cos(c)), p.lon(distanceM * math.sin(c)));
}

/// Weighted median of [values] with matching positive [weights].
double weightedMedian(List<double> values, List<double> weights) {
  assert(values.length == weights.length && values.isNotEmpty);
  final idx = List<int>.generate(values.length, (i) => i)
    ..sort((a, b) => values[a].compareTo(values[b]));
  var total = 0.0;
  for (final w in weights) {
    total += w;
  }
  var acc = 0.0;
  for (final i in idx) {
    acc += weights[i];
    if (acc >= total / 2) return values[i];
  }
  return values[idx.last];
}
