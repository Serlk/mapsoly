import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/map/engine/maplibre/style.dart';

const _colors = OverlayColors(
  primary: 'rgba(1,2,3,1.000)',
  surface: 'rgba(250,250,250,1.000)',
  outline: 'rgba(100,100,100,1.000)',
);

Map<String, dynamic> _vector(String name) =>
    jsonDecode(
          buildVectorStyle(
            bundledStyleJson: File(
              'assets/styles/$name.json',
            ).readAsStringSync(),
            name: name,
            pmtilesPath: '/data/packs/moscow/map.pmtiles',
            assetsDir: '/app/data/maplibre',
            colors: _colors,
          ),
        )
        as Map<String, dynamic>;

List<String> _ids(Map<String, dynamic> style) => [
  for (final l in style['layers'] as List) (l as Map)['id'] as String,
];

void main() {
  test('cssColor', () {
    expect(cssColor(0xFF2E7D6B), 'rgba(46,125,107,1.000)');
    expect(cssColor(0x802E7D6B, 0.5), 'rgba(46,125,107,0.251)');
  });

  for (final name in ['bright', 'dark']) {
    group('$name style', () {
      final style = _vector(name);
      final layers = (style['layers'] as List).cast<Map<String, dynamic>>();
      final ids = _ids(style);

      test('uses only local data', () {
        expect(style['sources']['openmaptiles'], {
          'type': 'vector',
          'url': 'pmtiles://file:///data/packs/moscow/map.pmtiles',
        });
        expect(
          style['glyphs'],
          'file:///app/data/maplibre/fonts/{fontstack}/{range}.pbf',
        );
        expect(
          style['sprite'],
          'file:///app/data/maplibre/sprites/$name/sprite',
        );
        expect(jsonEncode(style), isNot(contains('https://')));
        expect(jsonEncode(style), isNot(contains('{key}')));
      });

      test('keeps every layer of the bundled style, in order', () {
        final original = [
          for (final l
              in (jsonDecode(
                        File('assets/styles/$name.json').readAsStringSync(),
                      )
                      as Map)['layers']
                  as List)
            (l as Map)['id'] as String,
        ];
        expect(ids.where((i) => !i.startsWith('mapsoly-')).toList(), original);
      });

      test('route is above every road and below the road labels', () {
        final casing = ids.indexOf(MapIds.firstOverlayLayer);
        final route = ids.indexOf('mapsoly-route');
        expect(casing, greaterThan(0));
        expect(route, casing + 3);
        bool isRoad(Map<String, dynamic> l) =>
            l['type'] != 'symbol' && l['source-layer'] == 'transportation';
        expect(isRoad(layers[casing - 1]), isTrue);
        expect(layers.skip(route + 1).where(isRoad), isEmpty);
        // Road names and place names come after the route.
        final names = [
          for (var i = 0; i < ids.length; i++)
            if (layers[i]['type'] == 'symbol' &&
                (ids[i].contains('highway') || ids[i].contains('place')))
              i,
        ];
        expect(names, isNotEmpty);
        expect(names.every((i) => i > route), isTrue);
      });

      test('markers are on top, pins last', () {
        expect(ids.sublist(ids.length - 5), [
          'mapsoly-accuracy-fill',
          'mapsoly-accuracy-line',
          'mapsoly-position',
          'mapsoly-from',
          'mapsoly-pins',
        ]);
        for (final s in [MapIds.routes, MapIds.points, MapIds.accuracy]) {
          expect(style['sources'][s]['type'], 'geojson');
        }
        final route = layers.firstWhere((l) => l['id'] == 'mapsoly-route');
        expect(route['paint']['line-color'], _colors.primary);
        expect(route['filter'], ['==', 'kind', 'route']);
      });
    });
  }

  test('raster style goes through the tile server and has the overlays', () {
    for (final dark in [false, true]) {
      final style =
          jsonDecode(
                buildRasterStyle(
                  tilesUrl: 'http://127.0.0.1:4242/osm/{z}/{x}/{y}.png',
                  dark: dark,
                  highDensity: true,
                  assetsDir: '/a',
                  colors: _colors,
                ),
              )
              as Map<String, dynamic>;
      expect(style['sources']['osm']['tiles'], [
        'http://127.0.0.1:4242/osm/{z}/{x}/{y}.png',
      ]);
      expect(style['sources']['osm']['tileSize'], 128);
      final ids = _ids(style);
      expect(ids.take(3), ['background', 'osm', MapIds.firstOverlayLayer]);
      expect(ids.last, 'mapsoly-pins');
      final raster = (style['layers'] as List)[1] as Map;
      expect(raster.containsKey('paint'), dark);
    }
  });

  test('traffic source and layer share the versioned id', () {
    final source =
        jsonDecode(trafficSourceJson('http://x/{z}/{x}/{y}.png')) as Map;
    expect(source['type'], 'raster');
    expect(source['tileSize'], 256);
    final layer = jsonDecode(trafficLayerJson('yandex-17')) as Map;
    expect(layer['id'], 'mapsoly-traffic-yandex-17');
    expect(layer['source'], layer['id']);
  });
}
