import 'package:flutter/widgets.dart';
import 'package:latlong2/latlong.dart';

import 'flutter_map_engine.dart';
import 'map_engine.dart';

/// The one place that decides which rendering engine draws the map.
///
/// Today: the Flutter tile renderer. A MapLibre Native engine plugs in here
/// by returning its own controller and view.
MapViewController createMapController() => FlutterMapViewController();

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
