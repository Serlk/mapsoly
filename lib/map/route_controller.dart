import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../places/camera_alert.dart';
import '../places/cameras.dart';
import '../places/places_database.dart';
import '../routing/valhalla_client.dart';
import '../routing/valhalla_service.dart';
import '../traffic/traffic_sampler.dart';
import 'drive_camera.dart' show routeBearingAt;
import 'guidance.dart';

/// One stop of the trip being planned.
@immutable
class RouteStop {
  /// A fixed point, with the name it was found under (null: a map point).
  const RouteStop(LatLng this.point, {this.label}) : myPosition = false;

  /// "Wherever the device is". Only the first stop can be one. [point] is
  /// the fallback while there is no fix.
  const RouteStop.myPosition([this.point]) : label = null, myPosition = true;

  final LatLng? point;
  final String? label;
  final bool myPosition;

  @override
  bool operator ==(Object other) =>
      other is RouteStop &&
      other.point == point &&
      other.label == label &&
      other.myPosition == myPosition;

  @override
  int get hashCode => Object.hash(point, label, myPosition);
}

/// What a finished trip looked like, for the arrival card.
@immutable
class TripSummary {
  const TripSummary({
    required this.distanceM,
    required this.duration,
    this.label,
  });

  /// Metres driven along the route while guidance was on.
  final double distanceM;
  final Duration duration;

  /// Name of the destination, if it has one.
  final String? label;
}

/// The stop guidance is heading to, or has just reached.
@immutable
class StopNotice {
  const StopNotice({
    required this.number,
    required this.stop,
    required this.distanceM,
    required this.reached,
  });

  /// Position in the stop list, 1-based (the start is 1).
  final int number;
  final RouteStop stop;

  /// Metres left to it along the route (0 once [reached]).
  final double distanceM;
  final bool reached;
}

/// State of the trip being planned and driven: the stops, the computed
/// alternatives, the selection and guidance along the selected route.
class RouteController extends ChangeNotifier {
  RoutingBackend? _backend;

  /// Supplies a reader of the current traffic picture (null: no traffic
  /// data), used to re-estimate travel times of driving routes.
  TrafficSampler? Function()? trafficSampler;
  List<Duration?> _trafficTimes = const [];

  /// Installed pack's places database: the source of speed cameras.
  PlacesDatabase? places;

  /// Places databases of the other installed packs: more speed cameras.
  List<PlacesDatabase> morePlaces = const [];

  /// A routing client used instead of the pack's own backend.
  @visibleForTesting
  ValhallaClient? debugClient;

  /// Pause between an edit of the stop list and the routing request.
  Duration debounce = const Duration(milliseconds: 400);

  RouteTracker? _tracker;
  RouteProgress? _progress;
  CameraAlerter? _cameras;
  final _offRoute = OffRouteDetector();
  final _clock = Stopwatch()..start();
  double? _speedKmh;
  bool _speeding = false;
  bool _resumeGuidance = false;
  Directory? _pack;

  // The stops in driving order. While [_needStart] is set they are all
  // destinations and the start is still to be chosen.
  List<RouteStop> _stops = [];
  bool _needStart = false;
  LatLng? _myPosition;
  bool _guiding = false;
  int _step = 0;
  RouteCosting _costing = RouteCosting.auto;
  List<Route> _routes = const [];
  int _selected = 0;
  bool _loading = false;
  String? _error;
  int? _errorStop;
  int _request = 0;
  Timer? _debounce;

  // Guidance over several legs.
  List<double> _legEnds = const [];
  int _reached = 0;
  double _drivenM = 0;
  double? _lastAlong;
  final _trip = Stopwatch();
  TripSummary? _arrival;

  LatLng? _pointOf(RouteStop s) =>
      s.myPosition ? _myPosition ?? s.point : s.point;

  /// The stops in driving order. Without [needStart] the first one is the
  /// start.
  List<RouteStop> get stops => List.unmodifiable(_stops);

  /// True when there are destinations but no start yet (no position fix and
  /// none chosen).
  bool get needStart => _needStart;

  /// Where stop [index] is right now (null: my position without a fix).
  LatLng? pointOf(int index) => _pointOf(_stops[index]);

  /// Start of the route: the chosen point, or the current position while
  /// [fromIsMyPosition] is set.
  LatLng? get from =>
      _needStart || _stops.isEmpty ? null : _pointOf(_stops.first);

  /// Names of the endpoints when they came from search (null: map point).
  String? get fromLabel =>
      _needStart || _stops.isEmpty ? null : _stops.first.label;
  String? get toLabel => _destination?.label;

  RouteStop? get _destination {
    if (_stops.length > 1) return _stops.last;
    return _needStart && _stops.isNotEmpty ? _stops.last : null;
  }

  /// True when the route starts from wherever the device currently is.
  bool get fromIsMyPosition =>
      !_needStart && _stops.isNotEmpty && _stops.first.myPosition;

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

  /// Direction of the route at the matched position, in degrees clockwise
  /// from north; null without a matched position.
  double? get routeBearing {
    final t = _tracker, p = progress;
    return t == null || p == null ? null : routeBearingAt(t, p.alongM);
  }

  /// Metres to the start of the next maneuver while guiding with a fix.
  double? get toNextManeuverM {
    final route = selected, t = _tracker, p = progress;
    if (route == null || t == null || p == null) return null;
    final steps = route.maneuvers.toList();
    final next = _step + 1;
    if (next >= steps.length) return null;
    final d = t.alongOf(steps[next].beginShapeIndex) - p.alongM;
    return d < 0 ? 0 : d;
  }

  /// Metres left to the destination while guiding with a fix.
  double? get remainingM {
    final t = _tracker, p = progress;
    return t == null || p == null ? null : t.lengthM - p.alongM;
  }

  /// Set once the destination is reached while guiding: the trip in short.
  /// Guidance stays on (showing this) until [clear] or [stopGuidance].
  TripSummary? get arrival => _guiding ? _arrival : null;

  /// While guiding with a fix over a route with intermediate stops: the
  /// stop ahead when it is near, or the one just reached. Null otherwise.
  StopNotice? get stopNotice {
    final p = progress;
    if (p == null || _legEnds.length < 2) return null;
    final offset = _stops.length - _legEnds.length; // index of leg 0's end
    if (_reached > 0) {
      final passed = p.alongM - _legEnds[_reached - 1];
      if (passed < 120) {
        final i = offset + _reached - 1;
        return StopNotice(
          number: i + 1,
          stop: _stops[i],
          distanceM: 0,
          reached: true,
        );
      }
    }
    if (_reached >= _legEnds.length - 1) return null; // only the end is left
    final left = _legEnds[_reached] - p.alongM;
    if (left > 500) return null;
    final i = offset + _reached;
    return StopNotice(
      number: i + 1,
      stop: _stops[i],
      distanceM: left < 0 ? 0 : left,
      reached: false,
    );
  }

  /// Current speed in km/h when the position source reports one.
  double? get speedKmh => _speedKmh;

  /// Next camera ahead on the route and the distance to it.
  RouteCamera? get nextCamera => _guiding ? _cameras?.next : null;
  double? get nextCameraDistanceM =>
      _guiding ? _cameras?.distanceToNextM : null;

  /// True while driving above the limit of the camera being approached.
  bool get speeding => _guiding && _speeding;
  LatLng? get to => _destination?.point;
  RouteCosting get costing => _costing;
  List<Route> get routes => _routes;
  int get selectedIndex => _selected;
  Route? get selected => _routes.isEmpty ? null : _routes[_selected];
  bool get loading => _loading;

  /// Length and free-flow time of the way to stop [index] from the stop
  /// before it; null for the start and while there is no route.
  RouteSummary? legTo(int index) {
    final route = selected;
    if (route == null || index < 1 || _needStart) return null;
    if (route.legs.length != _stops.length - 1) return null;
    return route.legs[index - 1].summary;
  }

  /// Travel time of route [index] with current traffic, or null when it has
  /// not been estimated (no traffic data, or not a driving route).
  Duration? trafficTime(int index) =>
      index < _trafficTimes.length ? _trafficTimes[index] : null;

  /// Best available travel time of route [index].
  Duration timeOf(int index) => trafficTime(index) ?? _routes[index].duration;

  /// User-facing reason the last request failed, in Russian.
  String? get error => _error;

  /// The stop (index in [stops]) the failure is about, when that is known.
  int? get errorStop => _error == null ? null : _errorStop;

  /// True while the user is planning: there is something to show or clear.
  bool get active => _stops.isNotEmpty;

  /// True when a region pack with a routing graph is installed.
  bool get available => _pack != null || debugClient != null;

  /// Points routing at an installed region pack (null: no offline routing).
  /// The graph shared by all packs (`<packs>/.shared/valhalla`) is used
  /// when it is there; the pack's own graph otherwise.
  void usePack(Directory? pack) {
    bool hasGraph(Directory d) =>
        File('${d.path}/valhalla/valhalla.json').existsSync();
    Directory? chosen;
    if (pack != null) {
      final shared = Directory('${pack.parent.path}/.shared');
      chosen = hasGraph(shared)
          ? shared
          : hasGraph(pack)
          ? pack
          : null;
    }
    _pack = chosen;
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
    if (p != null && hadNone && _needStart && _stops.isNotEmpty) {
      _stops.insert(0, const RouteStop.myPosition());
      _needStart = false;
      _changed();
      return;
    }
    if (p != null && _guiding && _arrival == null) _advance(p, accuracyM);
    notifyListeners();
  }

  /// Guidance step for a new fix: match it to the route, move to the right
  /// maneuver, check cameras, and re-route when the driver left the route.
  void _advance(LatLng p, double accuracyM) {
    final route = selected, tracker = _tracker;
    if (route == null || tracker == null) return;
    final progress = _progress = tracker.match(p);
    if (_offRoute.update(progress.lateralM, accuracyM)) {
      // Continue from here to the stops that are still ahead.
      final ahead = _stops.length - _legEnds.length + _reached;
      _stops = [
        RouteStop.myPosition(p),
        ..._stops.sublist(ahead.clamp(1, _stops.length - 1)),
      ];
      _resumeGuidance = true;
      _changed();
      return;
    }
    final last = _lastAlong;
    if (last != null) {
      final step = progress.alongM - last;
      // Jumps are matching artefacts, not driving.
      if (step > 0 && step < 500) _drivenM += step;
    }
    _lastAlong = progress.alongM;
    while (_reached < _legEnds.length - 1 &&
        progress.alongM >= _legEnds[_reached] - 35) {
      _reached++;
    }
    if (tracker.lengthM - progress.alongM < 30 && progress.lateralM < 60) {
      _trip.stop();
      _arrival = TripSummary(
        distanceM: _drivenM,
        duration: _trip.elapsed,
        label: _stops.last.label,
      );
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

  // ------------------------------------------------- simple from / to flow

  void setFrom(LatLng p, {String? label}) {
    final stop = RouteStop(p, label: label);
    if (_needStart || _stops.isEmpty) {
      _stops.insert(0, stop);
      _needStart = false;
    } else {
      _stops[0] = stop;
    }
    _changed();
  }

  /// Start from the current position (no-op without a fix).
  void setFromMyPosition() {
    if (_myPosition == null) return;
    if (_needStart || _stops.isEmpty) {
      _stops.insert(0, const RouteStop.myPosition());
      _needStart = false;
    } else {
      _stops[0] = const RouteStop.myPosition();
    }
    _changed();
  }

  /// Sets the destination (the last stop). With a position fix and no start
  /// chosen, the route starts from the current position.
  void setTo(LatLng p, {String? label}) {
    final stop = RouteStop(p, label: label);
    if (_destination != null) {
      _stops[_stops.length - 1] = stop;
    } else {
      _appendFirstDestination(stop);
    }
    _changed();
  }

  void _appendFirstDestination(RouteStop stop) {
    if (_stops.isEmpty) {
      if (_myPosition != null) {
        _stops.add(const RouteStop.myPosition());
      } else {
        _needStart = true;
      }
    }
    _stops.add(stop);
  }

  /// Reverses the order of the stops.
  void swap() {
    if (_needStart || _stops.length < 2) return;
    _stops = [for (final s in _stops.reversed) _frozen(s)];
    _changed();
  }

  void clearFrom() {
    if (_needStart || _stops.isEmpty) return;
    _stops.removeAt(0);
    _needStart = _stops.isNotEmpty;
    _changed();
  }

  void clearTo() {
    if (_destination == null) return;
    _stops.removeLast();
    if (_stops.isEmpty) _needStart = false;
    _changed();
  }

  // -------------------------------------------------------- trip planning

  /// "My position" turned into the point it is at now, so that the stop
  /// can sit anywhere in the list.
  RouteStop _frozen(RouteStop s) {
    if (!s.myPosition) return s;
    final p = _pointOf(s);
    return p == null ? s : RouteStop(p, label: 'Место старта');
  }

  /// Adds a stop at the end of the trip. The first one added becomes the
  /// destination of a trip from the current position (or of a trip whose
  /// start is still to be chosen, see [needStart]).
  void addStop(LatLng p, {String? label}) {
    final stop = RouteStop(p, label: label);
    if (_stops.isEmpty) {
      _appendFirstDestination(stop);
    } else {
      _stops.add(stop);
    }
    _changed(debounced: true);
  }

  /// Puts a stop at [index] (used to undo a removal).
  void insertStop(int index, RouteStop stop) {
    final i = index.clamp(0, _stops.length);
    if (stop.myPosition && i != 0) stop = _frozen(stop);
    if (i == 0 && _stops.isNotEmpty && _stops.first.myPosition) {
      _stops[0] = _frozen(_stops.first);
    }
    _stops.insert(i, stop);
    _changed(debounced: true);
  }

  /// Replaces stop [index].
  void setStop(int index, LatLng p, {String? label}) {
    if (index < 0 || index >= _stops.length) return;
    _stops[index] = RouteStop(p, label: label);
    _changed(debounced: true);
  }

  /// Removes stop [index] and returns it. Removing the start leaves the
  /// next stop as the start.
  RouteStop? removeStop(int index) {
    if (index < 0 || index >= _stops.length) return null;
    final removed = _stops.removeAt(index);
    if (_stops.isEmpty) _needStart = false;
    _changed(debounced: true);
    return removed;
  }

  /// Moves a stop from [from] to position [to] (both indexes in [stops]).
  void moveStop(int from, int to) {
    if (from < 0 || from >= _stops.length) return;
    final target = to.clamp(0, _stops.length - 1);
    if (target == from) return;
    // "My position" can only be the start: once it moves, or something
    // moves in front of it, it becomes the point it is at now.
    final list = from == 0 || target == 0
        ? [for (final s in _stops) _frozen(s)]
        : [..._stops];
    list.insert(target, list.removeAt(from));
    _stops = list;
    _changed(debounced: true);
  }

  /// Replaces the whole trip (a saved route, "home" from here).
  void setStops(List<RouteStop> stops, {RouteCosting? costing}) {
    _stops = [
      for (var i = 0; i < stops.length; i++)
        i == 0 ? stops[i] : _frozen(stops[i]),
    ];
    _needStart = false;
    if (_stops.length == 1 && !_stops.first.myPosition) {
      // A lone destination: start from here when that is possible.
      if (_myPosition != null) {
        _stops.insert(0, const RouteStop.myPosition());
      } else {
        _needStart = true;
      }
    }
    if (costing != null) _costing = costing;
    _changed();
  }

  // --------------------------------------------------------------- guidance

  void startGuidance() => _startGuidance(resume: false);

  void _startGuidance({required bool resume}) {
    final route = selected;
    if (route == null) return;
    _guiding = true;
    _step = 0;
    _progress = null;
    _speeding = false;
    _offRoute.reset();
    final tracker = _tracker = RouteTracker(route.shape);
    _legEnds = [
      for (final leg in route.legs)
        tracker.alongOf(leg.shapeOffset + leg.shape.length - 1),
    ];
    _reached = 0;
    _lastAlong = null;
    _arrival = null;
    if (!resume) {
      _drivenM = 0;
      _trip
        ..reset()
        ..start();
    }
    try {
      final found = [
        for (final db in <PlacesDatabase>{?places, ...morePlaces})
          ...db.camerasAlong(route.shape),
      ];
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
    _arrival = null;
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
    _changed();
  }

  void select(int index) {
    if (index == _selected || index >= _routes.length) return;
    _selected = index;
    notifyListeners();
  }

  void clear() {
    _request++;
    _debounce?.cancel();
    _stops = [];
    _needStart = false;
    _guiding = false;
    _arrival = null;
    _step = 0;
    _routes = const [];
    _trafficTimes = const [];
    _selected = 0;
    _loading = false;
    _error = null;
    _errorStop = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------- routing

  List<LatLng>? get _locations {
    if (_needStart || _stops.length < 2) return null;
    final out = <LatLng>[];
    for (final s in _stops) {
      final p = _pointOf(s);
      if (p == null) return null;
      out.add(p);
    }
    return out;
  }

  /// The stop list changed: compute the route again, after a short pause
  /// when the change came from editing the list (more edits usually follow).
  void _changed({bool debounced = false}) {
    _debounce?.cancel();
    if (debounced &&
        available &&
        _locations != null &&
        debounce > Duration.zero) {
      _request++;
      _reset();
      _loading = true;
      notifyListeners();
      _debounce = Timer(debounce, _build);
    } else {
      _build();
    }
  }

  void _reset() {
    _guiding = false;
    _arrival = null;
    _step = 0;
    _routes = const [];
    _trafficTimes = const [];
    _selected = 0;
    _error = null;
    _errorStop = null;
  }

  Future<void> _build() async {
    final locations = _locations;
    final request = ++_request;
    final resume = _resumeGuidance;
    _resumeGuidance = false;
    _reset();
    _loading = false;
    if (locations == null) {
      notifyListeners();
      return;
    }
    if (!available) {
      _error = 'Нет офлайн-данных для маршрутов';
      notifyListeners();
      return;
    }
    _loading = true;
    notifyListeners();
    String? error;
    int? errorStop;
    var routes = const <Route>[];
    try {
      final client = await _client();
      try {
        final result = await client.route(
          locations: locations,
          costing: _costing,
          // Valhalla offers alternatives only between two points.
          alternates: locations.length == 2 ? 2 : 0,
          stopAtVias: true,
        );
        routes = result.routes;
      } on ValhallaException catch (e) {
        errorStop = locations.length > 2
            ? await _failingStop(client, locations, e)
            : null;
        error = _describe(e, errorStop);
      }
    } on Exception catch (e) {
      debugPrint('Routing failed: $e');
      error = 'Сервис маршрутов не запустился';
    }
    if (_disposed || request != _request) return; // superseded
    _loading = false;
    _routes = routes;
    _trafficTimes = const [];
    _error = error;
    _errorStop = errorStop;
    // After leaving the route, guidance continues on the new one.
    if (resume && routes.isNotEmpty) {
      _startGuidance(resume: true);
    } else {
      notifyListeners();
    }
    if (routes.isNotEmpty && _costing == RouteCosting.auto) {
      await _estimateTraffic(request, routes);
    }
  }

  Future<ValhallaClient> _client() async {
    final debug = debugClient;
    if (debug != null) return debug;
    final backend = _backend ??= RoutingBackend.forPack(
      _pack!,
      onLog: (line) => debugPrint('valhalla: $line'),
    );
    await backend.start();
    return backend.client;
  }

  /// Short name of a stop for messages.
  String _nameOf(int index) {
    final s = _stops[index];
    final label = s.myPosition ? 'Моё местоположение' : s.label;
    return label == null ? '№ ${index + 1}' : '${index + 1} «$label»';
  }

  String _describe(ValhallaException e, int? stop) {
    if (stop != null && stop < _stops.length) {
      final name = _nameOf(stop);
      if (e.noRoadNearby) return 'Рядом с остановкой $name нет дороги';
      if (e.tooFar) {
        return 'До остановки $name слишком далеко для этого способа '
            'передвижения';
      }
      return 'Не удалось проложить путь до остановки $name';
    }
    return e.noRoadNearby
        ? 'Рядом с точкой нет дороги'
        : e.tooFar
        ? 'Слишком далеко для этого способа передвижения'
        : e.noRoute
        ? 'Маршрут не найден'
        : 'Маршрут не построен: ${e.message}';
  }

  /// Finds which stop a failed request is about: the one without a road
  /// next to it, or the first one that cannot be reached from the stop
  /// before. Valhalla's own error does not say.
  Future<int?> _failingStop(
    ValhallaClient client,
    List<LatLng> locations,
    ValhallaException failure,
  ) async {
    try {
      if (failure.noRoadNearby) {
        for (var i = 0; i < locations.length; i++) {
          if (await client.locate(locations[i], costing: _costing) == null) {
            return i;
          }
        }
        return null;
      }
      for (var i = 1; i < locations.length; i++) {
        try {
          await client.route(
            locations: [locations[i - 1], locations[i]],
            costing: _costing,
          );
        } on ValhallaException {
          return i;
        }
      }
    } on Exception catch (e) {
      debugPrint('Could not tell which stop failed: $e');
    }
    return null;
  }

  /// Re-estimates each alternative from traffic colours along it and selects
  /// the fastest. Failures leave the free-flow times in place.
  Future<void> _estimateTraffic(int request, List<Route> routes) async {
    final sampler = trafficSampler?.call();
    final client = debugClient ?? _backend?.client;
    if (sampler == null || client == null) return;
    final times = <Duration?>[];
    for (final route in routes) {
      try {
        // All legs of the route, with shape indexes into the joined shape.
        final edges = await client.edges(route);
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
      if (_disposed || request != _request) return;
    }
    _trafficTimes = times;
    var best = 0;
    for (var i = 1; i < routes.length; i++) {
      if (timeOf(i) < timeOf(best)) best = i;
    }
    if (!_guiding) _selected = best;
    notifyListeners();
  }

  /// Puts the controller into a planned state without a routing backend.
  /// Without [stops] the trip goes from [from] to [to].
  @visibleForTesting
  void debugSetRoutes(
    List<Route> routes, {
    required LatLng from,
    required LatLng to,
    List<RouteStop>? stops,
    List<Duration?> trafficTimes = const [],
    bool loading = false,
    String? error,
    int? errorStop,
  }) {
    _stops = stops == null ? [RouteStop(from), RouteStop(to)] : [...stops];
    _needStart = false;
    _routes = routes;
    _trafficTimes = trafficTimes;
    _selected = 0;
    _loading = loading;
    _error = error;
    _errorStop = errorStop;
    notifyListeners();
  }

  bool _disposed = false;

  /// Sets the travel mode without routing again.
  @visibleForTesting
  void setCostingForTest(RouteCosting c) {
    _costing = c;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    _debounce?.cancel();
    _backend?.dispose();
    super.dispose();
  }
}

String formatDistance(double meters) {
  if (meters < 950) return '${(meters / 10).round() * 10} м';
  final km = meters / 1000;
  return km < 10
      ? '${km.toStringAsFixed(1).replaceAll('.', ',')} км'
      : '${km.round()} км';
}

String formatDuration(Duration d) {
  final minutes = (d.inSeconds / 60).round();
  if (minutes < 60) return '${minutes < 1 ? 1 : minutes} мин';
  final h = minutes ~/ 60, m = minutes % 60;
  return m == 0 ? '$h ч' : '$h ч $m мин';
}

/// "14:05".
String formatClock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// What to call a stop on screen.
String stopTitle(RouteStop stop) {
  if (stop.myPosition) return 'Моё местоположение';
  final label = stop.label;
  if (label != null && label.isNotEmpty) return label;
  final p = stop.point!;
  return '${p.latitude.toStringAsFixed(4)}, ${p.longitude.toStringAsFixed(4)}';
}
