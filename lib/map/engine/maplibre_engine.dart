import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../../offline/pmtiles.dart';
import 'flutter_map_engine.dart';
import 'map_engine.dart';
import 'maplibre/bridge.dart';
import 'maplibre/camera.dart';
import 'maplibre/gestures.dart';
import 'maplibre/scene.dart';
import 'maplibre/style.dart';
import 'maplibre/tile_server.dart';

/// MapLibre Native as the map engine (Linux, Wayland).
///
/// The map is not part of Flutter's scene. `libmapsoly_mln.so` draws it into
/// a Wayland subsurface placed *below* the application window; the window is
/// transparent and [MapLibreView] punches a hole into whatever Flutter
/// painted underneath it, so the map shows through while every widget
/// painted later (cards, buttons, sheets) stays on top. Input never reaches
/// the subsurface: gestures are ordinary Flutter pointer events, turned into
/// camera changes here. See docs/map-engine.md.
abstract final class MapLibreEngine {
  /// Offline glyphs and sprites, installed next to the Flutter assets.
  static String get assetsDirectory =>
      '${File(Platform.resolvedExecutable).parent.path}/data/maplibre';

  /// Why this engine cannot be used in this process, or null when it can.
  /// (A failure to create the map later still falls back, see [MapLibreView].)
  static String? unavailableReason() {
    if (!Platform.isLinux) return 'not Linux';
    final env = Platform.environment;
    if ((env['WAYLAND_DISPLAY'] ?? '').isEmpty) return 'not a Wayland session';
    if (env['GDK_BACKEND'] == 'x11') return 'GDK_BACKEND=x11';
    if (MapLibreBridge.load() == null) return MapLibreBridge.loadError;
    if (!Directory('$assetsDirectory/fonts').existsSync()) {
      return 'no map assets in $assetsDirectory';
    }
    return null;
  }
}

/// Camera control for [MapLibreView].
///
/// The camera lives here, in Dart: gestures and the calls below compute the
/// new camera and push it to the native map, so [center] and [zoom] are
/// always known synchronously.
class MapLibreViewController implements MapViewController {
  MapCamera? _camera;
  Size _size = Size.zero;
  _MapLibreViewState? _view;

  /// Parts of the view under other UI (`MediaQuery.padding` where the view
  /// is built). "Centre" for the screen is the centre of what is left.
  EdgeInsets _insets = EdgeInsets.zero;

  /// The visible centre, in logical pixels from the view centre.
  Offset get _visibleCentre => Offset(
    (_insets.left - _insets.right) / 2,
    (_insets.top - _insets.bottom) / 2,
  );

  /// The camera that shows [center] in the middle of the visible part.
  MapCamera _cameraFor(LatLng center, double zoom, double bearing) =>
      MapCamera(center, zoom, bearing).panned(_visibleCentre);

  /// Set when the native map could not be created: the Flutter engine draws
  /// instead and every call is passed on to its controller.
  FlutterMapViewController? _fallback;

  @override
  bool get ready => _fallback?.ready ?? (_camera != null && !_size.isEmpty);

  @override
  LatLng get center => _fallback?.center ?? _camera!.latLngAt(_visibleCentre);

  @override
  double get zoom => _fallback?.zoom ?? _camera!.zoom;

  @override
  double get bearing => _fallback?.bearing ?? _camera?.bearing ?? 0;

  @override
  void move(LatLng center, double zoom) {
    final fallback = _fallback;
    if (fallback != null) return fallback.move(center, zoom);
    _view?._moveCamera(
      _cameraFor(
        center,
        zoom.clamp(MapCamera.minZoom, MapCamera.maxZoom).toDouble(),
        _camera?.bearing ?? 0,
      ),
    );
  }

  @override
  void fit(List<LatLng> points, EdgeInsets padding) {
    final fallback = _fallback;
    if (fallback != null) return fallback.fit(points, padding);
    final camera = MapCamera.fit(
      points,
      _size,
      EdgeInsetsLike(
        padding.left + _insets.left,
        padding.top + _insets.top,
        padding.right + _insets.right,
        padding.bottom + _insets.bottom,
      ),
    );
    if (camera != null) _view?._moveCamera(camera);
  }

  @override
  void panBy(Offset fraction) {
    final fallback = _fallback;
    if (fallback != null) return fallback.panBy(fraction);
    final camera = _camera;
    if (camera == null) return;
    _view?._moveCamera(camera.panned(-fraction * _size.shortestSide));
  }

  @override
  void resetNorth() {
    final fallback = _fallback;
    if (fallback != null) return fallback.resetNorth();
    final camera = _camera;
    if (camera != null) _view?._moveCamera(camera.withBearing(0));
  }

  @override
  void dispose() => _fallback?.dispose();
}

class MapLibreView extends StatefulWidget {
  const MapLibreView({
    super.key,
    required this.controller,
    required this.scene,
    required this.initialCenter,
    required this.initialZoom,
    required this.onLongPress,
    required this.onCameraChanged,
    required this.visible,
  });

  final MapLibreViewController controller;
  final MapScene scene;
  final LatLng initialCenter;
  final double initialZoom;
  final ValueChanged<LatLng> onLongPress;
  final void Function(LatLng center, double zoom) onCameraChanged;

  /// False while something else covers the whole map: the native surface is
  /// then unmapped and nothing is rendered.
  final bool visible;

  @override
  State<MapLibreView> createState() => _MapLibreViewState();
}

class _MapLibreViewState extends State<MapLibreView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _channel = MethodChannel('mapsoly/native_view');

  /// Camera changes are reported to the screen at most this often.
  static const _cameraReportInterval = Duration(milliseconds: 250);

  MapLibreBridge? _bridge;
  Pointer<Void>? _map;
  NativeCallable<Void Function(Int32, Int64)>? _events;
  MapTileServer? _tiles;
  ({int display, int surface, int x, int y})? _handles;
  bool _creating = false;
  bool _disposed = false;
  String? _failure;

  // Geometry the native map was last given.
  Rect? _rect;
  int _scale = 0;

  // Scene: what should be shown, what has been sent, what is being loaded.
  SceneState? _wanted;
  SceneState? _applied;
  String? _loadingStyle;
  int _generation = 0;
  bool _holeOpen = false;
  Timer? _holeTimer;
  final List<Timer> _trafficRemovals = [];
  // Serialising a long route on every rebuild would be wasteful: reuse the
  // string while the screen passes the same list objects.
  Object? _routeIdentity, _alternativesIdentity;
  String _routesJson = SceneState.emptyGeoJson;
  Future<List<({String id, Uint8List rgba, int width, int height})>>? _pins;
  Object? _pinsKey;

  late final MapGestures _gestures = MapGestures(
    camera: () => widget.controller._camera!,
    setCamera: (camera, {animated = false}) =>
        _setCamera(camera, durationMs: animated ? 220 : 0),
    onLongPress: (position) {
      final camera = widget.controller._camera;
      if (camera == null) return;
      widget.onLongPress(
        camera.latLngAt(position - widget.controller._size.center(Offset.zero)),
      );
    },
    viewSize: () => widget.controller._size,
    onAnimating: (on) => on ? _startFling() : _fling.stop(),
  );
  late final Ticker _fling = createTicker(_onFlingTick);

  // Debug hook MAPSOLY_MAP_FLIP=<ms>: switches between the bright and the dark
  // style by itself, alternately after <ms> and after 80 ms (a second switch
  // while the first style is still loading), to exercise style changes
  // without touching the screen.
  bool _ownInitialCamera = false;
  bool _insetsKnown = false;
  bool _benchStarted = false;
  Timer? _benchTimer;
  bool _flipped = false;
  Timer? _flipTimer;
  bool get _dark => widget.scene.dark != _flipped;

  void _scheduleFlip(int ms, bool long) {
    _flipTimer = Timer(Duration(milliseconds: long ? ms : 80), () {
      if (!mounted) return;
      setState(() => _flipped = !_flipped);
      _scheduleFlip(ms, !long);
    });
  }

  Duration _flingLast = Duration.zero;
  Timer? _cameraReport;
  bool _cameraDirty = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ownInitialCamera = widget.controller._camera == null;
    widget.controller
      .._view = this
      .._camera ??= MapCamera(
        widget.initialCenter,
        widget.initialZoom
            .clamp(MapCamera.minZoom, MapCamera.maxZoom)
            .toDouble(),
      );
    final flip = int.tryParse(Platform.environment['MAPSOLY_MAP_FLIP'] ?? '');
    if (flip != null && flip > 0) _scheduleFlip(flip, true);
    _prepare();
  }

  /// Background colours of the bundled styles, read from their `background`
  /// layers; shown in the map's place until the map itself has drawn.
  final Map<String, Color> _styleBackground = {};

  Future<void> _readStyleBackgrounds() async {
    for (final name in const ['bright', 'dark']) {
      final argb = styleBackgroundColor(
        await rootBundle.loadString('assets/styles/$name.json'),
      );
      if (argb != null) _styleBackground[name] = Color(argb);
    }
    if (mounted) setState(() {});
  }

  /// Everything that has to be there before the native map can be created.
  Future<void> _prepare() async {
    try {
      await _readStyleBackgrounds();
      final bridge = MapLibreBridge.load();
      if (bridge == null) throw MapLibreBridge.loadError ?? 'no bridge';
      final h = (await _channel.invokeMapMethod<String, Object?>('handles'))!;
      if (h['wayland'] != true) throw 'the window is not on Wayland';
      final tiles = await MapTileServer.shared();
      if (_disposed) return;
      _bridge = bridge;
      _tiles = tiles;
      _handles = (
        display: h['display']! as int,
        surface: h['surface']! as int,
        x: h['x']! as int,
        y: h['y']! as int,
      );
      _syncGeometry();
    } catch (e) {
      _fail('$e');
    }
  }

  /// Gives up on MapLibre for this view; the Flutter engine takes over.
  void _fail(String reason) {
    if (_disposed || _failure != null) return;
    stderr.writeln('map engine: MapLibre failed ($reason), using Flutter');
    _destroyMap();
    setState(() {
      _failure = reason;
      widget.controller._fallback = FlutterMapViewController();
    });
  }

  @override
  void didChangeMetrics() {
    // Window resized or moved to a screen with another pixel ratio.
    if (mounted) setState(() {});
  }

  /// Reads the widget's rectangle and the pixel ratio and makes the native
  /// surface match; creates the native map on the first call that can.
  void _syncGeometry() {
    final handles = _handles, bridge = _bridge;
    if (_disposed || !mounted || handles == null || bridge == null) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || box.size.isEmpty) return;
    final origin = box.localToGlobal(Offset.zero);
    final rect = Rect.fromLTWH(
      origin.dx.roundToDouble(),
      origin.dy.roundToDouble(),
      box.size.width.roundToDouble(),
      box.size.height.roundToDouble(),
    );
    final scale = View.of(context).devicePixelRatio.round().clamp(1, 4);
    final map = _map;
    if (map != null && scale != _scale) {
      // The pixel ratio is fixed in a MapLibre renderer: start a new one.
      _destroyMap();
    }
    if (_map == null) {
      if (_creating) return;
      _creating = true;
      _create(rect, scale);
      _creating = false;
      return;
    }
    if (rect != _rect) {
      _rect = rect;
      bridge.setGeometry(
        _map!,
        handles.x + rect.left.toInt(),
        handles.y + rect.top.toInt(),
        rect.width.toInt(),
        rect.height.toInt(),
      );
      // The new position applies when GTK commits the window's surface.
      _channel.invokeMethod<void>('commit');
    }
  }

  void _create(Rect rect, int scale) {
    final handles = _handles!, bridge = _bridge!;
    final events = NativeCallable<Void Function(Int32, Int64)>.listener(
      _onNativeEvent,
    );
    final map = bridge.create(
      display: handles.display,
      parentSurface: handles.surface,
      x: handles.x + rect.left.toInt(),
      y: handles.y + rect.top.toInt(),
      width: rect.width.toInt(),
      height: rect.height.toInt(),
      scale: scale,
      onEvent: events.nativeFunction,
    );
    if (map == null) {
      events.close();
      _fail('the native map could not be created (see stderr)');
      return;
    }
    _map = map;
    _events = events;
    _rect = rect;
    _scale = scale;
    _applied = null;
    _appliedBlur = null;
    _loadingStyle = null;
    final env = Platform.environment;
    // Debug hook: one CSV row per rendered frame.
    final log = env['MAPSOLY_MAP_FRAMELOG'];
    if (log != null && log.isNotEmpty) bridge.frameLog(map, log);
    final camera = widget.controller._camera!;
    bridge.setCamera(
      map,
      lat: camera.center.latitude,
      lon: camera.center.longitude,
      zoom: camera.mapLibreZoom,
      bearing: camera.bearing,
    );
    if (!widget.visible) bridge.setVisible(map, false);
    _channel.invokeMethod<void>('commit');
    _syncScene();
  }

  void _destroyMap() {
    final map = _map;
    _map = null;
    for (final t in _trafficRemovals) {
      t.cancel();
    }
    _trafficRemovals.clear();
    _holeTimer?.cancel();
    _holeOpen = false;
    if (map != null) {
      // Joins the map thread: no native callback can arrive after this.
      _bridge!.destroy(map);
    }
    _events?.close();
    _events = null;
    _applied = null;
    _loadingStyle = null;
  }

  void _onNativeEvent(int event, int arg) {
    if (_disposed || _map == null) return;
    switch (event) {
      case MapLibreBridge.eventStyleLoaded when arg == _generation:
        _onStyleLoaded();
      case MapLibreBridge.eventStyleFailed when arg == _generation:
        // Not from inside the native callback: failing tears the map down.
        scheduleMicrotask(() => _fail('the map style could not be loaded'));
      case MapLibreBridge.eventMapFailed:
        scheduleMicrotask(() => _fail('the native map stopped working'));
      case MapLibreBridge.eventBenchDone:
        stderr.writeln('map engine: scripted run finished');
    }
  }

  // ---------------------------------------------------------------- scene

  OverlayColors _colors(ColorScheme c) => OverlayColors(
    primary: cssColor(c.primary.toARGB32()),
    surface: cssColor(c.surface.toARGB32()),
    outline: cssColor(c.outline.toARGB32()),
  );

  static String _trafficKey(TrafficOverlay t) =>
      '${t.source.name}-${t.version.replaceAll(RegExp('[^A-Za-z0-9._-]'), '_')}';

  /// The scene as the strings the native map needs.
  SceneState _describe(MapScene scene, ColorScheme scheme) {
    if (!identical(scene.route, _routeIdentity) ||
        !identical(scene.alternatives, _alternativesIdentity)) {
      _routeIdentity = scene.route;
      _alternativesIdentity = scene.alternatives;
      _routesJson = routesGeoJson(scene.route, scene.alternatives);
    }
    final traffic = scene.traffic;
    final colors = _colors(scheme);
    final packs = _packs(scene);
    return SceneState(
      // A pack that was replaced while the app runs is a new object with,
      // possibly, the same path: the style is reloaded for it as well.
      style: packs == null
          ? _styleLoading
          : '${_dark ? 'dark' : 'bright'}|'
                '${[for (final p in packs) '${p.path}#${identityHashCode(p.archive)}'].join(',')}|'
                '${colors.primary}|${colors.surface}|${colors.outline}',
      routes: _routesJson,
      points: pointsGeoJson(
        position: scene.position,
        from: scene.from,
        to: scene.to,
        picked: scene.picked,
      ),
      accuracy: accuracyGeoJson(scene.position, scene.positionAccuracyM),
      traffic: traffic == null ? null : _trafficKey(traffic),
    );
  }

  /// Style key of "the packs are still being opened": nothing is loaded.
  static const _styleLoading = 'loading';

  /// Debug hooks. MAPSOLY_MAP_PACKS=/a.pmtiles:/b.pmtiles draws these archives
  /// instead of the scene's packs; MAPSOLY_MAP_PACK_SERVER=1 sends even a
  /// single pack through the tile server (to compare with direct reading).
  static final bool _servePacksAlways =
      Platform.environment['MAPSOLY_MAP_PACK_SERVER'] == '1';
  static final List<({String path, PmTilesArchive archive})>? _debugPacks = () {
    final paths = Platform.environment['MAPSOLY_MAP_PACKS'];
    if (paths == null || paths.isEmpty) return null;
    return [
      for (final p in paths.split(':'))
        if (p.isNotEmpty) (path: p, archive: PmTilesArchive.open(p)),
    ];
  }();
  static int _packSetCounter = 0;
  String? _servedPacks;

  /// The packs to draw; null while they are still being opened.
  List<({String path, PmTilesArchive archive})>? _packs(MapScene scene) {
    final debug = _debugPacks;
    if (debug != null) return debug;
    if (scene.offlineLoading) return null;
    return [for (final m in scene.packs) (path: m.path, archive: m.archive)];
  }

  // Blur: MAPSOLY_MAP_BLUR=0 turns it off, =strip adds a 64 px strip along
  // the bottom edge whatever the scene says (for measuring).
  static const _blurSigma = 18.0;
  static final String _blurMode =
      Platform.environment['MAPSOLY_MAP_BLUR'] ?? '';
  List<double> _wantedBlur = const [];
  List<double>? _appliedBlur;

  List<double> _blurOf(MapScene scene, Size size) {
    if (_blurMode == '0') return const [];
    return [
      for (final r in scene.blurRects) ...[r.left, r.top, r.width, r.height],
      if (_blurMode == 'strip') ...[0, size.height - 64, size.width, 64],
    ];
  }

  /// Sends whatever differs between the wanted scene and the shown one.
  void _syncScene() {
    final map = _map, wanted = _wanted, bridge = _bridge;
    if (map == null || wanted == null || bridge == null) return;
    if (!listEquals(_wantedBlur, _appliedBlur)) {
      _appliedBlur = _wantedBlur;
      bridge.setBlur(map, _wantedBlur, _blurSigma);
    }
    if (wanted.style == _styleLoading) return;
    final traffic = widget.scene.traffic;
    if (traffic != null) _tiles!.trafficClient = traffic.client;
    for (final op in diffScene(_applied, wanted)) {
      switch (op) {
        case LoadStyle(:final style):
          if (_loadingStyle != style) _loadStyle(style);
          return;
        case SetGeoJson(:final source, :final json):
          bridge.setGeoJson(map, source, json);
        case SetTraffic(:final remove, :final add):
          if (add != null) {
            final id = '${MapIds.trafficPrefix}$add';
            final at = add.indexOf('-');
            bridge.addSource(
              map,
              id,
              trafficSourceJson(
                _tiles!.urlTemplate(
                  add.substring(0, at),
                  add.substring(at + 1),
                ),
              ),
            );
            bridge.addLayer(
              map,
              trafficLayerJson(add),
              MapIds.firstOverlayLayer,
            );
          }
          if (remove != null) {
            void drop() {
              final m = _map;
              if (m == null) return;
              bridge.removeLayer(m, '${MapIds.trafficPrefix}$remove');
              bridge.removeSource(m, '${MapIds.trafficPrefix}$remove');
            }

            // A refreshed layer replaces the old one once its tiles had time
            // to load, so the traffic does not blink every refresh.
            if (add == null) {
              drop();
            } else {
              _trafficRemovals.add(Timer(const Duration(seconds: 10), drop));
            }
          }
      }
    }
    _applied = wanted;
  }

  Future<void> _loadStyle(String key) async {
    _loadingStyle = key;
    final scene = widget.scene;
    final colors = _colors(Theme.of(context).colorScheme);
    final dark = _dark;
    final name = dark ? 'dark' : 'bright';
    final packs = _packs(scene) ?? const [];
    final String json;
    if (packs.isNotEmpty) {
      // One pack: MapLibre reads the archive itself. Several: the tile
      // server answers each tile from whichever pack has it.
      VectorTiles? served;
      if (packs.length > 1 || _servePacksAlways) {
        final archives = [for (final p in packs) p.archive];
        final range = zoomRangeOfPacks(archives);
        final old = _servedPacks;
        _servedPacks = 'set${++_packSetCounter}';
        served = VectorTiles(
          _tiles!.servePacks(_servedPacks!, archives),
          range.min,
          range.max,
        );
        if (old != null) _tiles!.dropPacks(old);
      }
      json = buildVectorStyle(
        bundledStyleJson: await rootBundle.loadString(
          'assets/styles/$name.json',
        ),
        name: name,
        pmtilesPath: served == null ? packs.single.path : null,
        tiles: served,
        assetsDir: MapLibreEngine.assetsDirectory,
        colors: colors,
      );
    } else {
      json = buildRasterStyle(
        tilesUrl: _tiles!.urlTemplate('osm'),
        dark: dark,
        highDensity: _scale > 1,
        assetsDir: MapLibreEngine.assetsDirectory,
        colors: colors,
      );
    }
    final map = _map;
    // The scene may have moved on while the asset was read.
    if (_disposed || map == null || _loadingStyle != key) return;
    for (final t in _trafficRemovals) {
      t.cancel();
    }
    _trafficRemovals.clear();
    _bridge!.setStyle(map, json, ++_generation);
  }

  Future<void> _onStyleLoaded() async {
    final key = _loadingStyle;
    final map = _map;
    if (key == null || map == null) return;
    final scheme = Theme.of(context).colorScheme;
    final pins = await _pinImages(scheme, _scale);
    if (_disposed || _map != map || _loadingStyle != key) return;
    for (final p in pins) {
      _bridge!.addImage(
        map,
        p.id,
        p.rgba,
        p.width,
        p.height,
        _scale.toDouble(),
      );
    }
    // The new style has the overlay sources, all empty, and no traffic.
    _applied = SceneState(style: key);
    _loadingStyle = null;
    _syncScene();
    // Debug hook: the scripted camera run of the prototype.
    final bench = Platform.environment['MAPSOLY_MAP_BENCH'];
    if (bench != null && bench.isNotEmpty && !_benchStarted) {
      // Once, 3 s after the last style load of the start-up (the pack's
      // style replaces the online one as soon as the pack is opened).
      _benchTimer?.cancel();
      _benchTimer = Timer(const Duration(seconds: 3), () {
        final m = _map;
        if (m == null || _benchStarted) return;
        _benchStarted = true;
        _bridge!.benchStart(m, bench);
      });
    }
    // Only now is there something to see below the window.
    _holeTimer?.cancel();
    _holeTimer = Timer(const Duration(milliseconds: 200), () {
      if (mounted && _map != null) setState(() => _holeOpen = true);
    });
  }

  /// The two pin markers, drawn from the Material icons in the scheme's
  /// colours (the same pictures the Flutter engine shows).
  Future<List<({String id, Uint8List rgba, int width, int height})>> _pinImages(
    ColorScheme scheme,
    int scale,
  ) {
    final key = (scheme.error, scheme.tertiary, scale);
    if (_pinsKey == key && _pins != null) return _pins!;
    _pinsKey = key;
    Future<({String id, Uint8List rgba, int width, int height})> draw(
      String id,
      IconData icon,
      Color color,
    ) async {
      final side = 36 * scale;
      final recorder = ui.PictureRecorder();
      final painter = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(
          text: String.fromCharCode(icon.codePoint),
          style: TextStyle(
            fontFamily: icon.fontFamily,
            package: icon.fontPackage,
            fontSize: side.toDouble(),
            height: 1,
            color: color,
          ),
        ),
      )..layout();
      painter.paint(Canvas(recorder), Offset.zero);
      final image = await recorder.endRecording().toImage(side, side);
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      image.dispose();
      painter.dispose();
      return (
        id: id,
        rgba: data!.buffer.asUint8List(),
        width: side,
        height: side,
      );
    }

    return _pins = Future.wait([
      draw(MapIds.pinTo, Icons.place, scheme.error),
      draw(MapIds.pinPicked, Icons.location_on, scheme.tertiary),
    ]);
  }

  // --------------------------------------------------------------- camera

  /// A camera change asked for by the screen: eased when it is a short hop,
  /// a jump when the target is far away.
  void _moveCamera(MapCamera target) {
    final current = widget.controller._camera;
    final size = widget.controller._size;
    var duration = 0;
    if (current != null && !size.isEmpty && _map != null) {
      final near =
          current.screenOf(target.center).distance < 2 * size.longestSide &&
          (current.zoom - target.zoom).abs() < 2.5;
      if (near) duration = 350;
    }
    _setCamera(target, durationMs: duration);
  }

  void _setCamera(MapCamera camera, {int durationMs = 0}) {
    final controller = widget.controller;
    if (camera == controller._camera) return;
    controller._camera = camera;
    final map = _map;
    if (map != null) {
      _bridge!.setCamera(
        map,
        lat: camera.center.latitude,
        lon: camera.center.longitude,
        zoom: camera.mapLibreZoom,
        bearing: camera.bearing,
        durationMs: durationMs,
      );
    }
    // Report now and then while it moves, and once after it stopped.
    _cameraDirty = true;
    _cameraReport ??= Timer(_cameraReportInterval, _reportCamera);
  }

  void _reportCamera() {
    _cameraReport = null;
    if (!_cameraDirty || _disposed) return;
    _cameraDirty = false;
    final controller = widget.controller;
    widget.onCameraChanged(controller.center, controller._camera!.zoom);
  }

  void _startFling() {
    _flingLast = Duration.zero;
    if (!_fling.isActive) _fling.start();
  }

  void _onFlingTick(Duration elapsed) {
    final dt = (elapsed - _flingLast).inMicroseconds / 1e6;
    _flingLast = elapsed;
    _gestures.advance(dt);
  }

  static double _seconds(PointerEvent e) => e.timeStamp.inMicroseconds / 1e6;

  // ------------------------------------------------------------ lifecycle

  @override
  void didUpdateWidget(MapLibreView old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller._view = null;
      widget.controller._view = this;
    }
    final map = _map;
    if (map != null && old.visible != widget.visible) {
      _bridge!.setVisible(map, widget.visible);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    if (widget.controller._view == this) widget.controller._view = null;
    _cameraReport?.cancel();
    _flipTimer?.cancel();
    _benchTimer?.cancel();
    _gestures.dispose();
    _fling.dispose();
    _destroyMap();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fallback = widget.controller._fallback;
    if (fallback != null) {
      return Offstage(
        offstage: !widget.visible,
        child: FlutterMapView(
          controller: fallback,
          scene: widget.scene,
          initialCenter:
              widget.controller._camera?.center ?? widget.initialCenter,
          initialZoom: widget.controller._camera?.zoom ?? widget.initialZoom,
          onLongPress: widget.onLongPress,
          onCameraChanged: widget.onCameraChanged,
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    // UI the view continues under (a bottom bar with extendBody): the
    // attribution and the "centre" of the camera keep clear of it.
    final insets = MediaQuery.paddingOf(context);
    final controller = widget.controller;
    if (controller._insets != insets) {
      final first = !_insetsKnown;
      _insetsKnown = true;
      final camera = controller._camera;
      // The initial centre is meant for the visible part as well.
      final centre = first && _ownInitialCamera ? camera?.center : null;
      controller._insets = insets;
      if (centre != null) {
        controller._camera = controller._cameraFor(
          centre,
          camera!.zoom,
          camera.bearing,
        );
      }
    }
    _wanted = _describe(widget.scene, scheme);
    return LayoutBuilder(
      builder: (context, constraints) {
        widget.controller._size = constraints.biggest;
        _wantedBlur = _blurOf(widget.scene, constraints.biggest);
        _syncScene();
        // The rectangle on screen is known after layout.
        WidgetsBinding.instance.addPostFrameCallback((_) => _syncGeometry());
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) =>
              _gestures.pointerDown(e.pointer, e.localPosition, _seconds(e)),
          onPointerMove: (e) =>
              _gestures.pointerMove(e.pointer, e.localPosition, _seconds(e)),
          onPointerUp: (e) =>
              _gestures.pointerUp(e.pointer, e.localPosition, _seconds(e)),
          onPointerCancel: (e) => _gestures.pointerCancel(e.pointer),
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) {
              _gestures.scroll(e.localPosition, e.scrollDelta.dy);
            }
          },
          child: CustomPaint(
            painter: _HolePainter(
              open: _holeOpen && widget.visible,
              // Until the map is up, the style's own background colour
              // instead of whatever is behind the window.
              placeholder:
                  _styleBackground[_dark ? 'dark' : 'bright'] ??
                  (_dark ? const Color(0xFF14181C) : const Color(0xFFF8F4F0)),
            ),
            child: Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: insets + const EdgeInsets.all(2),
                child: Text(
                  '© OpenStreetMap contributors',
                  style: TextStyle(
                    fontSize: 10,
                    color: scheme.onSurface.withValues(alpha: 0.7),
                    backgroundColor: scheme.surface.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Clears the pixels of the map's rectangle, including anything painted
/// below this widget (the scaffold's background), so the surface under the
/// window shows through. Widgets painted afterwards are unaffected.
class _HolePainter extends CustomPainter {
  const _HolePainter({required this.open, required this.placeholder});

  final bool open;
  final Color placeholder;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      open
          ? (Paint()..blendMode = BlendMode.clear)
          : (Paint()..color = placeholder),
    );
  }

  @override
  bool shouldRepaint(_HolePainter old) =>
      old.open != open || old.placeholder != placeholder;
}
