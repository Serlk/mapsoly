import 'package:latlong2/latlong.dart';

import 'polyline.dart';

/// Travel profile. [name] is the Valhalla `costing` value.
enum RouteCosting { auto, pedestrian, bicycle }

/// Valhalla maneuver types (`DirectionsLeg.Maneuver.Type`), in wire order.
enum ManeuverType {
  none,
  start,
  startRight,
  startLeft,
  destination,
  destinationRight,
  destinationLeft,
  becomes,
  continueStraight,
  slightRight,
  right,
  sharpRight,
  uturnRight,
  uturnLeft,
  sharpLeft,
  left,
  slightLeft,
  rampStraight,
  rampRight,
  rampLeft,
  exitRight,
  exitLeft,
  stayStraight,
  stayRight,
  stayLeft,
  merge,
  roundaboutEnter,
  roundaboutExit,
  ferryEnter,
  ferryExit,
  transit,
  transitTransfer,
  transitRemainOn,
  transitConnectionStart,
  transitConnectionTransfer,
  transitConnectionDestination,
  postTransitConnectionDestination,
  mergeRight,
  mergeLeft,
  elevatorEnter,
  stepsEnter,
  escalatorEnter,
  buildingEnter,
  buildingExit;

  /// Unknown codes (from a newer Valhalla) map to [none].
  static ManeuverType fromCode(int code) =>
      code >= 0 && code < values.length ? values[code] : none;
}

/// One turn-by-turn step.
class Maneuver {
  Maneuver({
    required this.type,
    required this.typeCode,
    required this.instruction,
    required this.streetNames,
    required this.beginStreetNames,
    required this.beginShapeIndex,
    required this.endShapeIndex,
    required this.lengthMeters,
    required this.timeSeconds,
    required this.raw,
  });

  factory Maneuver.fromJson(Map<String, dynamic> json, {int shapeOffset = 0}) {
    final code = (json['type'] as num?)?.toInt() ?? 0;
    return Maneuver(
      type: ManeuverType.fromCode(code),
      typeCode: code,
      instruction: json['instruction'] as String? ?? '',
      streetNames: _strings(json['street_names']),
      beginStreetNames: _strings(json['begin_street_names']),
      beginShapeIndex:
          ((json['begin_shape_index'] as num?)?.toInt() ?? 0) + shapeOffset,
      endShapeIndex:
          ((json['end_shape_index'] as num?)?.toInt() ?? 0) + shapeOffset,
      lengthMeters: _km(json['length']),
      timeSeconds: (json['time'] as num?)?.toDouble() ?? 0,
      raw: json,
    );
  }

  final ManeuverType type;

  /// Raw Valhalla type code, kept for codes [ManeuverType] does not know.
  final int typeCode;

  /// Written instruction in the requested language.
  final String instruction;

  /// Names of the road this maneuver travels on (may be empty).
  final List<String> streetNames;

  /// Names at the start of the maneuver when they differ from [streetNames].
  final List<String> beginStreetNames;

  /// Index into [Route.shape] where the maneuver starts.
  final int beginShapeIndex;

  /// Index into [Route.shape] where the maneuver ends (= next one's begin).
  final int endShapeIndex;

  final double lengthMeters;

  /// Free-flow travel time of the maneuver as estimated by Valhalla.
  final double timeSeconds;

  /// Untouched maneuver object from the response.
  final Map<String, dynamic> raw;

  /// Text to speak shortly before the maneuver.
  String? get verbalPreTransition =>
      raw['verbal_pre_transition_instruction'] as String?;

  /// Short early warning ("Поверните направо на ...").
  String? get verbalAlert =>
      raw['verbal_transition_alert_instruction'] as String?;

  /// Text to speak right after the maneuver ("Продолжайте движение ...").
  String? get verbalPostTransition =>
      raw['verbal_post_transition_instruction'] as String?;

  int? get bearingBefore => (raw['bearing_before'] as num?)?.toInt();
  int? get bearingAfter => (raw['bearing_after'] as num?)?.toInt();
  int? get roundaboutExitCount =>
      (raw['roundabout_exit_count'] as num?)?.toInt();
  bool get toll => raw['toll'] == true;
  bool get highway => raw['highway'] == true;
  bool get ferry => raw['ferry'] == true;
  bool get rough => raw['rough'] == true;

  /// "drive", "pedestrian", "bicycle" or "transit".
  String? get travelMode => raw['travel_mode'] as String?;

  @override
  String toString() =>
      'Maneuver($type, "$instruction", ${lengthMeters.round()} m)';
}

/// Totals for a leg or a whole route.
class RouteSummary {
  const RouteSummary({
    required this.lengthMeters,
    required this.timeSeconds,
    this.cost,
    this.hasToll = false,
    this.hasHighway = false,
    this.hasFerry = false,
    this.hasTimeRestrictions = false,
    this.southWest,
    this.northEast,
  });

  factory RouteSummary.fromJson(Map<String, dynamic> json) {
    LatLng? corner(String lat, String lon) {
      final a = json[lat], o = json[lon];
      return a is num && o is num ? LatLng(a.toDouble(), o.toDouble()) : null;
    }

    return RouteSummary(
      lengthMeters: _km(json['length']),
      timeSeconds: (json['time'] as num?)?.toDouble() ?? 0,
      cost: (json['cost'] as num?)?.toDouble(),
      hasToll: json['has_toll'] == true,
      hasHighway: json['has_highway'] == true,
      hasFerry: json['has_ferry'] == true,
      hasTimeRestrictions: json['has_time_restrictions'] == true,
      southWest: corner('min_lat', 'min_lon'),
      northEast: corner('max_lat', 'max_lon'),
    );
  }

  final double lengthMeters;

  /// Free-flow travel time (no live traffic) in seconds.
  final double timeSeconds;

  /// Valhalla's internal cost; only comparable between routes of one request.
  final double? cost;
  final bool hasToll;
  final bool hasHighway;
  final bool hasFerry;
  final bool hasTimeRestrictions;

  /// Bounding box corners, when the server reported them.
  final LatLng? southWest;
  final LatLng? northEast;

  Duration get duration => Duration(milliseconds: (timeSeconds * 1000).round());
}

/// The part of a route between two consecutive requested locations.
class RouteLeg {
  RouteLeg({
    required this.summary,
    required this.maneuvers,
    required this.shape,
    required this.encodedShape,
    required this.shapeOffset,
  });

  final RouteSummary summary;

  /// Maneuvers of this leg; shape indexes refer to [Route.shape].
  final List<Maneuver> maneuvers;

  /// Geometry of this leg only.
  final List<LatLng> shape;

  /// The leg geometry exactly as Valhalla sent it (polyline6). Feed this
  /// back to `/trace_attributes` to get per-edge data, see
  /// `ValhallaClient.edges`.
  final String encodedShape;

  /// Index in [Route.shape] of this leg's first point.
  final int shapeOffset;
}

/// One complete route (the best one or an alternate).
class Route {
  Route({
    required this.summary,
    required this.legs,
    required this.shape,
    required this.costing,
    required this.raw,
  });

  /// Parses a Valhalla `trip` object.
  factory Route.fromTrip(Map<String, dynamic> trip, {RouteCosting? costing}) {
    final legs = <RouteLeg>[];
    final shape = <LatLng>[];
    for (final legJson in (trip['legs'] as List? ?? const [])) {
      final leg = legJson as Map<String, dynamic>;
      final encoded = leg['shape'] as String? ?? '';
      final legShape = decodePolyline(encoded);
      // Consecutive legs share their joint point; keep it once.
      final skip =
          shape.isNotEmpty && legShape.isNotEmpty && shape.last == legShape[0]
          ? 1
          : 0;
      final offset = shape.length - skip;
      shape.addAll(legShape.skip(skip));
      legs.add(
        RouteLeg(
          summary: RouteSummary.fromJson(
            leg['summary'] as Map<String, dynamic>? ?? const {},
          ),
          maneuvers: [
            for (final m in (leg['maneuvers'] as List? ?? const []))
              Maneuver.fromJson(m as Map<String, dynamic>, shapeOffset: offset),
          ],
          shape: legShape,
          encodedShape: encoded,
          shapeOffset: offset,
        ),
      );
    }
    return Route(
      summary: RouteSummary.fromJson(
        trip['summary'] as Map<String, dynamic>? ?? const {},
      ),
      legs: legs,
      shape: shape,
      costing: costing,
      raw: trip,
    );
  }

  final RouteSummary summary;
  final List<RouteLeg> legs;

  /// Full geometry, all legs joined.
  final List<LatLng> shape;

  /// The profile this route was computed with, if known.
  final RouteCosting? costing;

  /// Untouched `trip` object from the response.
  final Map<String, dynamic> raw;

  double get lengthMeters => summary.lengthMeters;

  /// Free-flow travel time in seconds.
  double get timeSeconds => summary.timeSeconds;
  Duration get duration => summary.duration;

  /// All maneuvers of all legs in driving order.
  Iterable<Maneuver> get maneuvers => legs.expand((l) => l.maneuvers);
}

/// Answer to a `/route` request: the best route first, then alternates.
class RouteResult {
  RouteResult({required this.routes, required this.raw});

  /// Parses a full `/route` response body.
  factory RouteResult.fromJson(
    Map<String, dynamic> json, {
    RouteCosting? costing,
  }) {
    final routes = <Route>[];
    final trip = json['trip'];
    if (trip is Map<String, dynamic>) {
      routes.add(Route.fromTrip(trip, costing: costing));
    }
    for (final alt in (json['alternates'] as List? ?? const [])) {
      final altTrip = (alt as Map<String, dynamic>)['trip'];
      if (altTrip is Map<String, dynamic>) {
        routes.add(Route.fromTrip(altTrip, costing: costing));
      }
    }
    if (routes.isEmpty) {
      throw const FormatException('Valhalla response has no trip');
    }
    return RouteResult(routes: routes, raw: json);
  }

  /// Never empty. `routes.first` is Valhalla's preferred route.
  final List<Route> routes;
  final Map<String, dynamic> raw;

  Route get best => routes.first;
  List<Route> get alternates => routes.sublist(1);
}

/// One directed graph edge along a route, from `/trace_attributes`.
///
/// This is the granularity traffic works at: v1 re-estimates
/// [freeFlowSeconds] from sampled traffic colours, v2 would write a live
/// speed for [id] into Valhalla's traffic.tar.
class RouteEdge {
  RouteEdge({
    required this.id,
    required this.wayId,
    required this.lengthMeters,
    required this.speedKmh,
    required this.freeFlowSeconds,
    required this.elapsedSeconds,
    required this.beginShapeIndex,
    required this.endShapeIndex,
    required this.roadClass,
    required this.use,
    required this.names,
    required this.raw,
  });

  /// Valhalla GraphId of the directed edge (level/tile/index packed in 46
  /// bits). Stable only for one tile build.
  final int? id;

  /// OSM way id.
  final int? wayId;
  final double lengthMeters;

  /// Speed Valhalla assumed for this edge (km/h), before live traffic.
  final double speedKmh;

  /// Time to traverse this edge including the turn onto it, in seconds.
  final double freeFlowSeconds;

  /// Time from the route start to the end of this edge, in seconds.
  final double elapsedSeconds;

  /// Indexes into [Route.shape] (already shifted by the leg offset).
  final int beginShapeIndex;
  final int endShapeIndex;

  /// "motorway", "trunk", "primary", "secondary", "tertiary",
  /// "unclassified", "residential" or "service_other".
  final String? roadClass;

  /// "road", "ramp", "turn_channel", "track", "ferry", ...
  final String? use;
  final List<String> names;
  final Map<String, dynamic> raw;

  /// Parses the `edges` array of a `/trace_attributes` response.
  static List<RouteEdge> listFromJson(
    Map<String, dynamic> json, {
    int shapeOffset = 0,
    double elapsedOffset = 0,
  }) {
    final edges = <RouteEdge>[];
    var previousElapsed = 0.0;
    for (final item in (json['edges'] as List? ?? const [])) {
      final e = item as Map<String, dynamic>;
      final lengthMeters = _km(e['length']);
      final speed = (e['speed'] as num?)?.toDouble() ?? 0;
      final endNode = e['end_node'];
      final elapsed = endNode is Map<String, dynamic>
          ? (endNode['elapsed_time'] as num?)?.toDouble()
          : null;
      // Without node timings fall back to length / speed.
      final seconds = elapsed != null
          ? elapsed - previousElapsed
          : (speed > 0 ? lengthMeters / (speed / 3.6) : 0.0);
      previousElapsed = elapsed ?? previousElapsed + seconds;
      edges.add(
        RouteEdge(
          id: (e['id'] as num?)?.toInt(),
          wayId: (e['way_id'] as num?)?.toInt(),
          lengthMeters: lengthMeters,
          speedKmh: speed,
          freeFlowSeconds: seconds < 0 ? 0 : seconds,
          elapsedSeconds: elapsedOffset + previousElapsed,
          beginShapeIndex:
              ((e['begin_shape_index'] as num?)?.toInt() ?? 0) + shapeOffset,
          endShapeIndex:
              ((e['end_shape_index'] as num?)?.toInt() ?? 0) + shapeOffset,
          roadClass: e['road_class'] as String?,
          use: e['use'] as String?,
          names: _strings(e['names']),
          raw: e,
        ),
      );
    }
    return edges;
  }
}

/// Answer of `/status`.
class ValhallaStatus {
  ValhallaStatus({
    required this.version,
    required this.tilesetLastModified,
    required this.raw,
  });

  factory ValhallaStatus.fromJson(Map<String, dynamic> json) {
    final modified = (json['tileset_last_modified'] as num?)?.toInt();
    return ValhallaStatus(
      version: json['version'] as String? ?? '',
      tilesetLastModified: modified == null || modified == 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(modified * 1000, isUtc: true),
      raw: json,
    );
  }

  /// Valhalla version of the backend, e.g. "3.6.0".
  final String version;

  /// When the routing tiles were built, if the backend reports it.
  final DateTime? tilesetLastModified;
  final Map<String, dynamic> raw;
}

/// A point snapped to the road graph by `/locate`.
class SnappedPoint {
  SnappedPoint({
    required this.point,
    required this.wayId,
    required this.edgeId,
    required this.distanceMeters,
    required this.raw,
  });

  final LatLng point;
  final int? wayId;

  /// GraphId value of the snapped edge (verbose locate only).
  final int? edgeId;

  /// Distance from the requested point to [point].
  final double? distanceMeters;
  final Map<String, dynamic> raw;
}

/// An error reported by Valhalla (HTTP 4xx/5xx with a JSON body).
class ValhallaException implements Exception {
  ValhallaException({required this.message, this.errorCode, this.httpStatus});

  /// English text from Valhalla, e.g. "No path could be found for input".
  final String message;

  /// Valhalla error code, see
  /// https://valhalla.github.io/valhalla/api/turn-by-turn/api-reference/#internal-error-codes-and-conditions
  final int? errorCode;
  final int? httpStatus;

  /// No road near one of the requested points (codes 170, 171).
  bool get noRoadNearby => errorCode == 170 || errorCode == 171;

  /// The graph has no connection between the points (code 442).
  bool get noRoute => errorCode == 442;

  /// The request is longer than the configured limit (code 154).
  bool get tooFar => errorCode == 154;

  @override
  String toString() => 'ValhallaException($errorCode, $httpStatus): $message';
}

double _km(Object? value) => ((value as num?)?.toDouble() ?? 0) * 1000;

List<String> _strings(Object? value) =>
    value is List ? [for (final v in value) v.toString()] : const [];
