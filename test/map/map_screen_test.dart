import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/main.dart';
import 'package:mapsoly/map/drive_camera.dart';
import 'package:mapsoly/map/engine/map_engine.dart';
import 'package:mapsoly/map/map_screen.dart';
import 'package:mapsoly/map/route_controller.dart';
import 'package:mapsoly/map/speedometer.dart';
import 'package:mapsoly/map/route_panel.dart';
import 'package:mapsoly/places/search_panel.dart';
import 'package:mapsoly/positioning/positioning.dart';
import 'package:mapsoly/routing/valhalla_client.dart';
import 'package:mapsoly/settings.dart';
import 'package:mapsoly/user/file_exchange.dart';
import 'package:mapsoly/user/privacy_zones.dart';
import 'package:mapsoly/user/user_data.dart';
import 'package:mapsoly/user/user_places.dart';

import '../ui_shots.dart';
import '../user/fakes.dart';
import 'fake_routing.dart';

/// The whole main screen with a stand-in for the map: what lies on the map
/// in each state, the camera modes, picking a point, and "back" stepping
/// out of everything one level at a time.
void main() {
  setUpAll(loadShotFonts);

  late AppSettings settings;
  late UserData user;
  late FakeMapController map;
  late FakeGnss gnss;
  late PositioningEngine engine;
  late RouteController route;
  late Directory home;
  late DateTime clock;
  MapScene? scene;

  List<Route> routes() => RouteResult.fromJson(
    jsonDecode(fixture('route_auto_alternates.json')) as Map<String, dynamic>,
  ).routes;

  Future<void> start(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    double maxPitch = 60,
    Size size = const Size(720, 686),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    settings = (await tester.runAsync(AppSettings.load))!;
    map = FakeMapController(maxPitch: maxPitch);
    gnss = FakeGnss();
    clock = DateTime.utc(2026, 11, 27, 9);
    engine = PositioningEngine(
      db: LocationDb.inMemory(),
      gnss: gnss,
      now: () => clock,
      config: const PositioningConfig(
        wifiScanInterval: Duration(hours: 1),
        cellPollInterval: Duration(hours: 1),
        outputInterval: Duration(hours: 1),
      ),
    );
    route = RouteController()..debounce = Duration.zero;
    home = Directory.systemTemp.createTempSync('mapsoly_screen');
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await engine.dispose();
      });
      home.deleteSync(recursive: true);
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: screenKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: shotTheme(brightness),
          home: MapScreen(
            settings: settings,
            user: user,
            testHooks: MapScreenTestHooks(
              controller: map,
              mapView: (s) {
                scene = s;
                return const FakeMap();
              },
              engine: engine,
              route: route,
              files: DesktopFileExchange(home: home),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(engine.start);
    await tester.pumpAndSettle();
  }

  /// A few seconds of good GNSS at [p], moving at [speed] m/s.
  Future<void> fix(WidgetTester tester, LatLng p, {double speed = 0}) async {
    for (var i = 0; i < 4; i++) {
      final east = proj.x(p.longitude), north = proj.y(p.latitude);
      gnss.controller.add(fixAt(clock, east, north, speed: speed));
      clock = clock.add(const Duration(seconds: 1));
    }
    // The engine publishes its estimate after a poll.
    await tester.runAsync(engine.pollNow);
    await tester.pumpAndSettle();
  }

  Future<void> back(WidgetTester tester) async {
    final root = tester.state<NavigatorState>(find.byType(Navigator).first);
    await root.maybePop();
    await tester.pumpAndSettle();
  }

  Future<void> shot(WidgetTester tester, String name) =>
      snap(tester, name, key: screenKey);

  int section(WidgetTester tester) =>
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

  const palace = origin; // Palace Square
  const admiralty = LatLng(59.9375, 30.3086);
  const smolny = LatLng(59.9489, 30.3953);

  setUp(() {
    user = UserData.inMemory();
    scene = null;
  });

  testWidgets('the map by default: a chip, the buttons, the bar', (
    tester,
  ) async {
    await start(tester);
    await shot(tester, 'map_default');
    expect(find.byType(TrafficChip), findsOneWidget);
    expect(find.byType(MapButtons), findsOneWidget);
    expect(find.text('Домой'), findsNothing);
    expect(find.byType(RoutePanel), findsNothing);
    // The privacy guard is on the engine before anything else happens.
    expect(engine.privacyFilter, isNotNull);
    // Glass surfaces are reported to the engine for blurring.
    await tester.pump();
    expect(scene!.blurRects, isNotEmpty);
    expect(scene!.offlineLoading, isFalse);
    for (final tip in ['Приблизить', 'Отдалить', 'Объёмная карта']) {
      expect(tester.getSize(find.byTooltip(tip)), const Size(56, 56));
    }
    // Everything fits between the chip and the bar.
    final buttons = tester.getRect(find.byType(MapButtons));
    expect(buttons.top, greaterThanOrEqualTo(0));
    expect(buttons.bottom, lessThanOrEqualTo(686 - 64));
  });

  testWidgets('home and work are one tap away, and get out of the way', (
    tester,
  ) async {
    user.places
      ..save(SavedPlace(name: 'Дом', kind: SavedPlaceKind.home, point: smolny))
      ..save(
        SavedPlace(name: 'Работа', kind: SavedPlaceKind.work, point: admiralty),
      );
    await start(tester);
    route.debugClient = FakeRouting().client;
    await shot(tester, 'map_quick');
    expect(find.text('Домой'), findsOneWidget);
    expect(find.text('На работу'), findsOneWidget);

    // Without a position: the planner opens and asks where to start.
    await tester.tap(find.text('Домой'));
    await tester.pumpAndSettle();
    expect(section(tester), 2);
    expect(route.needStart, isTrue);
    expect(find.text('Выберите, откуда ехать'), findsWidgets);
    await shot(tester, 'map_quick_no_fix_planner');
    route.clear();
    await back(tester);
    expect(section(tester), 1);

    // With a position: a route from here, shown on the map.
    await fix(tester, palace);
    await tester.tap(find.text('На работу'));
    await settleIo(tester);
    expect(section(tester), 1);
    expect(route.stops.map(stopTitle), ['Моё местоположение', 'Работа']);
    expect(route.selected, isNotNull);
    expect(find.byType(RoutePanel), findsOneWidget);
    // The quick buttons give way to the route card.
    expect(find.text('Домой'), findsNothing);
    await shot(tester, 'map_route');
    expect(map.fitted, isNotNull);
  });

  testWidgets('back steps out one level at a time', (tester) async {
    await start(tester);
    route.debugClient = FakeRouting().client;
    await fix(tester, palace);

    // Settings -> a screen inside -> its editor.
    await tester.tap(find.text('Настройки'));
    await tester.pumpAndSettle();
    expect(section(tester), 3);
    await tester.scrollUntilVisible(
      find.text('Где ничего не записывать'),
      80,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Где ничего не записывать'));
    await tester.pumpAndSettle();
    expect(find.text('Добавить зону'), findsOneWidget);
    await back(tester);
    expect(find.text('Добавить зону'), findsNothing);
    expect(section(tester), 3);
    await back(tester);
    expect(section(tester), 1);

    // Routes -> choose a stop -> pick on the map: three levels.
    await tester.tap(find.text('Маршруты'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Добавить остановку'));
    await tester.pumpAndSettle();
    expect(find.text('Куда поедем?'), findsOneWidget);
    await tester.tap(find.text('На карте'));
    await tester.pumpAndSettle();
    // The map with a crosshair; the bar gives way to the two buttons.
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Выбрать эту точку'), findsOneWidget);
    await shot(tester, 'map_pick');
    await back(tester); // cancels picking: the chooser is still there
    expect(section(tester), 2);
    expect(find.text('Куда поедем?'), findsOneWidget);
    expect(route.active, isFalse);
    await back(tester); // closes the chooser
    expect(find.text('Куда поедем?'), findsNothing);
    expect(section(tester), 2);
    await back(tester); // leaves the section
    expect(section(tester), 1);

    // The same, confirmed: the centre of the map becomes the stop.
    await tester.tap(find.text('Маршруты'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Добавить остановку'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('На карте'));
    await tester.pumpAndSettle();
    map.gesture(center: admiralty);
    await tester.tap(find.text('Выбрать эту точку'));
    await settleIo(tester);
    expect(section(tester), 2);
    expect(route.stops.last.point, admiralty);
    expect(route.stops.first.myPosition, isTrue);
    expect(route.selected, isNotNull);

    await shot(tester, 'map_planner_after_pick');
    // "Go": guidance on the map. Back asks, back again ends it.
    await tester.pumpAndSettle();
    // (Pressed directly: with the test's block font, used when no real font
    // is given, the wide labels next to it squeeze this button.)
    tester
        .widget<FilledButton>(
          find.ancestor(
            of: find.text('Поехали'),
            matching: find.bySubtype<FilledButton>(),
          ),
        )
        .onPressed!();
    await tester.pumpAndSettle();
    expect(section(tester), 1);
    expect(route.guiding, isTrue);
    expect(find.byType(GuidanceBanner), findsOneWidget);
    await back(tester);
    expect(route.guiding, isTrue);
    expect(find.text('Завершить маршрут?'), findsOneWidget);
    await shot(tester, 'map_guidance_end_question');
    await back(tester);
    expect(route.guiding, isFalse);
    // The route card is back; one more step closes the route.
    expect(find.byType(RoutePanel), findsOneWidget);
    await back(tester);
    expect(route.active, isFalse);
    // Nothing left to close: the next "back" would leave the app.
    final root = tester.state<NavigatorState>(find.byType(Navigator).first);
    final scope = find.byWidgetPredicate((w) => w is PopScope).first;
    expect(tester.widget<PopScope>(scope).canPop, isTrue);
    expect(root.canPop(), isFalse);
  });

  testWidgets('the end question goes away by itself', (tester) async {
    final all = routes();
    await start(tester);
    route
      ..debugSetRoutes(
        all,
        from: all.first.shape.first,
        to: all.first.shape.last,
      )
      ..startGuidance();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Завершить маршрут'));
    await tester.pumpAndSettle();
    expect(find.text('Завершить маршрут?'), findsOneWidget);
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.text('Завершить маршрут?'), findsNothing);
    expect(route.guiding, isTrue);
  });

  testWidgets('saved places in search; a picked point can be saved', (
    tester,
  ) async {
    user.places.save(
      SavedPlace(
        name: 'Дача',
        point: smolny,
        address: 'посёлок Комарово, Морская улица, 14',
      ),
    );
    await start(tester);
    await tester.tap(find.text('Поиск'));
    await tester.pumpAndSettle();
    await shot(tester, 'search_saved_places');
    expect(find.text('Мои места').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Дача'));
    await tester.pumpAndSettle();
    expect(section(tester), 1);
    expect(find.byType(PickedPointCard), findsOneWidget);
    expect(scene!.picked, smolny);
    await shot(tester, 'map_picked');

    await tester.tap(find.text('Сохранить место'));
    await tester.pumpAndSettle();
    await shot(tester, 'map_save_place');
    await tester.tap(find.text('Работа'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
    await tester.pumpAndSettle();
    expect(user.places.work?.point, smolny);
    // Back closes the card.
    await back(tester);
    expect(find.byType(PickedPointCard), findsNothing);
  });

  testWidgets('3D and the compass', (tester) async {
    await start(tester);
    Finder compass() => find.byTooltip('Повернуть севером вверх');
    double opacity() => compass().evaluate().isEmpty ? 0 : 1;
    // North-up and flat: the compass is not shown.
    expect(opacity(), 0);
    await tester.tap(find.byTooltip('Объёмная карта'));
    await tester.pumpAndSettle();
    expect(map.pitch, tiltedPitch);
    expect(settings.tilted, isTrue);
    expect(scene!.buildings3d, isTrue);
    expect(opacity(), 1);
    expect(find.byTooltip('Плоская карта'), findsOneWidget);
    // The user turns the map: the needle shows where north is.
    map.gesture(bearing: 70);
    await tester.pumpAndSettle();
    await shot(tester, 'map_3d_turned');
    final needle = tester.widget<Transform>(
      find.descendant(of: compass(), matching: find.byType(Transform)),
    );
    expect(needle.transform.getRotation().entry(0, 1), greaterThan(0.9));
    // A tap turns north up and keeps the tilt.
    await tester.tap(compass());
    await tester.pumpAndSettle();
    expect(map.bearing, 0);
    expect(map.pitch, tiltedPitch);
    await tester.tap(find.byTooltip('Плоская карта'));
    await tester.pumpAndSettle();
    expect(map.pitch, 0);
    expect(settings.tilted, isFalse);
    expect(scene!.buildings3d, isFalse);
    expect(opacity(), 0);
  });

  testWidgets('an engine that cannot tilt has no 3D button', (tester) async {
    await start(tester, maxPitch: 0);
    expect(find.text('3D'), findsNothing);
    await shot(tester, 'map_flat_engine');
  });

  testWidgets('the location button: centre, then follow with the heading', (
    tester,
  ) async {
    await start(tester);
    // No position yet: the button explains why.
    expect(find.byIcon(Icons.location_searching), findsOneWidget);
    await tester.tap(find.byTooltip('Местоположение не определено'));
    await tester.pumpAndSettle();
    expect(find.text('Уточнять онлайн'), findsOneWidget);
    await back(tester);

    await fix(tester, palace);
    await tester.tap(find.byTooltip('Показать моё местоположение'));
    await tester.pumpAndSettle();
    expect(map.center.latitude, closeTo(palace.latitude, 1e-4));
    await shot(tester, 'map_location_centered');
    // It follows the position.
    final before = map.moves;
    await fix(tester, at(40, 30), speed: 8);
    expect(map.moves, greaterThan(before));

    // Second tap: the map turns with the course while moving.
    await tester.tap(find.byTooltip('Поворачивать карту по ходу движения'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.navigation), findsWidgets);
    await shot(tester, 'map_location_heading');

    // Dragging the map: free again.
    await tester.dragFrom(const Offset(300, 300), const Offset(60, 40));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Показать моё местоположение'), findsOneWidget);
    final moves = map.moves;
    await fix(tester, palace);
    expect(map.moves, moves);
  });

  testWidgets('moving without a route: 3D and no controls, unless off', (
    tester,
  ) async {
    await start(tester);
    route.updateMyPosition(palace, accuracyM: 5, speedMps: 1);
    await tester.pumpAndSettle();
    expect(map.pitch, 0);
    expect(find.byType(MapButtons), findsOneWidget);
    expect(find.byType(Speedometer), findsNothing);

    route.updateMyPosition(admiralty, accuracyM: 5, speedMps: 14);
    await tester.pumpAndSettle();
    expect(map.pitch, tiltedPitch);
    expect(find.byType(MapButtons), findsNothing);
    expect(find.byType(Speedometer), findsOneWidget);
    await shot(tester, 'map_cruising');

    // The 3D button is the same switch as in the settings.
    await tester.tapAt(const Offset(300, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D'));
    await tester.pumpAndSettle();
    expect(settings.drive3d, isFalse);
    expect(map.pitch, 0);
  });

  testWidgets('3D on the move switched off: the map stays flat', (
    tester,
  ) async {
    await start(tester);
    settings.drive3d = false;
    route.updateMyPosition(admiralty, accuracyM: 5, speedMps: 14);
    await tester.pumpAndSettle();
    expect(map.pitch, 0);
    expect(find.byType(MapButtons), findsNothing);
  });

  testWidgets('the driving camera follows, pauses on a touch, resumes', (
    tester,
  ) async {
    final all = routes();
    final r = all.first;
    await start(tester);
    route
      ..debugSetRoutes(all, from: r.shape.first, to: r.shape.last)
      ..startGuidance()
      ..updateMyPosition(r.shape[30], accuracyM: 5, speedMps: 14);
    await tester.pumpAndSettle();
    route.updateMyPosition(r.shape[31], accuracyM: 5, speedMps: 14);
    await tester.pumpAndSettle();
    await shot(tester, 'map_driving');
    // Behind the car: tilted, turned along the route, car in the lower
    // third of what the banner at the bottom leaves free.
    expect(map.pitch, tiltedPitch);
    expect(map.center.latitude, closeTo(r.shape[31].latitude, 1e-3));
    expect(map.padding.top, greaterThan(100));
    // The maneuver banner at the bottom does not cover the car.
    expect(map.padding.bottom, greaterThan(100));
    expect(
      tester.getBottomLeft(find.byType(GuidanceBanner)).dy,
      greaterThan(500),
    );
    expect(scene!.buildings3d, isTrue);
    expect(find.text('Вернуться к маршруту'), findsNothing);

    // Nothing but the road on the move: no bar, no buttons, the speed.
    expect(find.byType(MapButtons), findsNothing);
    expect(tester.getSize(find.byType(NavigationBar)).height, 64);
    expect(
      tester.getTopLeft(find.byType(NavigationBar)).dy,
      greaterThanOrEqualTo(686),
    );
    expect(
      find.descendant(of: find.byType(Speedometer), matching: find.text('50')),
      findsOneWidget,
    );

    // A tap brings the controls back and the camera keeps following.
    await tester.tapAt(const Offset(300, 400));
    await tester.pumpAndSettle();
    expect(find.byType(MapButtons), findsOneWidget);
    expect(tester.getTopLeft(find.byType(NavigationBar)).dy, lessThan(686));
    expect(find.text('Вернуться к маршруту'), findsNothing);
    await shot(tester, 'map_driving_controls');
    // Left alone, they go away again.
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.byType(MapButtons), findsNothing);

    // The driver looks around.
    await tester.dragFrom(const Offset(300, 400), const Offset(80, 40));
    await tester.pumpAndSettle();
    expect(find.text('Вернуться к маршруту'), findsOneWidget);
    await shot(tester, 'map_driving_paused');
    final moves = map.moves;
    route.updateMyPosition(r.shape[33], accuracyM: 5, speedMps: 14);
    await tester.pumpAndSettle();
    expect(map.moves, moves);
    await tester.tap(find.text('Вернуться к маршруту'));
    await tester.pumpAndSettle();
    expect(map.moves, greaterThan(moves));
    expect(find.text('Вернуться к маршруту'), findsNothing);

    // "3D in a trip" off: the same following, flat and north-up.
    final was = settings.drive3d;
    settings.drive3d = false;
    route.updateMyPosition(r.shape[35], accuracyM: 5, speedMps: 14);
    await tester.pumpAndSettle();
    expect(map.pitch, 0);
    expect(map.bearing, 0);
    expect(map.center.latitude, closeTo(r.shape[35].latitude, 1e-3));
    settings.drive3d = was;

    // Guidance over: the camera is released.
    route.stopGuidance();
    await tester.pumpAndSettle();
    expect(map.padding, EdgeInsets.zero);
    expect(map.pitch, 0);
  });

  testWidgets('arrival shows the trip in short', (tester) async {
    final all = routes();
    final r = all.first;
    await start(tester, brightness: Brightness.dark);
    route
      ..debugSetRoutes(
        all,
        from: r.shape.first,
        to: r.shape.last,
        stops: [
          RouteStop(r.shape.first),
          RouteStop(r.shape.last, label: 'Зеленоградск, променад'),
        ],
      )
      ..startGuidance();
    for (var i = 0; i < r.shape.length; i += 20) {
      route.updateMyPosition(r.shape[i], accuracyM: 5, speedMps: 20);
    }
    route.updateMyPosition(r.shape.last, accuracyM: 5, speedMps: 2);
    await tester.pumpAndSettle();
    expect(find.text('Вы приехали'), findsOneWidget);
    expect(find.byType(GuidanceBanner), findsNothing);
    await shot(tester, 'map_arrival_dark');
    await tester.tap(find.text('Готово'));
    await tester.pumpAndSettle();
    expect(route.active, isFalse);
  });

  testWidgets('in a privacy zone: a small shield, and no position for the '
      'online search', (tester) async {
    await start(tester);
    await fix(tester, palace);
    SearchPanel panel() => tester.widget<SearchPanel>(find.byType(SearchPanel));
    await tester.tap(find.text('Поиск'));
    await tester.pumpAndSettle();
    expect(panel().near, isNotNull);
    await back(tester);
    expect(find.byIcon(Icons.shield), findsNothing);

    user.zones.add(PrivacyZone(name: 'Дом', center: palace, radiusM: 300));
    await fix(tester, palace);
    expect(engine.status.privateArea, isTrue);
    expect(find.byIcon(Icons.shield), findsOneWidget);
    await shot(tester, 'map_private_area');
    await tester.tap(find.text('Поиск'));
    await tester.pumpAndSettle();
    expect(panel().near, isNull);
  });

  testWidgets('a tall phone', (tester) async {
    user.places.save(
      SavedPlace(name: 'Дом', kind: SavedPlaceKind.home, point: smolny),
    );
    final all = routes();
    await start(tester, size: const Size(380, 800));
    await shot(tester, 'map_tall');
    route.debugSetRoutes(
      all,
      from: all.first.shape.first,
      to: all.first.shape.last,
    );
    await tester.pumpAndSettle();
    await shot(tester, 'map_tall_route');
    route.startGuidance();
    await tester.pumpAndSettle();
    await shot(tester, 'map_tall_guidance');
  });

  test('the app theme: one accent, full-size touch targets', () {
    final theme = MapsolyApp.theme(Brightness.dark);
    expect(theme.visualDensity, VisualDensity.standard);
    expect(theme.brightness, Brightness.dark);
  });
}

final screenKey = GlobalKey();
