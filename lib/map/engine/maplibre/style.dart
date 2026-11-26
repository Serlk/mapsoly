/// Builds the MapLibre style documents of the app from the bundled style
/// JSON (`assets/styles/*.json`): local data instead of the online URLs, plus
/// the app's own sources and layers (route, markers, position).
///
/// Pure functions: JSON in, JSON out.
library;

import 'dart:convert';

/// Colours of the overlay layers, as CSS colour strings.
class OverlayColors {
  const OverlayColors({
    required this.primary,
    required this.surface,
    required this.outline,
  });

  final String primary, surface, outline;

  @override
  bool operator ==(Object other) =>
      other is OverlayColors &&
      other.primary == primary &&
      other.surface == surface &&
      other.outline == outline;

  @override
  int get hashCode => Object.hash(primary, surface, outline);
}

/// `rgba(r,g,b,a)` of a 0xAARRGGBB colour value.
String cssColor(int argb, [double opacity = 1]) {
  final a = ((argb >> 24) & 0xff) / 255 * opacity;
  return 'rgba(${(argb >> 16) & 0xff},${(argb >> 8) & 0xff},${argb & 0xff},'
      '${a.toStringAsFixed(3)})';
}

abstract final class MapIds {
  static const routes = 'mapsoly-routes';
  static const points = 'mapsoly-points';
  static const accuracy = 'mapsoly-accuracy';
  static const pinTo = 'mapsoly-pin-to';
  static const pinPicked = 'mapsoly-pin-picked';

  /// Lowest overlay layer: traffic goes right below it (above the roads,
  /// below the route and the labels).
  static const firstOverlayLayer = 'mapsoly-alt-casing';
  static const trafficPrefix = 'mapsoly-traffic-';
}

const _emptyCollection = {'type': 'FeatureCollection', 'features': <Object>[]};

Map<String, Object> _geoJsonSource() => {
  'type': 'geojson',
  'data': _emptyCollection,
};

/// Route lines; they are inserted below the labels.
List<Map<String, Object>> routeLayers(OverlayColors c) {
  Map<String, Object> line(
    String id,
    String kind,
    String color,
    double width, [
    double opacity = 1,
  ]) => {
    'id': id,
    'type': 'line',
    'source': MapIds.routes,
    'filter': ['==', 'kind', kind],
    'layout': {'line-cap': 'round', 'line-join': 'round'},
    'paint': {
      'line-color': color,
      'line-width': width,
      'line-opacity': opacity,
    },
  };
  return [
    line(MapIds.firstOverlayLayer, 'alt', c.surface, 7),
    line('mapsoly-alt', 'alt', c.outline, 5, 0.8),
    line('mapsoly-route-casing', 'route', c.surface, 10),
    line('mapsoly-route', 'route', c.primary, 6),
  ];
}

/// Position and markers; they go on top of everything.
List<Map<String, Object>> markerLayers(OverlayColors c) => [
  {
    'id': 'mapsoly-accuracy-fill',
    'type': 'fill',
    'source': MapIds.accuracy,
    'paint': {'fill-color': c.primary, 'fill-opacity': 0.12},
  },
  {
    'id': 'mapsoly-accuracy-line',
    'type': 'line',
    'source': MapIds.accuracy,
    'paint': {'line-color': c.primary, 'line-opacity': 0.5, 'line-width': 1},
  },
  {
    'id': 'mapsoly-position',
    'type': 'circle',
    'source': MapIds.points,
    'filter': ['==', 'kind', 'position'],
    'paint': {
      'circle-radius': 7,
      'circle-color': c.primary,
      'circle-stroke-color': c.surface,
      'circle-stroke-width': 3,
    },
  },
  {
    'id': 'mapsoly-from',
    'type': 'circle',
    'source': MapIds.points,
    'filter': ['==', 'kind', 'from'],
    'paint': {
      'circle-radius': 6,
      'circle-color': c.surface,
      'circle-stroke-color': c.primary,
      'circle-stroke-width': 4,
    },
  },
  {
    'id': 'mapsoly-pins',
    'type': 'symbol',
    'source': MapIds.points,
    'filter': ['has', 'icon'],
    'layout': {
      'icon-image': '{icon}',
      'icon-anchor': 'bottom',
      'icon-allow-overlap': true,
      'icon-ignore-placement': true,
    },
  },
];

void _addOverlays(Map<String, dynamic> style, OverlayColors colors) {
  final sources = style['sources'] as Map<String, dynamic>;
  sources[MapIds.routes] = _geoJsonSource();
  sources[MapIds.points] = _geoJsonSource();
  sources[MapIds.accuracy] = _geoJsonSource();
  final layers = (style['layers'] as List).cast<Map<String, dynamic>>();
  // Above every road and below the labels that follow them: right after the
  // last road or rail layer (labels of the roads come later in both styles).
  // Styles without such layers (raster): after the last non-label layer.
  var below = layers.lastIndexWhere(
    (l) => l['type'] != 'symbol' && l['source-layer'] == 'transportation',
  );
  if (below < 0) below = layers.lastIndexWhere((l) => l['type'] != 'symbol');
  layers.insertAll(below + 1, routeLayers(colors));
  layers.addAll(markerLayers(colors));
}

/// The vector style [name] (`bright` or `dark`) for the region pack at
/// [pmtilesPath], with glyphs and sprites from [assetsDir].
String buildVectorStyle({
  required String bundledStyleJson,
  required String name,
  required String pmtilesPath,
  required String assetsDir,
  required OverlayColors colors,
}) {
  final style = jsonDecode(bundledStyleJson) as Map<String, dynamic>;
  style['sources'] = <String, dynamic>{
    'openmaptiles': {'type': 'vector', 'url': 'pmtiles://file://$pmtilesPath'},
  };
  style['glyphs'] = 'file://$assetsDir/fonts/{fontstack}/{range}.pbf';
  style['sprite'] = 'file://$assetsDir/sprites/$name/sprite';
  _addOverlays(style, colors);
  return jsonEncode(style);
}

/// Online raster tiles (served through the app's tile server at [tilesUrl])
/// for when no region pack is installed.
String buildRasterStyle({
  required String tilesUrl,
  required bool dark,
  required bool highDensity,
  required String assetsDir,
  required OverlayColors colors,
}) {
  final style = <String, dynamic>{
    'version': 8,
    'name': 'online-raster',
    'glyphs': 'file://$assetsDir/fonts/{fontstack}/{range}.pbf',
    'sources': <String, dynamic>{
      'osm': {
        'type': 'raster',
        'tiles': [tilesUrl],
        // Half-size tiles on dense screens: the next zoom level is loaded,
        // so the picture is not blurry.
        'tileSize': highDensity ? 128 : 256,
        'maxzoom': 19,
        'attribution': 'OpenStreetMap contributors',
      },
    },
    'layers': <Map<String, dynamic>>[
      {
        'id': 'background',
        'type': 'background',
        'paint': {'background-color': dark ? '#101010' : '#e8e4dc'},
      },
      {
        'id': 'osm',
        'type': 'raster',
        'source': 'osm',
        // There is no dark variant of these tiles: invert and dim them.
        if (dark)
          'paint': {
            'raster-brightness-min': 1,
            'raster-brightness-max': 0.05,
            'raster-saturation': -0.6,
            'raster-contrast': -0.1,
          },
      },
    ],
  };
  _addOverlays(style, colors);
  return jsonEncode(style);
}

/// Source and layer of a traffic overlay named by [key].
String trafficSourceJson(String tilesUrl) => jsonEncode({
  'type': 'raster',
  'tiles': [tilesUrl],
  // The tiles are 512 px: sharp on dense screens.
  'tileSize': 256,
  'maxzoom': 19,
});

String trafficLayerJson(String key) => jsonEncode({
  'id': '${MapIds.trafficPrefix}$key',
  'type': 'raster',
  'source': '${MapIds.trafficPrefix}$key',
});
