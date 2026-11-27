import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../../offline/offline_map.dart';
import '../../traffic/traffic.dart';

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
    this.traffic,
    this.route,
    this.alternatives = const [],
    this.from,
    this.to,
    this.picked,
    this.position,
    this.positionAccuracyM,
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

  /// Traffic overlay to draw above the roads; null when off or not loaded.
  final TrafficOverlay? traffic;

  /// Selected route line and the other alternatives (drawn muted, below).
  final List<LatLng>? route;
  final List<List<LatLng>> alternatives;

  /// Route endpoints and the point picked by a long press or a search.
  final LatLng? from, to, picked;

  /// Device position with its accuracy radius in metres.
  final LatLng? position;
  final double? positionAccuracyM;
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

  void move(LatLng center, double zoom);

  /// Shows all of [points], leaving [padding] free for the UI on top.
  ///
  /// The MapLibre engine additionally keeps clear of the `MediaQuery.padding`
  /// of the place it is built in (a bottom bar the body extends under), for
  /// this call and for [center]/[move]: there "centre" is the centre of the
  /// part of the view that is not under such insets.
  void fit(List<LatLng> points, EdgeInsets padding);

  /// Pans by a fraction of the view's shorter side ((1, 0) is a full side
  /// to the east).
  void panBy(Offset fraction);

  /// Turns the map back to north-up.
  void resetNorth();

  void dispose();
}
