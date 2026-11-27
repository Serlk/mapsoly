import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'bridge.dart';
import 'surface_android.dart';

typedef MapEventCallback = Pointer<NativeFunction<Void Function(Int32, Int64)>>;

/// Where the native map draws, and how the widget's rectangle gets there.
///
/// The one part of the MapLibre engine that differs per platform:
///  - Linux: a Wayland subsurface *below* the transparent Flutter window
///    ([WaylandMapSurface]); the widget punches a hole to show it.
///  - Android: a Flutter texture ([AndroidMapSurface]); the map is a widget in
///    Flutter's own scene.
abstract class MapSurface {
  factory MapSurface.forPlatform() =>
      Platform.isAndroid ? AndroidMapSurface() : WaylandMapSurface();

  /// Directory with `fonts/` and `sprites/`; known after [prepare].
  String get assetsDirectory;

  /// Gets everything [create] needs. Throws (the reason, as text) when the
  /// map cannot be shown here.
  Future<void> prepare();

  /// The pixel ratio a native map is created with for a view of
  /// [devicePixelRatio]. It is fixed per native map: when this value changes
  /// the map has to be created again.
  double ratioFor(double devicePixelRatio);

  /// Creates the native map for the widget at [rect] (logical pixels in the
  /// window's coordinates). Null when that failed.
  Pointer<Void>? create(
    MapLibreBridge bridge,
    Rect rect,
    double ratio,
    MapEventCallback onEvent,
  );

  /// The widget's rectangle changed.
  void setGeometry(Rect rect);

  /// The native map of the last [create] is about to be destroyed.
  void detach();

  /// The map as a widget, when it is part of Flutter's scene; null when it
  /// lies outside (below the window) and the widget only has to uncover it.
  /// A surface that returns a widget is clipped and blurred by Flutter like
  /// any other, so the engine's own blur rectangles are not used with it.
  Widget? buildView();

  /// Called with a reason when the surface stops working after [prepare].
  ValueChanged<String>? onError;

  void dispose();
}

/// The Wayland subsurface of `native/maplibre/mlnb.cpp`, placed below the
/// window by the bridge; `linux/runner/native_view_plugin.cc` provides the
/// window's Wayland handles and commits the window when the subsurface moved.
class WaylandMapSurface implements MapSurface {
  static const _channel = MethodChannel('mapsoly/native_view');

  /// Offline glyphs and sprites, installed next to the Flutter assets.
  static String get bundleAssetsDirectory =>
      '${File(Platform.resolvedExecutable).parent.path}/data/maplibre';

  ({int display, int surface, int x, int y})? _handles;
  MapLibreBridge? _bridge;
  Pointer<Void>? _map;

  @override
  ValueChanged<String>? onError;

  @override
  String get assetsDirectory => bundleAssetsDirectory;

  @override
  Future<void> prepare() async {
    final h = (await _channel.invokeMapMethod<String, Object?>('handles'))!;
    if (h['wayland'] != true) throw 'the window is not on Wayland';
    _handles = (
      display: h['display']! as int,
      surface: h['surface']! as int,
      x: h['x']! as int,
      y: h['y']! as int,
    );
  }

  /// A Wayland buffer scale is an integer.
  @override
  double ratioFor(double devicePixelRatio) =>
      devicePixelRatio.round().clamp(1, 4).toDouble();

  @override
  Pointer<Void>? create(
    MapLibreBridge bridge,
    Rect rect,
    double ratio,
    MapEventCallback onEvent,
  ) {
    final handles = _handles!;
    final map = bridge.create(
      display: handles.display,
      parentSurface: handles.surface,
      x: handles.x + rect.left.toInt(),
      y: handles.y + rect.top.toInt(),
      width: rect.width.toInt(),
      height: rect.height.toInt(),
      scale: ratio.round(),
      onEvent: onEvent,
    );
    if (map == null) return null;
    _bridge = bridge;
    _map = map;
    // Position and stacking apply when GTK commits the window's surface.
    _channel.invokeMethod<void>('commit');
    return map;
  }

  @override
  void setGeometry(Rect rect) {
    final handles = _handles, map = _map;
    if (handles == null || map == null) return;
    _bridge!.setGeometry(
      map,
      handles.x + rect.left.toInt(),
      handles.y + rect.top.toInt(),
      rect.width.toInt(),
      rect.height.toInt(),
    );
    // The new position applies when GTK commits the window's surface.
    _channel.invokeMethod<void>('commit');
  }

  @override
  void detach() => _map = null;

  @override
  Widget? buildView() => null;

  @override
  void dispose() => _map = null;
}
