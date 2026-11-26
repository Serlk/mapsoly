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

@immutable
class _YandexTile extends ImageProvider<_YandexTile> {
  const _YandexTile(this.x, this.y, this.z, this.version, this.client);

  static const _out = 512.0;

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

  Future<ui.Image?> _fetch(int row) async {
    final uri = Uri.parse(
      'https://core-jams-rdr-cache.maps.yandex.net/1.1/tiles'
      '?trf&l=trf&lang=ru_RU&x=$x&y=$row&z=$z&scale=2&tm=$version',
    );
    // A failed or missing tile leaves a transparent gap; the next version
    // refresh retries it.
    try {
      final r = await client
          .get(uri, headers: trafficHeaders)
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
      final codec = await ui.instantiateImageCodec(r.bodyBytes);
      return (await codec.getNextFrame()).image;
    } on Exception {
      return null;
    }
  }

  Future<ImageInfo> _compose() async {
    final top = ellipticalRow(y.toDouble(), z);
    final bottom = ellipticalRow(y + 1.0, z);
    final firstRow = top.floor();
    final lastRow = (bottom - 1e-9).floor();
    final rows = [for (var r = firstRow; r <= lastRow; r++) r];
    final images = await Future.wait(rows.map(_fetch));

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()..filterQuality = FilterQuality.medium;
    for (var i = 0; i < rows.length; i++) {
      final img = images[i];
      if (img == null) continue;
      final from = math.max(top, rows[i].toDouble());
      final to = math.min(bottom, rows[i] + 1.0);
      canvas.drawImageRect(
        img,
        Rect.fromLTRB(
          0,
          (from - rows[i]) * img.height,
          img.width.toDouble(),
          (to - rows[i]) * img.height,
        ),
        Rect.fromLTRB(
          0,
          (from - top) / (bottom - top) * _out,
          _out,
          (to - top) / (bottom - top) * _out,
        ),
        paint,
      );
      img.dispose();
    }
    final image = await recorder.endRecording().toImage(
      _out.toInt(),
      _out.toInt(),
    );
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
