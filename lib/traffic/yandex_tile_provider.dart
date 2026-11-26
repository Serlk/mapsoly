import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;

import 'traffic.dart';

/// Yandex serves tiles in elliptical Mercator (EPSG:3395) while the map uses
/// spherical Mercator (EPSG:3857). Columns match; rows are shifted and
/// slightly stretched, so each map tile is recomposed from the one or two
/// Yandex tiles that cover its latitude span.
class YandexTrafficTileProvider extends TileProvider {
  YandexTrafficTileProvider({required this.client, required this.version});

  final http.Client client;
  final String version;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      _YandexTile(coordinates.x, coordinates.y, coordinates.z, version, client);
}

const _e = 0.0818191908426215; // WGS84 eccentricity

/// Row position (in 256px tile units at [z]) in EPSG:3395 of the latitude
/// found at row position [y] in EPSG:3857.
double ellipticalRow(double y, int z) {
  final n = (1 << z).toDouble();
  final lat = math.atan(_sinh(math.pi * (1 - 2 * y / n)));
  return ellipticalRowOfLatitude(lat * 180 / math.pi, z);
}

/// Row position (in 256px tile units at [z]) of [latitude] in EPSG:3395,
/// the projection Yandex tiles use.
double ellipticalRowOfLatitude(double latitude, int z) {
  final n = (1 << z).toDouble();
  final lat = latitude * math.pi / 180;
  final s = _e * math.sin(lat);
  final merc = math.log(
    math.tan(math.pi / 4 + lat / 2) * math.pow((1 - s) / (1 + s), _e / 2),
  );
  return n / 2 * (1 - merc / math.pi);
}

double _sinh(double v) => (math.exp(v) - math.exp(-v)) / 2;

/// Where Yandex serves the traffic tile ([x], [row], [z]) of data [version];
/// [scale] 2 gives 512 px tiles.
Uri yandexTrafficTileUri(
  int x,
  int row,
  int z,
  String version, {
  int scale = 2,
}) => Uri.parse(
  'https://core-jams-rdr-cache.maps.yandex.net/1.1/tiles'
  '?trf&l=trf&lang=ru_RU&x=$x&y=$row&z=$z&scale=$scale&tm=$version',
);

/// One strip of a Yandex tile row placed into a spherical-Mercator tile:
/// the fractions [srcTop]..[srcBottom] of the Yandex tile in [row] go to the
/// fractions [dstTop]..[dstBottom] of the map tile.
@immutable
class YandexStrip {
  const YandexStrip(
    this.row,
    this.srcTop,
    this.srcBottom,
    this.dstTop,
    this.dstBottom,
  );
  final int row;
  final double srcTop, srcBottom, dstTop, dstBottom;
}

/// The Yandex rows that cover the map tile row [y] at zoom [z], and how each
/// is cut and stretched.
List<YandexStrip> yandexStrips(int y, int z) {
  final top = ellipticalRow(y.toDouble(), z);
  final bottom = ellipticalRow(y + 1.0, z);
  final firstRow = top.floor();
  final lastRow = (bottom - 1e-9).floor();
  return [
    for (var r = firstRow; r <= lastRow; r++)
      YandexStrip(
        r,
        math.max(top, r.toDouble()) - r,
        math.min(bottom, r + 1.0) - r,
        (math.max(top, r.toDouble()) - top) / (bottom - top),
        (math.min(bottom, r + 1.0) - top) / (bottom - top),
      ),
  ];
}

/// Builds the spherical-Mercator traffic tile ([x], [y], [z]) of [size]
/// pixels from the one or two Yandex tiles covering it. A failed or missing
/// Yandex tile leaves a transparent gap; null when nothing could be loaded.
Future<ui.Image?> composeYandexTrafficTile(
  http.Client client,
  String version,
  int x,
  int y,
  int z, {
  int size = 512,
}) async {
  Future<ui.Image?> fetch(int row) async {
    try {
      final r = await client
          .get(
            yandexTrafficTileUri(x, row, z, version),
            headers: trafficHeaders,
          )
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
      final codec = await ui.instantiateImageCodec(r.bodyBytes);
      return (await codec.getNextFrame()).image;
    } on Exception {
      return null;
    }
  }

  final strips = yandexStrips(y, z);
  final images = await Future.wait(strips.map((s) => fetch(s.row)));
  if (images.every((i) => i == null)) return null;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final paint = Paint()..filterQuality = FilterQuality.medium;
  final out = size.toDouble();
  for (var i = 0; i < strips.length; i++) {
    final img = images[i];
    if (img == null) continue;
    final s = strips[i];
    canvas.drawImageRect(
      img,
      Rect.fromLTRB(
        0,
        s.srcTop * img.height,
        img.width.toDouble(),
        s.srcBottom * img.height,
      ),
      Rect.fromLTRB(0, s.dstTop * out, out, s.dstBottom * out),
      paint,
    );
    img.dispose();
  }
  return recorder.endRecording().toImage(size, size);
}

Future<ui.Image> _transparentTile() {
  final recorder = ui.PictureRecorder();
  Canvas(recorder);
  return recorder.endRecording().toImage(512, 512);
}

@immutable
class _YandexTile extends ImageProvider<_YandexTile> {
  const _YandexTile(this.x, this.y, this.z, this.version, this.client);

  final int x, y, z;
  final String version;
  final http.Client client;

  @override
  Future<_YandexTile> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _YandexTile key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(_compose());

  Future<ImageInfo> _compose() async {
    final image =
        await composeYandexTrafficTile(client, version, x, y, z) ??
        // Nothing loaded: a fully transparent tile, as before.
        await _transparentTile();
    return ImageInfo(image: image);
  }

  @override
  bool operator ==(Object other) =>
      other is _YandexTile &&
      other.x == x &&
      other.y == y &&
      other.z == z &&
      other.version == version;

  @override
  int get hashCode => Object.hash(x, y, z, version);
}
