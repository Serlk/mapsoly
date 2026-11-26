import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:latlong2/latlong.dart';

import 'flutter_map_engine.dart';
import 'map_engine.dart';
import 'maplibre_engine.dart';

/// The one place that decides which rendering engine draws the map.
///
/// MapLibre Native where it can run (Linux on Wayland, with the bridge
/// library and the map assets in the bundle), the Flutter tile renderer
/// everywhere else. `MAPSOLY_MAP_ENGINE=flutter|maplibre` overrides the
/// choice for testing; `maplibre` still falls back when it cannot work.
MapViewController createMapController() =>
    _useMapLibre ? MapLibreViewController() : FlutterMapViewController();

final bool _useMapLibre = _decide();

bool _decide() {
  final forced = Platform.environment['MAPSOLY_MAP_ENGINE'];
  if (forced == 'flutter') {
    stderr.writeln('map engine: Flutter (MAPSOLY_MAP_ENGINE=flutter)');
    return false;
  }
  final reason = MapLibreEngine.unavailableReason();
  if (reason != null) {
    stderr.writeln('map engine: Flutter ($reason)');
    return false;
  }
  stderr.writeln('map engine: MapLibre Native');
  return true;
}

/// Builds the view that belongs to [controller].
Widget buildMapView({
  required MapViewController controller,
  required MapScene scene,
  required LatLng initialCenter,
  required double initialZoom,
  required ValueChanged<LatLng> onLongPress,
  required void Function(LatLng center, double zoom) onCameraChanged,
  bool visible = true,
}) {
  // [visible] is false while another screen (search) covers the map: engines
  // that draw outside Flutter's scene must hide their surface then.
  if (controller is MapLibreViewController) {
    return MapLibreView(
      controller: controller,
      scene: scene,
      initialCenter: initialCenter,
      initialZoom: initialZoom,
      onLongPress: onLongPress,
      onCameraChanged: onCameraChanged,
      visible: visible,
    );
  }
  return Offstage(
    offstage: !visible,
    child: FlutterMapView(
      controller: controller,
      scene: scene,
      initialCenter: initialCenter,
      initialZoom: initialZoom,
      onLongPress: onLongPress,
      onCameraChanged: onCameraChanged,
    ),
  );
}
