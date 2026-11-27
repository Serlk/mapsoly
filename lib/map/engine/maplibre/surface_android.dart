import 'dart:async';
import 'dart:ffi' hide Size;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'bridge.dart';
import 'surface.dart';

/// The size in device pixels of a texture that covers [logical] exactly at
/// [devicePixelRatio] (at least 1x1).
({int width, int height}) texturePixels(
  Size logical,
  double devicePixelRatio,
) => (
  width: (logical.width * devicePixelRatio).round().clamp(1, 16384),
  height: (logical.height * devicePixelRatio).round().clamp(1, 16384),
);

/// One Flutter texture of MapSurface.kt and the Android window behind it.
///
/// The window is not a fixed thing: every size has its own, and Android takes
/// it away while the app is in the background and hands out another one
/// afterwards. This class asks for the texture, keeps it at the size wanted
/// last (requests do not overlap; sizes that were overtaken are skipped) and
/// reports every change of window to [onWindow], which gives it to the native
/// map. A window of 0 means "none at the moment": the map keeps its state and
/// draws nothing.
class TextureSurfaceController {
  TextureSurfaceController({
    MethodChannel channel = const MethodChannel('mapsoly/map_surface'),
    required this.onWindow,
    required this.onError,
  }) : _channel = channel;

  final MethodChannel _channel;

  /// The window to draw into from now on, with the size of its buffers.
  final void Function(int window, int widthPx, int heightPx) onWindow;
  final ValueChanged<String> onError;

  /// The texture to show; null until it exists.
  final ValueNotifier<int?> textureId = ValueNotifier(null);

  // Android sends window changes on the one channel: they are handed to the
  // controller that owns the texture.
  static final Map<int, TextureSurfaceController> _byTexture = {};

  ({int width, int height})? _wanted, _sized;
  bool _busy = false;
  bool _disposed = false;

  /// Makes the texture [widthPx] x [heightPx]; [onWindow] follows.
  void setSize(int widthPx, int heightPx) {
    final size = (width: widthPx, height: heightPx);
    if (size == _wanted) return;
    _wanted = size;
    _pump();
  }

  Future<void> _pump() async {
    if (_busy) return;
    _busy = true;
    try {
      while (!_disposed) {
        final want = _wanted;
        if (want == null || want == _sized) break;
        var texture = textureId.value;
        if (texture == null) {
          texture = (await _channel.invokeMethod<int>('create'))!;
          if (_disposed) {
            await _channel.invokeMethod<void>('dispose', texture);
            break;
          }
          _channel.setMethodCallHandler(_onPlatformCall);
          _byTexture[texture] = this;
          textureId.value = texture;
          // The size may have been overtaken while the texture was made.
          continue;
        }
        final window = await _channel.invokeMethod<int>('resize', {
          'texture': texture,
          'width': want.width,
          'height': want.height,
        });
        if (_disposed) break;
        _sized = want;
        onWindow(window ?? 0, want.width, want.height);
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
    _byTexture[args['texture']]?._windowChanged(args['window'] as int? ?? 0);
    return null;
  }

  /// Android replaced the window of the current size, or took it away.
  void _windowChanged(int window) {
    final sized = _sized;
    if (_disposed || sized == null) return;
    onWindow(window, sized.width, sized.height);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final texture = textureId.value;
    if (texture != null) {
      _byTexture.remove(texture);
      _channel.invokeMethod<void>('dispose', texture);
    }
    textureId.dispose();
  }
}

/// The Android surface of the map: a Flutter texture the native map renders
/// into (`native/maplibre/android/backend.hpp`), shown with a [Texture]
/// widget. See docs/map-engine.md, "Android".
class AndroidMapSurface implements MapSurface {
  static const _channel = MethodChannel('mapsoly/map_surface');

  late final TextureSurfaceController _texture = TextureSurfaceController(
    onWindow: _onWindow,
    onError: (reason) => onError?.call(reason),
  );
  String? _assets;
  MapLibreBridge? _bridge;
  Pointer<Void>? _map;
  double _ratio = 1;
  ({int window, int width, int height})? _window;

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

  /// Android densities are not integers (2.75 is common); the map is drawn
  /// at exactly the view's pixels.
  @override
  double ratioFor(double devicePixelRatio) => devicePixelRatio;

  @override
  Pointer<Void>? create(
    MapLibreBridge bridge,
    Rect rect,
    double ratio,
    MapEventCallback onEvent,
  ) {
    final px = texturePixels(rect.size, ratio);
    // The window of this size if there is one already (the map was created
    // again), none otherwise: it arrives through [_onWindow].
    final window = _window;
    final same =
        window != null &&
        window.width == px.width &&
        window.height == px.height;
    final map = bridge.androidCreate(
      window: same ? window.window : 0,
      widthPx: px.width,
      heightPx: px.height,
      pixelRatio: ratio,
      onEvent: onEvent,
    );
    if (map == null) return null;
    _bridge = bridge;
    _map = map;
    _ratio = ratio;
    _texture.setSize(px.width, px.height);
    return map;
  }

  @override
  void setGeometry(Rect rect) {
    final px = texturePixels(rect.size, _ratio);
    _texture.setSize(px.width, px.height);
  }

  void _onWindow(int window, int widthPx, int heightPx) {
    _window = (window: window, width: widthPx, height: heightPx);
    final map = _map;
    if (map != null) {
      _bridge!.androidSetSurface(map, window, widthPx, heightPx);
    }
  }

  @override
  void detach() => _map = null;

  @override
  Widget? buildView() => ValueListenableBuilder<int?>(
    valueListenable: _texture.textureId,
    builder: (context, id, _) =>
        id == null ? const SizedBox.expand() : Texture(textureId: id),
  );

  @override
  void dispose() {
    _map = null;
    _texture.dispose();
  }
}
