import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/offline/pmtiles.dart';
import 'package:mapsoly/map/engine/maplibre/tile_server.dart';
import 'package:mapsoly/traffic/traffic.dart';
import 'package:mapsoly/traffic/yandex_tile_provider.dart';

void main() {
  group('TileRequest.parse', () {
    test('osm', () {
      final t = TileRequest.parse('/osm/12/2476/1280.png')!;
      expect((t.kind, t.version, t.z, t.x, t.y), ('osm', '', 12, 2476, 1280));
      expect(
        t.upstream.toString(),
        'https://tile.openstreetmap.org/12/2476/1280.png',
      );
      expect(t.upstreamHeaders['User-Agent'], contains('dev.mapsoly.mapsoly'));
    });

    test('google keeps the query the Flutter engine used', () {
      final t = TileRequest.parse('/google/19283746/14/9905/5121.png')!;
      expect(
        (t.kind, t.version, t.z, t.x, t.y),
        ('google', '19283746', 14, 9905, 5121),
      );
      final u = t.upstream!;
      expect(u.host, 'mt${(9905 + 5121) % 4}.google.com');
      expect(
        u.toString(),
        contains('lyrs=h@159000000,traffic%7Cseconds_into_week:-1'),
      );
      expect(u.queryParameters['x'], '9905');
      expect(u.queryParameters['y'], '5121');
      expect(u.queryParameters['z'], '14');
      expect(u.queryParameters['_'], '19283746');
      // The traffic services reject non-browser clients.
      expect(t.upstreamHeaders, trafficHeaders);
    });

    test('yandex is composed, not proxied', () {
      final t = TileRequest.parse('/yandex/1764200000/11/1237/640.png')!;
      expect(
        (t.kind, t.version, t.z, t.x, t.y),
        ('yandex', '1764200000', 11, 1237, 640),
      );
      expect(t.upstream, isNull);
    });

    test('packs: vector tiles of a pack set', () {
      final t = TileRequest.parse('/packs/set3/14/9905/5121.pbf')!;
      expect(
        (t.kind, t.version, t.z, t.x, t.y),
        ('packs', 'set3', 14, 9905, 5121),
      );
      expect(t.upstream, isNull);
      expect(TileRequest.parse('/packs/set3/14/9905/5121.png'), isNull);
      expect(TileRequest.parse('/osm/1/0/0.pbf'), isNull);
    });

    test('rejects everything else', () {
      for (final p in [
        '/',
        '/osm/12/2476/1280',
        '/osm/12/2476/1280.jpg',
        '/osm/1/2/0.png', // x outside the pyramid
        '/osm/3/0/8.png',
        '/osm/-1/0/0.png',
        '/osm/30/0/0.png',
        '/google/14/9905/5121.png', // no version
        '/yandex/a b/11/1/1.png',
        '/yandex/../11/1/1.png',
        '/yandex/v/x/1/1.png',
        '/other/1/0/0.png',
        '/osm/1/0/0.png/extra',
      ]) {
        expect(TileRequest.parse(p), isNull, reason: p);
      }
    });
  });

  group('several packs as one tile set', () {
    // Monaco is at tile 8529/5974 (z14): the fixture has it, nothing near Moscow.
    late PmTilesArchive monaco, again;
    setUp(() {
      monaco = PmTilesArchive.open('test/fixtures/monaco.pmtiles');
      again = PmTilesArchive.open('test/fixtures/monaco.pmtiles');
    });
    tearDown(() {
      monaco.close();
      again.close();
    });

    test('a tile comes from the first pack that has it, as stored', () {
      final hit = tileFromPacks([monaco, again], 14, 8529, 5974)!;
      expect(hit.gzipped, monaco.tilesGzipped);
      final plain = hit.gzipped ? gzip.decode(hit.bytes) : hit.bytes;
      expect(plain, monaco.tile(14, 8529, 5974));
      expect(hit.bytes, monaco.storedTile(14, 8529, 5974));
    });

    test('no pack has the tile', () {
      expect(tileFromPacks([monaco, again], 14, 9905, 5121), isNull);
      expect(tileFromPacks(const [], 14, 8529, 5974), isNull);
      expect(
        tileFromPacks([monaco], 15, 17058, 11948),
        isNull,
      ); // above maxZoom
    });

    test('zoom range is the union', () {
      expect(zoomRangeOfPacks([monaco, again]), (
        min: monaco.minZoom,
        max: monaco.maxZoom,
      ));
    });
  });

  group('yandexStrips', () {
    test('cover the whole tile without gaps or overlap', () {
      for (final (y, z) in [
        (640, 11),
        (5121, 14),
        (20, 6),
        (0, 3),
        (160000, 19),
      ]) {
        final strips = yandexStrips(y, z);
        expect(strips.length, inInclusiveRange(1, 2), reason: '$y/$z');
        expect(strips.first.dstTop, closeTo(0, 1e-9));
        expect(strips.last.dstBottom, closeTo(1, 1e-9));
        for (var i = 1; i < strips.length; i++) {
          expect(strips[i].dstTop, closeTo(strips[i - 1].dstBottom, 1e-9));
          expect(strips[i].row, strips[i - 1].row + 1);
          expect(strips[i - 1].srcBottom, closeTo(1, 1e-9));
          expect(strips[i].srcTop, closeTo(0, 1e-9));
        }
        for (final s in strips) {
          expect(s.srcTop, inInclusiveRange(0, 1));
          expect(s.srcBottom, inInclusiveRange(s.srcTop, 1));
        }
      }
    });

    test('match the projection maths', () {
      // In Moscow a latitude sits a few rows further down in the elliptical
      // projection than in the spherical one.
      const y = 5121, z = 14;
      final top = ellipticalRow(y.toDouble(), z);
      final s = yandexStrips(y, z).first;
      expect(s.row, top.floor());
      expect(s.srcTop, closeTo(top - top.floor(), 1e-9));
      expect(top, greaterThan(y.toDouble()));
      expect(top, lessThan(y + 40));
    });

    test('tile URL', () {
      final u = yandexTrafficTileUri(1237, 638, 11, '1764200000');
      expect(u.host, 'core-jams-rdr-cache.maps.yandex.net');
      expect(u.queryParameters['x'], '1237');
      expect(u.queryParameters['y'], '638');
      expect(u.queryParameters['z'], '11');
      expect(u.queryParameters['scale'], '2');
      expect(u.queryParameters['tm'], '1764200000');
    });
  });
}
