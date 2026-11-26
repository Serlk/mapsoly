import 'dart:math' as math;
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

import 'yandex_tile_provider.dart' show ellipticalRowOfLatitude;

/// How congested a stretch of road is, read from the colour of the traffic
/// layer.
enum Congestion { unknown, free, slow, heavy, jam }

/// Speed relative to free flow assumed for each colour.
///
/// The traffic layer shows colours, not speeds, so these are rough factors
/// (assumptions, not measurements) and the resulting times are estimates.
const congestionSpeedFactor = {
  Congestion.unknown: 1.0,
  Congestion.free: 1.0,
  Congestion.slow: 0.55,
  Congestion.heavy: 0.3,
  Congestion.jam: 0.12,
};

/// Decoded traffic tile: square RGBA pixels, row by row.
class TrafficTile {
  TrafficTile(this.size, this.rgba);

  final int size;
  final ByteData rgba;

  Congestion at(int x, int y) {
    if (x < 0 || y < 0 || x >= size || y >= size) return Congestion.unknown;
    final o = (y * size + x) * 4;
    return classifyTrafficColor(
      rgba.getUint8(o),
      rgba.getUint8(o + 1),
      rgba.getUint8(o + 2),
      rgba.getUint8(o + 3),
    );
  }
}

/// Maps a traffic-layer pixel to a congestion level by hue.
Congestion classifyTrafficColor(int r, int g, int b, int a) {
  if (a < 128) return Congestion.unknown;
  final maxC = math.max(r, math.max(g, b)), minC = math.min(r, math.min(g, b));
  final delta = maxC - minC;
  // Greys and whites are outlines and closed roads, not a traffic level.
  if (delta < 40) return Congestion.unknown;
  double hue;
  if (maxC == r) {
    hue = 60 * (((g - b) / delta) % 6);
  } else if (maxC == g) {
    hue = 60 * ((b - r) / delta + 2);
  } else {
    hue = 60 * ((r - g) / delta + 4);
  }
  if (hue < 0) hue += 360;
  if (hue >= 70 && hue <= 170) return Congestion.free;
  if (hue >= 25 && hue < 70) return Congestion.slow;
  if (hue < 25 || hue >= 330) {
    return maxC < 150 ? Congestion.jam : Congestion.heavy;
  }
  return Congestion.unknown;
}

/// Loads the Yandex traffic tile at EPSG:3395 tile coordinates, or null.
typedef TrafficTileLoader = Future<TrafficTile?> Function(int x, int y, int z);

/// A road stretch whose travel time is to be re-estimated: indexes into the
/// route shape and the time it takes without traffic.
class TrafficSegment {
  const TrafficSegment(this.beginIndex, this.endIndex, this.freeFlowSeconds);

  final int beginIndex, endIndex;
  final double freeFlowSeconds;
}

class TrafficEstimate {
  const TrafficEstimate(this.seconds, this.coverage);

  /// Travel time over the given segments with traffic.
  final double seconds;

  /// Share (0..1) of sampled points where the layer showed a traffic colour.
  final double coverage;
}

/// Re-estimates travel time by reading traffic colours along a route.
class TrafficSampler {
  TrafficSampler(this.loader, {this.zoom = 15, this.stepMeters = 60});

  final TrafficTileLoader loader;
  final int zoom;
  final double stepMeters;
  final _tiles = <(int, int), Future<TrafficTile?>>{};
  static const _distance = Distance();

  /// Pixel offsets to the right of travel tried in order: the layer draws
  /// each direction on its own side of the road (right-hand traffic).
  static const _rightOffsets = [2.0, 3.0, 1.0, 4.0, 0.0];

  Future<Congestion> _sample(LatLng p, double bearingRad) async {
    final n = (1 << zoom).toDouble();
    final px = (p.longitude + 180) / 360 * n * 256;
    final py = ellipticalRowOfLatitude(p.latitude, zoom) * 256;
    // Unit vector to the right of travel in pixel space (y grows south).
    final rx = math.cos(bearingRad), ry = math.sin(bearingRad);
    for (final k in _rightOffsets) {
      final x = px + rx * k, y = py + ry * k;
      final tx = (x / 256).floor(), ty = (y / 256).floor();
      final tile = await (_tiles[(tx, ty)] ??= loader(tx, ty, zoom));
      if (tile == null) continue;
      final scale = tile.size / 256;
      final c = tile.at(
        ((x - tx * 256) * scale).floor(),
        ((y - ty * 256) * scale).floor(),
      );
      if (c != Congestion.unknown) return c;
    }
    return Congestion.unknown;
  }

  Future<TrafficEstimate> estimate(
    List<LatLng> shape,
    Iterable<TrafficSegment> segments,
  ) async {
    var seconds = 0.0;
    var samples = 0, known = 0;
    for (final s in segments) {
      final end = math.min(s.endIndex, shape.length - 1);
      // Mean slowdown over the points sampled along this segment.
      var slowdown = 0.0;
      var count = 0;
      var carried = stepMeters / 2;
      for (var i = s.beginIndex; i < end; i++) {
        final a = shape[i], b = shape[i + 1];
        final length = _distance.as(LengthUnit.Meter, a, b);
        if (length <= 0) continue;
        final bearing = _distance.bearing(a, b) * math.pi / 180;
        while (carried <= length) {
          final t = carried / length;
          final p = LatLng(
            a.latitude + (b.latitude - a.latitude) * t,
            a.longitude + (b.longitude - a.longitude) * t,
          );
          final c = await _sample(p, bearing);
          slowdown += 1 / congestionSpeedFactor[c]!;
          count++;
          samples++;
          if (c != Congestion.unknown) known++;
          carried += stepMeters;
        }
        carried -= length;
      }
      seconds += s.freeFlowSeconds * (count == 0 ? 1 : slowdown / count);
    }
    return TrafficEstimate(seconds, samples == 0 ? 0 : known / samples);
  }
}
