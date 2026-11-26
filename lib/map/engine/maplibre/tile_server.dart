import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../traffic/traffic.dart';
import '../../../traffic/yandex_tile_provider.dart';

/// A tile request understood by [MapTileServer].
@immutable
class TileRequest {
  const TileRequest(this.kind, this.version, this.z, this.x, this.y);

  /// `osm`, `google` or `yandex`.
  final String kind;

  /// Data version of a traffic layer; empty for `osm`.
  final String version;
  final int z, x, y;

  /// Parses `/osm/{z}/{x}/{y}.png` and `/{google|yandex}/{version}/{z}/{x}/{y}.png`.
  /// Null for anything else, including coordinates outside the tile pyramid.
  static TileRequest? parse(String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    final kind = parts.first;
    final String version;
    if (kind == 'osm' && parts.length == 4) {
      version = '';
    } else if ((kind == 'google' || kind == 'yandex') && parts.length == 5) {
      version = parts[1];
      if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(version)) {
        return null;
      }
    } else {
      return null;
    }
    final last = parts.last;
    if (!last.endsWith('.png')) return null;
    final z = int.tryParse(parts[parts.length - 3]);
    final x = int.tryParse(parts[parts.length - 2]);
    final y = int.tryParse(last.substring(0, last.length - 4));
    if (z == null || x == null || y == null) return null;
    if (z < 0 || z > 22) return null;
    final n = 1 << z;
    if (x < 0 || x >= n || y < 0 || y >= n) return null;
    return TileRequest(kind, version, z, x, y);
  }

  /// Where the tile comes from, for the kinds that are plain proxies.
  Uri? get upstream => switch (kind) {
    'osm' => Uri.parse('https://tile.openstreetmap.org/$z/$x/$y.png'),
    'google' => Uri.parse(
      'https://mt${(x + y) % 4}.google.com/vt?lyrs=h@159000000,traffic'
      '%7Cseconds_into_week:-1&style=3&x=$x&y=$y&z=$z&_=$version',
    ),
    _ => null,
  };

  Map<String, String> get upstreamHeaders => kind == 'osm'
      ? const {'User-Agent': 'flutter_map (dev.mapsoly.mapsoly)'}
      : trafficHeaders;
}

/// Loopback HTTP server that feeds MapLibre the raster tiles it cannot fetch
/// itself: MapLibre Native sends a fixed User-Agent the traffic services
/// reject, and Yandex traffic tiles are in another projection (EPSG:3395)
/// and have to be recomposed per tile.
///
///   /osm/{z}/{x}/{y}.png                 OpenStreetMap raster tiles (no pack installed)
///   /google/{version}/{z}/{x}/{y}.png    Google traffic, proxied with browser headers
///   /yandex/{version}/{z}/{x}/{y}.png    Yandex traffic, reprojected to EPSG:3857
class MapTileServer {
  MapTileServer._(this._server);

  static Future<MapTileServer>? _shared;

  /// The one server of the process, started on first use.
  static Future<MapTileServer> shared() => _shared ??= _start();

  static Future<MapTileServer> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final s = MapTileServer._(server);
    server.listen(s._handle);
    return s;
  }

  final HttpServer _server;
  final http.Client _own = http.Client();

  /// Client of the traffic controller (shares its connections); set by the
  /// map engine whenever a traffic overlay is shown.
  http.Client? trafficClient;

  String urlTemplate(String kind, [String version = '']) =>
      'http://127.0.0.1:${_server.port}/$kind/'
      '${version.isEmpty ? '' : '$version/'}{z}/{x}/{y}.png';

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final tile = TileRequest.parse(request.uri.path);
      if (tile == null) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final bytes = await _load(tile);
      if (bytes == null) {
        // "No tile here": MapLibre draws nothing and does not retry at once.
        response.statusCode = HttpStatus.noContent;
        return;
      }
      response.headers
        ..contentType = ContentType('image', 'png')
        ..set(HttpHeaders.cacheControlHeader, 'max-age=600');
      response.add(bytes);
    } on Exception {
      response.statusCode = HttpStatus.noContent;
    } finally {
      await response.close();
    }
  }

  Future<List<int>?> _load(TileRequest tile) async {
    final client = tile.kind == 'osm' ? _own : (trafficClient ?? _own);
    final upstream = tile.upstream;
    if (upstream != null) {
      final r = await client
          .get(upstream, headers: tile.upstreamHeaders)
          .timeout(const Duration(seconds: 15));
      return r.statusCode == 200 && r.bodyBytes.isNotEmpty ? r.bodyBytes : null;
    }
    final image = await composeYandexTrafficTile(
      client,
      tile.version,
      tile.x,
      tile.y,
      tile.z,
    );
    if (image == null) return null;
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return png?.buffer.asUint8List();
  }
}
