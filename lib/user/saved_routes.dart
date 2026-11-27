/// Routes the user built and kept.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../routing/polyline.dart';
import '../routing/route_models.dart' show RouteCosting;
import 'json_store.dart';

/// One stop of a saved route.
@immutable
class RoutePoint {
  const RoutePoint(this.point, {this.label});

  final LatLng point;

  /// What the user sees for this stop (address, place name), if known.
  final String? label;

  Map<String, dynamic> toJson() => {
    'point': pointToJson(point),
    'label': ?label,
  };

  static RoutePoint? fromJson(Object? json) {
    if (json is! Map) return null;
    final point = pointFromJson(json['point']);
    final label = json['label'];
    if (point == null) return null;
    return RoutePoint(
      point,
      label: label is String && label.isNotEmpty ? label : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RoutePoint && other.point == point && other.label == label;

  @override
  int get hashCode => Object.hash(point, label);

  @override
  String toString() => 'RoutePoint($point${label == null ? '' : ', "$label"'})';
}

/// Rounds to 1e-6 degrees (about 0.1 m), the precision of the routing
/// engine's own shapes.
double _micro(double v) => (v * 1e6).round() / 1e6;

/// Name used when the user gave none.
String defaultRouteName(DateTime created) {
  final t = created.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return 'Маршрут ${two(t.day)}.${two(t.month)}.${t.year}';
}

/// A route kept for later: the stops, how to travel and, optionally, the
/// line as it was planned.
@immutable
class SavedRoute {
  /// Without [id] a new one is generated; without [created] the current
  /// time is used.
  ///
  /// [geometry] is stored with 1e-6 degree precision (what the routing
  /// engine produces); finer input is rounded here, so that a route equals
  /// its copy read back from disk or from a GPX file.
  ///
  /// Throws [ArgumentError] for fewer than two [points].
  SavedRoute({
    String? id,
    required this.name,
    required List<RoutePoint> points,
    this.costing = RouteCosting.auto,
    DateTime? created,
    List<LatLng>? geometry,
    this.lengthMeters,
  }) : id = id ?? newUserId(),
       points = List.unmodifiable(points),
       created = (created ?? DateTime.now()).toUtc(),
       geometry = geometry == null
           ? null
           : List.unmodifiable([
               for (final p in geometry)
                 LatLng(_micro(p.latitude), _micro(p.longitude)),
             ]) {
    if (points.length < 2) {
      throw ArgumentError.value(points, 'points', 'a route needs two points');
    }
  }

  final String id;
  final String name;

  /// First = start, last = destination, between = via points.
  final List<RoutePoint> points;
  final RouteCosting costing;

  /// Always UTC.
  final DateTime created;

  /// The line as it was planned. It is a record of that plan, not a
  /// promise: after a map update the route should be computed again from
  /// [points].
  final List<LatLng>? geometry;
  final double? lengthMeters;

  RoutePoint get start => points.first;
  RoutePoint get destination => points.last;
  List<RoutePoint> get via => points.sublist(1, points.length - 1);

  SavedRoute copyWith({String? name}) => SavedRoute(
    id: id,
    name: name ?? this.name,
    points: points,
    costing: costing,
    created: created,
    geometry: geometry,
    lengthMeters: lengthMeters,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'costing': costing.name,
    'created': created.toIso8601String(),
    'points': [for (final p in points) p.toJson()],
    'lengthMeters': ?lengthMeters,
    // polyline6: compact and exact for coordinates rounded to 1e-6.
    if (geometry != null) 'geometry': encodePolyline(geometry!),
  };

  /// Null when [json] lacks an id or two valid points. An unreadable
  /// geometry is dropped, the route itself is kept.
  static SavedRoute? fromJson(Map<String, dynamic> json) {
    final id = json['id'], name = json['name'], raw = json['points'];
    if (id is! String || id.isEmpty || raw is! List) return null;
    final points = <RoutePoint>[];
    for (final e in raw) {
      final p = RoutePoint.fromJson(e);
      if (p == null) return null;
      points.add(p);
    }
    if (points.length < 2) return null;
    final created =
        DateTime.tryParse(json['created'] is String ? json['created'] : '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    List<LatLng>? geometry;
    final encoded = json['geometry'];
    if (encoded is String) {
      try {
        geometry = decodePolyline(encoded);
        if (geometry.any((p) => !validLatLon(p.latitude, p.longitude))) {
          geometry = null;
        }
      } on FormatException {
        geometry = null;
      }
    }
    final length = json['lengthMeters'];
    return SavedRoute(
      id: id,
      name: name is String && name.trim().isNotEmpty
          ? name
          : defaultRouteName(created),
      points: points,
      costing: RouteCosting.values.firstWhere(
        (c) => c.name == json['costing'],
        orElse: () => RouteCosting.auto,
      ),
      created: created,
      geometry: geometry,
      lengthMeters: length is num && length.isFinite && length >= 0
          ? length.toDouble()
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SavedRoute &&
      other.id == id &&
      other.name == name &&
      other.costing == costing &&
      other.created == created &&
      other.lengthMeters == lengthMeters &&
      listEquals(other.points, points) &&
      listEquals(other.geometry, geometry);

  @override
  int get hashCode =>
      Object.hash(id, name, costing, created, lengthMeters, points.length);

  @override
  String toString() =>
      'SavedRoute($id, "$name", ${costing.name}, ${points.length} points, '
      '${geometry?.length ?? 0} shape points)';
}

/// The saved routes, kept in `routes.json`.
class SavedRoutes extends JsonListStore<SavedRoute> {
  SavedRoutes._(File? file) : super(file, 'routes');

  /// Loads `<dir>/routes.json`. Never throws; see [loadError].
  factory SavedRoutes.load(Directory dir) {
    final store = SavedRoutes._(File('${dir.path}/routes.json'))..load();
    final ids = <String>{};
    store.items.removeWhere((r) => !ids.add(r.id));
    return store;
  }

  /// A store that is not persisted.
  factory SavedRoutes.inMemory() => SavedRoutes._(null);

  @override
  SavedRoute? decodeItem(Map<String, dynamic> json) =>
      SavedRoute.fromJson(json);

  @override
  Map<String, dynamic> encodeItem(SavedRoute item) => item.toJson();

  /// Newest first.
  List<SavedRoute> get routes => List.unmodifiable(
    [...items]..sort((a, b) {
      final t = b.created.compareTo(a.created);
      return t != 0 ? t : b.id.compareTo(a.id);
    }),
  );

  SavedRoute? byId(String id) {
    for (final r in items) {
      if (r.id == id) return r;
    }
    return null;
  }

  static SavedRoute _clean(SavedRoute r) {
    final name = r.name.trim();
    return name == r.name && name.isNotEmpty
        ? r
        : r.copyWith(name: name.isEmpty ? defaultRouteName(r.created) : name);
  }

  void _put(SavedRoute route) {
    items
      ..removeWhere((r) => r.id == route.id)
      ..add(_clean(route));
  }

  /// Adds [route], or replaces the one with the same id. The name is
  /// trimmed; an empty name becomes [defaultRouteName]. Returns the route
  /// as stored.
  SavedRoute save(SavedRoute route) {
    _put(route);
    changed();
    return byId(route.id)!;
  }

  /// Adds routes from an import in one write (same id = replace). Returns
  /// the number of routes taken.
  int addAll(Iterable<SavedRoute> imported) {
    var n = 0;
    for (final r in imported) {
      _put(r);
      n++;
    }
    if (n > 0) changed();
    return n;
  }

  /// Returns false when there is no such route.
  bool remove(String id) {
    final before = items.length;
    items.removeWhere((r) => r.id == id);
    if (items.length == before) return false;
    changed();
    return true;
  }

  /// Returns false when there is no such route. An empty name becomes
  /// [defaultRouteName].
  bool rename(String id, String name) {
    final r = byId(id);
    if (r == null) return false;
    _put(r.copyWith(name: name));
    changed();
    return true;
  }
}
