import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'route_models.dart';

import 'polyline.dart';
export 'polyline.dart';
export 'route_models.dart';

/// The backend could not be reached at all (not running, wrong URL, timeout).
/// Errors Valhalla itself reports are [ValhallaException]s instead.
class ValhallaUnavailableException implements Exception {
  ValhallaUnavailableException(this.cause);

  final Object cause;

  @override
  String toString() => 'ValhallaUnavailableException: $cause';
}

/// Client for the Valhalla HTTP JSON API.
///
/// Works the same against the local backend on the phone, the Docker
/// container on the PC or a remote server: only the base URL differs.
class ValhallaClient {
  /// [baseUrl] is e.g. `http://127.0.0.1:8002`.
  ValhallaClient(
    Uri baseUrl, {
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
    this.language = 'ru-RU',
  }) : _baseUrl = (() => baseUrl),
       _http = httpClient ?? http.Client(),
       _ownsHttp = httpClient == null;

  /// Resolves the base URL on every request. Use this with a backend whose
  /// address can change, e.g. `ValhallaClient.dynamic(() => backend.baseUrl)`
  /// for a local service that may come back on another port after a crash.
  ValhallaClient.dynamic(
    Uri Function() baseUrl, {
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
    this.language = 'ru-RU',
  }) : _baseUrl = baseUrl,
       _http = httpClient ?? http.Client(),
       _ownsHttp = httpClient == null;

  final Uri Function() _baseUrl;
  final http.Client _http;
  final bool _ownsHttp;

  /// Applied to every request.
  final Duration timeout;

  /// Language of maneuver instructions (Valhalla locale tag).
  final String language;

  Uri get baseUrl => _baseUrl();

  /// Computes a route through [locations] (at least two: start, optional
  /// via points, destination).
  ///
  /// [alternates] is how many extra routes to ask for; Valhalla returns
  /// fewer (often none) when it finds no sufficiently different ones, and
  /// only supports alternates for two locations.
  ///
  /// [headingDegrees] (0 = north, clockwise) makes the start snap to the
  /// road direction the vehicle is facing.
  ///
  /// [costingOptions] goes into `costing_options.<costing>`, e.g.
  /// `{'use_tolls': 0, 'use_highways': 0.5}`.
  ///
  /// With [stopAtVias] the intermediate locations are stops (`break`): the
  /// route gets one [RouteLeg] per pair of consecutive locations, each with
  /// its own summary and its own arrival maneuver. Without it (the default)
  /// they are passed through without stopping and the legs are joined.
  ///
  /// Throws [ValhallaException] if Valhalla rejects the request and
  /// [ValhallaUnavailableException] if the backend is unreachable.
  Future<RouteResult> route({
    required List<LatLng> locations,
    RouteCosting costing = RouteCosting.auto,
    int alternates = 0,
    double? headingDegrees,
    Map<String, dynamic>? costingOptions,
    bool stopAtVias = false,
  }) async {
    if (locations.length < 2) {
      throw ArgumentError.value(locations, 'locations', 'need at least two');
    }
    final json = await _post(
      'route',
      buildRouteRequest(
        locations: locations,
        costing: costing,
        alternates: alternates,
        headingDegrees: headingDegrees,
        costingOptions: costingOptions,
        stopAtVias: stopAtVias,
        language: language,
      ),
    );
    try {
      return RouteResult.fromJson(json, costing: costing);
    } on FormatException catch (e) {
      throw ValhallaException(message: 'Bad /route response: ${e.message}');
    }
  }

  /// Builds the `/route` request body. Public for tests and debugging.
  static Map<String, dynamic> buildRouteRequest({
    required List<LatLng> locations,
    RouteCosting costing = RouteCosting.auto,
    int alternates = 0,
    double? headingDegrees,
    Map<String, dynamic>? costingOptions,
    bool stopAtVias = false,
    String language = 'ru-RU',
  }) {
    return {
      'locations': [
        for (var i = 0; i < locations.length; i++)
          {
            'lat': locations[i].latitude,
            'lon': locations[i].longitude,
            // Via points are stops of their own, or passed through.
            'type': stopAtVias || i == 0 || i == locations.length - 1
                ? 'break'
                : 'through',
            if (i == 0 && headingDegrees != null)
              'heading': headingDegrees.round() % 360,
          },
      ],
      'costing': costing.name,
      if (costingOptions != null)
        'costing_options': {costing.name: costingOptions},
      if (alternates > 0) 'alternates': alternates,
      'units': 'kilometers',
      'language': language,
      'directions_type': 'instructions',
    };
  }

  /// Per-edge data along [route]: edge ids, lengths, assumed speeds and
  /// free-flow times, with shape indexes pointing into [Route.shape].
  ///
  /// This asks `/trace_attributes` to walk the exact geometry `/route`
  /// returned (`shape_match: edge_walk`), which costs a few milliseconds.
  /// If the walk fails (it can at odd start/end positions) it retries with
  /// map matching, which is slower and may differ slightly from the route.
  Future<List<RouteEdge>> edges(Route route, {RouteCosting? costing}) async {
    final profile = costing ?? route.costing ?? RouteCosting.auto;
    final all = <RouteEdge>[];
    var elapsed = 0.0;
    for (final leg in route.legs) {
      Map<String, dynamic> json;
      try {
        json = await _post(
          'trace_attributes',
          buildEdgesRequest(leg.encodedShape, profile),
        );
      } on ValhallaException {
        json = await _post(
          'trace_attributes',
          buildEdgesRequest(leg.encodedShape, profile, shapeMatch: 'map_snap'),
        );
      }
      final edges = RouteEdge.listFromJson(
        json,
        shapeOffset: leg.shapeOffset,
        elapsedOffset: elapsed,
      );
      if (edges.isNotEmpty) elapsed = edges.last.elapsedSeconds;
      all.addAll(edges);
    }
    return all;
  }

  /// Builds the `/trace_attributes` request used by [edges].
  static Map<String, dynamic> buildEdgesRequest(
    String encodedShape,
    RouteCosting costing, {
    String shapeMatch = 'edge_walk',
  }) {
    return {
      'encoded_polyline': encodedShape,
      'shape_match': shapeMatch,
      'costing': costing.name,
      'units': 'kilometers',
      'filters': {
        'action': 'include',
        'attributes': [
          'edge.id',
          'edge.way_id',
          'edge.length',
          'edge.speed',
          'edge.road_class',
          'edge.use',
          'edge.names',
          'edge.begin_shape_index',
          'edge.end_shape_index',
          'node.elapsed_time',
        ],
      },
    };
  }

  /// Snaps [point] to the nearest road usable with [costing].
  /// Returns null if there is no road within Valhalla's search radius.
  Future<SnappedPoint?> locate(
    LatLng point, {
    RouteCosting costing = RouteCosting.auto,
  }) async {
    final json = await _postAny('locate', {
      'locations': [
        {'lat': point.latitude, 'lon': point.longitude},
      ],
      'costing': costing.name,
      'verbose': true,
    });
    if (json is! List || json.isEmpty) return null;
    final first = json.first;
    if (first is! Map<String, dynamic>) return null;
    final edges = first['edges'];
    if (edges is! List || edges.isEmpty) return null;
    final edge = edges.first as Map<String, dynamic>;
    final lat = edge['correlated_lat'], lon = edge['correlated_lon'];
    if (lat is! num || lon is! num) return null;
    final edgeId = edge['edge_id'];
    final info = edge['edge_info'];
    return SnappedPoint(
      point: LatLng(lat.toDouble(), lon.toDouble()),
      wayId: info is Map ? (info['way_id'] as num?)?.toInt() : null,
      edgeId: edgeId is Map ? (edgeId['value'] as num?)?.toInt() : null,
      distanceMeters: (edge['distance'] as num?)?.toDouble(),
      raw: edge,
    );
  }

  /// The road a car is on, given two points it just passed ([from] then
  /// [to], a few dozen metres apart): map-matched, so the carriageway and
  /// direction are the driven ones. Null when no road matches.
  Future<DrivenEdge?> drivenEdge(
    LatLng from,
    LatLng to, {
    RouteCosting costing = RouteCosting.auto,
  }) async {
    final Map<String, dynamic> json;
    try {
      json = await _post('trace_attributes', {
        'shape': [
          {'lat': from.latitude, 'lon': from.longitude},
          {'lat': to.latitude, 'lon': to.longitude},
        ],
        'costing': costing.name,
        'shape_match': 'map_snap',
        'filters': {
          'action': 'include',
          'attributes': [
            'edge.speed_limit',
            'edge.density',
            'edge.road_class',
            'edge.use',
            'shape',
          ],
        },
      });
    } on ValhallaException {
      return null; // nothing to match here
    }
    final edges = json['edges'];
    if (edges is! List || edges.isEmpty) return null;
    final last = edges.last;
    if (last is! Map<String, dynamic>) return null;
    final shape = json['shape'];
    return DrivenEdge.fromJson(
      last,
      shape: shape is String ? decodePolyline(shape) : const [],
    );
  }

  /// Asks the backend for its version. Throws if it is not reachable.
  Future<ValhallaStatus> status() async =>
      ValhallaStatus.fromJson(await _post('status', const {}));

  /// True if the backend answers `/status`. Never throws.
  Future<bool> isHealthy({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      await _send('status', const {}, timeout);
      return true;
    } on Exception {
      return false;
    }
  }

  /// Closes the underlying HTTP client unless it was passed in.
  void close() {
    if (_ownsHttp) _http.close();
  }

  Future<Map<String, dynamic>> _post(
    String action,
    Map<String, dynamic> body,
  ) async {
    final json = await _postAny(action, body);
    if (json is Map<String, dynamic>) return json;
    throw ValhallaException(message: 'Unexpected /$action response');
  }

  Future<Object?> _postAny(String action, Map<String, dynamic> body) =>
      _send(action, body, timeout);

  Future<Object?> _send(
    String action,
    Map<String, dynamic> body,
    Duration timeout,
  ) async {
    final base = _baseUrl();
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final uri = base.replace(path: '$basePath/$action');
    final http.Response response;
    try {
      response = await _http
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on TimeoutException catch (e) {
      throw ValhallaUnavailableException(e);
    } on Exception catch (e) {
      // SocketException, http.ClientException, ...
      throw ValhallaUnavailableException(e);
    }
    return parseResponse(response.statusCode, response.bodyBytes);
  }

  /// Decodes a response body, turning Valhalla error objects into
  /// [ValhallaException]. Public for tests.
  static Object? parseResponse(int statusCode, List<int> bodyBytes) {
    Object? json;
    try {
      json = jsonDecode(utf8.decode(bodyBytes));
    } on FormatException {
      throw ValhallaException(
        message: 'Backend returned non-JSON (HTTP $statusCode)',
        httpStatus: statusCode,
      );
    }
    if (json is Map<String, dynamic> &&
        (statusCode >= 400 || json.containsKey('error_code'))) {
      throw ValhallaException(
        message: json['error'] as String? ?? 'HTTP $statusCode',
        errorCode: (json['error_code'] as num?)?.toInt(),
        httpStatus: (json['status_code'] as num?)?.toInt() ?? statusCode,
      );
    }
    if (statusCode >= 400) {
      throw ValhallaException(
        message: 'HTTP $statusCode',
        httpStatus: statusCode,
      );
    }
    return json;
  }
}
