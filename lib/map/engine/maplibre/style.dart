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
  static const buildings3d = 'mapsoly-buildings-3d';
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

/// Extruded buildings, from the OpenMapTiles `building` layer. Shown from
/// zoom 15 (app zoom); flat when the view is not tilted, so always there.
Map<String, Object> buildingsLayer(String color) => {
  'id': MapIds.buildings3d,
  'type': 'fill-extrusion',
  'source': 'openmaptiles',
  'source-layer': 'building',
  'minzoom': 14,
  'paint': {
    'fill-extrusion-color': color,
    'fill-extrusion-height': ['get', 'render_height'],
    'fill-extrusion-base': ['get', 'render_min_height'],
    'fill-extrusion-opacity': 0.85,
  },
};

/// Colour for extruded buildings in the style [name]: soft grey on the light
/// map; on the dark one a little lighter than the flat buildings of the
/// style, so the blocks stand out from the ground.
String buildingsColor(String name, Map<String, dynamic> style) {
  if (name != 'dark') return '#d6d1ca';
  for (final layer in (style['layers'] as List).cast<Map<String, dynamic>>()) {
    if (layer['source-layer'] != 'building' || layer['type'] != 'fill') {
      continue;
    }
    final paint = layer['paint'];
    final c = paint is Map ? paint['fill-color'] : null;
    final m = c is String
        ? RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(c.trim())
        : null;
    if (m == null) continue;
    final v = int.parse(m.group(1)!, radix: 16);
    int up(int x) => (x + 28).clamp(0, 255);
    final r = up(v >> 16 & 0xff), g = up(v >> 8 & 0xff), b = up(v & 0xff);
    return '#${(r << 16 | g << 8 | b).toRadixString(16).padLeft(6, '0')}';
  }
  return '#3a4048';
}

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
  String? pmtilesPath,
  VectorTiles? tiles,
  bool buildings3d = false,
  required String assetsDir,
  required OverlayColors colors,
}) {
  assert((pmtilesPath == null) != (tiles == null));
  final style = jsonDecode(bundledStyleJson) as Map<String, dynamic>;
  style['sources'] = <String, dynamic>{
    'openmaptiles': tiles == null
        ? {'type': 'vector', 'url': 'pmtiles://file://$pmtilesPath'}
        : {
            'type': 'vector',
            'tiles': [tiles.urlTemplate],
            'minzoom': tiles.minZoom,
            'maxzoom': tiles.maxZoom,
          },
  };
  style['glyphs'] = 'file://$assetsDir/fonts/{fontstack}/{range}.pbf';
  style['sprite'] = 'file://$assetsDir/sprites/$name/sprite';
  _addOverlays(style, colors);
  if (buildings3d) {
    // Under the route (and so under the labels), over everything flat.
    final layers = (style['layers'] as List).cast<Map<String, dynamic>>();
    layers.insert(
      layers.indexWhere((l) => l['id'] == MapIds.firstOverlayLayer),
      buildingsLayer(buildingsColor(name, style)),
    );
  }
  return jsonEncode(style);
}

/// Vector tiles fetched by URL template instead of read from one archive:
/// several packs served as one tile set by the app's tile server.
class VectorTiles {
  const VectorTiles(this.urlTemplate, this.minZoom, this.maxZoom);
  final String urlTemplate;
  final int minZoom, maxZoom;
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

/// Colour of the style's `background` layer as 0xAARRGGBB, or null when the
/// style has none or writes it in a form other than `#rgb`, `#rrggbb` or
/// `rgb(r,g,b)`. The view shows it until the map has drawn its first frame.
int? styleBackgroundColor(String styleJson) {
  final layers = (jsonDecode(styleJson) as Map<String, dynamic>)['layers'];
  if (layers is! List) return null;
  for (final layer in layers) {
    if (layer is! Map || layer['type'] != 'background') continue;
    final paint = layer['paint'];
    final color = paint is Map ? paint['background-color'] : null;
    if (color is! String) return null;
    final c = color.trim();
    final hex = RegExp(r'^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$').firstMatch(c);
    if (hex != null) {
      var h = hex.group(1)!;
      if (h.length == 3) h = h.split('').map((x) => '$x$x').join();
      return 0xFF000000 | int.parse(h, radix: 16);
    }
    final rgb = RegExp(
      r'^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,[^)]*)?\)$',
    ).firstMatch(c);
    if (rgb != null) {
      final v = [
        for (var i = 1; i <= 3; i++) int.parse(rgb.group(i)!).clamp(0, 255),
      ];
      return 0xFF000000 | (v[0] << 16) | (v[1] << 8) | v[2];
    }
    return null;
  }
  return null;
}
