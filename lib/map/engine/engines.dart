import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:latlong2/latlong.dart';

import '../../platform/android_properties.dart';
import 'flutter_map_engine.dart';
import 'map_engine.dart';
import 'maplibre_engine.dart';

/// The one place that decides which rendering engine draws the map.
///
/// MapLibre Native where it can run (Linux on Wayland with the bridge
/// library and the map assets in the bundle; Android with the bridge library
/// in the APK), the Flutter tile renderer everywhere else.
/// `MAPSOLY_MAP_ENGINE=flutter|maplibre` overrides the choice for testing
/// (on Android: `adb shell setprop debug.mapsoly.map_engine flutter`, read
/// when the app starts); `maplibre` still falls back when it cannot work.
MapViewController createMapController() =>
    _useMapLibre ? MapLibreViewController() : FlutterMapViewController();

/// Android's stand-in for the `MAPSOLY_MAP_ENGINE` environment variable.
const androidEngineProperty = 'debug.mapsoly.map_engine';

final bool _useMapLibre = _decide();

bool _decide() {
  final forced = Platform.isAndroid
      ? androidSystemProperty(androidEngineProperty)
      : Platform.environment['MAPSOLY_MAP_ENGINE'];
  if (forced == 'flutter') {
    mapEngineLog(
      'map engine: Flutter '
      '(${Platform.isAndroid ? androidEngineProperty : 'MAPSOLY_MAP_ENGINE'}=flutter)',
    );
    return false;
  }
  final reason = MapLibreEngine.unavailableReason();
  if (reason != null) {
    mapEngineLog('map engine: Flutter ($reason)');
    return false;
  }
  mapEngineLog('map engine: MapLibre Native');
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
  // The box keeps its size while the map is offstage: an Offstage child is
  // laid out as empty, and the screen's Stack takes its size from this
  // view, so without it every section shown instead of the map would be
  // squeezed to nothing.
  return SizedBox.expand(
    child: Offstage(
      offstage: !visible,
      child: FlutterMapView(
        controller: controller,
        scene: scene,
        initialCenter: initialCenter,
        initialZoom: initialZoom,
        onLongPress: onLongPress,
        onCameraChanged: onCameraChanged,
      ),
    ),
  );
}
