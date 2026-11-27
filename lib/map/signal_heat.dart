/// The "signal map" layer: the app's own collection of transmitters (Wi-Fi,
/// cells, Bluetooth) around the view, as points of a heat map.
///
/// Purely local: the points are read from the positioning database and
/// drawn; nothing is sent anywhere.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Color, Size;

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../positioning/location_db.dart';
import 'engine/map_engine.dart';

/// Most points handed to the map engine at once.
const signalHeatMaxPoints = 4000;

/// A grid cell is at most this wide on the screen (logical px), and at least
/// half of it: the grid step is a power-of-two fraction of 360 degrees.
const _cellMaxPx = 40.0;

/// How much one transmitter of a kind counts. A cell tower is heard
/// kilometres away, so where it is put is a rough guess: it counts least.
const _wifiFactor = 1.0, _bleFactor = 0.6, _cellFactor = 0.35;

/// The count of transmitters in a grid cell stops mattering here.
const _countCap = 10;

/// 0.15..1 for the strongest signal seen: -90 dBm and weaker is the floor,
/// -40 dBm and stronger is 1, linear in between. An unknown signal counts as
/// a middling one.
double _strength(double? dbm) =>
    dbm == null ? 0.4 : ((dbm + 100) / 60).clamp(0.15, 1.0);

double _kindWeight(int count, double? bestDbm, double factor) => count <= 0
    ? 0
    : factor *
          math.sqrt(math.min(count, _countCap) / _countCap) *
          _strength(bestDbm);

/// Weight of a grid cell in the heat map, 0..1: "how many and how strong".
///
/// For each kind of transmitter in the cell
///
///     w_kind = factor * sqrt(min(count, 10) / 10) * strength(best signal)
///
/// with factor 1 for Wi-Fi, 0.6 for Bluetooth and 0.35 for cells, and
/// strength = clamp((dBm + 100) / 60, 0.15, 1). The weight of the cell is
/// the sum over the kinds, capped at 1. The square root keeps a single
/// access point visible (0.32 at full strength) while ten of them saturate.
double signalHeatWeight(TransmitterCell c) => math.min(
  1.0,
  _kindWeight(c.wifi, c.bestWifiDbm, _wifiFactor) +
      _kindWeight(c.ble, c.bestBleDbm, _bleFactor) +
      _kindWeight(c.cells, c.bestCellDbm, _cellFactor),
);

/// Colour of a heat value 0..1 for engines that paint the points themselves:
/// the same ramp as the MapLibre layer (blue, cyan, green, yellow, red).
Color signalHeatColor(double weight) {
  const stops = [
    (0.0, Color(0xFF4169E1)),
    (0.3, Color(0xFF00D5FF)),
    (0.55, Color(0xFF32D74B)),
    (0.8, Color(0xFFFFD60A)),
    (1.0, Color(0xFFFF3B30)),
  ];
  final w = weight.clamp(0.0, 1.0);
  for (var i = 1; i < stops.length; i++) {
    if (w <= stops[i].$1) {
      final t = (w - stops[i - 1].$1) / (stops[i].$1 - stops[i - 1].$1);
      return Color.lerp(stops[i - 1].$2, stops[i].$2, t)!;
    }
  }
  return stops.last.$2;
}

/// The part of the database to read for a view: a box around the camera and
/// the grid the transmitters in it are gathered on.
@immutable
class SignalHeatArea {
  const SignalHeatArea({
    required this.center,
    required this.halfLat,
    required this.halfLon,
    required this.level,
    required this.latDivisor,
  });

  /// The area for a view of [view] logical pixels at [zoom] (256 px tiles)
  /// around [center]: a square twice the longer side of the view, so the
  /// map can be dragged, turned or tilted for a while before more is
  /// needed. [coarser] doubles the grid step that many times.
  factory SignalHeatArea.of(
    LatLng center,
    double zoom,
    Size view, {
    int coarser = 0,
  }) {
    final degPerPx = 360 / (256 * math.pow(2, zoom));
    final side = math.max(view.longestSide, 256.0);
    final cos = math.cos(center.latitude.clamp(-85.0, 85.0) * math.pi / 180);
    final halfLon = math.min(side * degPerPx, 180.0);
    // The step that makes a cell at most _cellMaxPx wide.
    final level = (math.log(360 / (degPerPx * _cellMaxPx)) / math.ln2).ceil();
    return SignalHeatArea(
      center: center,
      halfLat: math.min(halfLon * cos, 85.0),
      halfLon: halfLon,
      level: (level - coarser).clamp(1, 23),
      // A degree of latitude is 1/cos times longer on the ground than one
      // of longitude: in steps of a half, so that the grid stays where it
      // is while the map is dragged north or south a little.
      latDivisor: ((2 / cos).round() / 2).clamp(1.0, 8.0),
    );
  }

  final LatLng center;

  /// Half the size of the box, degrees.
  final double halfLat, halfLon;

  /// The grid step along the longitude is 360 / 2^level degrees.
  final int level;

  /// The step along the latitude is that divided by this.
  final double latDivisor;

  double get lonStep => 360 / math.pow(2, level);
  double get latStep => lonStep / latDivisor;

  double get south => math.max(center.latitude - halfLat, -90);
  double get north => math.min(center.latitude + halfLat, 90);
  double get west => math.max(center.longitude - halfLon, -180);
  double get east => math.min(center.longitude + halfLon, 180);

  /// Whether what was read for this area still serves a view that needs
  /// [other]: the same grid, and the camera not far from where it was.
  bool serves(SignalHeatArea other) =>
      level == other.level &&
      latDivisor == other.latDivisor &&
      (other.center.latitude - center.latitude).abs() <= halfLat * 0.3 &&
      (other.center.longitude - center.longitude).abs() <= halfLon * 0.3;
}

/// With more records than this (of any source) in the area the database is
/// not read: gathering them costs a few microseconds each on the UI
/// isolate, and a view that wide (a whole region with a large database)
/// would stall the map. The layer then shows nothing until the map is
/// zoomed in.
const signalHeatMaxRecords = 30000;

/// Reads the heat points for a view from [db]; null when the area holds
/// more than [maxRecords] records (see [signalHeatMaxRecords]). When the
/// area has more non-empty grid cells than [maxPoints] the grid is made
/// coarser (up to three times) instead of cutting the list, which would
/// leave a part of the area empty.
List<HeatPoint>? querySignalHeat(
  LocationDb db,
  LatLng center,
  double zoom,
  Size view, {
  int maxPoints = signalHeatMaxPoints,
  int maxRecords = signalHeatMaxRecords,
}) {
  final box = SignalHeatArea.of(center, zoom, view);
  final records = db.countInBounds(
    south: box.south,
    west: box.west,
    north: box.north,
    east: box.east,
    limit: maxRecords + 1,
  );
  if (records > maxRecords) return null;
  var cells = const <TransmitterCell>[];
  for (var coarser = 0; coarser <= 3 && records > 0; coarser++) {
    final area = SignalHeatArea.of(center, zoom, view, coarser: coarser);
    cells = db.wardrivingGrid(
      south: area.south,
      west: area.west,
      north: area.north,
      east: area.east,
      latStep: area.latStep,
      lonStep: area.lonStep,
      limit: maxPoints + 1,
    );
    if (cells.length <= maxPoints) break;
  }
  return [
    for (final c in cells.take(maxPoints))
      HeatPoint(LatLng(c.lat, c.lon), signalHeatWeight(c)),
  ];
}

/// Keeps the heat points for the current view: reads them again when the
/// camera has moved far enough or the zoom changed the grid, not more often
/// than [minInterval], and every [refreshEvery] so that what was collected
/// a moment ago appears during a drive.
///
/// The database is read on the caller's isolate (its handle lives there);
/// the query is a range scan over the position index, and when it does turn
/// out slow the pause before the next one grows with it.
class SignalHeatController extends ChangeNotifier {
  SignalHeatController({
    required this.database,
    this.minInterval = const Duration(seconds: 1),
    this.refreshEvery = const Duration(seconds: 10),
  });

  /// The database to read; null while there is none (positioning not up).
  final LocationDb? Function() database;
  final Duration minInterval, refreshEvery;

  bool _enabled = false;
  List<HeatPoint>? _points;
  SignalHeatArea? _loaded;
  (LatLng, double, Size)? _view;
  Timer? _cooldown, _refresh;
  bool _pending = false;
  bool _disposed = false;

  /// How many times the database has been read (for tests).
  @visibleForTesting
  int queries = 0;

  /// True when the last view held too many records to read (see
  /// [signalHeatMaxRecords]): there are no points then.
  bool tooMuch = false;

  /// What to draw: null when the layer is off.
  List<HeatPoint>? get points => _points;

  bool get enabled => _enabled;

  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    _refresh?.cancel();
    _refresh = null;
    if (value) {
      _points = const [];
      _refresh = Timer.periodic(refreshEvery, (_) => _request());
      _request();
    } else {
      _cooldown?.cancel();
      _cooldown = null;
      _pending = false;
      _points = null;
      _loaded = null;
      tooMuch = false;
    }
    notifyListeners();
  }

  /// Tells where the camera is; cheap, may be called on every camera change.
  void viewChanged(LatLng center, double zoom, Size view) {
    if (view.isEmpty || !zoom.isFinite) return;
    _view = (center, zoom, view);
    if (!_enabled) return;
    final loaded = _loaded;
    if (loaded != null &&
        loaded.serves(SignalHeatArea.of(center, zoom, view))) {
      return;
    }
    _request();
  }

  void _request() {
    if (!_enabled || _disposed) return;
    if (_cooldown != null) {
      _pending = true;
      return;
    }
    _load();
  }

  void _load() {
    final view = _view;
    final db = database();
    if (view == null || db == null) return;
    final (center, zoom, size) = view;
    final watch = Stopwatch()..start();
    final List<HeatPoint> points;
    try {
      final read = querySignalHeat(db, center, zoom, size);
      tooMuch = read == null;
      points = read ?? const [];
    } on Object catch (e) {
      // A closed or busy database: the layer keeps what it has.
      debugPrint('Signal map not read: $e');
      return;
    }
    queries++;
    _loaded = SignalHeatArea.of(center, zoom, size);
    // A slow read (a huge database, a view of a whole country) is repeated
    // less often: the pause is at least twenty times what the read took.
    final pause = watch.elapsed * 20;
    _pending = false;
    _cooldown = Timer(pause > minInterval ? pause : minInterval, () {
      _cooldown = null;
      if (_pending) _request();
    });
    if (!listEquals(points, _points)) {
      _points = points;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cooldown?.cancel();
    _refresh?.cancel();
    super.dispose();
  }
}
