import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../offline/pmtiles.dart';
import '../../../traffic/traffic.dart';
import '../../../traffic/yandex_tile_provider.dart';

/// A tile request understood by [MapTileServer].
@immutable
class TileRequest {
  const TileRequest(this.kind, this.version, this.z, this.x, this.y);

  /// `osm`, `google`, `yandex` or `packs`.
  final String kind;

  /// Data version of a traffic layer, id of a pack set; empty for `osm`.
  final String version;
  final int z, x, y;

  /// Parses `/osm/{z}/{x}/{y}.png`, `/{google|yandex}/{version}/{z}/{x}/{y}.png`
  /// and `/packs/{set}/{z}/{x}/{y}.pbf`.
  /// Null for anything else, including coordinates outside the tile pyramid.
  static TileRequest? parse(String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    final kind = parts.first;
    final String version;
    if (kind == 'osm' && parts.length == 4) {
      version = '';
    } else if ((kind == 'google' || kind == 'yandex' || kind == 'packs') &&
        parts.length == 5) {
      version = parts[1];
      if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(version)) {
        return null;
      }
    } else {
      return null;
    }
    final last = parts.last;
    if (!last.endsWith(kind == 'packs' ? '.pbf' : '.png')) return null;
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
///   /packs/{set}/{z}/{x}/{y}.pbf         vector tile from whichever installed pack has it
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

  final Map<String, List<PmTilesArchive>> _packSets = {};

  /// Serves [archives] as one tile set named [id]; returns its URL template.
  String servePacks(String id, List<PmTilesArchive> archives) {
    _packSets[id] = List.of(archives);
    return 'http://127.0.0.1:${_server.port}/packs/$id/{z}/{x}/{y}.pbf';
  }

  void dropPacks(String id) => _packSets.remove(id);

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
      if (tile.kind == 'packs') {
        final hit = tileFromPacks(
          _packSets[tile.version] ?? const [],
          tile.z,
          tile.x,
          tile.y,
        );
        if (hit == null) {
          response.statusCode = HttpStatus.noContent;
          return;
        }
        response.headers
          ..contentType = ContentType('application', 'x-protobuf')
          ..set(HttpHeaders.cacheControlHeader, 'max-age=86400');
        // Stored bytes go out as they are: the client inflates them.
        if (hit.gzipped) {
          response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
        }
        response.add(hit.bytes);
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

/// The tile from the first of [archives] that has it, as stored there.
/// Packs cut from one tileset hold identical tiles along their borders, so
/// which one answers does not matter.
({Uint8List bytes, bool gzipped})? tileFromPacks(
  List<PmTilesArchive> archives,
  int z,
  int x,
  int y,
) {
  for (final archive in archives) {
    final bytes = archive.storedTile(z, x, y);
    if (bytes != null) return (bytes: bytes, gzipped: archive.tilesGzipped);
  }
  return null;
}

/// Zoom range covered by a set of packs.
({int min, int max}) zoomRangeOfPacks(List<PmTilesArchive> archives) {
  var min = archives.first.minZoom, max = archives.first.maxZoom;
  for (final a in archives.skip(1)) {
    if (a.minZoom < min) min = a.minZoom;
    if (a.maxZoom > max) max = a.maxZoom;
  }
  return (min: min, max: max);
}
