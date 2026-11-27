import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import '../offline/offline_map.dart';
import '../packs/pack_store.dart';
import '../packs/packs_screen.dart';
import '../places/photon_geocoder.dart';
import '../places/places_database.dart';
import '../places/search_panel.dart';
import '../positioning/positioning.dart';
import '../settings.dart';
import '../settings_screen.dart';
import '../traffic/traffic.dart';
import 'engine/engines.dart';
import 'engine/map_engine.dart';
import 'guidance.dart';
import 'location_sheet.dart';
import 'route_controller.dart';
import 'route_panel.dart';
import 'routes_screen.dart';

/// Sections of the main screen, in the order of the bottom bar.
enum _Section { search, navigator, routes, settings }

class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapViewController _map = createMapController();
  final _traffic = TrafficController();
  final _route = RouteController();
  OfflineMap? _offline;
  Timer? _saveCamera;
  Object? _fittedRoute;
  Object? _shownStep;
  LatLng? _picked;
  String? _pickedLabel;
  PlacesDatabase? _places;
  final _photon = PhotonGeocoder();
  // Debug hook: MAPSOLY_SEARCH="query" opens search with that text.
  final _initialQuery = Platform.environment['MAPSOLY_SEARCH'] ?? '';
  late _Section _section = _initialQuery.isNotEmpty
      ? _Section.search
      : _Section.navigator;
  bool get _searching => _section == _Section.search;

  void _open(_Section section) => setState(() => _section = section);
  PositioningNotifier? _positioning;
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
    _route.trafficSampler = _traffic.sampler;
    _startPositioning();
    widget.settings.addListener(_applyLocationSettings);
    _loadOffline();
  }

  /// Opens the installed region pack (map, routing graph, search index).
  /// Called again after packs were downloaded or deleted.
  void _loadOffline() {
    // Stop drawing from the old archive before closing it.
    final old = _offline;
    if (old != null) setState(() => _offline = null);
    old?.archive.close();
    _places?.close();
    _places = null;
    _route.places = null;
    OfflineMap.load().then((map) {
      if (!mounted) return;
      setState(() => _offline = map);
      _route.usePack(map?.packDirectory);
      if (map != null) {
        try {
          _places = PlacesDatabase.tryOpen(
            '${map.packDirectory.path}/places.sqlite',
          );
          _route.places = _places;
        } on Exception catch (e) {
          debugPrint('Search index not opened: $e');
        }
      }
      // Debug hook: MAPSOLY_ROUTE="lat,lon;lat,lon" plans a route at startup.
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
      if (map != null && widget.settings.center == null) {
        final b = map.archive.bounds;
        _map.move(LatLng((b[1] + b[3]) / 2, (b[0] + b[2]) / 2), 12);
      }
    }, onError: (Object e) => debugPrint('Offline map failed to open: $e'));
  }

  @override
  void dispose() {
    _saveCamera?.cancel();
    widget.settings.removeListener(_applyLocationSettings);
    final positioning = _positioning;
    if (positioning != null) {
      positioning.removeListener(_onPosition);
      positioning.dispose();
      positioning.engine.dispose();
    }
    _simulation?.cancel();
    _places?.close();
    _photon.close();
    _traffic.dispose();
    _route.dispose();
    _offline?.archive.close();
    _map.dispose();
    super.dispose();
  }

  void _zoom(double delta) =>
      _map.move(_map.center, (_map.zoom + delta).clamp(3, 19));

  void _pan(double dx, double dy) => _map.panBy(Offset(dx, dy) / 4);

  /// What the map should show right now.
  MapScene _scene(BuildContext context) {
    final version = _traffic.version;
    final routes = _route.routes;
    final selected = _route.selectedIndex;
    final fix = _positioning?.estimate;
    return MapScene(
      dark: Theme.of(context).brightness == Brightness.dark,
      offline: _offline,
      traffic: version == null || _traffic.source == TrafficSource.off
          ? null
          : TrafficOverlay(_traffic.source, version, _traffic.client),
      route: routes.isEmpty ? null : routes[selected].shape,
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
    if (route == null) return;
    // Guidance with a fix: the map follows the matched position.
    final progress = _route.progress;
    if (progress != null) {
      _map.move(progress.point, _map.zoom < 15 ? 16 : _map.zoom);
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
    _map.fit(route.shape, const EdgeInsets.fromLTRB(40, 90, 70, 200));
  }

  /// Starts Wi-Fi/cell/GNSS positioning. Any failure leaves the app working
  /// without a position.
  Future<void> _startPositioning() async {
    if (!Platform.isLinux) return;
    try {
      final dir = await getApplicationSupportDirectory();
      dir.createSync(recursive: true);
      final engine = PositioningEngine.linux(
        dbPath: '${dir.path}/positioning.sqlite',
      );
      final notifier = PositioningNotifier(engine)..addListener(_onPosition);
      if (!mounted) {
        notifier.dispose();
        await engine.dispose();
        return;
      }
      setState(() => _positioning = notifier);
      _applyLocationSettings();
      await engine.start();
    } on Object catch (e) {
      debugPrint('Positioning not started: $e');
    }
  }

  void _applyLocationSettings() {
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
    final store = PackStore(await OfflineMap.packsDirectory());
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) =>
            PacksScreen(store: store, onChanged: _loadOffline),
      ),
    );
    store.close();
  }

  void _showLocation() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) =>
          LocationSheet(positioning: _positioning, settings: widget.settings),
    );
  }

  /// Centres the map on the current position, or explains why there is none.
  void _goToMyPosition() {
    final fix = _positioning?.estimate;
    if (fix == null) {
      _showLocation();
      return;
    }
    final zoom = _map.zoom < 14 ? 15.0 : _map.zoom;
    _map.move(LatLng(fix.lat, fix.lon), zoom);
  }

  /// Where to rank search results around: the position, else the map view.
  LatLng? _searchNear() {
    final fix = _positioning?.estimate;
    if (fix != null) return LatLng(fix.lat, fix.lon);
    // Before the first layout (search opened at startup) there is no camera.
    return _map.ready ? _map.center : widget.settings.center;
  }

  void _onPlaceSelected(PlaceResult place) {
    final context = place.context;
    setState(() {
      _section = _Section.navigator;
      _picked = place.point;
      _pickedLabel = context == null || context.isEmpty
          ? place.name
          : '${place.name} — $context';
    });
    _map.move(place.point, _map.zoom < 15 ? 16 : _map.zoom);
  }

  void _cycleTheme() {
    const order = [ThemeMode.system, ThemeMode.light, ThemeMode.dark];
    final settings = widget.settings;
    settings.themeMode =
        order[(order.indexOf(settings.themeMode) + 1) % order.length];
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      // Single-letter shortcuts would swallow typing in the search field.
      bindings: _searching
          ? const {}
          : {
              const SingleActivator(LogicalKeyboardKey.slash): () =>
                  _open(_Section.search),
              const SingleActivator(
                LogicalKeyboardKey.keyF,
                control: true,
              ): () =>
                  _open(_Section.search),
              const SingleActivator(LogicalKeyboardKey.keyL): _goToMyPosition,
              const SingleActivator(LogicalKeyboardKey.equal): () => _zoom(1),
              const SingleActivator(LogicalKeyboardKey.add): () => _zoom(1),
              const SingleActivator(LogicalKeyboardKey.minus): () => _zoom(-1),
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                  _pan(-1, 0),
              const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                  _pan(1, 0),
              const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                  _pan(0, -1),
              const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                  _pan(0, 1),
              const SingleActivator(LogicalKeyboardKey.keyT): _cycleTraffic,
              const SingleActivator(LogicalKeyboardKey.keyD): _cycleTheme,
            },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: ListenableBuilder(
            listenable: Listenable.merge([_traffic, _route, _positioning]),
            builder: (context, _) => LayoutBuilder(
              builder: (context, box) {
                // Square and landscape screens (Titan 2 is 720x686 logical px) have
                // no spare height: keep every control on the side edges.
                final short = box.maxHeight < box.maxWidth * 1.3;
                return Stack(
                  children: [
                    // While search covers the screen the map is not drawn, so
                    // typing does not compete with map rendering.
                    buildMapView(
                      visible: _section == _Section.navigator,
                      controller: _map,
                      scene: _scene(context),
                      initialCenter:
                          widget.settings.center ??
                          const LatLng(55.7522, 37.6156),
                      initialZoom: widget.settings.zoom ?? 11,
                      onLongPress: (point) => setState(() {
                        _picked = point;
                        _pickedLabel = null;
                      }),
                      onCameraChanged: (center, zoom) {
                        _saveCamera?.cancel();
                        _saveCamera = Timer(
                          const Duration(seconds: 1),
                          () => widget.settings.saveCamera(center, zoom),
                        );
                      },
                    ),
                    SafeArea(
                      minimum: const EdgeInsets.all(8),
                      child: Stack(
                        children: [
                          if (!_route.guiding)
                            Align(
                              alignment: short
                                  ? Alignment.topLeft
                                  : Alignment.bottomCenter,
                              child: Padding(
                                padding: EdgeInsets.only(
                                  bottom: short ? 0 : 24,
                                ),
                                child: _TrafficSwitch(
                                  controller: _traffic,
                                  vertical: short,
                                ),
                              ),
                            ),
                          if (_route.guiding && _route.selected != null)
                            Align(
                              alignment: Alignment.topCenter,
                              child: Padding(
                                padding: const EdgeInsets.only(right: 56),
                                child: GuidanceBanner(controller: _route),
                              ),
                            )
                          else if (_picked != null || _route.active)
                            Align(
                              alignment: short
                                  ? Alignment.bottomLeft
                                  : Alignment.bottomCenter,
                              child: Padding(
                                padding: EdgeInsets.only(
                                  bottom: short ? 28 : 84,
                                  right: short ? 64 : 0,
                                ),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 380,
                                  ),
                                  child: _picked != null
                                      ? PickedPointCard(
                                          point: _picked!,
                                          label: _pickedLabel,
                                          onTo: () {
                                            _route.setTo(
                                              _picked!,
                                              label: _pickedLabel,
                                            );
                                            setState(() => _picked = null);
                                          },
                                          onFrom: () {
                                            _route.setFrom(
                                              _picked!,
                                              label: _pickedLabel,
                                            );
                                            setState(() => _picked = null);
                                          },
                                          onClose: () =>
                                              setState(() => _picked = null),
                                        )
                                      : RoutePanel(controller: _route),
                                ),
                              ),
                            ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: _MapButtons(
                              onMyPosition: _goToMyPosition,
                              onLocationDetails: _showLocation,
                              hasFix: _positioning?.estimate != null,
                              onZoom: _zoom,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_searching)
                      Positioned.fill(
                        child: Material(
                          color: Theme.of(context).colorScheme.surface,
                          child: SafeArea(
                            child: SearchPanel(
                              database: _places,
                              online: _photon,
                              near: _searchNear(),
                              initialQuery: _initialQuery,
                              onSelected: _onPlaceSelected,
                              onClose: () => _open(_Section.navigator),
                            ),
                          ),
                        ),
                      ),
                    if (_section == _Section.routes ||
                        _section == _Section.settings)
                      Positioned.fill(
                        child: Material(
                          color: Theme.of(context).colorScheme.surface,
                          child: SafeArea(
                            child: _section == _Section.routes
                                ? RoutesScreen(
                                    route: _route,
                                    onShowOnMap: () =>
                                        _open(_Section.navigator),
                                    onSearch: () => _open(_Section.search),
                                  )
                                : SettingsScreen(
                                    settings: widget.settings,
                                    traffic: _traffic,
                                    positioning: _positioning,
                                    onOpenPacks: _showPacks,
                                  ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          // The main sections sit under the thumb; more can be added here.
          bottomNavigationBar: NavigationBar(
            height: 64,
            selectedIndex: _section.index,
            onDestinationSelected: (i) => _open(_Section.values[i]),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.search), label: 'Поиск'),
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
    );
  }
}

/// Zoom and position buttons on the right edge: few, and large enough to
/// hit while driving.
class _MapButtons extends StatelessWidget {
  const _MapButtons({
    required this.onMyPosition,
    required this.onLocationDetails,
    required this.hasFix,
    required this.onZoom,
  });

  final VoidCallback onMyPosition, onLocationDetails;
  final bool hasFix;
  final void Function(double delta) onZoom;

  @override
  Widget build(BuildContext context) {
    Widget button(String tooltip, IconData icon, VoidCallback onPressed) =>
        IconButton(
          tooltip: tooltip,
          iconSize: 28,
          constraints: const BoxConstraints.tightFor(width: 56, height: 56),
          icon: Icon(icon),
          onPressed: onPressed,
        );
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          button('Приблизить', Icons.add, () => onZoom(1)),
          button('Отдалить', Icons.remove, () => onZoom(-1)),
          const SizedBox(width: 32, child: Divider(height: 8)),
          GestureDetector(
            onLongPress: onLocationDetails,
            child: button(
              hasFix ? 'Моё местоположение' : 'Местоположение не определено',
              hasFix ? Icons.my_location : Icons.location_searching,
              onMyPosition,
            ),
          ),
        ],
      ),
    );
  }
}

class _TrafficSwitch extends StatelessWidget {
  const _TrafficSwitch({required this.controller, required this.vertical});

  final TrafficController controller;
  final bool vertical;

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
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    return 'Обновлено в $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _status();
    final statusText = status == null
        ? null
        : Text(
            status,
            style: theme.textTheme.labelSmall?.copyWith(
              color: controller.error != null
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
          );

    // Short screens get a single button with a menu instead of a wide switch.
    if (vertical) {
      return Card(
        clipBehavior: Clip.antiAlias,
        child: PopupMenuButton<TrafficSource>(
          tooltip: 'Пробки',
          initialValue: controller.source,
          onSelected: controller.select,
          itemBuilder: (context) => [
            for (final s in TrafficSource.values)
              PopupMenuItem(value: s, child: Text(_labels[s]!)),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.traffic_outlined, size: 20),
                const SizedBox(width: 8),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _labels[controller.source]!,
                      style: theme.textTheme.labelLarge,
                    ),
                    ?statusText,
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<TrafficSource>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: [
                for (final s in TrafficSource.values)
                  ButtonSegment(value: s, label: Text(_labels[s]!)),
              ],
              selected: {controller.source},
              onSelectionChanged: (s) => controller.select(s.first),
            ),
            if (statusText != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
                child: statusText,
              ),
          ],
        ),
      ),
    );
  }
}
