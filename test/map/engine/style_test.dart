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
        expect(ids.sublist(ids.length - 6), [
          'mapsoly-accuracy-fill',
          'mapsoly-accuracy-line',
          'mapsoly-position',
          'mapsoly-position-arrow',
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

  test('extruded buildings: below the route, coloured per style', () {
    for (final name in ['bright', 'dark']) {
      final style =
          jsonDecode(
                buildVectorStyle(
                  bundledStyleJson: File(
                    'assets/styles/$name.json',
                  ).readAsStringSync(),
                  name: name,
                  pmtilesPath: '/p',
                  buildings3d: true,
                  assetsDir: '/a',
                  colors: _colors,
                ),
              )
              as Map<String, dynamic>;
      final ids = _ids(style);
      final at = ids.indexOf(MapIds.buildings3d);
      expect(at, ids.indexOf(MapIds.firstOverlayLayer) - 1);
      final layer = (style['layers'] as List)[at] as Map;
      expect(layer['type'], 'fill-extrusion');
      expect(layer['source-layer'], 'building');
      expect(layer['paint']['fill-extrusion-height'], ['get', 'render_height']);
      expect(
        layer['paint']['fill-extrusion-color'],
        matches(RegExp(r'^#[0-9a-f]{6}$')),
      );
      // Off by default.
      expect(_ids(_vector(name)), isNot(contains(MapIds.buildings3d)));
    }
    // Dark: a little lighter than the flat buildings of that style.
    expect(
      buildingsColor('dark', {
        'layers': [
          {
            'type': 'fill',
            'source-layer': 'building',
            'paint': {'fill-color': '#202830'},
          },
        ],
      }),
      '#3c444c',
    );
    expect(buildingsColor('bright', {'layers': []}), '#d6d1ca');
  });

  group('signal heat map', () {
    Map<String, dynamic> vector(
      String name, {
      bool heat = true,
      bool buildings3d = false,
    }) =>
        jsonDecode(
              buildVectorStyle(
                bundledStyleJson: File(
                  'assets/styles/$name.json',
                ).readAsStringSync(),
                name: name,
                pmtilesPath: '/p',
                buildings3d: buildings3d,
                signalHeat: heat,
                assetsDir: '/a',
                colors: _colors,
              ),
            )
            as Map<String, dynamic>;
    Map<String, dynamic> raster({required bool heat, bool dark = false}) =>
        jsonDecode(
              buildRasterStyle(
                tilesUrl: 'http://127.0.0.1:4000/osm/{z}/{x}/{y}',
                dark: dark,
                highDensity: false,
                signalHeat: heat,
                assetsDir: '/a',
                colors: _colors,
              ),
            )
            as Map<String, dynamic>;

    test('off: neither the source nor the layer', () {
      for (final style in [
        _vector('bright'),
        _vector('dark'),
        vector('bright', heat: false),
        raster(heat: false),
      ]) {
        expect((style['sources'] as Map).keys, isNot(contains(MapIds.heat)));
        expect(_ids(style), isNot(contains(MapIds.heat)));
        expect(jsonEncode(style), isNot(contains('heatmap')));
      }
    });

    test('on: a GeoJSON source and a heatmap layer, in every style', () {
      for (final style in [
        vector('bright'),
        vector('dark'),
        raster(heat: true),
        raster(heat: true, dark: true),
      ]) {
        expect(style['sources'][MapIds.heat], {
          'type': 'geojson',
          'data': {'type': 'FeatureCollection', 'features': <Object>[]},
        });
        final layer =
            (style['layers'] as List).singleWhere(
                  (l) => (l as Map)['id'] == MapIds.heat,
                )
                as Map;
        expect(layer['type'], 'heatmap');
        expect(layer['source'], MapIds.heat);
      }
    });

    test('below the route and where the traffic goes, above the roads', () {
      for (final name in ['bright', 'dark']) {
        final style = vector(name);
        final layers = (style['layers'] as List).cast<Map<String, dynamic>>();
        final ids = _ids(style);
        final at = ids.indexOf(MapIds.heat);
        // The traffic overlay is inserted right below the first route
        // layer: the heat map directly under that stays under the traffic.
        expect(at, ids.indexOf(MapIds.firstOverlayLayer) - 1);
        for (final id in [
          'mapsoly-alt',
          'mapsoly-route-casing',
          'mapsoly-route',
          'mapsoly-route-traffic',
          'mapsoly-position',
          'mapsoly-pins',
        ]) {
          expect(at, lessThan(ids.indexOf(id)), reason: id);
        }
        final lastRoad = layers.lastIndexWhere(
          (l) => l['type'] != 'symbol' && l['source-layer'] == 'transportation',
        );
        expect(at, lastRoad + 1);
        // Every label of the base map is above it.
        final firstLabelAfterRoads = layers.indexWhere(
          (l) => l['type'] == 'symbol',
          lastRoad,
        );
        expect(firstLabelAfterRoads, greaterThan(at));
        // One layer more than without the heat map.
        expect(ids.length, _ids(_vector(name)).length + 1);
      }
      final ids = _ids(raster(heat: true));
      expect(ids.indexOf('osm'), lessThan(ids.indexOf(MapIds.heat)));
      expect(
        ids.indexOf(MapIds.heat),
        ids.indexOf(MapIds.firstOverlayLayer) - 1,
      );
    });

    test('with extruded buildings: buildings, heat, route', () {
      final ids = _ids(vector('dark', buildings3d: true));
      final at = ids.indexOf(MapIds.heat);
      expect(ids.indexOf(MapIds.buildings3d), at - 1);
      expect(ids.indexOf(MapIds.firstOverlayLayer), at + 1);
    });

    test('paint: weight from the point, zoom ramps, transparent start', () {
      final paint = heatLayer()['paint'] as Map;
      expect(jsonEncode(paint['heatmap-weight']), contains('["get","w"]'));
      for (final key in ['heatmap-radius', 'heatmap-intensity']) {
        final ramp = paint[key] as List;
        expect(ramp.sublist(0, 3), [
          'interpolate',
          ['linear'],
          ['zoom'],
        ], reason: key);
        // Stops in ascending zoom, values positive.
        final stops = ramp.sublist(3).cast<num>();
        for (var i = 2; i < stops.length; i += 2) {
          expect(stops[i], greaterThan(stops[i - 2]), reason: key);
        }
        for (var i = 1; i < stops.length; i += 2) {
          expect(stops[i], greaterThan(0), reason: key);
        }
      }
      final color = paint['heatmap-color'] as List;
      expect(color.sublist(0, 3), [
        'interpolate',
        ['linear'],
        ['heatmap-density'],
      ]);
      // Nothing collected, nothing drawn: zero density is transparent.
      expect(color[3], 0);
      expect(color[4], matches(RegExp(r'^rgba\(\d+,\d+,\d+,0\)$')));
      expect(color[color.length - 2], 1);
      expect(color.last, 'rgb(255,59,48)');
      expect(paint['heatmap-opacity'], inInclusiveRange(0.6, 0.7));
    });
  });

  test('several packs: tiles by URL template with the zoom range', () {
    final style =
        jsonDecode(
              buildVectorStyle(
                bundledStyleJson: File(
                  'assets/styles/bright.json',
                ).readAsStringSync(),
                name: 'bright',
                tiles: const VectorTiles(
                  'http://127.0.0.1:4242/packs/set1/{z}/{x}/{y}.pbf',
                  0,
                  14,
                ),
                assetsDir: '/a',
                colors: _colors,
              ),
            )
            as Map<String, dynamic>;
    expect(style['sources']['openmaptiles'], {
      'type': 'vector',
      'tiles': ['http://127.0.0.1:4242/packs/set1/{z}/{x}/{y}.pbf'],
      'minzoom': 0,
      'maxzoom': 14,
    });
    expect(_ids(style), contains('mapsoly-route'));
  });

  test('background colour is read from the style', () {
    String style(Object? color) => jsonEncode({
      'layers': [
        {'id': 'x', 'type': 'fill'},
        {
          'id': 'background',
          'type': 'background',
          'paint': {'background-color': ?color},
        },
      ],
    });
    expect(styleBackgroundColor(style('#14181c')), 0xFF14181C);
    expect(styleBackgroundColor(style('#abc')), 0xFFAABBCC);
    expect(styleBackgroundColor(style('rgb(12, 12,12)')), 0xFF0C0C0C);
    expect(styleBackgroundColor(style('rgba(1,2,3,0.5)')), 0xFF010203);
    expect(styleBackgroundColor(style('hsl(0,0%,5%)')), isNull);
    expect(styleBackgroundColor(style(null)), isNull);
    expect(styleBackgroundColor('{"layers":[]}'), isNull);
    // Both bundled styles have one the app can read.
    for (final name in ['bright', 'dark']) {
      expect(
        styleBackgroundColor(
          File('assets/styles/$name.json').readAsStringSync(),
        ),
        isNotNull,
        reason: name,
      );
    }
  });

  test('traffic source and layer share the versioned id', () {
    final source =
        jsonDecode(trafficSourceJson('http://x/{z}/{x}/{y}.png')) as Map;
    expect(source['type'], 'raster');
    expect(source['tileSize'], 512);
    final layer = jsonDecode(trafficLayerJson('yandex-17')) as Map;
    expect(layer['id'], 'mapsoly-traffic-yandex-17');
    expect(layer['source'], layer['id']);
  });
}
