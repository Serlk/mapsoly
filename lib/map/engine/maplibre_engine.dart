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

import '../../debug_stats.dart';
import '../../offline/pmtiles.dart';
import '../../platform/android_properties.dart';
import 'flutter_map_engine.dart';
import '../position_arrow.dart';
import 'map_engine.dart';
import 'maplibre/bridge.dart';
import 'maplibre/camera.dart';
import 'maplibre/gestures.dart';
import 'maplibre/scene.dart';
import 'maplibre/style.dart';
import 'maplibre/surface.dart';
import 'maplibre/tile_server.dart';

/// MapLibre Native as the map engine (Linux on Wayland, Android).
///
/// On Linux the map is not part of Flutter's scene. `libmapsoly_mln.so` draws
/// it into a Wayland subsurface placed *below* the application window; the
/// window is transparent and [MapLibreView] punches a hole into whatever
/// Flutter painted underneath it, so the map shows through while every widget
/// painted later (cards, buttons, sheets) stays on top. On Android the same
/// library draws into a Flutter texture, shown by a `Texture` widget. That
/// difference is all in [MapSurface]. Input never reaches the native map:
/// gestures are ordinary Flutter pointer events, turned into camera changes
/// here. See docs/map-engine.md.
abstract final class MapLibreEngine {
  /// Why this engine cannot be used in this process, or null when it can.
  /// (A failure to create the map later still falls back, see [MapLibreView].)
  static String? unavailableReason() {
    if (Platform.isAndroid) {
      // The glyphs and sprites are unpacked from the APK when the view
      // starts; if they are missing the view falls back by itself.
      return MapLibreBridge.load() == null ? MapLibreBridge.loadError : null;
    }
    if (!Platform.isLinux) return 'not Linux';
    final env = Platform.environment;
    if ((env['WAYLAND_DISPLAY'] ?? '').isEmpty) return 'not a Wayland session';
    if (env['GDK_BACKEND'] == 'x11') return 'GDK_BACKEND=x11';
    if (MapLibreBridge.load() == null) return MapLibreBridge.loadError;
    final assets = WaylandMapSurface.bundleAssetsDirectory;
    if (!Directory('$assets/fonts').existsSync()) {
      return 'no map assets in $assets';
    }
    return null;
  }
}

/// Camera control for [MapLibreView].
///
/// The camera lives here, in Dart: gestures and the calls below compute the
/// new camera and push it to the native map, so [center], [zoom], [bearing]
/// and [pitch] are always known synchronously. While the native map eases
/// towards a new camera, the same interpolation is evaluated here, so the
/// getters (and [cameraChanges]) follow what is on screen.
class MapLibreViewController implements MapViewController {
  /// Where the camera is, or is heading (the end of a running animation).
  MapCamera? _camera;
  Size _size = Size.zero;
  _MapLibreViewState? _view;
  final _changes = _CameraChanges();

  // The animation the native map is running, mirrored.
  CameraTween? _tween;
  final Stopwatch _tweenClock = Stopwatch();
  int _tweenMs = 0;

  /// Insets set by the screen and those of the place the view is built in
  /// (`MediaQuery.padding`: a bottom bar the body extends under). The camera
  /// target is shown at the centre of what the larger of them leave free.
  EdgeInsetsLike _userPadding = const EdgeInsetsLike(0, 0, 0, 0);
  EdgeInsetsLike _viewInsets = const EdgeInsetsLike(0, 0, 0, 0);
  EdgeInsetsLike get _padding => _userPadding.max(_viewInsets);

  /// Where the camera target is drawn, from the view's top-left corner.
  Offset get _origin => _size.center(Offset.zero) + _padding.centreOffset;

  /// Set when the native map could not be created: the Flutter engine draws
  /// instead and every call is passed on to its controller.
  FlutterMapViewController? _fallback;

  /// What is on screen right now (differs from [_camera] during an animation).
  MapCamera? get _shown {
    final tween = _tween;
    if (tween == null) return _camera;
    final t = _tweenClock.elapsedMilliseconds / _tweenMs;
    if (t >= 1) {
      _tween = null;
      return _camera;
    }
    return tween.at(t);
  }

  @override
  bool get ready => _fallback?.ready ?? (_camera != null && !_size.isEmpty);

  @override
  LatLng get center => _fallback?.center ?? _shown!.center;

  @override
  double get zoom => _fallback?.zoom ?? _shown!.zoom;

  @override
  double get bearing => _fallback?.bearing ?? _shown?.bearing ?? 0;

  @override
  double get pitch => _fallback?.pitch ?? _shown?.pitch ?? 0;

  @override
  double get maxPitch => _fallback?.maxPitch ?? MapCamera.maxPitch;

  @override
  Listenable get cameraChanges => _fallback?.cameraChanges ?? _changes;

  @override
  void move(LatLng center, double zoom) =>
      moveCamera(center: center, zoom: zoom);

  DateTime? _lastMove;

  @override
  void moveCamera({
    LatLng? center,
    double? zoom,
    double? bearing,
    double? pitch,
    Duration? duration,
  }) {
    final fallback = _fallback;
    if (fallback != null) {
      return fallback.moveCamera(
        center: center,
        zoom: zoom,
        bearing: bearing,
        pitch: pitch,
        duration: duration,
      );
    }
    final current = _camera;
    if (current == null) return;
    final target = current.copyWith(
      center: center,
      zoom: zoom?.clamp(MapCamera.minZoom, MapCamera.maxZoom).toDouble(),
      bearing: bearing == null ? null : MapCamera.normalizeBearing(bearing),
      pitch: pitch?.clamp(0.0, MapCamera.maxPitch).toDouble(),
    );
    final now = DateTime.now();
    final sinceLast = _lastMove == null
        ? null
        : now.difference(_lastMove!).inMilliseconds;
    _lastMove = now;
    final plan = planCameraMove(
      requestedMs: duration?.inMilliseconds,
      sinceLastMoveMs: sinceLast,
      screenDistance: (_shown ?? current).screenOf(target.center).distance,
      zoomChange: (target.zoom - current.zoom).abs(),
      viewSide: _size.longestSide,
    );
    _view?._setCamera(target, durationMs: plan.ms, linear: plan.linear);
  }

  int _maxFps = 0;

  @override
  void setFrameRateLimit(int? fps) {
    final wanted = fps ?? 0;
    if (wanted == _maxFps) return;
    _maxFps = wanted;
    _view?._applyMaxFps();
  }

  @override
  void setPadding(EdgeInsets padding) {
    final fallback = _fallback;
    if (fallback != null) return fallback.setPadding(padding);
    final p = EdgeInsetsLike(
      padding.left,
      padding.top,
      padding.right,
      padding.bottom,
    );
    if (p == _userPadding) return;
    _userPadding = p;
    _view?._paddingChanged();
  }

  @override
  void fit(List<LatLng> points, EdgeInsets padding) {
    final fallback = _fallback;
    if (fallback != null) return fallback.fit(points, padding);
    final camera = MapCamera.fit(
      points,
      _size,
      EdgeInsetsLike(padding.left, padding.top, padding.right, padding.bottom),
      cameraPadding: _padding,
    );
    if (camera != null) {
      _view?._setCamera(camera, durationMs: _shown == null ? 0 : 350);
    }
  }

  @override
  void panBy(Offset fraction) {
    final fallback = _fallback;
    if (fallback != null) return fallback.panBy(fraction);
    final camera = _camera;
    if (camera == null) return;
    _view?._setCamera(
      camera.panned(-fraction * _size.shortestSide),
      durationMs: 250,
    );
  }

  @override
  void resetNorth() => moveCamera(bearing: 0);

  @override
  void dispose() {
    _fallback?.dispose();
    _changes.dispose();
  }
}

/// One line about the engine in the app's log: stderr, and logcat on Android
/// (where stderr goes nowhere).
void mapEngineLog(String line) =>
    Platform.isAndroid ? debugPrint(line) : stderr.writeln(line);

class _CameraChanges extends ChangeNotifier {
  void notify() => notifyListeners();
}

/// How a camera move asked for by the screen is animated.
///
/// An explicit duration is taken as it is (0 jumps). Otherwise: calls that
/// come in a steady stream (a position update about once a second while
/// driving) are run at constant speed for a little longer than their
/// interval, so they blend into one continuous motion instead of
/// start-stop; a single call eases over a short hop and jumps when the
/// target is far away.
({int ms, bool linear}) planCameraMove({
  required int? requestedMs,
  required int? sinceLastMoveMs,
  required double screenDistance,
  required double zoomChange,
  required double viewSide,
}) {
  if (requestedMs != null) return (ms: requestedMs, linear: false);
  final far = screenDistance > 2 * viewSide || zoomChange >= 2.5;
  if (far) return (ms: 0, linear: false);
  if (sinceLastMoveMs != null &&
      sinceLastMoveMs >= 150 &&
      sinceLastMoveMs <= 1600) {
    return (
      ms: (sinceLastMoveMs * 1.15).round().clamp(250, 1800),
      linear: true,
    );
  }
  return (ms: 350, linear: false);
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
  /// Camera changes are reported to the screen at most this often.
  static const _cameraReportInterval = Duration(milliseconds: 250);

  MapLibreBridge? _bridge;
  Pointer<Void>? _map;
  NativeCallable<Void Function(Int32, Int64)>? _events;
  MapTileServer? _tiles;
  final MapSurface _surface = MapSurface.forPlatform();
  bool _prepared = false;
  bool _creating = false;
  bool _disposed = false;
  String? _failure;

  // Geometry the native map was last given. [_ratio] is the map's pixel
  // ratio; [_scale] the whole number at or above it, in which the images the
  // map is given (pins, the position arrow) are drawn.
  Rect? _rect;
  double _ratio = 0;
  int _scale = 0;

  // Scene: what should be shown, what has been sent, what is being loaded.
  DateTime? _puckAt;
  SceneState? _wanted;
  SceneState? _applied;
  String? _loadingStyle;
  int _generation = 0;
  bool _holeOpen = false;
  Timer? _holeTimer;
  final List<Timer> _trafficRemovals = [];
  // Serialising a long route on every rebuild would be wasteful: reuse the
  // string while the screen passes the same list objects.
  Object? _routeIdentity, _routeTrafficIdentity;
  List<List<LatLng>>? _alternativesIdentity;
  String _routesJson = SceneState.emptyGeoJson;
  Object? _heatIdentity;
  String _heatJson = SceneState.emptyGeoJson;
  Future<List<({String id, Uint8List rgba, int width, int height})>>? _pins;
  Object? _pinsKey;

  late final MapGestures _gestures = MapGestures(
    // What is on screen: a finger that lands during an animation takes
    // over from there.
    camera: () => widget.controller._shown!,
    setCamera: (camera, {animated = false}) =>
        _setCamera(camera, durationMs: animated ? 220 : 0),
    onLongPress: (position) {
      final camera = widget.controller._shown;
      if (camera == null) return;
      widget.onLongPress(camera.latLngAt(position - widget.controller._origin));
    },
    origin: () => widget.controller._origin,
    onAnimating: (on) => on ? _startFling() : _fling.stop(),
  );
  late final Ticker _fling = createTicker(_onFlingTick);

  // Debug hook MAPSOLY_MAP_FLIP=<ms>: switches between the bright and the dark
  // style by itself, alternately after <ms> and after 80 ms (a second switch
  // while the first style is still loading), to exercise style changes
  // without touching the screen.
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
  Timer? _cameraTick;
  Timer? _snapshotTimer;
  bool _cameraDirty = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller
      .._view = this
      .._camera ??= MapCamera(
        widget.initialCenter,
        widget.initialZoom
            .clamp(MapCamera.minZoom, MapCamera.maxZoom)
            .toDouble(),
        0,
        (_debugPitch ?? 0).clamp(0, MapCamera.maxPitch).toDouble(),
      );
    final flip = int.tryParse(Platform.environment['MAPSOLY_MAP_FLIP'] ?? '');
    if (flip != null && flip > 0) _scheduleFlip(flip, true);
    _prepare();
  }

  /// The map as a widget where it is part of Flutter's scene (Android), null
  /// where it lies below the window (Wayland). Built once: the surface's
  /// widget listens for its texture itself.
  late final Widget? _mapView = _surface.buildView();
  bool get _inFlutterScene => _mapView != null;

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
      _surface.onError = _fail;
      await _surface.prepare();
      final tiles = await MapTileServer.shared();
      if (_disposed) return;
      _bridge = bridge;
      _tiles = tiles;
      _prepared = true;
      _syncGeometry();
    } catch (e) {
      _fail('$e');
    }
  }

  /// Gives up on MapLibre for this view; the Flutter engine takes over.
  void _fail(String reason) {
    if (_disposed || _failure != null) return;
    mapEngineLog('map engine: MapLibre failed ($reason), using Flutter');
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
    final bridge = _bridge;
    if (_disposed || !mounted || !_prepared || bridge == null) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || box.size.isEmpty) return;
    final origin = box.localToGlobal(Offset.zero);
    // A subsurface sits on whole logical pixels; a texture covers the box
    // exactly (logical sizes are fractions at Android's densities).
    final rect = _inFlutterScene
        ? origin & box.size
        : Rect.fromLTWH(
            origin.dx.roundToDouble(),
            origin.dy.roundToDouble(),
            box.size.width.roundToDouble(),
            box.size.height.roundToDouble(),
          );
    final ratio = _surface.ratioFor(View.of(context).devicePixelRatio);
    final map = _map;
    if (map != null && ratio != _ratio) {
      // The pixel ratio is fixed in a MapLibre renderer: start a new one.
      _destroyMap();
    }
    if (_map == null) {
      if (_creating) return;
      _creating = true;
      _create(rect, ratio);
      _creating = false;
      return;
    }
    if (rect != _rect) {
      _rect = rect;
      _surface.setGeometry(rect);
    }
  }

  void _create(Rect rect, double ratio) {
    final bridge = _bridge!;
    final events = NativeCallable<Void Function(Int32, Int64)>.listener(
      _onNativeEvent,
    );
    final map = _surface.create(bridge, rect, ratio, events.nativeFunction);
    if (map == null) {
      events.close();
      _fail('the native map could not be created (see stderr)');
      return;
    }
    _map = map;
    _events = events;
    _rect = rect;
    _ratio = ratio;
    _scale = ratio.ceil();
    _applied = null;
    _appliedBlur = null;
    _loadingStyle = null;
    final env = Platform.environment;
    // Debug hook: one CSV row per rendered frame. On Android, which has no
    // environment to set, the system property debug.mapsoly.map_framelog
    // (a path the app may write, e.g. in its folder on the shared storage).
    final log = Platform.isAndroid
        ? androidSystemProperty('debug.mapsoly.map_framelog')
        : env['MAPSOLY_MAP_FRAMELOG'];
    if (log != null && log.isNotEmpty) bridge.frameLog(map, log);
    // Debug hook MAPSOLY_MAP_SNAPSHOTS=<prefix>,<period ms>,<count>: writes
    // the map's own frames (without the Flutter layer) to <prefix>-NN.ppm.
    final shots = (env['MAPSOLY_MAP_SNAPSHOTS'] ?? '').split(',');
    if (shots.length == 3 && _snapshotTimer == null) {
      final period = int.tryParse(shots[1]) ?? 1000;
      final count = int.tryParse(shots[2]) ?? 1;
      var n = 0;
      _snapshotTimer = Timer.periodic(Duration(milliseconds: period), (t) {
        final m = _map;
        if (m == null || n >= count) return t.cancel();
        bridge.snapshot(m, '${shots[0]}-${'${n++}'.padLeft(2, '0')}.ppm');
      });
    }
    _sendCamera(widget.controller._camera!, 0, false);
    if (!widget.visible) bridge.setVisible(map, false);
    if (widget.controller._maxFps != 0) {
      bridge.setMaxFps(map, widget.controller._maxFps);
    }
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
      _surface.detach();
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
        mapEngineLog('map engine: scripted run finished');
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

  static bool _sameShapes(List<List<LatLng>> a, List<List<LatLng>>? b) {
    if (b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  /// The scene as the strings the native map needs.
  SceneState _describe(MapScene scene, ColorScheme scheme) {
    if (!identical(scene.route, _routeIdentity) ||
        // The screen builds the list of alternatives anew every time: it
        // is the shapes in it that say whether anything changed. (Compared
        // as a list it never matched, and the whole route was written out
        // as GeoJSON again on every rebuild.)
        !_sameShapes(scene.alternatives, _alternativesIdentity) ||
        !identical(scene.routeTraffic, _routeTrafficIdentity)) {
      _routeIdentity = scene.route;
      _alternativesIdentity = scene.alternatives;
      _routeTrafficIdentity = scene.routeTraffic;
      _routesJson = routesGeoJson(
        scene.route,
        scene.alternatives,
        scene.routeTraffic,
      );
    }
    if (!identical(scene.signalHeat, _heatIdentity)) {
      _heatIdentity = scene.signalHeat;
      _heatJson = heatGeoJson(scene.signalHeat);
    }
    final traffic = scene.traffic;
    final position = scene.position;
    final colors = _colors(scheme);
    final packs = _packs(scene);
    return SceneState(
      // A pack that was replaced while the app runs is a new object with,
      // possibly, the same path: the style is reloaded for it as well.
      style: packs == null
          ? _styleLoading
          : '${_dark ? 'dark' : 'bright'}|'
                '${[for (final p in packs) '${p.path}#${identityHashCode(p.archive)}'].join(',')}|'
                '${scene.buildings3d ? '3d' : ''}|'
                // The heat map's source and layer are part of the style.
                '${scene.signalHeat != null ? 'heat' : ''}|'
                '${colors.primary}|${colors.surface}|${colors.outline}|'
                '${scene.positionArrow.name}',
      routes: _routesJson,
      // The position itself is the native marker below, not a feature.
      points: pointsGeoJson(
        from: scene.from,
        to: scene.to,
        picked: scene.picked,
      ),
      puck: position == null
          ? null
          : PuckState(
              // A centimetre and a degree: finer than the eye, and coarse
              // enough for an unchanged position to stay equal.
              lat: double.parse(position.latitude.toStringAsFixed(7)),
              lon: double.parse(position.longitude.toStringAsFixed(7)),
              heading: scene.positionHeading?.roundToDouble(),
              accuracyM: (scene.positionAccuracyM ?? 0).roundToDouble(),
            ),
      heat: _heatJson,
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
  // Debug hook MAPSOLY_MAP_3D=<pitch>: extruded buildings on and the camera
  // tilted by that many degrees from the start.
  static final double? _debugPitch = double.tryParse(
    Platform.environment['MAPSOLY_MAP_3D'] ?? '',
  );
  static bool get _debug3d => _debugPitch != null;
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
    // A map inside Flutter's scene is blurred by the BackdropFilter of the
    // glass surfaces themselves.
    if (_blurMode == '0' || _inFlutterScene) return const [];
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
        case SetPuck(:final puck):
          final now = DateTime.now();
          final last = _puckAt;
          _puckAt = puck == null ? null : now;
          // As long as the fixes are apart, so that it arrives when the
          // next one does and never stands still in between. After a
          // pause (or the first time) it is simply put there.
          final since = last == null ? 0 : now.difference(last).inMilliseconds;
          DebugStats.count('map.puck');
          bridge.setPuck(
            map,
            lat: puck?.lat ?? double.nan,
            lon: puck?.lon ?? double.nan,
            bearing: puck?.heading ?? double.nan,
            accuracyM: puck?.accuracyM ?? 0,
            durationMs: since > 3000 ? 0 : since.clamp(0, 2000),
          );
        case SetGeoJson(:final source, :final json):
          DebugStats.count('map.geojson.$source');
          bridge.setGeoJson(map, source, json);
        case SetTraffic(:final remove, :final add):
          if (add != null) {
            final id = '${MapIds.trafficPrefix}$add';
            if (debugSkip?.hasMatch(id) ?? false) break;
            final at = add.indexOf('-');
            bridge.addSource(
              map,
              id,
              trafficSourceJson(
                _tiles!.urlTemplate(
                  '${add.substring(0, at)}4',
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
        buildings3d: scene.buildings3d || _debug3d,
        signalHeat: scene.signalHeat != null,
        assetsDir: _surface.assetsDirectory,
        colors: colors,
      );
    } else {
      json = buildRasterStyle(
        tilesUrl: _tiles!.urlTemplate('osm'),
        dark: dark,
        highDensity: _scale > 1,
        signalHeat: scene.signalHeat != null,
        assetsDir: _surface.assetsDirectory,
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
    final pins = await _pinImages(scheme, _scale, widget.scene.positionArrow);
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
    PositionArrow arrow,
  ) {
    final key = (
      scheme.error,
      scheme.tertiary,
      scheme.primary,
      scheme.surface,
      scale,
      arrow,
    );
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

    Future<({String id, Uint8List rgba, int width, int height})>
    drawArrow() async {
      final side = 44 * scale;
      final recorder = ui.PictureRecorder();
      paintPositionArrow(
        Canvas(recorder),
        side.toDouble(),
        arrow,
        color: scheme.primary,
        outline: scheme.surface,
      );
      final image = await recorder.endRecording().toImage(side, side);
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      image.dispose();
      return (
        id: MapIds.arrow,
        rgba: data!.buffer.asUint8List(),
        width: side,
        height: side,
      );
    }

    return _pins = Future.wait([
      drawArrow(),
      draw(MapIds.pinTo, Icons.place, scheme.error),
      draw(MapIds.pinPicked, Icons.location_on, scheme.tertiary),
    ]);
  }

  // --------------------------------------------------------------- camera

  void _sendCamera(MapCamera camera, int durationMs, bool linear) {
    final map = _map;
    if (map == null) return;
    final p = widget.controller._padding;
    _bridge!.setCamera(
      map,
      lat: camera.center.latitude,
      lon: camera.center.longitude,
      zoom: camera.mapLibreZoom,
      bearing: camera.bearing,
      pitch: camera.pitch,
      padding: [p.left, p.top, p.right, p.bottom],
      durationMs: durationMs,
      linear: linear,
    );
  }

  /// Makes [camera] the camera: at once, or eased over [durationMs].
  void _setCamera(MapCamera camera, {int durationMs = 0, bool linear = false}) {
    DebugStats.count('map.setCamera');
    final controller = widget.controller;
    camera = camera.copyWith(viewHeight: controller._size.height);
    final shown = controller._shown;
    if (camera == controller._camera && controller._tween == null) return;
    controller._camera = camera;
    if (durationMs > 0 && shown != null && _map != null) {
      controller
        .._tween = CameraTween(shown, camera, linear: linear)
        .._tweenMs = durationMs
        .._tweenClock.reset()
        .._tweenClock.start();
    } else {
      controller._tween = null;
      durationMs = 0;
    }
    _sendCamera(camera, durationMs, linear);
    _cameraMoved();
  }

  /// The camera padding changed: same target, new place on screen.
  void _applyMaxFps() {
    final map = _map, bridge = _bridge;
    if (map == null || bridge == null) return;
    bridge.setMaxFps(map, widget.controller._maxFps);
  }

  void _paddingChanged() {
    final camera = widget.controller._camera;
    if (camera == null) return;
    widget.controller._tween = null;
    _sendCamera(camera, _map == null ? 0 : 300, false);
    _cameraMoved();
  }

  /// Tells the listeners: [MapViewController.cameraChanges] about 30 times
  /// a second while the camera moves, the screen's `onCameraChanged` every
  /// 250 ms and once after it stopped.
  void _cameraMoved() {
    _cameraDirty = true;
    _cameraReport ??= Timer(_cameraReportInterval, _reportCamera);
    _cameraTick ??= Timer.periodic(const Duration(milliseconds: 33), (timer) {
      final controller = widget.controller;
      // `_shown` ends the mirrored animation when its time is up.
      controller._shown;
      controller._changes.notify();
      if (controller._tween == null && !_cameraDirty) {
        timer.cancel();
        _cameraTick = null;
      }
    });
    widget.controller._changes.notify();
  }

  void _reportCamera() {
    _cameraReport = null;
    if (!_cameraDirty || _disposed) return;
    _cameraDirty = false;
    final controller = widget.controller;
    widget.onCameraChanged(controller.center, controller.zoom);
    // Still animating: report again until it has stopped.
    if (controller._tween != null) {
      _cameraDirty = true;
      _cameraReport = Timer(_cameraReportInterval, _reportCamera);
    }
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
    _cameraTick?.cancel();
    _snapshotTimer?.cancel();
    _flipTimer?.cancel();
    _benchTimer?.cancel();
    _gestures.dispose();
    _fling.dispose();
    _destroyMap();
    _surface.dispose();
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
    // attribution and the camera target keep clear of it.
    final insets = MediaQuery.paddingOf(context);
    final controller = widget.controller;
    final viewInsets = EdgeInsetsLike(
      insets.left,
      insets.top,
      insets.right,
      insets.bottom,
    );
    if (controller._viewInsets != viewInsets) {
      controller._viewInsets = viewInsets;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _paddingChanged();
      });
    }
    _wanted = _describe(widget.scene, scheme);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (controller._size != constraints.biggest) {
          controller._size = constraints.biggest;
          // The perspective of a tilted view depends on its height.
          controller._camera = controller._camera?.copyWith(
            viewHeight: constraints.biggest.height,
          );
        }
        _wantedBlur = _blurOf(widget.scene, constraints.biggest);
        _syncScene();
        // The rectangle on screen is known after layout.
        WidgetsBinding.instance.addPostFrameCallback((_) => _syncGeometry());
        // Until the map is up, the style's own background colour instead of
        // whatever is behind the window.
        final placeholder =
            _styleBackground[_dark ? 'dark' : 'bright'] ??
            (_dark ? const Color(0xFF14181C) : const Color(0xFFF8F4F0));
        final attribution = Align(
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
        );
        final mapView = _mapView;
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
          child: mapView == null
              ? CustomPaint(
                  painter: _HolePainter(
                    open: _holeOpen && widget.visible,
                    placeholder: placeholder,
                  ),
                  child: attribution,
                )
              // In Flutter's scene: the map is a layer of its own above the
              // placeholder, shown once it has something to show.
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(color: placeholder),
                    if (_holeOpen) mapView,
                    attribution,
                  ],
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
