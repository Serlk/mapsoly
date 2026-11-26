/// Speed / enforcement cameras: model, spatial queries and route matching.
///
/// The same `camera` + `camera_rtree` schema is used by the region pack
/// (`places.sqlite`, built by `tool/build_places.sh`) and by the user camera
/// database (`user_cameras.dart`), so [CameraStore] serves both.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';
import 'package:sqlite3/sqlite3.dart';

import 'geo.dart';

/// What a camera enforces. [code] is the value stored in the `type` column
/// (the OSM `enforcement=*` value).
enum CameraType {
  speed('maxspeed'),
  averageSpeed('average_speed'),
  trafficSignals('traffic_signals'),
  minDistance('mindistance'),
  busLane('access'),
  roadMarking('road_marking'),
  other('other');

  const CameraType(this.code);
  final String code;

  /// Maps a `type` value; for combined values ("maxspeed;access") speed
  /// wins, otherwise the first known part.
  static CameraType fromCode(String code) {
    final parts = code.split(';').map((p) => p.trim()).toList();
    if (parts.contains(speed.code)) return speed;
    for (final p in parts) {
      for (final t in values) {
        if (t.code == p) return t;
      }
    }
    return other;
  }
}

/// Where a camera record came from.
enum CameraSource { pack, user }

/// One enforcement device (or the start of an average-speed section).
class SpeedCamera {
  const SpeedCamera({
    required this.id,
    required this.source,
    required this.type,
    required this.rawType,
    required this.point,
    this.bearing,
    this.bidirectional = false,
    this.maxSpeedKmh,
    this.maxSpeedFromRoad = false,
    this.zoneEnd,
    this.osmRef,
  });

  final int id;
  final CameraSource source;
  final CameraType type;

  /// Raw `type` column value (useful when [type] is [CameraType.other]).
  final String rawType;

  /// Device position; for an average-speed section, where the section starts.
  final LatLng point;

  /// Direction of travel the camera applies to, degrees from north.
  /// Null = unknown, the camera is reported for every direction.
  final int? bearing;

  /// True when the camera applies to both directions along the [bearing] axis
  /// (two-way road, direction not tagged).
  final bool bidirectional;

  /// Limit enforced, if known.
  final int? maxSpeedKmh;

  /// True when [maxSpeedKmh] was taken from the road the camera stands on
  /// rather than from the camera itself.
  final bool maxSpeedFromRoad;

  /// End of an average-speed section.
  final LatLng? zoneEnd;

  /// OSM object ("n123", "r456") or null for user cameras.
  final String? osmRef;

  /// Stable key across databases, used to warn once per camera.
  String get key => '${source.name}:$id';

  /// Whether the camera applies to traffic moving along [courseDeg].
  bool appliesTo(double courseDeg, {double toleranceDeg = 50}) {
    final b = bearing;
    if (b == null) return true;
    final d = angleDiff(courseDeg, b.toDouble());
    return d <= toleranceDeg || (bidirectional && d >= 180 - toleranceDeg);
  }
}

/// A camera matched to a route.
class RouteCamera {
  const RouteCamera({
    required this.camera,
    required this.alongM,
    required this.lateralM,
    this.zoneEndAlongM,
  });

  final SpeedCamera camera;

  /// Distance from the start of the route to the camera, along the route.
  final double alongM;

  /// Distance from the camera to the route line.
  final double lateralM;

  /// For average-speed sections whose end lies on the route: its distance
  /// along the route (always > [alongM]).
  final double? zoneEndAlongM;
}

/// A camera near a position.
class NearbyCamera {
  const NearbyCamera(this.camera, this.distanceM, this.bearingTo);
  final SpeedCamera camera;
  final double distanceM;

  /// Bearing from the query point to the camera.
  final double bearingTo;
}

const String cameraSchemaSql = '''
CREATE TABLE IF NOT EXISTS camera(id INTEGER PRIMARY KEY, type TEXT NOT NULL,
  lat REAL NOT NULL, lon REAL NOT NULL, bearing INTEGER,
  bidir INTEGER NOT NULL DEFAULT 0, maxspeed INTEGER,
  maxspeed_from_road INTEGER NOT NULL DEFAULT 0,
  end_lat REAL, end_lon REAL, osm TEXT);
CREATE VIRTUAL TABLE IF NOT EXISTS camera_rtree USING rtree(id, min_lat,
  max_lat, min_lon, max_lon);
''';

/// Camera queries over a database with the `camera` schema.
class CameraStore {
  CameraStore(this._db, this.source)
    : _boxStmt = _db.prepare(
        'SELECT c.id, c.type, c.lat, c.lon, c.bearing, c.bidir, c.maxspeed, '
        'c.maxspeed_from_road, c.end_lat, c.end_lon, c.osm '
        'FROM camera_rtree r JOIN camera c ON c.id = r.id '
        'WHERE r.max_lat >= ? AND r.min_lat <= ? '
        'AND r.max_lon >= ? AND r.min_lon <= ?',
      );

  final Database _db;
  final CameraSource source;
  final PreparedStatement _boxStmt;

  int get count =>
      _db.select('SELECT count(*) FROM camera').first.columnAt(0) as int;

  void dispose() => _boxStmt.dispose();

  List<SpeedCamera> _inBox(double s, double n, double w, double e) {
    final rows = _boxStmt.select([s, n, w, e]);
    return [
      for (final r in rows)
        SpeedCamera(
          id: r.columnAt(0) as int,
          source: source,
          type: CameraType.fromCode(r.columnAt(1) as String),
          rawType: r.columnAt(1) as String,
          point: LatLng(
            (r.columnAt(2) as num).toDouble(),
            (r.columnAt(3) as num).toDouble(),
          ),
          bearing: r.columnAt(4) as int?,
          bidirectional: (r.columnAt(5) as int) != 0,
          maxSpeedKmh: r.columnAt(6) as int?,
          maxSpeedFromRoad: (r.columnAt(7) as int) != 0,
          zoneEnd: r.columnAt(8) == null || r.columnAt(9) == null
              ? null
              : LatLng(
                  (r.columnAt(8) as num).toDouble(),
                  (r.columnAt(9) as num).toDouble(),
                ),
          osmRef: r.columnAt(10) as String?,
        ),
    ];
  }

  /// Cameras within [radiusM] of [p], nearest first. With [courseDeg] only
  /// cameras that apply to that direction of travel are returned.
  List<NearbyCamera> near(LatLng p, double radiusM, {double? courseDeg}) {
    final dLat = radiusM / mPerDegLat;
    final dLon = radiusM / math.max(1.0, mPerDegLon(p.latitude));
    final out = <NearbyCamera>[];
    for (final c in _inBox(
      p.latitude - dLat,
      p.latitude + dLat,
      p.longitude - dLon,
      p.longitude + dLon,
    )) {
      final d = distanceM(p, c.point);
      if (d > radiusM) continue;
      if (courseDeg != null && !c.appliesTo(courseDeg)) continue;
      out.add(NearbyCamera(c, d, bearingDeg(p, c.point)));
    }
    out.sort((a, b) => a.distanceM.compareTo(b.distanceM));
    return out;
  }

  /// Cameras that apply to travel along [route], ordered by distance along
  /// it. See [matchCamerasToRoute] for the matching rules.
  List<RouteCamera> along(
    List<LatLng> route, {
    double corridorM = 35,
    double toleranceDeg = 50,
  }) => matchCamerasToRoute(
    route,
    (s, n, w, e) => _inBox(s, n, w, e),
    corridorM: corridorM,
    toleranceDeg: toleranceDeg,
  );
}

/// Returns cameras whose position lies in the given lat/lon box.
typedef CameraBoxQuery =
    List<SpeedCamera> Function(
      double south,
      double north,
      double west,
      double east,
    );

/// Matches cameras to a route polyline.
///
/// A camera matches when it lies within [corridorM] of a route segment and
/// applies to the direction of that segment ([SpeedCamera.appliesTo] with
/// [toleranceDeg]). Each camera is reported once, at the matching segment it
/// is closest to. For average-speed sections the end point is looked up
/// further along the route (within 2×[corridorM]).
List<RouteCamera> matchCamerasToRoute(
  List<LatLng> route,
  CameraBoxQuery query, {
  double corridorM = 35,
  double toleranceDeg = 50,
}) {
  if (route.length < 2) return const [];
  final n = route.length;
  final cum = List<double>.filled(n, 0);
  for (var i = 1; i < n; i++) {
    cum[i] = cum[i - 1] + distanceM(route[i - 1], route[i]);
  }
  final best = <String, RouteCamera>{};
  const chunkM = 3000.0;
  var start = 0;
  while (start < n - 1) {
    var end = start + 1;
    var s = route[start].latitude, nn = s;
    var w = route[start].longitude, e = w;
    while (true) {
      final p = route[end];
      s = math.min(s, p.latitude);
      nn = math.max(nn, p.latitude);
      w = math.min(w, p.longitude);
      e = math.max(e, p.longitude);
      if (end == n - 1 || cum[end] - cum[start] >= chunkM) break;
      end++;
    }
    final dLat = corridorM / mPerDegLat;
    final dLon = corridorM / math.max(1.0, mPerDegLon((s + nn) / 2));
    final cams = query(s - dLat, nn + dLat, w - dLon, e + dLon);
    for (final c in cams) {
      for (var i = start; i < end; i++) {
        final a = route[i], b = route[i + 1];
        final segLen = cum[i + 1] - cum[i];
        if (segLen <= 0) continue;
        final pr = projectOnSegment(c.point, a, b);
        if (pr.distanceM > corridorM) continue;
        if (!c.appliesTo(bearingDeg(a, b), toleranceDeg: toleranceDeg)) {
          continue;
        }
        final prev = best[c.key];
        if (prev == null || pr.distanceM < prev.lateralM) {
          best[c.key] = RouteCamera(
            camera: c,
            alongM: cum[i] + pr.t * segLen,
            lateralM: pr.distanceM,
          );
        }
      }
    }
    start = end;
  }
  final out = <RouteCamera>[];
  for (final rc in best.values) {
    final zoneEnd = rc.camera.zoneEnd;
    if (zoneEnd == null) {
      out.add(rc);
      continue;
    }
    double? endAlong;
    var bestD = corridorM * 2;
    for (var i = 0; i < n - 1; i++) {
      if (cum[i + 1] <= rc.alongM) continue;
      final pr = projectOnSegment(zoneEnd, route[i], route[i + 1]);
      if (pr.distanceM < bestD) {
        final along = cum[i] + pr.t * (cum[i + 1] - cum[i]);
        if (along > rc.alongM) {
          bestD = pr.distanceM;
          endAlong = along;
        }
      }
    }
    out.add(
      RouteCamera(
        camera: rc.camera,
        alongM: rc.alongM,
        lateralM: rc.lateralM,
        zoneEndAlongM: endAlong,
      ),
    );
  }
  out.sort((a, b) => a.alongM.compareTo(b.alongM));
  return out;
}
