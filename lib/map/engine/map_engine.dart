import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../../offline/offline_map.dart';
import '../../traffic/traffic.dart';
import '../position_arrow.dart';
import '../../traffic/traffic_sampler.dart';

/// Everything the map should show, independent of the rendering engine.
///
/// The screen describes the scene; an engine (the Flutter tile renderer
/// today, MapLibre Native later) turns it into pixels.
@immutable
class MapScene {
  const MapScene({
    required this.dark,
    this.offline,
    this.offlineMaps = const [],
    this.offlineLoading = false,
    this.blurRects = const [],
    this.buildings3d = false,
    this.traffic,
    this.signalHeat,
    this.route,
    this.alternatives = const [],
    this.routeTraffic = const [],
    this.from,
    this.to,
    this.picked,
    this.position,
    this.positionAccuracyM,
    this.positionHeading,
    this.positionArrow = PositionArrow.chevron,
  });

  /// Dark map style.
  final bool dark;

  /// Installed region pack; null shows online raster tiles.
  final OfflineMap? offline;

  /// All installed region packs, drawn as one map: each tile comes from
  /// whichever pack has it (packs cut from one tileset join seamlessly).
  /// When empty, [offline] alone is used. Engines that draw a single archive
  /// take the first.
  final List<OfflineMap> offlineMaps;

  /// True while the installed packs are still being opened: the engine then
  /// shows its placeholder and waits, instead of starting with online tiles
  /// and switching a moment later.
  final bool offlineLoading;

  /// The packs to draw, whichever of the two fields carries them.
  List<OfflineMap> get packs =>
      offlineMaps.isNotEmpty ? offlineMaps : [?offline];

  /// Rectangles of the map (logical pixels in the view's coordinates) that
  /// lie under translucent UI and should look like frosted glass. Engines
  /// that draw outside Flutter's scene blur them themselves; an engine drawn
  /// by Flutter ignores this (a BackdropFilter in the UI already works there).
  final List<Rect> blurRects;

  /// Draw buildings extruded when the camera is tilted.
  final bool buildings3d;

  /// Traffic overlay to draw above the roads; null when off or not loaded.
  final TrafficOverlay? traffic;

  /// The "signal map": where the app has collected transmitters, drawn as a
  /// translucent heat map below the traffic and the route. Null when the
  /// layer is off; an empty list when it is on with nothing to show. The
  /// list is replaced, never changed in place (engines compare by identity).
  final List<HeatPoint>? signalHeat;

  /// Selected route line and the other alternatives (drawn muted, below).
  final List<LatLng>? route;
  final List<List<LatLng>> alternatives;

  /// Traffic along [route] (indexes into it): the line is coloured by it,
  /// inside a band of the route colour so it still reads as the route.
  final List<TrafficSpan> routeTraffic;

  /// Route endpoints and the point picked by a long press or a search.
  final LatLng? from, to, picked;

  /// Device position with its accuracy radius in metres.
  final LatLng? position;
  final double? positionAccuracyM;

  /// Where the device or the car is heading, degrees clockwise from north;
  /// null when not known. With it the position is drawn as
  /// [positionArrow], without it as a dot.
  final double? positionHeading;
  final PositionArrow positionArrow;
}

/// One point of a heat map: a place and how much it adds, 0..1.
@immutable
class HeatPoint {
  const HeatPoint(this.point, this.weight);

  final LatLng point;
  final double weight;

  @override
  bool operator ==(Object other) =>
      other is HeatPoint && other.point == point && other.weight == weight;

  @override
  int get hashCode => Object.hash(point, weight);

  @override
  String toString() => 'HeatPoint($point, $weight)';
}

/// Which traffic tiles to draw. [version] changes when the data is refreshed.
@immutable
class TrafficOverlay {
  const TrafficOverlay(this.source, this.version, this.client);

  final TrafficSource source;
  final String version;
  final http.Client client;
}

/// Camera control of a map view, whatever engine draws it.
abstract class MapViewController {
  /// False until the view has been laid out once; [center] and [zoom] are
  /// then unavailable.
  bool get ready;
  LatLng get center;
  double get zoom;

  /// Compass direction that points up on the screen, in degrees clockwise;
  /// 0 when the map is north-up (always, for engines that do not rotate).
  double get bearing;

  /// Tilt in degrees: 0 looks straight down. Engines without tilt report 0.
  double get pitch;

  /// Largest tilt the engine supports (0 when it cannot tilt at all), so the
  /// UI can hide 3D controls.
  double get maxPitch;

  void move(LatLng center, double zoom);

  /// Moves the camera. Null arguments keep the current value. [duration]
  /// null uses the engine's default easing; Duration.zero jumps.
  void moveCamera({
    LatLng? center,
    double? zoom,
    double? bearing,
    double? pitch,
    Duration? duration,
  });

  /// Insets (logical px) of the area the camera should treat as the visible
  /// map: the camera target is placed at the centre of what remains. Used to
  /// keep the position in the lower third while driving and clear of UI.
  void setPadding(EdgeInsets padding);

  /// Caps how many frames a second the map draws while it animates; null
  /// lifts the cap. For a camera that follows the car for hours: every
  /// frame costs processor time, and 30 a second look the same on the road.
  /// Engines that cannot do it ignore the call.
  void setFrameRateLimit(int? fps);

  /// Notifies when bearing, pitch, zoom or centre change (also by gestures),
  /// at most ~30 times a second: drives the compass button.
  Listenable get cameraChanges;

  /// Shows all of [points], leaving [padding] free for the UI on top.
  ///
  /// It is added to the camera padding (see [setPadding]; the MapLibre engine
  /// also counts the `MediaQuery.padding` of the place it is built in, e.g. a
  /// bottom bar the body extends under, as camera padding).
  void fit(List<LatLng> points, EdgeInsets padding);

  /// Pans by a fraction of the view's shorter side ((1, 0) is a full side
  /// to the east).
  void panBy(Offset fraction);

  /// Turns the map back to north-up.
  void resetNorth();

  void dispose();
}
