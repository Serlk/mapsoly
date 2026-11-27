import 'dart:math' as math;
import 'dart:async';
import 'dart:ffi' hide Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'bridge.dart';
import 'surface.dart';

/// The pixel ratio the map of a [view] (logical pixels) is drawn at on a
/// screen of [devicePixelRatio].
///
/// A map is all fill: every pixel is painted several times over (ground,
/// roads, buildings, traffic, labels). A 2560x1600 tablet asks for four
/// million pixels of that from a GPU half as fast as a phone's that draws
/// two. So the map gets a budget of [budget] pixels: above it the map's
/// buffers are made smaller than its view and the display's scaler stretches
/// them (`SurfaceHolder.setFixedSize`, MapSurface.kt). Lines and labels keep
/// their size on the screen (MapLibre lays the map out in logical pixels; the
/// ratio only says how finely), they are just a little softer.
///
/// Never below 1 (or the screen's own ratio, should that be lower): under it
/// the map would be coarser than the sprites and glyphs it is made of, and
/// text that small does not survive being stretched. So a very large view
/// may still be over the budget. Never above the screen's ratio.
///
/// In steps of a quarter (1, 1.25, 1.5, ...), so that a view resized by a few
/// pixels does not change it (a new ratio means a new native map): the value
/// flips only where a step is crossed, and once the floor is reached not at
/// all. On a screen whose own ratio is not on a step (1.27, say) the choice
/// is that ratio when the view fits the budget, else 1.25 if that fits, else
/// 1: the quarter grid is kept there rather than a value fitted to the view,
/// which would change with every pixel of the view's size.
double mapPixelRatio(
  double devicePixelRatio,
  Size view, {
  double budget = 2.2e6,
}) {
  final logical = view.width * view.height;
  if (logical <= 0 || logical * devicePixelRatio * devicePixelRatio <= budget) {
    return devicePixelRatio;
  }
  final fit = math.sqrt(budget / logical);
  final stepped = (fit * 4).floor() / 4;
  return stepped.clamp(math.min(1.0, devicePixelRatio), devicePixelRatio);
}

/// The size in pixels of buffers that cover [logical] at [pixelRatio] (at
/// least 1x1).
({int width, int height}) bufferPixels(Size logical, double pixelRatio) => (
  width: (logical.width * pixelRatio).round().clamp(1, 16384),
  height: (logical.height * pixelRatio).round().clamp(1, 16384),
);

/// Where the map's `SurfaceView` lies and how large its buffers are.
/// [x], [y], [width], [height]: pixels of the screen, relative to the Flutter
/// view. [bufferWidth] x [bufferHeight]: what the map draws; the display
/// stretches it over the view when it is smaller.
typedef SurfacePlacement = ({
  int x,
  int y,
  int width,
  int height,
  int bufferWidth,
  int bufferHeight,
});

/// The placement of a map at [rect] (logical pixels of the Flutter view) on a
/// screen of [devicePixelRatio], drawn at [mapRatio].
///
/// The view's edges are the widget's edges rounded to whole pixels, so
/// neighbouring widgets meet it exactly. Drawn at the screen's own ratio the
/// buffers are exactly the view (nothing is scaled, not even by one pixel);
/// at a lower ratio they are the logical size times that ratio.
SurfacePlacement placeSurface(
  Rect rect,
  double devicePixelRatio,
  double mapRatio,
) {
  final left = (rect.left * devicePixelRatio).round();
  final top = (rect.top * devicePixelRatio).round();
  final width = ((rect.right * devicePixelRatio).round() - left).clamp(
    1,
    16384,
  );
  final height = ((rect.bottom * devicePixelRatio).round() - top).clamp(
    1,
    16384,
  );
  final buffer = mapRatio >= devicePixelRatio
      ? (width: width, height: height)
      : bufferPixels(rect.size, mapRatio);
  return (
    x: left,
    y: top,
    width: width,
    height: height,
    bufferWidth: math.min(buffer.width, width),
    bufferHeight: math.min(buffer.height, height),
  );
}

/// One `SurfaceView` of MapSurface.kt and the Android window behind it.
///
/// The window is not a fixed thing: Android takes it away while the app is in
/// the background and hands out another one afterwards, and a new buffer size
/// announces it again. This class asks for the view, keeps it where it was
/// wanted last (requests do not overlap; placements that were overtaken are
/// skipped) and reports every change of window to [onWindow], which gives it
/// to the native map. A window of 0 means "none at the moment": the map keeps
/// its state and draws nothing.
class SurfaceViewController {
  SurfaceViewController({
    MethodChannel channel = const MethodChannel('mapsoly/map_surface'),
    required this.onWindow,
    required this.onError,
  }) : _channel = channel;

  final MethodChannel _channel;

  /// The window to draw into from now on, with the size of its buffers (for
  /// window 0: the size of the buffers of the window before).
  final void Function(int window, int widthPx, int heightPx) onWindow;
  final ValueChanged<String> onError;

  // Android sends window changes on the one channel: they are handed to the
  // controller that owns the surface.
  static final Map<int, SurfaceViewController> _bySurface = {};

  int? _id;
  SurfacePlacement? _wanted, _placed;
  ({int width, int height})? _buffers;
  bool _busy = false;
  bool _disposed = false;

  /// Puts the view there; [onWindow] follows when that gives the surface
  /// other buffers (and for the first placement).
  void place(SurfacePlacement placement) {
    if (placement == _wanted) return;
    _wanted = placement;
    _pump();
  }

  Future<void> _pump() async {
    if (_busy) return;
    _busy = true;
    try {
      while (!_disposed) {
        final want = _wanted;
        if (want == null || want == _placed) break;
        var id = _id;
        if (id == null) {
          id = (await _channel.invokeMethod<int>('create'))!;
          if (_disposed) {
            await _channel.invokeMethod<void>('dispose', id);
            break;
          }
          _channel.setMethodCallHandler(_onPlatformCall);
          _bySurface[id] = this;
          _id = id;
          // The placement may have been overtaken while the view was made.
          continue;
        }
        await _channel.invokeMethod<void>('place', {
          'surface': id,
          'x': want.x,
          'y': want.y,
          'width': want.width,
          'height': want.height,
          'bufferWidth': want.bufferWidth,
          'bufferHeight': want.bufferHeight,
        });
        _placed = want;
      }
    } on PlatformException catch (e) {
      if (!_disposed) onError(e.message ?? e.code);
    } on MissingPluginException {
      if (!_disposed) onError('no map surface on this platform');
    } finally {
      _busy = false;
    }
  }

  static Future<Object?> _onPlatformCall(MethodCall call) async {
    if (call.method != 'surface') return null;
    final args = (call.arguments as Map).cast<String, Object?>();
    _bySurface[args['surface']]?._windowChanged(
      args['window'] as int? ?? 0,
      args['width'] as int? ?? 0,
      args['height'] as int? ?? 0,
    );
    return null;
  }

  /// Android made a window for the surface, changed its buffers, or took it
  /// away.
  void _windowChanged(int window, int widthPx, int heightPx) {
    if (_disposed) return;
    if (window != 0 && widthPx > 0 && heightPx > 0) {
      _buffers = (width: widthPx, height: heightPx);
      onWindow(window, widthPx, heightPx);
      return;
    }
    // None: the map keeps the size it had (it must not shrink to nothing).
    final buffers = _buffers;
    if (buffers != null) onWindow(0, buffers.width, buffers.height);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final id = _id;
    if (id != null) {
      _bySurface.remove(id);
      _channel.invokeMethod<void>('dispose', id);
    }
  }
}

/// The Android surface of the map: a `SurfaceView` below the transparent
/// Flutter view, which the native map renders into
/// (`native/maplibre/android/backend.hpp`). Like the Wayland subsurface it is
/// outside Flutter's scene: the widget leaves a hole for it and the bridge
/// blurs the map under the glass panels itself. See docs/map-engine.md,
/// "Android".
class AndroidMapSurface implements MapSurface {
  static const _channel = MethodChannel('mapsoly/map_surface');

  /// How long after the map got a window its first frame is taken to be on
  /// the screen (the bridge does not say; a frame takes 16-70 ms).
  static const _firstFrame = Duration(milliseconds: 150);

  late final SurfaceViewController _view = SurfaceViewController(
    onWindow: _onWindow,
    onError: (reason) => onError?.call(reason),
  );
  String? _assets;
  MapLibreBridge? _bridge;
  Pointer<Void>? _map;
  double _ratio = 1;
  double _deviceRatio = 1;
  ({int window, int width, int height})? _window;
  final ValueNotifier<bool> _present = ValueNotifier(false);
  Timer? _presentTimer;
  bool _disposed = false;

  @override
  ValueChanged<String>? onError;

  @override
  String get assetsDirectory => _assets!;

  @override
  Future<void> prepare() async {
    try {
      _assets = (await _channel.invokeMethod<String>('assets'))!;
    } on PlatformException catch (e) {
      throw e.message ?? e.code;
    }
  }

  /// Draw the map at every pixel of the screen, whatever that costs. Off
  /// (the default) the map of a large dense screen is drawn at fewer pixels
  /// and scaled up, see [mapPixelRatio].
  static bool fullResolution = false;

  /// Android densities are not integers (2.75 is common). Remembers the
  /// screen's ratio: the view is placed in pixels of the screen.
  @override
  double ratioFor(double devicePixelRatio, [Size? view]) {
    _deviceRatio = devicePixelRatio;
    return view == null || fullResolution
        ? devicePixelRatio
        : mapPixelRatio(devicePixelRatio, view);
  }

  @override
  bool get wholeLogicalPixels => false;

  @override
  ValueListenable<bool> get present => _present;

  @override
  Pointer<Void>? create(
    MapLibreBridge bridge,
    Rect rect,
    double ratio,
    MapEventCallback onEvent,
  ) {
    final place = placeSurface(rect, _deviceRatio, ratio);
    debugPrint(
      'map surface: view ${place.width}x${place.height} px, drawn at ratio '
      '$ratio of $_deviceRatio = ${place.bufferWidth}x${place.bufferHeight} px'
      '${fullResolution ? ' (full resolution asked for)' : ''}',
    );
    // The window with these buffers if there is one already (the map was
    // created again), none otherwise: it arrives through [_onWindow].
    final window = _window;
    final same =
        window != null &&
        window.window != 0 &&
        window.width == place.bufferWidth &&
        window.height == place.bufferHeight;
    final map = bridge.androidCreate(
      window: same ? window.window : 0,
      widthPx: place.bufferWidth,
      heightPx: place.bufferHeight,
      pixelRatio: ratio,
      onEvent: onEvent,
    );
    if (map == null) return null;
    _bridge = bridge;
    _map = map;
    _ratio = ratio;
    _setPresent(same);
    _view.place(place);
    return map;
  }

  @override
  void setGeometry(Rect rect) =>
      _view.place(placeSurface(rect, _deviceRatio, _ratio));

  void _onWindow(int window, int widthPx, int heightPx) {
    _window = (window: window, width: widthPx, height: heightPx);
    final map = _map;
    if (map != null) {
      _bridge!.androidSetSurface(map, window, widthPx, heightPx);
    }
    _setPresent(window != 0 && map != null);
  }

  /// Without a window drawn into there is nothing below the hole: at once
  /// when the window goes, a frame's time after one came.
  void _setPresent(bool drawing) {
    if (_disposed) return;
    if (!drawing) {
      _presentTimer?.cancel();
      _presentTimer = null;
      _present.value = false;
    } else if (!_present.value) {
      _presentTimer ??= Timer(_firstFrame, () {
        _presentTimer = null;
        _present.value = true;
      });
    }
  }

  @override
  void detach() {
    _map = null;
    _setPresent(false);
  }

  @override
  void dispose() {
    _map = null;
    _setPresent(false);
    _disposed = true;
    _view.dispose();
  }
}
