import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_tile/vector_tile.dart';
import 'package:mapsoly/offline/pmtiles.dart';

void main() {
  test('tile ids follow the Hilbert order from the PMTiles spec', () {
    expect(PmTilesArchive.tileId(0, 0, 0), 0);
    expect(PmTilesArchive.tileId(1, 0, 0), 1);
    expect(PmTilesArchive.tileId(1, 0, 1), 2);
    expect(PmTilesArchive.tileId(1, 1, 1), 3);
    expect(PmTilesArchive.tileId(1, 1, 0), 4);
    expect(PmTilesArchive.tileId(2, 0, 0), 5);
    expect(PmTilesArchive.tileId(12, 3423, 1763), 19078479);
  });

  // Built by tilemaker from the Geofabrik Monaco extract
  // (© OpenStreetMap contributors, ODbL).
  group('real archive', () {
    late PmTilesArchive archive;
    setUp(() => archive = PmTilesArchive.open('test/fixtures/monaco.pmtiles'));
    tearDown(() => archive.close());

    test('header describes Monaco', () {
      expect(archive.minZoom, 0);
      expect(archive.maxZoom, 14);
      final b = archive.bounds;
      expect(b[0], lessThan(7.42));
      expect(b[2], greaterThan(7.42));
      expect(b[1], lessThan(43.73));
      expect(b[3], greaterThan(43.73));
    });

    test('a city-centre tile decodes as a vector tile with roads', () {
      const z = 14, lon = 7.42, lat = 43.735;
      final n = 1 << z;
      final x = ((lon + 180) / 360 * n).floor();
      final r = lat * math.pi / 180;
      final y =
          ((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * n)
              .floor();
      final bytes = archive.tile(z, x, y);
      expect(bytes, isNotNull);
      final layers = VectorTile.fromBytes(bytes: bytes!).layers;
      expect(layers.map((l) => l.name), contains('transportation'));
    });

    test('tiles outside the archive are absent', () {
      expect(archive.tile(14, 0, 0), isNull);
      expect(archive.tile(15, 0, 0), isNull);
    });
  });
}
