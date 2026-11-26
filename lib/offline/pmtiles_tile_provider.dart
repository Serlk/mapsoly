import 'dart:typed_data';

import 'package:vector_map_tiles/vector_map_tiles.dart';

import 'pmtiles.dart';

/// Serves vector tiles to the map straight from a local PMTiles archive.
class PmTilesVectorTileProvider extends VectorTileProvider {
  PmTilesVectorTileProvider(this.archive);

  final PmTilesArchive archive;

  @override
  int get maximumZoom => archive.maxZoom;

  @override
  int get minimumZoom => archive.minZoom;

  @override
  TileOffset get tileOffset => TileOffset.DEFAULT;

  @override
  Future<Uint8List> provide(TileIdentity tile) async {
    final data = archive.tile(tile.z, tile.x, tile.y);
    if (data == null) {
      throw ProviderException(
        message: 'No tile ${tile.z}/${tile.x}/${tile.y} in the offline map',
        statusCode: 404,
        retryable: Retryable.none,
      );
    }
    return data;
  }
}
