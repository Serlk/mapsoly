import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// dart:ffi bindings of `libmapsoly_mln.so` (native/maplibre/mlnb.h).
///
/// Every call is asynchronous on the native side (posted to the map thread)
/// except [create] and [destroy].
class MapLibreBridge {
  MapLibreBridge._(DynamicLibrary lib)
    : _create = lib.lookupFunction<_CreateC, _CreateD>('mlnb_create'),
      _destroy = lib.lookupFunction<_PtrC, _PtrD>('mlnb_destroy'),
      _setGeometry = lib.lookupFunction<_GeomC, _GeomD>('mlnb_set_geometry'),
      _setVisible = lib.lookupFunction<_IntC, _IntD>('mlnb_set_visible'),
      _setStyle = lib.lookupFunction<_StyleC, _StyleD>('mlnb_set_style_json'),
      _setCamera = lib.lookupFunction<_CamC, _CamD>('mlnb_set_camera'),
      _addSource = lib.lookupFunction<_Str2C, _Str2D>('mlnb_add_source'),
      _removeSource = lib.lookupFunction<_Str1C, _Str1D>('mlnb_remove_source'),
      _addLayer = lib.lookupFunction<_Str2C, _Str2D>('mlnb_add_layer'),
      _removeLayer = lib.lookupFunction<_Str1C, _Str1D>('mlnb_remove_layer'),
      _setGeoJson = lib.lookupFunction<_Str2C, _Str2D>('mlnb_set_geojson'),
      _addImage = lib.lookupFunction<_ImageC, _ImageD>('mlnb_add_image'),
      _setBlur = lib.lookupFunction<_BlurC, _BlurD>('mlnb_set_blur'),
      _frameLog = lib.lookupFunction<_Str1C, _Str1D>('mlnb_frame_log'),
      _snapshot = lib.lookupFunction<_Str1C, _Str1D>('mlnb_snapshot'),
      _benchStart = lib.lookupFunction<_Str1C, _Str1D>('mlnb_bench_start'),
      _getStats = lib.lookupFunction<_StatsC, _StatsD>('mlnb_get_stats');

  static const abiVersion = 6;
  static const eventStyleLoaded = 1;
  static const eventStyleFailed = 2;
  static const eventBenchDone = 3;
  static const eventMapFailed = 4;

  /// The bridge library sits next to the executable's other libraries.
  static String get libraryPath =>
      '${File(Platform.resolvedExecutable).parent.path}/lib/libmapsoly_mln.so';

  static MapLibreBridge? _instance;
  static String? _error;

  /// Loads the library once. Null (with [loadError] set) when it is missing,
  /// cannot be loaded or is of another version.
  static MapLibreBridge? load() {
    if (_instance != null || _error != null) return _instance;
    final path = libraryPath;
    if (!File(path).existsSync()) {
      _error = 'no $path';
      return null;
    }
    try {
      final lib = DynamicLibrary.open(path);
      final abi = lib.lookupFunction<Int32 Function(), int Function()>(
        'mlnb_abi_version',
      )();
      if (abi != abiVersion) {
        _error = 'bridge ABI $abi, expected $abiVersion';
        return null;
      }
      _instance = MapLibreBridge._(lib);
    } on ArgumentError catch (e) {
      _error = 'cannot load $path: $e';
    }
    return _instance;
  }

  static String? get loadError => _error;

  static final _libc = DynamicLibrary.process();
  static final _malloc = _libc
      .lookupFunction<
        Pointer<Void> Function(IntPtr),
        Pointer<Void> Function(int)
      >('malloc');
  static final _free = _libc
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('free');

  final _CreateD _create;
  final _PtrD _destroy;
  final _GeomD _setGeometry;
  final _IntD _setVisible;
  final _StyleD _setStyle;
  final _CamD _setCamera;
  final _Str2D _addSource;
  final _Str1D _removeSource;
  final _Str2D _addLayer;
  final _Str1D _removeLayer;
  final _Str2D _setGeoJson;
  final _ImageD _addImage;
  final _BlurD _setBlur;
  final _Str1D _frameLog;
  final _Str1D _snapshot;
  final _Str1D _benchStart;
  final _StatsD _getStats;

  static Pointer<Uint8> _bytes(Uint8List data, {bool terminate = false}) {
    final p = _malloc(data.length + (terminate ? 1 : 0)).cast<Uint8>();
    p.asTypedList(data.length + (terminate ? 1 : 0)).setAll(0, data);
    if (terminate) p[data.length] = 0;
    return p;
  }

  static Pointer<Uint8> _string(String s) =>
      _bytes(utf8.encode(s), terminate: true);

  T _with1<T>(String a, T Function(Pointer<Uint8>) f) {
    final pa = _string(a);
    try {
      return f(pa);
    } finally {
      _free(pa.cast());
    }
  }

  T _with2<T>(
    String a,
    String b,
    T Function(Pointer<Uint8>, Pointer<Uint8>) f,
  ) {
    final pa = _string(a), pb = _string(b);
    try {
      return f(pa, pb);
    } finally {
      _free(pa.cast());
      _free(pb.cast());
    }
  }

  /// Creates a map in a subsurface of [parentSurface]. Null on failure.
  Pointer<Void>? create({
    required int display,
    required int parentSurface,
    required int x,
    required int y,
    required int width,
    required int height,
    required int scale,
    required Pointer<NativeFunction<Void Function(Int32, Int64)>> onEvent,
  }) {
    final map = _create(
      Pointer.fromAddress(display),
      Pointer.fromAddress(parentSurface),
      x,
      y,
      width,
      height,
      scale,
      nullptr,
      onEvent,
    );
    return map == nullptr ? null : map;
  }

  /// Stops the map thread and frees everything; no event arrives afterwards.
  void destroy(Pointer<Void> map) => _destroy(map);

  void setGeometry(Pointer<Void> map, int x, int y, int width, int height) =>
      _setGeometry(map, x, y, width, height);

  void setVisible(Pointer<Void> map, bool visible) =>
      _setVisible(map, visible ? 1 : 0);

  void setStyle(Pointer<Void> map, String json, int generation) =>
      _with1(json, (p) => _setStyle(map, p, generation));

  /// [padding]: left, top, right, bottom insets in logical pixels.
  void setCamera(
    Pointer<Void> map, {
    required double lat,
    required double lon,
    required double zoom,
    required double bearing,
    required double pitch,
    required List<double> padding,
    int durationMs = 0,
    bool linear = false,
  }) {
    final p = _malloc(32).cast<Double>();
    try {
      for (var i = 0; i < 4; i++) {
        p[i] = padding[i];
      }
      _setCamera(
        map,
        lat,
        lon,
        zoom,
        bearing,
        pitch,
        p,
        durationMs,
        linear ? 1 : 0,
      );
    } finally {
      _free(p.cast());
    }
  }

  void addSource(Pointer<Void> map, String id, String json) =>
      _with2(id, json, (a, b) => _addSource(map, a, b));

  void removeSource(Pointer<Void> map, String id) =>
      _with1(id, (a) => _removeSource(map, a));

  void addLayer(Pointer<Void> map, String json, String beforeId) =>
      _with2(json, beforeId, (a, b) => _addLayer(map, a, b));

  void removeLayer(Pointer<Void> map, String id) =>
      _with1(id, (a) => _removeLayer(map, a));

  void setGeoJson(Pointer<Void> map, String sourceId, String geoJson) =>
      _with2(sourceId, geoJson, (a, b) => _setGeoJson(map, a, b));

  /// [rgba]: straight alpha, `width * height * 4` bytes.
  void addImage(
    Pointer<Void> map,
    String id,
    Uint8List rgba,
    int width,
    int height,
    double pixelRatio,
  ) {
    final pixels = _bytes(rgba);
    try {
      _with1(id, (a) => _addImage(map, a, pixels, width, height, pixelRatio));
    } finally {
      _free(pixels.cast());
    }
  }

  /// [xywh]: four numbers per rectangle, logical pixels; empty turns it off.
  void setBlur(Pointer<Void> map, List<double> xywh, double sigma) {
    final p = _malloc(xywh.length * 4 + 4).cast<Float>();
    try {
      for (var i = 0; i < xywh.length; i++) {
        p[i] = xywh[i];
      }
      _setBlur(map, p, xywh.length ~/ 4, sigma);
    } finally {
      _free(p.cast());
    }
  }

  /// Debug: the next frame, as it goes to the compositor, as a PPM file.
  void snapshot(Pointer<Void> map, String path) =>
      _with1(path, (a) => _snapshot(map, a));

  void frameLog(Pointer<Void> map, String path) =>
      _with1(path, (a) => _frameLog(map, a));

  void benchStart(Pointer<Void> map, String prefix) =>
      _with1(prefix, (a) => _benchStart(map, a));

  /// Frames rendered, last frame interval in microseconds, slow frames.
  List<int> stats(Pointer<Void> map) {
    final out = _malloc(24).cast<Int64>();
    try {
      _getStats(map, out);
      return [out[0], out[1], out[2]];
    } finally {
      _free(out.cast());
    }
  }
}

typedef _EventPtr = Pointer<NativeFunction<Void Function(Int32, Int64)>>;
typedef _CreateC =
    Pointer<Void> Function(
      Pointer<Void>,
      Pointer<Void>,
      Int32,
      Int32,
      Int32,
      Int32,
      Int32,
      Pointer<Uint8>,
      _EventPtr,
    );
typedef _CreateD =
    Pointer<Void> Function(
      Pointer<Void>,
      Pointer<Void>,
      int,
      int,
      int,
      int,
      int,
      Pointer<Uint8>,
      _EventPtr,
    );
typedef _PtrC = Void Function(Pointer<Void>);
typedef _PtrD = void Function(Pointer<Void>);
typedef _GeomC = Void Function(Pointer<Void>, Int32, Int32, Int32, Int32);
typedef _GeomD = void Function(Pointer<Void>, int, int, int, int);
typedef _IntC = Void Function(Pointer<Void>, Int32);
typedef _IntD = void Function(Pointer<Void>, int);
typedef _StyleC = Void Function(Pointer<Void>, Pointer<Uint8>, Int64);
typedef _StyleD = void Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _CamC =
    Void Function(
      Pointer<Void>,
      Double,
      Double,
      Double,
      Double,
      Double,
      Pointer<Double>,
      Int32,
      Int32,
    );
typedef _CamD =
    void Function(
      Pointer<Void>,
      double,
      double,
      double,
      double,
      double,
      Pointer<Double>,
      int,
      int,
    );
typedef _Str1C = Void Function(Pointer<Void>, Pointer<Uint8>);
typedef _Str1D = void Function(Pointer<Void>, Pointer<Uint8>);
typedef _Str2C = Void Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>);
typedef _Str2D = void Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>);
typedef _ImageC =
    Void Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Int32,
      Int32,
      Double,
    );
typedef _ImageD =
    void Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      int,
      int,
      double,
    );
typedef _BlurC = Void Function(Pointer<Void>, Pointer<Float>, Int32, Float);
typedef _BlurD = void Function(Pointer<Void>, Pointer<Float>, int, double);
typedef _StatsC = Void Function(Pointer<Void>, Pointer<Int64>);
typedef _StatsD = void Function(Pointer<Void>, Pointer<Int64>);
