import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../obd/obd_service.dart';
import '../obd/obd_widgets.dart';
import '../offline/offline_map.dart';
import '../packs/pack_downloads.dart';
import '../packs/pack_store.dart';
import '../packs/packs_screen.dart';
import '../places/photon_geocoder.dart';
import '../places/places_database.dart';
import '../places/search_panel.dart';
import '../positioning/positioning.dart';
import '../settings.dart';
import '../sensors_screen.dart';
import '../settings_screen.dart';
import '../traffic/traffic.dart';
import '../user/file_exchange.dart';
import '../user/places_screen.dart';
import '../user/user_data.dart';
import '../user/user_places.dart';
import 'alert_sound.dart';
import 'drive_camera.dart';
import 'engine/engines.dart';
import 'engine/map_engine.dart';
import 'guidance.dart';
import 'keep_awake.dart';
import 'location_sheet.dart';
import 'point_picker.dart';
import 'route_controller.dart';
import 'speed_limit.dart';
import 'speedometer.dart';
import 'route_panel.dart';
import 'routes_screen.dart';
import 'ui_kit.dart';

/// Sections of the main screen, in the order of the bottom bar.
enum _Section { search, navigator, routes, settings }

/// Stand-ins for what the screen normally creates itself, so that it can
/// be pumped in a widget test.
@visibleForTesting
class MapScreenTestHooks {
  MapScreenTestHooks({
    required this.controller,
    required this.mapView,
    this.engine,
    this.route,
    this.obd,
    this.files,
    this.compass,
  });

  final MapViewController controller;

  /// Drawn instead of the real map view.
  final Widget Function(MapScene scene) mapView;

  /// Positioning engine to use (not started by the screen's own sources).
  final PositioningEngine? engine;

  /// The trip controller to use (disposed by the screen).
  final RouteController? route;
  final ObdService? obd;
  final FileExchange? files;
  final CompassSource? compass;
}

class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    required this.settings,
    required this.user,
    this.testHooks,
  });

  final AppSettings settings;

  /// Saved places and routes, privacy zones and their guard.
  final UserData user;

  @visibleForTesting
  final MapScreenTestHooks? testHooks;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

/// A "choose a point on the map" request in progress.
class _Pick {
  _Pick(this.title, this.returnTo);

  final String title;
  final _Section returnTo;
  final completer = Completer<PickedPlace?>();
}

class _MapScreenState extends State<MapScreen> implements MapServices {
  late final MapViewController _map =
      widget.testHooks?.controller ?? createMapController();
  final _traffic = TrafficController();
  late final RouteController _route =
      widget.testHooks?.route ?? RouteController();
  List<OfflineMap> _offline = const [];
  bool _offlineLoading = true;
  Timer? _saveCamera;
  Object? _fittedRoute;
  Object? _shownStep;
  LatLng? _picked;
  String? _pickedLabel;
  List<PlacesDatabase> _places = const [];
  final _photon = PhotonGeocoder();
  late final FileExchange _files =
      widget.testHooks?.files ?? createFileExchange();
  // Debug hook: MAPSOLY_SEARCH="query" opens search with that text.
  final _initialQuery = Platform.environment['MAPSOLY_SEARCH'] ?? '';
  late _Section _section = _initialQuery.isNotEmpty
      ? _Section.search
      : _Section.navigator;
  bool get _searching => _section == _Section.search;

  // The routes and settings sections keep their own page stacks, so that a
  // screen opened there stays as it was while the user picks a point on the
  // map.
  final _routesNav = GlobalKey<NavigatorState>();
  final _settingsNav = GlobalKey<NavigatorState>();
  final _routesTab = ValueNotifier(0);
  // Bumped when something the section roots are built from is replaced.
  final _epoch = ValueNotifier(0);
  final _glass = GlassRegistry();
  final _mapKey = GlobalKey();
  final _bannerKey = GlobalKey();
  _Pick? _pick;

  // Ending the route asks first; the question goes away by itself.
  bool _confirmEnd = false;
  Timer? _confirmEndTimer;

  // Camera modes.
  LocationMode _locationMode = LocationMode.free;
  final _follow = FollowState();
  final _driveCamera = DriveCamera();
  final _heading = AngleSmoother();
  CompassSource? _compass;
  StreamSubscription<double>? _compassSub;
  double? _compassHeading;
  bool _driving = false;
  bool _tilted = false;
  bool _tiltRestored = false;
  Size _viewSize = Size.zero;

  // Speed, the limit of the road, and the controls that hide on the move.
  late final SpeedLimitTracker _speedLimit = SpeedLimitTracker(
    _route.drivenEdge,
  );
  final _chrome = DriveChrome();
  final _keepAwake = KeepAwake();
  final _speedAlarm = SpeedingAlarm();
  Timer? _chromeTimer;
  Offset? _pointerDownAt;
  bool _cruising = false;
  bool _compassMode = false;
  double? _markerHeading;
  final _markerSmoother = AngleSmoother(deadbandDeg: 2, factor: 0.5);
  bool _hasCompass = false;

  // Map downloads: they go on while the "Maps" screen is closed.
  PackDownloads? _downloads;

  void _open(_Section section) => setState(() => _section = section);

  /// A card at the bottom needs the bar and buttons to act on it.
  bool get _showsCard =>
      _route.arrival != null ||
      (!_route.guiding && (_picked != null || _route.active));

  /// The bottom bar and the map buttons are out of the way: the car is
  /// moving and nothing on screen is waiting for an answer.
  bool get _chromeHidden =>
      _section == _Section.navigator &&
      _pick == null &&
      !_showsCard &&
      !_confirmEnd &&
      _chrome.hidden;

  /// A touch brings the hidden controls back for a few seconds.
  void _revealChrome() {
    if (!_chrome.moving) return;
    final wasHidden = _chromeHidden;
    _chrome.reveal();
    _chromeTimer?.cancel();
    _chromeTimer = Timer(DriveChrome.revealFor, () {
      _chrome.conceal();
      _rebuild();
    });
    if (wasHidden) setState(() {});
  }

  /// The limit for the sign next to the speed: the one mapped on the
  /// road; else the limit of the camera being approached, which is what
  /// will be enforced; else the general rule for this kind of road.
  RoadLimit? get _limit {
    final road = _speedLimit.limit;
    if (road != null && road.posted) return road;
    final camera = _route.nextCamera?.camera.maxSpeedKmh;
    final distance = _route.nextCameraDistanceM;
    if (camera != null && distance != null && distance < 700) {
      return RoadLimit(camera);
    }
    return road;
  }

  /// Speed known right now, km/h.
  double? get _speedKmh {
    final fromRoute = _route.speedKmh;
    if (fromRoute != null) return fromRoute;
    final mps = _positioning?.estimate?.speedMps;
    return mps == null ? null : mps * 3.6;
  }

  /// Driving without guidance began or ended: tilt the map and turn it
  /// along the way ("3D in a trip" in the settings), then put it back.
  void _applyCruise() {
    if (!_map.ready || _map.maxPitch <= 0 || !widget.settings.drive3d) return;
    final tilted = math.min(tiltedPitch, _map.maxPitch);
    if (_cruising) {
      _map.moveCamera(pitch: tilted);
      // A map that was following the position now also turns with it; a
      // map the user moved away stays where they left it.
      if (_locationMode == LocationMode.centered) {
        _setLocationMode(LocationMode.heading);
      }
    } else {
      _map.moveCamera(pitch: widget.settings.tilted ? tilted : 0);
    }
  }

  /// Once per position update: is the car moving, and on what road.
  void _trackDriving() {
    final speed = _speedKmh;
    final wasHidden = _chromeHidden;
    _chrome.update(speed, DateTime.now());
    // The bottom bar is not rebuilt with the route, so say it out loud.
    if (_chromeHidden != wasHidden) _rebuild();
    if (_speedAlarm.update(speed, _limit?.kmh, DateTime.now()) &&
        widget.settings.speedSound) {
      unawaited(AlertSound.play());
    }
    // Asked again here in case the first request came before the window
    // was ready.
    _keepAwake.set(true);
    final progress = _route.progress;
    // Moving without a route: the map still goes 3D, unless switched off.
    final cruising = _chrome.moving && progress == null;
    if (cruising != _cruising) {
      _cruising = cruising;
      _applyCruise();
    }
    final at = progress?.point ?? _route.myPosition;
    if (at == null || speed == null || speed < 5) {
      if (!_chrome.moving) _speedLimit.reset();
      return;
    }
    _speedLimit.update(
      at,
      progress != null
          ? _route.routeBearing
          : _positioning?.estimate?.courseDeg,
    );
  }

  /// True when "back" has something to close inside this screen.
  bool get _canGoBack =>
      _pick != null ||
      _section != _Section.navigator ||
      _picked != null ||
      _route.guiding ||
      _route.active;

  /// "Back": undo the most recent step, one at a time — cancel picking a
  /// point, close a screen inside a section, leave the section, drop the
  /// picked point, end guidance (asking first), then close the route.
  void _goBack() {
    if (_pick != null) {
      _finishPick(null);
      return;
    }
    switch (_section) {
      case _Section.routes || _Section.settings:
        final nav = _section == _Section.routes
            ? _routesNav.currentState
            : _settingsNav.currentState;
        if (nav != null && nav.canPop()) {
          nav.maybePop();
        } else {
          _open(_Section.navigator);
        }
      case _Section.search:
        _open(_Section.navigator);
      case _Section.navigator:
        if (_picked != null) {
          setState(() => _picked = null);
        } else if (_route.arrival != null) {
          _route.clear();
        } else if (_route.guiding) {
          _confirmEnd ? _endGuidance() : _askEnd();
        } else if (_route.active) {
          _route.clear();
        }
    }
  }

  void _askEnd() {
    _confirmEndTimer?.cancel();
    _confirmEndTimer = Timer(const Duration(seconds: 6), _cancelEnd);
    setState(() => _confirmEnd = true);
  }

  void _cancelEnd() {
    _confirmEndTimer?.cancel();
    if (mounted && _confirmEnd) setState(() => _confirmEnd = false);
  }

  void _endGuidance() {
    _cancelEnd();
    _route.stopGuidance();
  }

  PositioningNotifier? _positioning;

  /// Where reading the position takes the user's consent: its state, and
  /// the way to ask.
  LocationAccess? _locationAccess;
  bool _radioPositioning = true;
  ObdService? _obd;
  Timer? _simulation;
  bool _demoStarted = false;
  bool _presetApplied = false;

  @override
  void initState() {
    super.initState();
    _traffic.select(widget.settings.traffic);
    // Debug hook: MAPSOLY_TRAFFIC=yandex|google overrides the saved choice.
    final preset = Platform.environment['MAPSOLY_TRAFFIC'];
    for (final s in TrafficSource.values) {
      if (s.name == preset) _traffic.select(s);
    }
    _traffic.addListener(() => widget.settings.traffic = _traffic.source);
    _route.addListener(_onRouteChanged);
    _speedLimit.addListener(_rebuild);
    _findCompass();
    // The map is something to look at, not to touch: the screen stays on
    // for as long as the app is open, until the user turns it off.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _keepAwake.set(true);
    });
    _route.trafficSampler = _traffic.sampler;
    _glass.addListener(_rebuild);
    _map.cameraChanges.addListener(_onCameraMoved);
    _startPositioning();
    widget.settings.addListener(_applyLocationSettings);
    widget.settings.addListener(_applySensorSettings);
    _loadOffline();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  /// Opens the installed region packs (maps, routing graph, search
  /// indexes). Called again after packs were downloaded or deleted.
  void _loadOffline() {
    // Stop drawing from the old archives before closing them.
    final old = _offline;
    if (old.isNotEmpty) setState(() => _offline = const []);
    for (final map in old) {
      map.archive.close();
    }
    for (final db in _places) {
      db.close();
    }
    _places = const [];
    _route
      ..places = null
      ..morePlaces = const [];
    if (widget.testHooks != null) {
      _offlineLoading = false;
      return;
    }
    setState(() => _offlineLoading = true);
    OfflineMap.loadAll().then(
      (maps) {
        if (!mounted) {
          for (final map in maps) {
            map.archive.close();
          }
          return;
        }
        final places = <PlacesDatabase>[];
        for (final map in maps) {
          try {
            final db = PlacesDatabase.tryOpen(
              '${map.packDirectory.path}/places.sqlite',
            );
            if (db != null) places.add(db);
          } on Exception catch (e) {
            debugPrint('Search index not opened: $e');
          }
        }
        setState(() {
          _offline = maps;
          _offlineLoading = false;
          _places = places;
        });
        _epoch.value++;
        _route
          ..usePack(maps.isEmpty ? null : maps.first.packDirectory)
          ..places = places.isEmpty ? null : places.first
          ..morePlaces = places.skip(1).toList();
        // Debug hook: MAPSOLY_ROUTE="lat,lon;lat,lon" plans a route at
        // startup.
        final preset = Platform.environment['MAPSOLY_ROUTE']?.split(';');
        if (preset != null && preset.length == 2 && !_presetApplied) {
          _presetApplied = true;
          LatLng parse(String s) {
            final p = s.split(',').map(double.parse).toList();
            return LatLng(p[0], p[1]);
          }

          _route.setFrom(parse(preset[0]));
          _route.setTo(parse(preset[1]));
        }
        // First launch with a region pack: start inside the region.
        if (maps.isNotEmpty && widget.settings.center == null) {
          final b = maps.first.archive.bounds;
          _map.move(LatLng((b[1] + b[3]) / 2, (b[0] + b[2]) / 2), 12);
        }
      },
      onError: (Object e) {
        debugPrint('Offline maps failed to open: $e');
        if (mounted) setState(() => _offlineLoading = false);
      },
    );
  }

  @override
  void dispose() {
    _saveCamera?.cancel();
    _confirmEndTimer?.cancel();
    _chromeTimer?.cancel();
    _keepAwake.set(false);
    _speedLimit.dispose();
    _downloads?.dispose();
    _pick?.completer.complete(null);
    widget.settings.removeListener(_applyLocationSettings);
    widget.settings.removeListener(_applySensorSettings);
    _map.cameraChanges.removeListener(_onCameraMoved);
    _hasCompass = false;
    _compassSub?.cancel();
    _compass?.stop();
    _obd?.dispose();
    widget.user.guard.detach();
    final positioning = _positioning;
    if (positioning != null) {
      positioning.removeListener(_onPosition);
      positioning.dispose();
      if (widget.testHooks == null) positioning.engine.dispose();
    }
    _simulation?.cancel();
    for (final db in _places) {
      db.close();
    }
    _photon.close();
    _traffic.dispose();
    _route.dispose();
    for (final map in _offline) {
      map.archive.close();
    }
    if (widget.testHooks == null) _map.dispose();
    _routesTab.dispose();
    _epoch.dispose();
    _glass.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ camera

  void _zoom(double delta) {
    _userMovedMap(pan: false);
    _map.move(_map.center, (_map.zoom + delta).clamp(3, 19));
  }

  void _pan(double dx, double dy) {
    _userMovedMap();
    _map.panBy(Offset(dx, dy) / 4);
  }

  /// The user moved the map by hand: stop moving it for them. Following
  /// the position survives a zoom, but not a pan; the driving camera
  /// pauses for either.
  void _userMovedMap({bool pan = true}) {
    if (_driving) {
      final wasFollowing = _follow.following;
      _follow.userMoved(DateTime.now());
      if (wasFollowing) setState(() {});
    } else if (pan && _locationMode != LocationMode.free) {
      _setLocationMode(LocationMode.free);
    }
  }

  void _onCameraMoved() {
    if (!_map.ready) return;
    if (!_tiltRestored) {
      // The map is up: bring back the 3D view it was left in.
      _tiltRestored = true;
      if (widget.settings.tilted && _map.maxPitch > 0 && !_driving) {
        _map.moveCamera(pitch: math.min(tiltedPitch, _map.maxPitch));
      }
    }
    final tilted = _map.pitch > 1;
    if (tilted != _tilted) setState(() => _tilted = tilted);
  }

  void _toggle3d() {
    if (_map.maxPitch <= 0) return;
    if (_driving) {
      // While driving the button is the "3D in a trip" switch.
      widget.settings.drive3d = !widget.settings.drive3d;
      _follow.resume();
      _onRouteChanged();
      return;
    }
    if (_cruising) {
      // On the move without a route it is the same switch.
      final on = widget.settings.drive3d = !widget.settings.drive3d;
      _map.moveCamera(pitch: on ? math.min(tiltedPitch, _map.maxPitch) : 0);
      return;
    }
    final tilt = _map.pitch <= 1;
    widget.settings.tilted = tilt;
    _map.moveCamera(pitch: tilt ? math.min(tiltedPitch, _map.maxPitch) : 0);
  }

  /// North-up again; the tilt stays as it is.
  /// The map turns with the device, by its compass; works without a
  /// position. Switched by the compass button while the map is north-up.
  void _setCompassMode(bool on) {
    if (on == _compassMode) return;
    setState(() => _compassMode = on);
    if (on) {
      _heading.reset();
      _startCompass();
    } else if (_locationMode != LocationMode.heading) {
      _stopCompass();
    }
  }

  void _followCompass() {
    final heading = _compassHeading;
    if (!_compassMode ||
        heading == null ||
        _driving ||
        _cruising ||
        _locationMode == LocationMode.heading ||
        !_map.ready) {
      return;
    }
    _map.moveCamera(bearing: _heading.update(heading));
  }

  /// True when the map is centred on the position (within a thumb's
  /// width on screen).
  bool _centredOn(LatLng p) {
    if (!_map.ready) return false;
    final metresPerPixel =
        156543.03 *
        math.cos(p.latitude * math.pi / 180) /
        math.pow(2, _map.zoom);
    return const Distance().as(LengthUnit.Meter, _map.center, p) <
        40 * metresPerPixel;
  }

  void _northUp() {
    // First to where I am; the button changes the mode only from there,
    // so the map never starts turning around some other place.
    final fix = _positioning?.estimate;
    if (fix != null && !_driving) {
      final here = LatLng(fix.lat, fix.lon);
      if (!_centredOn(here)) {
        _map.move(here, _map.zoom < 14 ? 15.0 : _map.zoom);
        if (_locationMode == LocationMode.free) {
          _setLocationMode(LocationMode.centered);
        }
        return;
      }
    }
    if (_compassMode) {
      _setCompassMode(false);
      _map.moveCamera(bearing: 0);
      return;
    }
    if (_locationMode == LocationMode.heading) {
      _setLocationMode(LocationMode.centered);
    } else if (_driving && widget.settings.drive3d && _follow.following) {
      // The driving camera would turn it straight back.
      widget.settings.drive3d = false;
      _onRouteChanged();
    } else if (_hasCompass &&
        !_driving &&
        _map.ready &&
        angleDelta(0, _map.bearing).abs() <= 0.5) {
      // Already north-up: the button turns the compass on instead.
      _setCompassMode(true);
    } else {
      _map.moveCamera(bearing: 0);
    }
  }

  void _setLocationMode(LocationMode mode) {
    if (mode == _locationMode) return;
    final wasHeading = _locationMode == LocationMode.heading;
    setState(() => _locationMode = mode);
    if (mode == LocationMode.heading) {
      _heading.reset();
      _startCompass();
    } else if (wasHeading) {
      if (!_compassMode) _stopCompass();
      if (mode == LocationMode.centered) _map.moveCamera(bearing: 0);
    }
  }

  /// Looks for a compass, so the button that follows it can be offered.
  Future<void> _findCompass() async {
    final hooked = widget.testHooks?.compass;
    if (hooked != null) {
      _compass = hooked;
      _hasCompass = true;
      _startCompass();
      return;
    }
    if (widget.testHooks != null) return;
    final key = _compassKey = _compassSettingsKey;
    try {
      final compass = platformCompass(widget.settings);
      if (compass == null) return;
      final found = await compass.available();
      if (!mounted || key != _compassKey) {
        unawaited(compass.dispose());
        return;
      }
      _compass = found ? compass : null;
      if (!found) unawaited(compass.dispose());
      setState(() => _hasCompass = found);
      // It runs all the time: the arrow on the map shows where the device
      // points.
      if (found) _startCompass();
    } on Object catch (e) {
      debugPrint('Compass not found: $e');
    }
  }

  String get _compassSettingsKey {
    final s = widget.settings;
    return '${s.compass.name}|${s.magnetSensor}|${s.accelSensor}';
  }

  String? _compassKey;

  /// The choice of sensors changed in the settings: drop the old compass
  /// and look again.
  void _applySensorSettings() {
    if (widget.testHooks != null || _compassKey == _compassSettingsKey) return;
    _stopCompass(force: true);
    _hasCompass = false;
    final old = _compass;
    _compass = null;
    if (old is LocalCompass) unawaited(old.dispose());
    unawaited(_findCompass());
  }

  void _startCompass() {
    try {
      final compass = _compass ??=
          widget.testHooks?.compass ??
          (widget.testHooks == null ? platformCompass(widget.settings) : null);
      if (compass == null) return;
      _compassSub ??= compass.headings.listen((h) {
        _compassHeading = h;
        _followPosition();
        _followCompass();
        // The arrow on the map turns in steps large enough to be seen, so
        // the screen is not rebuilt for every wobble of the needle.
        final shown = _markerSmoother.update(h);
        final old = _markerHeading;
        if (old == null || angleDelta(old, shown).abs() >= 2) {
          _markerHeading = shown;
          if (_section == _Section.navigator) _rebuild();
        }
      });
      unawaited(
        compass.start().catchError((Object e) {
          debugPrint('Compass not started: $e');
        }),
      );
    } on Object catch (e) {
      debugPrint('Compass not available: $e');
    }
  }

  /// Stops following the compass. While the device has one it keeps
  /// running for the arrow on the map, unless [force]d (the sensors
  /// changed, or the screen is going away).
  void _stopCompass({bool force = false}) {
    if (_hasCompass && !force) return;
    _markerHeading = null;
    _markerSmoother.reset();
    _compassSub?.cancel();
    _compassSub = null;
    _compassHeading = null;
    final compass = _compass;
    if (compass != null) {
      unawaited(compass.stop().catchError((Object _) {}));
    }
  }

  /// Outside guidance: keeps the position in view in the "centred" and
  /// "heading" modes of the location button.
  void _followPosition() {
    if (_driving || _locationMode == LocationMode.free || !_map.ready) return;
    final fix = _positioning?.estimate;
    if (fix == null) return;
    double? bearing;
    if (_locationMode == LocationMode.heading) {
      // The course is trustworthy only while moving; standing still the
      // device compass says where the device points.
      final moving = (fix.speedMps ?? 0) > 1.5 && fix.courseDeg != null;
      final raw = moving ? fix.courseDeg : _compassHeading;
      if (raw != null) bearing = _heading.update(raw);
    }
    _map.moveCamera(center: LatLng(fix.lat, fix.lon), bearing: bearing);
  }

  /// One tap centres the map on the position, the next makes it turn with
  /// the direction of travel; without a position, explains why.
  void _onLocationButton() {
    final fix = _positioning?.estimate;
    if (fix == null) {
      _showLocation();
      return;
    }
    if (_driving) {
      _resumeFollowing();
      return;
    }
    final next = nextLocationMode(_locationMode);
    if (_locationMode == LocationMode.free) {
      final zoom = _map.zoom < 14 ? 15.0 : _map.zoom;
      _map.move(LatLng(fix.lat, fix.lon), zoom);
    }
    _setLocationMode(next);
    _followPosition();
  }

  void _resumeFollowing() {
    _follow.resume();
    setState(() {});
    _onRouteChanged();
  }

  /// The camera behind the car, about once per position update.
  void _drive(RouteProgress progress) {
    final now = DateTime.now();
    final speed = _route.speedKmh ?? 0;
    final wasPaused = _follow.paused;
    _follow.tick(now, moving: speed > DriveCamera.movingKmh);
    if (wasPaused && _follow.following) setState(() {});
    if (_follow.paused || !_map.ready) return;
    final tilt = widget.settings.drive3d && _map.maxPitch > 0;
    final frame = _driveCamera.frame(
      point: progress.point,
      speedKmh: speed,
      tilt: tilt,
      maxPitch: _map.maxPitch,
      routeBearing: _route.routeBearing,
      toManeuverM: _route.toNextManeuverM,
      courseDeg: _positioning?.estimate?.courseDeg,
    );
    // No duration: the engine stretches each move to the next update, so
    // the motion is continuous.
    _map.moveCamera(
      center: frame.center,
      zoom: frame.zoom,
      bearing: frame.bearing,
      pitch: frame.pitch,
    );
  }

  void _setDriving(bool driving) {
    if (driving == _driving) return;
    _driving = driving;
    if (driving) {
      _follow.resume();
      _driveCamera.reset();
      if (_locationMode != LocationMode.free || _compassMode) {
        _locationMode = LocationMode.free;
        _compassMode = false;
        _stopCompass();
      }
      _applyDrivePadding();
    } else {
      _map.setPadding(EdgeInsets.zero);
      if (_map.ready) {
        _map.moveCamera(
          bearing: 0,
          pitch: widget.settings.tilted && _map.maxPitch > 0
              ? math.min(tiltedPitch, _map.maxPitch)
              : 0,
        );
      }
    }
    // Called while the route notifies; the screen is rebuilt right after.
  }

  /// Puts the car in the lower third of what is free between the speed
  /// badge at the top and the maneuver banner at the bottom.
  void _applyDrivePadding() {
    if (!_driving || _viewSize.isEmpty) return;
    final banner = _bannerKey.currentContext?.findRenderObject();
    final cover = banner is RenderBox && banner.hasSize
        ? banner.size.height + 16
        : 150.0;
    final padding = drivePadding(_viewSize, top: 16, bottom: 64 + cover);
    _map.setPadding(padding.copyWith(bottom: cover));
  }

  /// What the map should show right now.
  MapScene _scene(BuildContext context) {
    final version = _traffic.version;
    final routes = _route.routes;
    final selected = _route.selectedIndex;
    final fix = _positioning?.estimate;
    // The glass surfaces, in the map view's own coordinates.
    final view = _mapKey.currentContext?.findRenderObject();
    final origin = view is RenderBox && view.attached
        ? view.localToGlobal(Offset.zero)
        : Offset.zero;
    return MapScene(
      dark: Theme.of(context).brightness == Brightness.dark,
      offline: _offline.isEmpty ? null : _offline.first,
      offlineMaps: _offline,
      offlineLoading: _offlineLoading,
      blurRects: _section == _Section.navigator
          ? [for (final r in _glass.rects.take(6)) r.shift(-origin)]
          : const [],
      buildings3d: _tilted,
      traffic: version == null || _traffic.source == TrafficSource.off
          ? null
          : TrafficOverlay(_traffic.source, version, _traffic.client),
      route: routes.isEmpty ? null : routes[selected].shape,
      routeTraffic: _route.trafficSpans,
      alternatives: [
        for (var i = 0; i < routes.length; i++)
          if (i != selected) routes[i].shape,
      ],
      from: _route.from,
      to: _route.to,
      picked: _picked,
      // While guiding the marker sits on the route; otherwise on the raw fix.
      position:
          _route.progress?.point ??
          (fix == null ? _route.myPosition : LatLng(fix.lat, fix.lon)),
      positionAccuracyM: fix?.accuracyM,
      // Along the route when guided, along the course when moving, else
      // where the device points.
      positionHeading: _route.progress != null
          ? _route.routeBearing
          : fix != null && (fix.speedMps ?? 0) > 1.5 && fix.courseDeg != null
          ? fix.courseDeg
          : _markerHeading,
      positionArrow: widget.settings.positionArrow,
    );
  }

  void _cycleTraffic() {
    const all = TrafficSource.values;
    _traffic.select(all[(_traffic.source.index + 1) % all.length]);
  }

  void _onRouteChanged() {
    final route = _route.selected;
    // Debug: a preset route with MAPSOLY_SIMULATE starts driving by itself.
    if (route != null &&
        !_demoStarted &&
        Platform.environment['MAPSOLY_SIMULATE'] != null &&
        Platform.environment['MAPSOLY_ROUTE'] != null) {
      _demoStarted = true;
      _route.startGuidance();
      return;
    }
    _updateSimulation();
    _trackDriving();
    if (!_route.guiding && _confirmEnd) _cancelEnd();
    // Guidance with a fix: the camera sits behind the car.
    final progress = _route.progress;
    _setDriving(progress != null && _route.arrival == null);
    if (route == null) return;
    if (progress != null) {
      if (_driving) _drive(progress);
      return;
    }
    // Guidance by hand: keep the current maneuver in view.
    if (_route.guiding) {
      final key = (route, _route.step);
      if (key == _shownStep) return;
      _shownStep = key;
      final steps = route.maneuvers.toList();
      final m = steps[_route.step.clamp(0, steps.length - 1)];
      _map.move(route.shape[m.beginShapeIndex], 16);
      return;
    }
    _shownStep = null;
    if (route == _fittedRoute) return;
    _fittedRoute = route;
    // Clear of the buttons on the right and the route card at the bottom.
    _map.fit(route.shape, const EdgeInsets.fromLTRB(40, 80, 80, 250));
  }

  // -------------------------------------------------------------- services

  /// Starts Wi-Fi/cell/GNSS positioning and then the car adapter, whose
  /// trip log takes its (zone-filtered) position from the same engine. Any
  /// failure leaves the app working without a position.
  Future<void> _startPositioning() async {
    final hooks = widget.testHooks;
    PositioningEngine? engine = hooks?.engine;
    try {
      final dir = widget.user.supportDirectory;
      if (engine == null && hooks == null && dir != null) {
        dir.createSync(recursive: true);
        final platform = createPlatformPositioning(
          dbPath: '${dir.path}/positioning.sqlite',
        );
        engine = platform?.engine;
        _locationAccess = platform?.access;
        _radioPositioning = platform?.radio ?? true;
      }
      if (engine != null) {
        // Before anything is collected or sent: the privacy zones.
        widget.user.guard.attach(engine);
        final notifier = PositioningNotifier(engine)..addListener(_onPosition);
        if (!mounted) {
          notifier.dispose();
          if (hooks == null) await engine.dispose();
          return;
        }
        setState(() => _positioning = notifier);
        _epoch.value++;
        _applyLocationSettings();
      }
    } on Object catch (e) {
      debugPrint('Positioning not created: $e');
      engine = null;
    }
    _startObd(engine);
    try {
      if (hooks == null) await engine?.start();
    } on Object catch (e) {
      debugPrint('Positioning not started: $e');
    }
  }

  /// Connects to the ELM327 adapter according to the settings. Its speed
  /// feeds the positioning filter, which is what keeps the position moving
  /// when there is no satellite fix.
  void _startObd(PositioningEngine? engine) {
    if (!mounted) return;
    final hooks = widget.testHooks;
    final logs = widget.user.tripLogDirectory;
    if (hooks != null ? hooks.obd == null : logs == null) return;
    final service =
        hooks?.obd ??
        ObdService(
          logDirectory: logs!,
          // Null inside a privacy zone: the row is logged without
          // coordinates.
          position: engine == null
              ? null
              : widget.user.guard.enginePosition(engine),
          onSpeed: (sample) => _positioning?.engine.addSpeedSample(
            sample.speedMps,
            time: sample.time,
          ),
        );
    setState(() => _obd = service);
    _epoch.value++;
    unawaited(service.apply(widget.settings.obd));
  }

  void _applyLocationSettings() {
    _obd?.apply(widget.settings.obd);
    final engine = _positioning?.engine;
    if (engine == null) return;
    engine.onlineLookups = widget.settings.onlineLocation;
    engine.wardriving = widget.settings.wardriving;
  }

  void _onPosition() {
    if (_simulation != null) return; // a demo drive owns the position
    final fix = _positioning?.estimate;
    _route.updateMyPosition(
      fix == null ? null : LatLng(fix.lat, fix.lon),
      accuracyM: fix?.accuracyM ?? 30,
      speedMps: fix?.speedMps,
    );
    _followPosition();
  }

  /// Debug hook: `MAPSOLY_SIMULATE=60` (km/h) drives a fake position along the
  /// route while guidance is on, to exercise it without a position source.
  void _updateSimulation() {
    final speed = double.tryParse(
      Platform.environment['MAPSOLY_SIMULATE'] ?? '',
    );
    final route = _route.selected;
    if (speed == null || !_route.guiding || route == null) {
      _simulation?.cancel();
      _simulation = null;
      return;
    }
    if (_simulation != null) return;
    final tracker = RouteTracker(route.shape);
    var along = 0.0;
    _simulation = Timer.periodic(const Duration(seconds: 1), (_) {
      along += speed / 3.6;
      if (along >= tracker.lengthM) {
        _simulation?.cancel();
        _simulation = null;
      }
      _route.updateMyPosition(
        tracker.pointAt(along),
        accuracyM: 10,
        speedMps: speed / 3.6,
      );
    });
  }

  Future<void> _showPacks() async {
    final downloads = _downloads ??= PackDownloads(
      PackStore(await OfflineMap.packsDirectory()),
      onInstalled: _loadOffline,
    )..addListener(_rebuild);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => PacksScreen(
          downloads: downloads,
          catalogUrl: widget.settings.catalogUrl,
          onChanged: _loadOffline,
        ),
      ),
    );
  }

  void _showLocation() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => LocationSheet(
        positioning: _positioning,
        settings: widget.settings,
        access: _locationAccess,
        radio: _radioPositioning,
      ),
    );
  }

  /// Where to rank search results around: the position, else the map view.
  /// The hint also goes to the online search, so a point inside a privacy
  /// zone is never used.
  LatLng? _searchNear() {
    final guard = widget.user.guard;
    final fix = _positioning?.estimate;
    if (fix != null) {
      return guard.shareable(
        LatLng(fix.lat, fix.lon),
        accuracyM: fix.accuracyM,
      );
    }
    // Before the first layout (search opened at startup) there is no camera.
    return guard.shareable(_map.ready ? _map.center : widget.settings.center);
  }

  static String _labelOf(PlaceResult place) {
    final context = place.context;
    return context == null || context.isEmpty
        ? place.name
        : '${place.name} — $context';
  }

  /// Shows a point on the map with the card that offers what to do with it.
  void _showPoint(LatLng point, String? label) {
    setState(() {
      _section = _Section.navigator;
      _picked = point;
      _pickedLabel = label;
    });
    _userMovedMap();
    _map.move(point, _map.zoom < 15 ? 16 : _map.zoom);
  }

  /// "Home" / "Work" / a saved place in one tap: a route from here, or the
  /// planner asking for a start when there is no position.
  void _goToPlace(SavedPlace place) {
    _settingsNav.currentState?.popUntil((r) => r.isFirst);
    setState(() => _picked = null);
    _route.setStops([RouteStop(place.point, label: place.name)]);
    if (_route.needStart) {
      _routesTab.value = 0;
      _open(_Section.routes);
    } else {
      _open(_Section.navigator);
    }
  }

  Future<void> _savePicked() async {
    final point = _picked;
    if (point == null) return;
    final saved = await savePlaceDialog(
      context,
      widget.user.places,
      point: point,
      name: _pickedLabel?.split(' — ').first,
      address: _pickedLabel,
    );
    if (saved != null && mounted) {
      showNote(context, 'Место «${saved.name}» сохранено');
    }
  }

  // ------------------------------------------------------------ MapServices

  @override
  LatLng? get myPosition {
    final fix = _positioning?.estimate;
    return fix == null ? null : LatLng(fix.lat, fix.lon);
  }

  @override
  Future<PickedPlace?> pickOnMap({required String title, LatLng? around}) {
    _pick?.completer.complete(null);
    final pick = _Pick(title, _section);
    setState(() {
      _pick = pick;
      _picked = null;
      _section = _Section.navigator;
    });
    if (around != null && _map.ready) {
      _map.move(around, _map.zoom < 14 ? 15 : _map.zoom);
    }
    return pick.completer.future;
  }

  void _finishPick(LatLng? point) {
    final pick = _pick;
    if (pick == null) return;
    setState(() {
      _pick = null;
      _section = pick.returnTo;
    });
    pick.completer.complete(point == null ? null : PickedPlace(point));
  }

  @override
  Widget searchPanel({
    required ValueChanged<PickedPlace> onSelected,
    required VoidCallback onClose,
  }) => SearchPanel(
    database: _places.isEmpty ? null : _places.first,
    moreDatabases: _places.skip(1).toList(),
    online: _photon,
    near: _searchNear(),
    onSelected: (r) => onSelected(PickedPlace(r.point, label: _labelOf(r))),
    onClose: onClose,
  );

  void _cycleTheme() {
    const order = [ThemeMode.system, ThemeMode.light, ThemeMode.dark];
    final settings = widget.settings;
    settings.themeMode =
        order[(order.indexOf(settings.themeMode) + 1) % order.length];
  }

  // -------------------------------------------------------------------- UI

  /// A section's own page stack, kept alive while another section shows.
  Widget _sectionPages(
    _Section section,
    GlobalKey<NavigatorState> key,
    WidgetBuilder root,
  ) => _Layer(
    visible: _section == section,
    child: Navigator(
      key: key,
      onGenerateRoute: (_) => MaterialPageRoute<void>(
        builder: (context) => ListenableBuilder(
          listenable: _epoch,
          builder: (context, _) => root(context),
        ),
      ),
    ),
  );

  /// Saved places offered in search before anything is typed.
  Widget? _savedPlacesList() {
    final places = widget.user.places.places;
    final history = widget.user.searches;
    if (places.isEmpty && history.isEmpty) return null;
    return ListenableBuilder(
      listenable: history,
      builder: (context, _) {
        final searched = history.ranked;
        return ListView(
          children: [
            if (places.isNotEmpty) const SectionHeader('Мои места'),
            for (final p in places)
              BigRow(
                icon: placeKindIcon(p.kind),
                title: p.name,
                subtitle: p.address,
                trailing: const SizedBox.shrink(),
                onTap: () => _showPoint(p.point, p.name),
              ),
            // What was looked for before, the most often picked first.
            if (searched.isNotEmpty) const SectionHeader('Вы искали'),
            for (final p in searched.take(30))
              BigRow(
                icon: Icons.history,
                title: p.label,
                trailing: Ui.iconButton(
                  icon: Icons.close,
                  label: 'Убрать из истории',
                  onPressed: () => history.remove(p),
                ),
                onTap: () {
                  history.record(p.label, p.point);
                  _showPoint(p.point, p.label);
                },
              ),
            if (searched.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(Ui.pad),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    style: Ui.text,
                    onPressed: history.clear,
                    child: const Text('Очистить историю поиска'),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// A search result was picked: show it and remember it — unless it lies
  /// in a privacy zone, where nothing is written down.
  void _onSearchPicked(PlaceResult r) {
    final label = _labelOf(r);
    if (!widget.user.zones.contains(r.point)) {
      widget.user.searches.record(label, r.point);
    }
    _showPoint(r.point, label);
  }

  /// What lies on the map in the navigator section.
  List<Widget> _mapOverlay(BuildContext context) {
    final pick = _pick;
    final status = _positioning?.status;
    // A wide window keeps cards and the banner clear of the buttons on the
    // right. A narrow phone gives them the full width and moves the
    // buttons out of their way instead.
    final narrow = _viewSize.width < 500;
    final side = narrow ? 0.0 : 72.0;
    final showsBanner = _route.guiding && _route.arrival == null;
    final showsCard = _pick == null && _showsCard;
    final hidden = _chromeHidden;
    final speed = _speedKmh;
    // The speed is worth showing on the move, and during guidance always.
    final speedometer =
        speed != null && !showsCard && (_route.progress != null || speed >= 5)
        ? Speedometer(
            speedKmh: speed,
            limitKmh: _limit?.kmh,
            limitPosted: _limit?.posted ?? true,
            signFirst: true,
          )
        : null;
    final downloads = _downloads;
    final Widget buttons = hidden
        ? const SizedBox.shrink()
        : Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: EdgeInsets.only(
                top: narrow && speedometer != null
                    ? Speedometer.size + Ui.gap
                    : 0,
                bottom: narrow && showsCard
                    ? 270
                    : narrow && showsBanner
                    ? 190
                    : 0,
              ),
              child: MapButtons(
                camera: _map,
                onZoom: _zoom,
                onToggle3d: _toggle3d,
                onNorthUp: _northUp,
                hasCompass: _hasCompass,
                compassMode: _compassMode,
                onLocation: _onLocationButton,
                onLocationDetails: _showLocation,
                hasFix: status?.estimate != null,
                mode: _driving
                    ? (_follow.following
                          ? LocationMode.heading
                          : LocationMode.free)
                    : _locationMode,
                privateArea: status?.privateArea ?? false,
                tilted: _driving
                    ? widget.settings.drive3d && _map.maxPitch > 0
                    : _tilted,
              ),
            ),
          );
    final buttonsSlot = AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: KeyedSubtree(key: ValueKey(hidden), child: buttons),
    );

    if (pick != null) {
      return [
        const IgnorePointer(child: Center(child: _Crosshair())),
        buttonsSlot,
        Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: EdgeInsets.only(right: side),
            child: Glass(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Ui.pad,
                  vertical: 10,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pick.title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      'Подвиньте карту так, чтобы место оказалось под прицелом',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Glass(
              child: Padding(
                padding: const EdgeInsets.all(Ui.gap),
                child: Row(
                  children: [
                    OutlinedButton(
                      style: Ui.outlined,
                      onPressed: () => _finishPick(null),
                      child: const Text('Отмена'),
                    ),
                    const SizedBox(width: Ui.gap),
                    Expanded(
                      child: FilledButton.icon(
                        style: Ui.filled,
                        onPressed: _map.ready
                            ? () => _finishPick(_map.center)
                            : null,
                        icon: const Icon(Icons.check),
                        label: const Text('Выбрать эту точку'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ];
    }

    final arrival = _route.arrival;
    final guiding = _route.guiding && _route.selected != null;
    final places = widget.user.places;
    final quick = [?places.home, ?places.work];

    // The card at the bottom left: at most one thing at a time.
    Widget? card;
    if (arrival != null) {
      card = ArrivalCard(summary: arrival, onDone: _route.clear);
    } else if (guiding) {
      card = null;
    } else if (_picked != null) {
      card = PickedPointCard(
        point: _picked!,
        label: _pickedLabel,
        onTo: () {
          _route.setTo(_picked!, label: _pickedLabel);
          setState(() => _picked = null);
        },
        onFrom: () {
          _route.setFrom(_picked!, label: _pickedLabel);
          setState(() => _picked = null);
        },
        onAddStop: _route.stops.length >= 2 && !_route.needStart
            ? () {
                _route.addStop(_picked!, label: _pickedLabel);
                setState(() => _picked = null);
              }
            : null,
        onSave: _savePicked,
        onClose: () => setState(() => _picked = null),
      );
    } else if (_route.active) {
      card = RoutePanel(
        controller: _route,
        onPlan: () {
          _routesTab.value = 0;
          _open(_Section.routes);
        },
      );
    }

    return [
      if (!guiding)
        Align(
          alignment: Alignment.topLeft,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TrafficChip(controller: _traffic),
              if (downloads != null && downloads.active)
                Padding(
                  padding: const EdgeInsets.only(top: Ui.gap),
                  child: _GlassButton(
                    icon: Icons.download,
                    label: downloads.installing
                        ? 'Карты: установка'
                        : 'Карты: ${(downloads.fraction * 100).floor()}%',
                    onTap: _showPacks,
                  ),
                ),
              if (_obd != null)
                Padding(
                  padding: const EdgeInsets.only(top: Ui.gap),
                  child: VehicleChip(service: _obd!),
                ),
            ],
          ),
        ),
      if (card != null)
        Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: EdgeInsets.only(right: side),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: card,
            ),
          ),
        )
      else if (guiding)
        // The maneuver sits at the bottom left, next to the thumb and out
        // of the way of the road ahead; what belongs to the trip stacks
        // above it.
        Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: EdgeInsets.only(right: side),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (_obd != null)
                      Padding(
                        padding: const EdgeInsets.only(right: Ui.gap),
                        child: VehicleChip(service: _obd!),
                      ),
                    if (_driving && _follow.paused)
                      _GlassButton(
                        icon: Icons.navigation,
                        label: 'Вернуться к маршруту',
                        accent: true,
                        onTap: _resumeFollowing,
                      ),
                  ],
                ),
                const SizedBox(height: Ui.gap),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: GuidanceBanner(
                    key: _bannerKey,
                    controller: _route,
                    confirmingEnd: _confirmEnd,
                    onAskEnd: _askEnd,
                    onCancelEnd: _cancelEnd,
                    onEnd: _endGuidance,
                  ),
                ),
              ],
            ),
          ),
        )
      else if (quick.isNotEmpty)
        // Nothing planned: home and work are one tap away.
        Align(
          alignment: Alignment.bottomLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final p in quick)
                Padding(
                  padding: const EdgeInsets.only(right: Ui.gap),
                  child: _GlassButton(
                    icon: placeKindIcon(p.kind),
                    label: p.kind == SavedPlaceKind.home
                        ? 'Домой'
                        : 'На работу',
                    onTap: () => _goToPlace(p),
                  ),
                ),
            ],
          ),
        ),
      // The speed sits in the top right corner, where drivers look for it.
      if (speedometer != null)
        Align(
          alignment: Alignment.topRight,
          child: Padding(padding: EdgeInsets.zero, child: speedometer),
        ),
      buttonsSlot,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final onMap = _section == _Section.navigator;
    final hooks = widget.testHooks;
    return CallbackShortcuts(
      // Single-letter shortcuts belong to the map: anywhere else they would
      // swallow typing. Search handles Escape itself.
      bindings: {
        if (!_searching)
          const SingleActivator(LogicalKeyboardKey.escape): _goBack,
        if (onMap) ...{
          const SingleActivator(LogicalKeyboardKey.slash): () =>
              _open(_Section.search),
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
              _open(_Section.search),
          const SingleActivator(LogicalKeyboardKey.keyL): _onLocationButton,
          const SingleActivator(LogicalKeyboardKey.equal): () => _zoom(1),
          const SingleActivator(LogicalKeyboardKey.add): () => _zoom(1),
          const SingleActivator(LogicalKeyboardKey.minus): () => _zoom(-1),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              _pan(-1, 0),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              _pan(1, 0),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _pan(0, -1),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _pan(0, 1),
          const SingleActivator(LogicalKeyboardKey.keyT): _cycleTraffic,
          const SingleActivator(LogicalKeyboardKey.keyD): _cycleTheme,
          const SingleActivator(LogicalKeyboardKey.digit3): _toggle3d,
          const SingleActivator(LogicalKeyboardKey.keyN): _northUp,
        },
      },
      child: GlassScope(
        registry: _glass,
        child: ListenableBuilder(
          // Rebuilt with the route, so "back" always knows what is open.
          listenable: _route,
          // The system or hardware back key lands here while there is
          // something to close; with nothing left it leaves the app.
          builder: (context, child) => PopScope(
            canPop: !_canGoBack,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) _goBack();
            },
            child: child!,
          ),
          child: Focus(
            autofocus: true,
            child: Scaffold(
              // The map continues under the translucent bottom bar.
              extendBody: true,
              body: ListenableBuilder(
                listenable: Listenable.merge([
                  _traffic,
                  _route,
                  _positioning,
                  _downloads,
                  widget.user.places,
                  widget.user.searches,
                ]),
                builder: (context, _) => LayoutBuilder(
                  builder: (context, box) {
                    if (box.biggest != _viewSize) {
                      _viewSize = box.biggest;
                      _applyDrivePadding();
                    }
                    final scene = _scene(context);
                    // Any touch brings back the controls hidden on the move.
                    return Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: (_) => _revealChrome(),
                      child: Stack(
                        children: [
                          // While another section covers the screen the map is
                          // not drawn, so typing does not compete with it.
                          Listener(
                            key: _mapKey,
                            // A tap only brings the controls back; the camera
                            // stops following once the finger drags the map.
                            onPointerDown: (e) => _pointerDownAt = e.position,
                            onPointerMove: (e) {
                              final down = _pointerDownAt;
                              if (down != null &&
                                  (e.position - down).distance > 10) {
                                _pointerDownAt = null;
                                _userMovedMap();
                              }
                            },
                            onPointerSignal: (_) => _userMovedMap(pan: false),
                            child: hooks != null
                                ? hooks.mapView(scene)
                                : buildMapView(
                                    visible: onMap,
                                    controller: _map,
                                    scene: scene,
                                    initialCenter:
                                        widget.settings.center ??
                                        const LatLng(55.7522, 37.6156),
                                    initialZoom: widget.settings.zoom ?? 11,
                                    onLongPress: (point) {
                                      if (_pick != null) return;
                                      setState(() {
                                        _picked = point;
                                        _pickedLabel = null;
                                      });
                                    },
                                    onCameraChanged: (center, zoom) {
                                      _saveCamera?.cancel();
                                      _saveCamera = Timer(
                                        const Duration(seconds: 1),
                                        () => widget.settings.saveCamera(
                                          center,
                                          zoom,
                                        ),
                                      );
                                    },
                                  ),
                          ),
                          if (onMap)
                            SafeArea(
                              minimum: const EdgeInsets.all(Ui.gap),
                              child: Stack(children: _mapOverlay(context)),
                            ),
                          if (_searching)
                            Positioned.fill(
                              child: Material(
                                color: Theme.of(context).colorScheme.surface,
                                child: SafeArea(
                                  child: SearchPanel(
                                    database: _places.isEmpty
                                        ? null
                                        : _places.first,
                                    moreDatabases: _places.skip(1).toList(),
                                    online: _photon,
                                    near: _searchNear(),
                                    initialQuery: _initialQuery,
                                    emptyQuery: _savedPlacesList(),
                                    onSelected: _onSearchPicked,
                                    onClose: () => _open(_Section.navigator),
                                  ),
                                ),
                              ),
                            ),
                          _sectionPages(
                            _Section.routes,
                            _routesNav,
                            (_) => RoutesScreen(
                              route: _route,
                              user: widget.user,
                              services: this,
                              files: _files,
                              tab: _routesTab,
                              onGo: () => _open(_Section.navigator),
                            ),
                          ),
                          _sectionPages(
                            _Section.settings,
                            _settingsNav,
                            (_) => SettingsScreen(
                              settings: widget.settings,
                              traffic: _traffic,
                              positioning: _positioning,
                              obd: _obd,
                              onOpenPacks: _showPacks,
                              showSensors: hooks == null && Platform.isLinux,
                              locationAccess: _locationAccess,
                              radioPositioning: _radioPositioning,
                              user: widget.user,
                              services: this,
                              files: _files,
                              canTilt: _map.maxPitch > 0,
                              onGoToPlace: _goToPlace,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              // The main sections sit under the thumb. Picking a point is a
              // step of its own: the bar gives way to its two buttons.
              bottomNavigationBar: _pick != null
                  ? null
                  : _Collapsible(
                      collapsed: _chromeHidden,
                      child: _FrostedBar(
                        child: NavigationBar(
                          backgroundColor: Colors.transparent,
                          surfaceTintColor: Colors.transparent,
                          elevation: 0,
                          height: 64,
                          selectedIndex: _section.index,
                          onDestinationSelected: (i) =>
                              _open(_Section.values[i]),
                          destinations: const [
                            NavigationDestination(
                              icon: Icon(Icons.search),
                              label: 'Поиск',
                            ),
                            NavigationDestination(
                              icon: Icon(Icons.navigation_outlined),
                              selectedIcon: Icon(Icons.navigation),
                              label: 'Навигатор',
                            ),
                            NavigationDestination(
                              icon: Icon(Icons.alt_route),
                              label: 'Маршруты',
                            ),
                            NavigationDestination(
                              icon: Icon(Icons.settings_outlined),
                              selectedIcon: Icon(Icons.settings),
                              label: 'Настройки',
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Slides its child down out of sight, giving its height back to the map.
class _Collapsible extends StatelessWidget {
  const _Collapsible({required this.collapsed, required this.child});

  final bool collapsed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        heightFactor: collapsed ? 0 : 1,
        child: IgnorePointer(ignoring: collapsed, child: child),
      ),
    );
  }
}

/// A section that covers the map: fades in quickly, and while hidden keeps
/// its state but takes no taps, focus or frames.
class _Layer extends StatelessWidget {
  const _Layer({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !visible,
        child: ExcludeFocus(
          excluding: !visible,
          child: ExcludeSemantics(
            excluding: !visible,
            // The fade itself must keep ticking while the layer hides; only
            // what is inside stops.
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              child: TickerMode(enabled: visible, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// Translucent, blurred backing for the bottom bar.
class _FrostedBar extends StatelessWidget {
  const _FrostedBar({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Glass(
      radius: 0,
      opacity: 0.72,
      border: false,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: colors.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
        child: child,
      ),
    );
  }
}

/// The mark in the middle of the map while a point is being chosen.
class _Crosshair extends StatelessWidget {
  const _Crosshair();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // A light halo under a dark mark (or the reverse) shows on any map.
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colors.surface.withValues(alpha: 0.55),
            border: Border.all(color: colors.primary, width: 2),
          ),
        ),
        Icon(Icons.add, size: 40, color: colors.onSurface),
      ],
    );
  }
}

/// A compact glass button with an icon and a word: quick actions on the map.
class _GlassButton extends StatelessWidget {
  const _GlassButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Filled with the accent colour: the one thing to press right now.
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final fg = accent ? colors.onPrimary : colors.onSurface;
    return Glass(
      color: accent ? colors.primary : null,
      opacity: accent ? 0.95 : 0.86,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Ui.button),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Ui.pad),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 24, color: accent ? fg : colors.primary),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: theme.textTheme.titleSmall?.copyWith(color: fg),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The buttons on the right edge: zoom, 3D and the position, few and large
/// enough to hit while driving; above them the compass, which appears only
/// while the map is turned or tilted.
class MapButtons extends StatelessWidget {
  const MapButtons({
    super.key,
    required this.camera,
    required this.onZoom,
    required this.onToggle3d,
    required this.onNorthUp,
    required this.onLocation,
    required this.onLocationDetails,
    required this.hasFix,
    required this.mode,
    required this.tilted,
    this.privateArea = false,
    this.hasCompass = false,
    this.compassMode = false,
  });

  final MapViewController camera;
  final void Function(double delta) onZoom;
  final VoidCallback onToggle3d, onNorthUp, onLocation, onLocationDetails;
  final bool hasFix;
  final LocationMode mode;

  /// The device has a compass: the compass button is always there and,
  /// with the map north-up, turns [compassMode] on.
  final bool hasCompass;

  /// The map is turning with the device.
  final bool compassMode;

  /// Whether the 3D view is on (the button looks pressed).
  final bool tilted;

  /// Inside a privacy zone: a small shield on the location button says
  /// that collecting is paused.
  final bool privateArea;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget button(
      String label,
      Widget icon,
      VoidCallback onPressed, {
      bool active = false,
    }) => IconButton(
      tooltip: label,
      iconSize: 28,
      color: active ? colors.primary : colors.onSurface,
      style: active
          ? IconButton.styleFrom(
              backgroundColor: colors.primary.withValues(alpha: 0.14),
            )
          : null,
      constraints: const BoxConstraints.tightFor(width: 56, height: 56),
      icon: icon,
      onPressed: onPressed,
    );

    final locationIcon = !hasFix
        ? Icons.location_searching
        : mode == LocationMode.heading
        ? Icons.navigation
        : Icons.my_location;
    final locationLabel = !hasFix
        ? 'Местоположение не определено'
        : switch (mode) {
            LocationMode.free => 'Показать моё местоположение',
            LocationMode.centered => 'Поворачивать карту по ходу движения',
            LocationMode.heading => 'Карта следует за мной',
          };

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Glass(
          blur: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              button('Приблизить', const Icon(Icons.add), () => onZoom(1)),
              button('Отдалить', const Icon(Icons.remove), () => onZoom(-1)),
              if (camera.maxPitch > 0)
                button(
                  tilted ? 'Плоская карта' : 'Объёмная карта',
                  const Text(
                    '3D',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  onToggle3d,
                  active: tilted,
                ),
              const SizedBox(width: 32, child: Divider(height: 8)),
              GestureDetector(
                onLongPress: onLocationDetails,
                child: Stack(
                  children: [
                    button(
                      locationLabel,
                      Icon(locationIcon),
                      onLocation,
                      active: hasFix && mode != LocationMode.free,
                    ),
                    if (privateArea)
                      Positioned(
                        right: 6,
                        top: 6,
                        child: IgnorePointer(
                          child: Icon(
                            Icons.shield,
                            size: 16,
                            color: colors.primary,
                            semanticLabel:
                                'Безопасная зона: сбор приостановлен',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // The compass sits under the buttons and keeps its place while
        // hidden, so they do not jump when it appears.
        ListenableBuilder(
          listenable: camera.cameraChanges,
          builder: (context, _) {
            final bearing = camera.ready ? camera.bearing : 0.0;
            final pitch = camera.ready ? camera.pitch : 0.0;
            final turned = angleDelta(0, bearing).abs() > 0.5;
            final shown = turned || pitch > 1 || hasCompass;
            final offer = hasCompass && !turned && !compassMode;
            return Padding(
              padding: const EdgeInsets.only(top: Ui.gap),
              child: SizedBox(
                width: 56,
                height: 56,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: !shown
                      ? const SizedBox.shrink()
                      : Glass(
                          radius: 28,
                          blur: false,
                          child: button(
                            compassMode
                                ? 'Карта по компасу: выключить'
                                : offer
                                ? 'Поворачивать карту по компасу'
                                : 'Повернуть севером вверх',
                            offer
                                ? Icon(
                                    Icons.explore_outlined,
                                    color: colors.onSurfaceVariant,
                                  )
                                : Transform.rotate(
                                    angle: -bearing * math.pi / 180,
                                    child: Icon(
                                      Icons.navigation,
                                      color: turned || compassMode
                                          ? colors.primary
                                          : colors.outline,
                                    ),
                                  ),
                            onNorthUp,
                            active: compassMode,
                          ),
                        ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Traffic source on the map: one glass chip with the choice and its state.
class TrafficChip extends StatelessWidget {
  const TrafficChip({super.key, required this.controller});

  final TrafficController controller;

  static const _labels = {
    TrafficSource.off: 'Без пробок',
    TrafficSource.yandex: 'Яндекс',
    TrafficSource.google: 'Google',
  };

  String? _status() {
    if (controller.source == TrafficSource.off) return null;
    if (controller.error != null) return 'Пробки не загрузились';
    final at = controller.updatedAt;
    if (at == null) return 'Загрузка…';
    return 'Обновлено в ${formatClock(at)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final status = _status();
    final on = controller.source != TrafficSource.off;
    return Glass(
      child: PopupMenuButton<TrafficSource>(
        tooltip: 'Пробки',
        initialValue: controller.source,
        onSelected: controller.select,
        itemBuilder: (context) => [
          for (final s in TrafficSource.values)
            PopupMenuItem(
              value: s,
              height: Ui.button,
              child: Text(_labels[s]!),
            ),
        ],
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Ui.button),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Ui.pad),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.traffic_outlined,
                  size: 24,
                  color: on ? colors.primary : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _labels[controller.source]!,
                      style: theme.textTheme.titleSmall,
                    ),
                    if (status != null)
                      Text(
                        status,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: controller.error != null
                              ? colors.error
                              : colors.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
