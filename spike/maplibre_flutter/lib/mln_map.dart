// Minimal Dart API of the MapLibre prototype.
//
// Set-up (texture registration, benchmark, state polling) goes through the
// "mapsoly/mln_map" method channel; camera calls go through dart:ffi straight into
// libmapsoly_mln.so, which posts them to the map thread (no platform-thread hop).
import 'dart:ffi' hide Size;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef _MoveC = Void Function(Pointer<Void>, Double, Double);
typedef _MoveD = void Function(Pointer<Void>, double, double);
typedef _ZoomC = Void Function(Pointer<Void>, Double, Double, Double, Int32);
typedef _ZoomD = void Function(Pointer<Void>, double, double, double, int);
typedef _RotC = Void Function(Pointer<Void>, Double, Double, Double);
typedef _RotD = void Function(Pointer<Void>, double, double, double);
typedef _CamC =
    Void Function(Pointer<Void>, Double, Double, Double, Double, Double, Int32);
typedef _CamD =
    void Function(Pointer<Void>, double, double, double, double, double, int);
typedef _ResizeC = Void Function(Pointer<Void>, Int32, Int32);
typedef _ResizeD = void Function(Pointer<Void>, int, int);
typedef _GestC = Void Function(Pointer<Void>, Int32);
typedef _GestD = void Function(Pointer<Void>, int);

class MlnMapState {
  MlnMapState(Map<Object?, Object?> m)
    : lat = m['lat']! as double,
      lon = m['lon']! as double,
      zoom = m['zoom']! as double,
      bearing = m['bearing']! as double,
      pitch = m['pitch']! as double,
      rendered = m['rendered']! as int,
      consumed = m['consumed']! as int,
      bench = m['bench']! as int;
  final double lat, lon, zoom, bearing, pitch;
  final int rendered, consumed;

  /// 0 idle, 1 running, 2 finished.
  final int bench;
}

class MlnMapController {
  MlnMapController._(this.textureId, this._h, DynamicLibrary lib)
    : _moveBy = lib.lookupFunction<_MoveC, _MoveD>('mlnb_move_by'),
      _zoomBy = lib.lookupFunction<_ZoomC, _ZoomD>('mlnb_zoom_by'),
      _rotateBy = lib.lookupFunction<_RotC, _RotD>('mlnb_rotate_by'),
      _setCamera = lib.lookupFunction<_CamC, _CamD>('mlnb_set_camera'),
      _resize = lib.lookupFunction<_ResizeC, _ResizeD>('mlnb_resize'),
      _gesture = lib.lookupFunction<_GestC, _GestD>('mlnb_set_gesture');

  static const _channel = MethodChannel('mapsoly/mln_map');

  /// -1 in subsurface mode (the map is not part of Flutter's scene then).
  final int textureId;
  final Pointer<Void> _h;
  final _MoveD _moveBy;
  final _ZoomD _zoomBy;
  final _RotD _rotateBy;
  final _CamD _setCamera;
  final _ResizeD _resize;
  final _GestD _gesture;

  /// [size] in logical pixels; [pixelRatio] is fixed for the map's lifetime.
  static Future<MlnMapController> create({
    required String style,
    required Size size,
    required double pixelRatio,
    bool subsurface = false,
  }) async {
    final r = (await _channel.invokeMapMethod<String, Object?>('create', {
      'style': style,
      'width': size.width.round(),
      'height': size.height.round(),
      'ratio': pixelRatio,
      'subsurface': subsurface,
    }))!;
    DynamicLibrary lib;
    try {
      lib = DynamicLibrary.process();
      lib.lookup<NativeFunction<_MoveC>>('mlnb_move_by');
    } on ArgumentError {
      lib = DynamicLibrary.open('libmapsoly_mln.so');
    }
    return MlnMapController._(
      r['textureId']! as int,
      Pointer<Void>.fromAddress(r['handle']! as int),
      lib,
    );
  }

  /// Null components stay as they are. [duration] zero = jump.
  void setCamera({
    double? lat,
    double? lon,
    double? zoom,
    double? bearing,
    double? pitch,
    Duration duration = Duration.zero,
  }) => _setCamera(
    _h,
    lat ?? double.nan,
    lon ?? double.nan,
    zoom ?? double.nan,
    bearing ?? double.nan,
    pitch ?? double.nan,
    duration.inMilliseconds,
  );

  /// Moves the map content by logical pixels (finger delta).
  void moveBy(double dx, double dy) => _moveBy(_h, dx, dy);

  /// [delta] in zoom levels around [focalPoint] (logical px, widget-local).
  void zoomBy(
    double delta, {
    Offset? focalPoint,
    Duration duration = Duration.zero,
  }) => _zoomBy(
    _h,
    delta,
    focalPoint?.dx ?? double.nan,
    focalPoint?.dy ?? double.nan,
    duration.inMilliseconds,
  );

  void rotateBy(double degrees, {Offset? focalPoint}) => _rotateBy(
    _h,
    degrees,
    focalPoint?.dx ?? double.nan,
    focalPoint?.dy ?? double.nan,
  );

  void resize(Size size) => _resize(_h, size.width.round(), size.height.round());

  void setGestureInProgress(bool v) => _gesture(_h, v ? 1 : 0);

  /// Runs the scripted camera animation of the spike; writes
  /// `<prefix>.frames.csv`, `.consume.csv`, `.paint.csv`.
  Future<void> startBenchmark(String outPrefix) =>
      _channel.invokeMethod('benchStart', outPrefix);

  Future<MlnMapState> state() async =>
      MlnMapState((await _channel.invokeMapMethod<Object?, Object?>('getState'))!);

  Future<void> dispose() => _channel.invokeMethod('dispose');
}

/// The map as a widget: a [Texture] plus pan / pinch / rotate gestures.
class MlnMapView extends StatefulWidget {
  const MlnMapView({
    super.key,
    required this.style,
    this.subsurface = false,
    this.onCreated,
  });
  final String style;

  /// Route B: the map is a Wayland subsurface below the (transparent) Flutter
  /// window; this widget is then only a transparent hole taking the gestures.
  /// The map is placed at the window origin, so the widget must start there.
  final bool subsurface;
  final ValueChanged<MlnMapController>? onCreated;

  @override
  State<MlnMapView> createState() => _MlnMapViewState();
}

class _MlnMapViewState extends State<MlnMapView> {
  MlnMapController? _c;
  bool _creating = false;
  Size? _size;
  String? _error;
  double _lastScale = 1, _lastRotation = 0;

  void _layout(Size size, double dpr) {
    if (size.isEmpty) return;
    final c = _c;
    if (c == null) {
      if (_creating) {
        _size = size;
        return;
      }
      _creating = true;
      _size = size;
      MlnMapController.create(
        style: widget.style,
        size: size,
        pixelRatio: dpr,
        subsurface: widget.subsurface,
      ).then(
        (c) {
          if (!mounted) {
            c.dispose();
            return;
          }
          if (_size != size) c.resize(_size!);
          setState(() => _c = c);
          widget.onCreated?.call(c);
        },
        onError: (Object e) {
          if (mounted) setState(() => _error = '$e');
        },
      );
    } else if (_size != size) {
      _size = size;
      c.resize(size);
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        _layout(constraints.biggest, dpr);
        final c = _c;
        if (_error != null) return Center(child: Text(_error!));
        if (c == null) {
          return widget.subsurface
              ? const SizedBox.expand()
              : const ColoredBox(color: Color(0xFFE8E0D8));
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (d) {
            _lastScale = 1;
            _lastRotation = 0;
            c.setGestureInProgress(true);
          },
          onScaleUpdate: (d) {
            final f = d.localFocalPoint;
            if (d.focalPointDelta != Offset.zero) {
              c.moveBy(d.focalPointDelta.dx, d.focalPointDelta.dy);
            }
            if (d.pointerCount > 1) {
              if (d.scale != _lastScale && d.scale > 0) {
                // log2 of the scale ratio since the last event
                c.zoomBy(_log2(d.scale / _lastScale), focalPoint: f);
                _lastScale = d.scale;
              }
              if (d.rotation != _lastRotation) {
                c.rotateBy(
                  -(d.rotation - _lastRotation) * 180 / math.pi,
                  focalPoint: f,
                );
                _lastRotation = d.rotation;
              }
            }
          },
          onScaleEnd: (d) => c.setGestureInProgress(false),
          // MapLibre's framebuffer is bottom-up, Flutter samples external textures
          // top-down: flip in the compositor instead of copying.
          child: c.textureId < 0
              ? const SizedBox.expand()
              : Transform.flip(
                  flipY: true,
                  child: Texture(textureId: c.textureId),
                ),
        );
      },
    );
  }
}

double _log2(double x) => x <= 0 ? 0 : math.log(x) / math.ln2;
