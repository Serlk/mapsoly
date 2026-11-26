import 'dart:math' as math;
import 'dart:ui';

import 'package:latlong2/latlong.dart';

/// Camera of the map view and the Web Mercator arithmetic around it.
///
/// [zoom] follows the convention of the rest of the app (256 px tiles: the
/// world is `256 * 2^zoom` logical pixels wide); MapLibre counts 512 px tiles,
/// see [mapLibreZoom]. [bearing] is in degrees clockwise: the compass
/// direction that points up on the screen.
class MapCamera {
  const MapCamera(this.center, this.zoom, [this.bearing = 0]);

  final LatLng center;
  final double zoom;
  final double bearing;

  static const minZoom = 3.0;
  static const maxZoom = 19.0;
  static const _maxLatitude = 85.0;

  double get mapLibreZoom => zoom - 1;

  static double worldSize(double zoom) => 256.0 * math.pow(2, zoom);

  /// World pixel position of [p] at [zoom] (x east, y south).
  static Offset project(LatLng p, double zoom) {
    final w = worldSize(zoom);
    final lat = p.latitude.clamp(-_maxLatitude, _maxLatitude) * math.pi / 180;
    return Offset(
      (p.longitude + 180) / 360 * w,
      (1 - math.log(math.tan(math.pi / 4 + lat / 2)) / math.pi) / 2 * w,
    );
  }

  static LatLng unproject(Offset world, double zoom) {
    final w = worldSize(zoom);
    final y = (world.dy / w).clamp(0.0, 1.0);
    final lat = math.atan(_sinh(math.pi * (1 - 2 * y))) * 180 / math.pi;
    var lon = world.dx / w * 360 - 180;
    lon = (lon + 180) % 360 - 180;
    return LatLng(lat.clamp(-_maxLatitude, _maxLatitude), lon);
  }

  /// Screen vector (y down) to world vector, undoing the rotation.
  Offset _toWorld(Offset screen) {
    final b = bearing * math.pi / 180;
    final c = math.cos(b), s = math.sin(b);
    return Offset(screen.dx * c - screen.dy * s, screen.dx * s + screen.dy * c);
  }

  Offset _toScreen(Offset world) {
    final b = bearing * math.pi / 180;
    final c = math.cos(b), s = math.sin(b);
    return Offset(world.dx * c + world.dy * s, -world.dx * s + world.dy * c);
  }

  /// The place shown at [fromCenter] (logical pixels from the view centre).
  LatLng latLngAt(Offset fromCenter) =>
      unproject(project(center, zoom) + _toWorld(fromCenter), zoom);

  /// Where [p] is drawn, in logical pixels from the view centre.
  Offset screenOf(LatLng p) =>
      _toScreen(project(p, zoom) - project(center, zoom));

  MapCamera withCenter(LatLng c) => MapCamera(c, zoom, bearing);

  /// The map content follows a finger that moved by [delta].
  MapCamera panned(Offset delta) => MapCamera(latLngAt(-delta), zoom, bearing);

  /// Changes the zoom, keeping the place under [focal] where it is.
  MapCamera zoomedAround(Offset focal, double newZoom) {
    final z = newZoom.clamp(minZoom, maxZoom).toDouble();
    final anchor = latLngAt(focal);
    final moved = MapCamera(center, z, bearing);
    return MapCamera(
      unproject(project(anchor, z) - moved._toWorld(focal), z),
      z,
      bearing,
    );
  }

  /// Turns the map by [degrees] (positive: the content turns clockwise on
  /// screen, like two fingers turning clockwise), keeping [focal] in place.
  MapCamera rotatedAround(Offset focal, double degrees) {
    final anchor = latLngAt(focal);
    final turned = MapCamera(center, zoom, normalizeBearing(bearing - degrees));
    return MapCamera(
      unproject(project(anchor, zoom) - turned._toWorld(focal), zoom),
      zoom,
      turned.bearing,
    );
  }

  MapCamera withBearing(double b) => MapCamera(center, zoom, b);

  static double normalizeBearing(double b) {
    var r = b % 360;
    if (r > 180) r -= 360;
    if (r <= -180) r += 360;
    return r;
  }

  /// A north-up camera showing all of [points] inside a view of [size],
  /// leaving [padding] free. Null when there is nothing to show.
  static MapCamera? fit(
    List<LatLng> points,
    Size size,
    EdgeInsetsLike padding, {
    double maxZoom = 17,
  }) {
    if (points.isEmpty || size.isEmpty) return null;
    const z0 = 10.0;
    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final p in points) {
      final w = project(p, z0);
      minX = math.min(minX, w.dx);
      maxX = math.max(maxX, w.dx);
      minY = math.min(minY, w.dy);
      maxY = math.max(maxY, w.dy);
    }
    final freeW = math.max(size.width - padding.left - padding.right, 32.0);
    final freeH = math.max(size.height - padding.top - padding.bottom, 32.0);
    final spanX = math.max(maxX - minX, 1e-9),
        spanY = math.max(maxY - minY, 1e-9);
    final scale = math.min(freeW / spanX, freeH / spanY);
    final zoom = (z0 + math.log(scale) / math.ln2)
        .clamp(minZoom, maxZoom)
        .toDouble();
    final k = math.pow(2, zoom - z0).toDouble();
    // The bounds' centre goes to the centre of the free area, which is off
    // the view centre when the padding is asymmetric.
    final shift = Offset(
      (padding.left - padding.right) / 2,
      (padding.top - padding.bottom) / 2,
    );
    final mid = Offset((minX + maxX) / 2, (minY + maxY) / 2) * k;
    return MapCamera(unproject(mid - shift, zoom), zoom);
  }

  @override
  bool operator ==(Object other) =>
      other is MapCamera &&
      other.center == center &&
      other.zoom == zoom &&
      other.bearing == bearing;

  @override
  int get hashCode => Object.hash(center, zoom, bearing);

  @override
  String toString() =>
      'MapCamera(${center.latitude}, ${center.longitude}, z$zoom, $bearing°)';
}

/// The four insets [MapCamera.fit] needs (kept free of the widgets library so
/// the camera maths stays pure).
class EdgeInsetsLike {
  const EdgeInsetsLike(this.left, this.top, this.right, this.bottom);
  final double left, top, right, bottom;
}

double _sinh(double v) => (math.exp(v) - math.exp(-v)) / 2;

/// A closed ring approximating a circle of [radiusM] metres around [center]
/// on the ground, as `[lon, lat]` pairs (GeoJSON order).
List<List<double>> circleRing(LatLng center, double radiusM, {int steps = 48}) {
  const earth = 6378137.0;
  final lat = center.latitude * math.pi / 180;
  final dLat = radiusM / earth * 180 / math.pi;
  final dLon = dLat / math.max(math.cos(lat), 1e-6);
  return [
    for (var i = 0; i <= steps; i++)
      [
        center.longitude + dLon * math.cos(2 * math.pi * (i % steps) / steps),
        center.latitude + dLat * math.sin(2 * math.pi * (i % steps) / steps),
      ],
  ];
}
