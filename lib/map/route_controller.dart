import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../places/camera_alert.dart';
import '../places/cameras.dart';
import '../places/places_database.dart';
import '../routing/valhalla_client.dart';
import '../routing/valhalla_service.dart';
import '../traffic/traffic_sampler.dart';
import 'guidance.dart';

/// State of the route being planned: endpoints, alternatives, selection.
class RouteController extends ChangeNotifier {
  RoutingBackend? _backend;

  /// Supplies a reader of the current traffic picture (null: no traffic
  /// data), used to re-estimate travel times of driving routes.
  TrafficSampler? Function()? trafficSampler;
  List<Duration?> _trafficTimes = const [];

  /// Installed pack's places database: the source of speed cameras.
  PlacesDatabase? places;

  RouteTracker? _tracker;
  RouteProgress? _progress;
  CameraAlerter? _cameras;
  final _offRoute = OffRouteDetector();
  final _clock = Stopwatch()..start();
  double? _speedKmh;
  bool _speeding = false;
  bool _resumeGuidance = false;
  Directory? _pack;

  LatLng? _from, _to;
  LatLng? _myPosition;
  String? _fromLabel, _toLabel;
  bool _fromIsMyPosition = false;
  bool _guiding = false;
  int _step = 0;
  RouteCosting _costing = RouteCosting.auto;
  List<Route> _routes = const [];
  int _selected = 0;
  bool _loading = false;
  String? _error;
  int _request = 0;

  /// Start of the route: the chosen point, or the current position while
  /// [fromIsMyPosition] is set.
  LatLng? get from => _fromIsMyPosition ? _myPosition ?? _from : _from;

  /// Names of the endpoints when they came from search (null: map point).
  String? get fromLabel => _fromIsMyPosition ? null : _fromLabel;
  String? get toLabel => _toLabel;

  /// True when the route starts from wherever the device currently is.
  bool get fromIsMyPosition => _fromIsMyPosition;

  /// Latest known device position, null when positioning has no fix.
  LatLng? get myPosition => _myPosition;

  /// True while the user is following the route step by step.
  bool get guiding => _guiding;

  /// Index of the maneuver currently shown in guidance.
  int get step => _step;

  /// Matched position on the route while guiding with a position fix; null
  /// when maneuvers are being stepped through by hand.
  RouteProgress? get progress => _guiding ? _progress : null;

  /// Distance along the selected route to shape point [shapeIndex].
  double alongOf(int shapeIndex) => _tracker?.alongOf(shapeIndex) ?? 0;

  /// Metres left to the destination while guiding with a fix.
  double? get remainingM {
    final t = _tracker, p = progress;
    return t == null || p == null ? null : t.lengthM - p.alongM;
  }

  /// Current speed in km/h when the position source reports one.
  double? get speedKmh => _speedKmh;

  /// Next camera ahead on the route and the distance to it.
  RouteCamera? get nextCamera => _guiding ? _cameras?.next : null;
  double? get nextCameraDistanceM =>
      _guiding ? _cameras?.distanceToNextM : null;

  /// True while driving above the limit of the camera being approached.
  bool get speeding => _guiding && _speeding;
  LatLng? get to => _to;
  RouteCosting get costing => _costing;
  List<Route> get routes => _routes;
  int get selectedIndex => _selected;
  Route? get selected => _routes.isEmpty ? null : _routes[_selected];
  bool get loading => _loading;

  /// Travel time of route [index] with current traffic, or null when it has
  /// not been estimated (no traffic data, or not a driving route).
  Duration? trafficTime(int index) =>
      index < _trafficTimes.length ? _trafficTimes[index] : null;

  /// Best available travel time of route [index].
  Duration timeOf(int index) => trafficTime(index) ?? _routes[index].duration;

  /// User-facing reason the last request failed, in Russian.
  String? get error => _error;

  /// True while the user is planning: there is something to show or clear.
  bool get active => _from != null || _to != null;

  /// True when a region pack with a routing graph is installed.
  bool get available => _pack != null;

  /// Points routing at an installed region pack (null: no offline routing).
  void usePack(Directory? pack) {
    final hasGraph =
        pack != null &&
        File('${pack.path}/valhalla/valhalla.json').existsSync();
    _pack = hasGraph ? pack : null;
    _backend?.dispose();
    _backend = null;
    notifyListeners();
  }

  /// Feeds the device position. A route that starts "from my position" is
  /// not rebuilt on every fix; guidance handles movement along it.
  void updateMyPosition(LatLng? p, {double accuracyM = 30, double? speedMps}) {
    final hadNone = _myPosition == null;
    _myPosition = p;
    _speedKmh = speedMps == null ? null : speedMps * 3.6;
    if (p != null && hadNone && _to != null && _from == null) {
      _fromIsMyPosition = true;
      _build();
      return;
    }
    if (p != null && _guiding) _advance(p, accuracyM);
    notifyListeners();
  }

  /// Guidance step for a new fix: match it to the route, move to the right
  /// maneuver, check cameras, and re-route when the driver left the route.
  void _advance(LatLng p, double accuracyM) {
    final route = selected, tracker = _tracker;
    if (route == null || tracker == null) return;
    final progress = _progress = tracker.match(p);
    if (_offRoute.update(progress.lateralM, accuracyM)) {
      _resumeGuidance = true;
      _fromIsMyPosition = true;
      _build();
      return;
    }
    final steps = route.maneuvers.toList();
    var step = 0;
    for (var i = 0; i < steps.length; i++) {
      if (tracker.alongOf(steps[i].beginShapeIndex) <= progress.alongM + 5) {
        step = i;
      }
    }
    _step = step;
    final cameras = _cameras;
    if (cameras != null) {
      for (final alert in cameras.update(
        alongM: progress.alongM,
        speedKmh: _speedKmh ?? 0,
        time: _clock.elapsed,
      )) {
        switch (alert.kind) {
          case CameraAlertKind.speeding || CameraAlertKind.zoneSpeeding:
            _speeding = true;
          case CameraAlertKind.passed || CameraAlertKind.zoneLeft:
            _speeding = false;
          default:
            break;
        }
      }
    }
  }

  void setFrom(LatLng p, {String? label}) {
    _from = p;
    _fromLabel = label;
    _fromIsMyPosition = false;
    _build();
  }

  /// Start from the current position (no-op without a fix).
  void setFromMyPosition() {
    if (_myPosition == null) return;
    _fromIsMyPosition = true;
    _build();
  }

  /// Sets the destination. With a position fix and no start chosen, the
  /// route starts from the current position.
  void setTo(LatLng p, {String? label}) {
    _to = p;
    _toLabel = label;
    if (_from == null && _myPosition != null) _fromIsMyPosition = true;
    _build();
  }

  void swap() {
    final start = from, end = _to;
    final startLabel = fromLabel, endLabel = _toLabel;
    _from = end;
    _to = start;
    _fromLabel = endLabel;
    _toLabel = startLabel;
    _fromIsMyPosition = false;
    _build();
  }

  void clearFrom() {
    _from = null;
    _fromLabel = null;
    _fromIsMyPosition = false;
    _build();
  }

  void clearTo() {
    _to = null;
    _toLabel = null;
    _build();
  }

  void startGuidance() {
    final route = selected;
    if (route == null) return;
    _guiding = true;
    _step = 0;
    _progress = null;
    _speeding = false;
    _offRoute.reset();
    _tracker = RouteTracker(route.shape);
    try {
      final found = places?.camerasAlong(route.shape) ?? const [];
      // A re-route must not announce again the cameras already warned about.
      _cameras = CameraAlerter(found, alreadyWarned: _cameras?.warnedKeys);
    } on Exception catch (e) {
      debugPrint('Cameras not loaded: $e');
      _cameras = null;
    }
    final here = _myPosition;
    if (here != null) _advance(here, 30);
    notifyListeners();
  }

  void stopGuidance() {
    _guiding = false;
    _cameras = null;
    notifyListeners();
  }

  /// Moves guidance to another maneuver (manual until positioning drives it).
  void goToStep(int index) {
    final route = selected;
    if (route == null) return;
    final last = route.maneuvers.length - 1;
    _step = index < 0 ? 0 : (index > last ? last : index);
    notifyListeners();
  }

  void setCosting(RouteCosting c) {
    if (c == _costing) return;
    _costing = c;
    _build();
  }

  void select(int index) {
    if (index == _selected || index >= _routes.length) return;
    _selected = index;
    notifyListeners();
  }

  void clear() {
    _request++;
    _from = _to = null;
    _fromLabel = _toLabel = null;
    _fromIsMyPosition = false;
    _guiding = false;
    _step = 0;
    _routes = const [];
    _selected = 0;
    _loading = false;
    _error = null;
    notifyListeners();
  }

  Future<void> _build() async {
    final from = this.from, to = _to, pack = _pack;
    final request = ++_request;
    final resume = _resumeGuidance;
    _resumeGuidance = false;
    _guiding = false;
    _step = 0;
    _routes = const [];
    _trafficTimes = const [];
    _selected = 0;
    _error = null;
    if (from == null || to == null) {
      notifyListeners();
      return;
    }
    if (pack == null) {
      _error = 'Нет офлайн-данных для маршрутов';
      notifyListeners();
      return;
    }
    _loading = true;
    notifyListeners();
    String? error;
    var routes = const <Route>[];
    try {
      final backend = _backend ??= RoutingBackend.forPack(
        pack,
        onLog: (line) => debugPrint('valhalla: $line'),
      );
      await backend.start();
      final result = await backend.client.route(
        locations: [from, to],
        costing: _costing,
        alternates: 2,
      );
      routes = result.routes;
    } on ValhallaException catch (e) {
      error = e.noRoadNearby
          ? 'Рядом с точкой нет дороги'
          : e.tooFar
          ? 'Слишком далеко для этого способа передвижения'
          : e.noRoute
          ? 'Маршрут не найден'
          : 'Маршрут не построен: ${e.message}';
    } on Exception catch (e) {
      debugPrint('Routing failed: $e');
      error = 'Сервис маршрутов не запустился';
    }
    if (request != _request) return; // superseded by a newer request
    _loading = false;
    _routes = routes;
    _trafficTimes = const [];
    _error = error;
    // After leaving the route, guidance continues on the new one.
    if (resume && routes.isNotEmpty) {
      startGuidance();
    } else {
      notifyListeners();
    }
    if (routes.isNotEmpty && _costing == RouteCosting.auto) {
      await _estimateTraffic(request, routes);
    }
  }

  /// Re-estimates each alternative from traffic colours along it and selects
  /// the fastest. Failures leave the free-flow times in place.
  Future<void> _estimateTraffic(int request, List<Route> routes) async {
    final sampler = trafficSampler?.call();
    final backend = _backend;
    if (sampler == null || backend == null) return;
    final times = <Duration?>[];
    for (final route in routes) {
      try {
        final edges = await backend.client.edges(route);
        final freeFlow = edges.fold(0.0, (s, e) => s + e.freeFlowSeconds);
        final estimate = await sampler.estimate(route.shape, [
          for (final e in edges)
            TrafficSegment(
              e.beginShapeIndex,
              e.endShapeIndex,
              e.freeFlowSeconds,
            ),
        ]);
        debugPrint(
          'traffic: ${edges.length} edges, free-flow ${freeFlow.round()} s, '
          'with traffic ${estimate.seconds.round()} s, '
          'coverage ${(estimate.coverage * 100).round()}%',
        );
        // Turn and wait costs outside the edges stay as routed.
        final rest = route.timeSeconds - freeFlow;
        times.add(
          estimate.coverage < 0.2
              ? null
              : Duration(
                  seconds: (estimate.seconds + (rest > 0 ? rest : 0)).round(),
                ),
        );
      } on Exception catch (e) {
        debugPrint('Traffic estimate failed: $e');
        times.add(null);
      }
      if (request != _request) return;
    }
    _trafficTimes = times;
    var best = 0;
    for (var i = 1; i < routes.length; i++) {
      if (timeOf(i) < timeOf(best)) best = i;
    }
    if (!_guiding) _selected = best;
    notifyListeners();
  }

  @override
  void dispose() {
    _backend?.dispose();
    super.dispose();
  }
}

String formatDistance(double meters) {
  if (meters < 950) return '${(meters / 10).round() * 10} м';
  final km = meters / 1000;
  return km < 10 ? '${km.toStringAsFixed(1)} км' : '${km.round()} км';
}

String formatDuration(Duration d) {
  final minutes = (d.inSeconds / 60).round();
  if (minutes < 60) return '${minutes < 1 ? 1 : minutes} мин';
  final h = minutes ~/ 60, m = minutes % 60;
  return m == 0 ? '$h ч' : '$h ч $m мин';
}
