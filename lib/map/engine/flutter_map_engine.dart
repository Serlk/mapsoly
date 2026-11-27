import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';

import '../../offline/pmtiles_tile_provider.dart';
import '../../traffic/traffic.dart';
import '../../traffic/yandex_tile_provider.dart';
import 'map_engine.dart';

/// Camera control for [FlutterMapView].
class FlutterMapViewController implements MapViewController {
  final MapController _map = MapController();
  bool _ready = false;
  final _changes = _CameraChanges();
  StreamSubscription<MapEvent>? _events;
  DateTime _lastNotified = DateTime.fromMillisecondsSinceEpoch(0);

  /// Called by the view once the map exists.
  void _attach() {
    _ready = true;
    _events ??= _map.mapEventStream.listen((_) {
      // At most ~30 notifications a second.
      final now = DateTime.now();
      if (now.difference(_lastNotified).inMilliseconds < 33) return;
      _lastNotified = now;
      _changes.notify();
    });
  }

  @override
  bool get ready => _ready;

  @override
  LatLng get center => _map.camera.center;

  @override
  double get zoom => _map.camera.zoom;

  // flutter_map turns the map clockwise by `rotation`: the direction that is
  // up on screen is then the opposite angle.
  @override
  double get bearing {
    var b = -_map.camera.rotation % 360;
    if (b > 180) b -= 360;
    return b;
  }

  @override
  void resetNorth() => _map.rotate(0);

  /// This engine draws flat: no tilt.
  @override
  double get pitch => 0;

  @override
  double get maxPitch => 0;

  @override
  void move(LatLng center, double zoom) => _map.move(center, zoom);

  /// Jumps (this engine does not animate); [pitch] is ignored.
  @override
  void moveCamera({
    LatLng? center,
    double? zoom,
    double? bearing,
    double? pitch,
    Duration? duration,
  }) {
    final camera = _map.camera;
    _map.moveAndRotate(
      center ?? camera.center,
      zoom ?? camera.zoom,
      bearing == null ? camera.rotation : -bearing,
    );
  }

  /// Not supported here: the camera target stays at the view centre.
  @override
  void setPadding(EdgeInsets padding) {}

  @override
  Listenable get cameraChanges => _changes;

  @override
  void fit(List<LatLng> points, EdgeInsets padding) => _map.fitCamera(
    CameraFit.coordinates(coordinates: points, padding: padding),
  );

  @override
  void panBy(Offset fraction) {
    final c = _map.camera;
    final step = c.nonRotatedSize.shortestSide;
    _map.move(
      c.unprojectAtZoom(c.projectAtZoom(c.center) + fraction * step),
      c.zoom,
    );
  }

  @override
  void dispose() {
    _events?.cancel();
    _changes.dispose();
    _map.dispose();
  }
}

class _CameraChanges extends ChangeNotifier {
  void notify() => notifyListeners();
}

/// The map drawn inside Flutter: vector tiles rasterised by Skia, with the
/// overlays as Flutter layers.
class FlutterMapView extends StatelessWidget {
  const FlutterMapView({
    super.key,
    required this.controller,
    required this.scene,
    required this.initialCenter,
    required this.initialZoom,
    required this.onLongPress,
    required this.onCameraChanged,
  });

  final MapViewController controller;
  final MapScene scene;
  final LatLng initialCenter;
  final double initialZoom;
  final ValueChanged<LatLng> onLongPress;
  final void Function(LatLng center, double zoom) onCameraChanged;

  static const _darkRaster = ColorFilter.matrix([
    -0.55, -0.25, -0.05, 0, 245, //
    -0.20, -0.60, -0.05, 0, 245, //
    -0.20, -0.25, -0.40, 0, 250, //
    0, 0, 0, 1, 0,
  ]);

  /// Offline vector map when a region pack is installed, otherwise online
  /// raster tiles.
  Widget _baseLayer(BuildContext context) {
    // One archive at a time here; several packs are drawn together only by
    // the MapLibre engine.
    final offline = scene.packs.firstOrNull;
    if (offline == null) {
      final tiles = TileLayer(
        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
        userAgentPackageName: 'dev.mapsoly.mapsoly',
        maxNativeZoom: 19,
        // Raster tiles are 256px; on dense screens load the next zoom level
        // so the map is not blurry.
        retinaMode: RetinaMode.isHighDensity(context),
      );
      // The public raster tiles have no dark variant: invert and dim them.
      return scene.dark
          ? ColorFiltered(colorFilter: _darkRaster, child: tiles)
          : tiles;
    }
    return VectorTileLayer(
      key: ValueKey(scene.dark),
      theme: scene.dark ? offline.darkTheme : offline.theme,
      tileProviders: TileProviders({
        'openmaptiles': PmTilesVectorTileProvider(offline.archive),
      }),
      maximumZoom: 19,
    );
  }

  Widget? _trafficLayer() {
    final traffic = scene.traffic;
    if (traffic == null) return null;
    switch (traffic.source) {
      case TrafficSource.off:
        return null;
      case TrafficSource.yandex:
        return TileLayer(
          key: ValueKey('yandex-${traffic.version}'),
          maxNativeZoom: 19,
          tileProvider: YandexTrafficTileProvider(
            client: traffic.client,
            version: traffic.version,
          ),
        );
      case TrafficSource.google:
        return TileLayer(
          key: ValueKey('google-${traffic.version}'),
          urlTemplate:
              'https://mt{s}.google.com/vt?lyrs=h@159000000,traffic'
              '%7Cseconds_into_week:-1&style=3&x={x}&y={y}&z={z}'
              '&_=${traffic.version}',
          subdomains: const ['0', '1', '2', '3'],
          maxNativeZoom: 19,
          // TileLayer adds its own header to this map, so it must be mutable.
          tileProvider: NetworkTileProvider(headers: {...trafficHeaders}),
        );
    }
  }

  List<Widget> _positionLayers(ColorScheme colors) {
    final point = scene.position;
    if (point == null) return const [];
    return [
      CircleLayer(
        circles: [
          CircleMarker(
            point: point,
            radius: scene.positionAccuracyM ?? 10,
            useRadiusInMeter: true,
            color: colors.primary.withValues(alpha: 0.12),
            borderColor: colors.primary.withValues(alpha: 0.5),
            borderStrokeWidth: 1,
          ),
          CircleMarker(
            point: point,
            radius: 7,
            color: colors.primary,
            borderColor: colors.surface,
            borderStrokeWidth: 3,
          ),
        ],
      ),
    ];
  }

  List<Widget> _routeLayers(ColorScheme colors) {
    final route = scene.route;
    Marker pin(LatLng p, IconData icon, Color color, {bool tip = true}) =>
        Marker(
          point: p,
          width: 36,
          height: 36,
          // Pins point at the place with their tip; dots sit centred on it.
          alignment: tip ? Alignment.topCenter : Alignment.center,
          child: Icon(icon, size: tip ? 36 : 26, color: color),
        );
    return [
      if (route != null)
        PolylineLayer(
          polylines: [
            for (final other in scene.alternatives)
              Polyline(
                points: other,
                strokeWidth: 5,
                color: colors.outline.withValues(alpha: 0.8),
                borderStrokeWidth: 1,
                borderColor: colors.surface,
              ),
            Polyline(
              points: route,
              strokeWidth: 6,
              color: colors.primary,
              borderStrokeWidth: 2,
              borderColor: colors.surface,
            ),
          ],
        ),
      MarkerLayer(
        markers: [
          if (scene.from != null)
            pin(scene.from!, Icons.trip_origin, colors.primary, tip: false),
          if (scene.to != null) pin(scene.to!, Icons.place, colors.error),
          if (scene.picked != null)
            pin(scene.picked!, Icons.location_on, colors.tertiary),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final controller = this.controller as FlutterMapViewController;
    return FlutterMap(
      mapController: controller._map,
      options: MapOptions(
        initialCenter: initialCenter,
        initialZoom: initialZoom,
        onMapReady: controller._attach,
        onLongPress: (_, point) => onLongPress(point),
        onPositionChanged: (camera, _) =>
            onCameraChanged(camera.center, camera.zoom),
        minZoom: 3,
        maxZoom: 19,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
      ),
      children: [
        _baseLayer(context),
        ?_trafficLayer(),
        ..._positionLayers(colors),
        ..._routeLayers(colors),
        const SimpleAttributionWidget(
          source: Text('OpenStreetMap contributors'),
        ),
      ],
    );
  }
}
