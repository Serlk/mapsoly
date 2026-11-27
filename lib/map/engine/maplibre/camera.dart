import 'dart:math' as math;
import 'dart:ui';

import 'package:latlong2/latlong.dart';

/// Camera of the map view and the Web Mercator arithmetic around it.
///
/// [center] is the camera target: the place shown at the centre of the
/// visible part of the view (the view centre, moved by the camera padding).
/// Screen positions in this class are logical pixels *from that point*.
/// [zoom] follows the convention of the rest of the app (256 px tiles: the
/// world is `256 * 2^zoom` logical pixels wide); MapLibre counts 512 px tiles,
/// see [mapLibreZoom]. [bearing] is in degrees clockwise: the compass
/// direction that points up on the screen. [pitch] tilts the view (0 looks
/// straight down); the perspective then depends on [viewHeight], the height
/// of the whole view in logical pixels.
class MapCamera {
  const MapCamera(
    this.center,
    this.zoom, [
    this.bearing = 0,
    this.pitch = 0,
    this.viewHeight = 0,
  ]);

  final LatLng center;
  final double zoom;
  final double bearing;
  final double pitch;
  final double viewHeight;

  static const maxPitch = 60.0;

  /// MapLibre's vertical field of view, in radians.
  static const _fov = 0.6435011087932844;

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

  /// Distance from the eye to the camera target, in pixels.
  double get _eye => 0.5 * viewHeight / math.tan(_fov / 2);

  bool get _tilted => pitch > 0 && viewHeight > 0;

  /// Screen vector (y down) to world vector: undoes the perspective of a
  /// tilted view, then the rotation. Points at or above the horizon are
  /// taken as very far away.
  Offset _toWorld(Offset screen) {
    var x = screen.dx, y = screen.dy;
    if (_tilted) {
      final p = pitch * math.pi / 180;
      final d = _eye;
      final t = d / math.max(d + y * math.tan(p), d * 0.02);
      x = x * t;
      y = y * t / math.cos(p);
    }
    final b = bearing * math.pi / 180;
    final c = math.cos(b), s = math.sin(b);
    return Offset(x * c - y * s, x * s + y * c);
  }

  Offset _toScreen(Offset world) {
    final b = bearing * math.pi / 180;
    final c = math.cos(b), s = math.sin(b);
    var x = world.dx * c + world.dy * s, y = -world.dx * s + world.dy * c;
    if (_tilted) {
      final p = pitch * math.pi / 180;
      final d = _eye;
      // Behind the eye: clamp, it is far off screen anyway.
      final depth = math.max(d - y * math.sin(p), d * 0.02);
      x = x * d / depth;
      y = y * math.cos(p) * d / depth;
    }
    return Offset(x, y);
  }

  /// The place shown at [fromCenter] (logical pixels from the view centre).
  LatLng latLngAt(Offset fromCenter) =>
      unproject(project(center, zoom) + _toWorld(fromCenter), zoom);

  /// Where [p] is drawn, in logical pixels from the view centre.
  Offset screenOf(LatLng p) =>
      _toScreen(project(p, zoom) - project(center, zoom));

  MapCamera copyWith({
    LatLng? center,
    double? zoom,
    double? bearing,
    double? pitch,
    double? viewHeight,
  }) => MapCamera(
    center ?? this.center,
    zoom ?? this.zoom,
    bearing ?? this.bearing,
    pitch ?? this.pitch,
    viewHeight ?? this.viewHeight,
  );

  MapCamera withCenter(LatLng c) => copyWith(center: c);

  /// Shifts the view so that what was at the target is now [delta] away
  /// from it (exact for a flat view; use [dragged] to follow a finger).
  MapCamera panned(Offset delta) => copyWith(center: latLngAt(-delta));

  /// The place that was under a finger at [from] is under it at [to].
  MapCamera dragged(Offset from, Offset to) {
    final anchor = latLngAt(from);
    return copyWith(
      center: unproject(project(anchor, zoom) - _toWorld(to), zoom),
    );
  }

  MapCamera withPitch(double p) =>
      copyWith(pitch: p.clamp(0.0, maxPitch).toDouble());

  /// Changes the zoom, keeping the place under [focal] where it is.
  MapCamera zoomedAround(Offset focal, double newZoom) {
    final z = newZoom.clamp(minZoom, maxZoom).toDouble();
    final anchor = latLngAt(focal);
    final moved = copyWith(zoom: z);
    return moved.copyWith(
      center: unproject(project(anchor, z) - moved._toWorld(focal), z),
    );
  }

  /// Turns the map by [degrees] (positive: the content turns clockwise on
  /// screen, like two fingers turning clockwise), keeping [focal] in place.
  MapCamera rotatedAround(Offset focal, double degrees) {
    final anchor = latLngAt(focal);
    final turned = copyWith(bearing: normalizeBearing(bearing - degrees));
    return turned.copyWith(
      center: unproject(project(anchor, zoom) - turned._toWorld(focal), zoom),
    );
  }

  MapCamera withBearing(double b) => copyWith(bearing: normalizeBearing(b));

  /// Degrees to turn from bearing [from] to [to] the short way round
  /// (-180..180).
  static double bearingDelta(double from, double to) =>
      normalizeBearing(to - from);

  static double normalizeBearing(double b) {
    var r = b % 360;
    if (r > 180) r -= 360;
    if (r <= -180) r += 360;
    return r;
  }

  /// A north-up, untilted camera showing all of [points] inside a view of
  /// [size], leaving [padding] free in addition to [cameraPadding] (the
  /// insets the camera target is already centred in). Null when there is
  /// nothing to show.
  static MapCamera? fit(
    List<LatLng> points,
    Size size,
    EdgeInsetsLike padding, {
    EdgeInsetsLike cameraPadding = const EdgeInsetsLike(0, 0, 0, 0),
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
    final freeW = math.max(
      size.width -
          padding.left -
          padding.right -
          cameraPadding.left -
          cameraPadding.right,
      32.0,
    );
    final freeH = math.max(
      size.height -
          padding.top -
          padding.bottom -
          cameraPadding.top -
          cameraPadding.bottom,
      32.0,
    );
    final spanX = math.max(maxX - minX, 1e-9),
        spanY = math.max(maxY - minY, 1e-9);
    final scale = math.min(freeW / spanX, freeH / spanY);
    final zoom = (z0 + math.log(scale) / math.ln2)
        .clamp(minZoom, maxZoom)
        .toDouble();
    final k = math.pow(2, zoom - z0).toDouble();
    // The bounds' centre goes to the centre of the free area, which is off
    // the camera target when [padding] is asymmetric.
    final shift = Offset(
      (padding.left - padding.right) / 2,
      (padding.top - padding.bottom) / 2,
    );
    final mid = Offset((minX + maxX) / 2, (minY + maxY) / 2) * k;
    return MapCamera(unproject(mid - shift, zoom), zoom, 0, 0, size.height);
  }

  @override
  bool operator ==(Object other) =>
      other is MapCamera &&
      other.center == center &&
      other.zoom == zoom &&
      other.bearing == bearing &&
      other.pitch == pitch &&
      other.viewHeight == viewHeight;

  @override
  int get hashCode => Object.hash(center, zoom, bearing, pitch, viewHeight);

  @override
  String toString() =>
      'MapCamera(${center.latitude}, ${center.longitude}, z$zoom, '
      '$bearing°, pitch $pitch)';
}

/// A camera move from [from] to [to], as the native map animates it: used
/// to know what is on screen at any moment of the animation.
class CameraTween {
  const CameraTween(this.from, this.to, {required this.linear});

  final MapCamera from, to;

  /// Constant speed (a stream of position updates blends into one motion)
  /// instead of MapLibre's default ease-out curve.
  final bool linear;

  /// MapLibre's default easing, cubic-bezier(0, 0, 0.25, 1).
  static double ease(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    // x(s) = 0.75 s^2 (1 - s) + s^3 with control points x1 = 0, x2 = 0.25.
    double x(double s) => 3 * 0.25 * s * s * (1 - s) + s * s * s;
    var lo = 0.0, hi = 1.0;
    for (var i = 0; i < 30; i++) {
      final mid = (lo + hi) / 2;
      if (x(mid) < t) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final s = (lo + hi) / 2;
    // y(s) with control points y1 = 0, y2 = 1.
    return 3 * s * s * (1 - s) + s * s * s;
  }

  /// The camera after the fraction [t] (0..1) of the duration.
  MapCamera at(double t) {
    if (t <= 0) return from;
    if (t >= 1) return to;
    final f = linear ? t : ease(t);
    final a = MapCamera.project(from.center, 0);
    var b = MapCamera.project(to.center, 0);
    // Across the antimeridian the short way.
    if ((b.dx - a.dx).abs() > 128) {
      b = Offset(b.dx + (b.dx < a.dx ? 256 : -256), b.dy);
    }
    return MapCamera(
      MapCamera.unproject(Offset.lerp(a, b, f)!, 0),
      from.zoom + (to.zoom - from.zoom) * f,
      MapCamera.normalizeBearing(
        from.bearing + MapCamera.bearingDelta(from.bearing, to.bearing) * f,
      ),
      from.pitch + (to.pitch - from.pitch) * f,
      to.viewHeight,
    );
  }
}

/// The four insets [MapCamera.fit] needs (kept free of the widgets library so
/// the camera maths stays pure).
class EdgeInsetsLike {
  const EdgeInsetsLike(this.left, this.top, this.right, this.bottom);
  final double left, top, right, bottom;

  /// Where the centre of the area inside these insets lies, from the centre
  /// of the whole view.
  Offset get centreOffset => Offset((left - right) / 2, (top - bottom) / 2);

  /// The larger inset on each side.
  EdgeInsetsLike max(EdgeInsetsLike o) => EdgeInsetsLike(
    math.max(left, o.left),
    math.max(top, o.top),
    math.max(right, o.right),
    math.max(bottom, o.bottom),
  );

  @override
  bool operator ==(Object other) =>
      other is EdgeInsetsLike &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
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
