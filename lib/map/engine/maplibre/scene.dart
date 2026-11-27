import '../../../traffic/traffic_sampler.dart';
import 'dart:convert';

import 'package:latlong2/latlong.dart';

import '../map_engine.dart' show HeatPoint;
import 'camera.dart';
import 'style.dart';

/// What the native map currently shows, reduced to the strings that are sent
/// to it. Comparing two states gives the minimal set of updates.
class SceneState {
  const SceneState({
    required this.style,
    this.routes = emptyGeoJson,
    this.points = emptyGeoJson,
    this.accuracy = emptyGeoJson,
    this.heat = emptyGeoJson,
    this.traffic,
  });

  static const emptyGeoJson = '{"type":"FeatureCollection","features":[]}';

  /// Identifies the base style (pack, theme, colours); a change reloads it.
  final String style;

  /// GeoJSON of the three overlay sources.
  final String routes, points, accuracy;

  /// GeoJSON of the signal heat map. Its source and layer are part of the
  /// style only while the layer is on (the style key says so); otherwise
  /// this stays empty.
  final String heat;

  /// `<source>/<version>` of the traffic overlay, null when off.
  final String? traffic;
}

sealed class SceneOp {
  const SceneOp();
}

/// Replace the whole style; everything else must be sent again afterwards
/// (diff against a state that has only [SceneState.style]).
class LoadStyle extends SceneOp {
  const LoadStyle(this.style);
  final String style;
}

class SetGeoJson extends SceneOp {
  const SetGeoJson(this.source, this.json);
  final String source, json;
}

/// Show the traffic overlay [add] and drop [remove] (either may be null).
class SetTraffic extends SceneOp {
  const SetTraffic({this.remove, this.add});
  final String? remove, add;
}

/// Updates that turn [old] into [next].
List<SceneOp> diffScene(SceneState? old, SceneState next) {
  if (old == null || old.style != next.style) return [LoadStyle(next.style)];
  return [
    if (old.traffic != next.traffic)
      SetTraffic(remove: old.traffic, add: next.traffic),
    if (old.routes != next.routes) SetGeoJson(MapIds.routes, next.routes),
    if (old.points != next.points) SetGeoJson(MapIds.points, next.points),
    if (old.accuracy != next.accuracy)
      SetGeoJson(MapIds.accuracy, next.accuracy),
    if (old.heat != next.heat) SetGeoJson(MapIds.heat, next.heat),
  ];
}

List<double> _lonLat(LatLng p) => [
  double.parse(p.longitude.toStringAsFixed(6)),
  double.parse(p.latitude.toStringAsFixed(6)),
];

String _collection(List<Map<String, Object>> features) =>
    jsonEncode({'type': 'FeatureCollection', 'features': features});

/// The selected route and its alternatives as line features.
String routesGeoJson(
  List<LatLng>? route,
  List<List<LatLng>> alternatives, [
  List<TrafficSpan> traffic = const [],
]) {
  Map<String, Object> line(List<LatLng> shape, String kind, [String? level]) =>
      {
        'type': 'Feature',
        'properties': {'kind': kind, 'level': ?level},
        'geometry': {
          'type': 'LineString',
          'coordinates': [for (final p in shape) _lonLat(p)],
        },
      };
  if (route == null) return SceneState.emptyGeoJson;
  return _collection([
    for (final other in alternatives)
      if (other.length > 1) line(other, 'alt'),
    if (route.length > 1) line(route, 'route'),
    // The traffic along the route, drawn inside its band.
    if (route.length > 1)
      for (final span in traffic)
        if (span.beginIndex >= 0 &&
            span.endIndex < route.length &&
            span.endIndex > span.beginIndex)
          line(
            route.sublist(span.beginIndex, span.endIndex + 1),
            'traffic',
            span.level.name,
          ),
  ]);
}

/// The points of the signal heat map, each with its weight `w`.
String heatGeoJson(List<HeatPoint>? points) {
  if (points == null || points.isEmpty) return SceneState.emptyGeoJson;
  return _collection([
    for (final p in points)
      {
        'type': 'Feature',
        'properties': {'w': double.parse(p.weight.toStringAsFixed(2))},
        'geometry': {
          'type': 'Point',
          // A metre is plenty for a blurred spot.
          'coordinates': [
            double.parse(p.point.longitude.toStringAsFixed(5)),
            double.parse(p.point.latitude.toStringAsFixed(5)),
          ],
        },
      },
  ]);
}

/// Position dot and the three markers as point features.
String pointsGeoJson({
  LatLng? position,
  double? heading,
  LatLng? from,
  LatLng? to,
  LatLng? picked,
}) {
  Map<String, Object> point(
    LatLng p,
    String kind, [
    String? icon,
    double? heading,
  ]) => {
    'type': 'Feature',
    // A position with a heading is drawn as an arrow, else as a dot.
    'properties': {
      'kind': heading == null ? kind : '$kind-heading',
      'icon': ?icon,
      'heading': ?heading,
    },
    'geometry': {'type': 'Point', 'coordinates': _lonLat(p)},
  };
  if (position == null && from == null && to == null && picked == null) {
    return SceneState.emptyGeoJson;
  }
  return _collection([
    if (position != null)
      point(position, 'position', null, heading?.roundToDouble()),
    if (from != null) point(from, 'from'),
    if (to != null) point(to, 'to', MapIds.pinTo),
    if (picked != null) point(picked, 'picked', MapIds.pinPicked),
  ]);
}

/// The accuracy circle: a polygon of [radiusM] metres on the ground.
String accuracyGeoJson(LatLng? position, double? radiusM) {
  if (position == null) return SceneState.emptyGeoJson;
  return _collection([
    {
      'type': 'Feature',
      'properties': <String, Object>{},
      'geometry': {
        'type': 'Polygon',
        'coordinates': [circleRing(position, radiusM ?? 10)],
      },
    },
  ]);
}
