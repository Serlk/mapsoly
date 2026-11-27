import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/map/route_controller.dart';
import 'package:mapsoly/map/route_panel.dart';
import 'package:mapsoly/map/speedometer.dart';
import 'package:mapsoly/places/places_database.dart';
import 'package:mapsoly/routing/valhalla_client.dart';

import '../places/fixture.dart';
import '../ui_shots.dart';

/// Renders what lies on the map (route card, picked-point card, guidance
/// banner, arrival card) over a map-like background at the Titan 2's window
/// size, and fails on layout overflow. With `UI_SHOTS=dir` it also writes
/// PNGs for inspection.
void main() {
  setUpAll(loadShotFonts);

  List<Route> load(String name) => RouteResult.fromJson(
    jsonDecode(File('test/routing/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>,
  ).routes;
  List<Route> routes() => load('route_auto_alternates.json');
  Route twoLegs() => load('route_pedestrian_two_legs.json').first;

  DateTime noon() => DateTime(2026, 11, 27, 12, 40);

  // Cards sit at the bottom left, the banner at the top left; both stay
  // clear of the buttons on the right.
  Widget onMap(Widget child, {bool top = false, double width = 400}) => FakeMap(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 80, 8),
      child: Align(
        alignment: top ? Alignment.topLeft : Alignment.bottomLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width),
          child: child,
        ),
      ),
    ),
  );

  Future<void> both(
    WidgetTester tester,
    String name,
    Widget Function() build,
  ) async {
    await shoot(tester, name, build(), tab: 1);
    await shoot(
      tester,
      '${name}_dark',
      build(),
      tab: 1,
      brightness: Brightness.dark,
    );
  }

  testWidgets('picked point card: go there first, the rest quieter', (
    tester,
  ) async {
    var saved = 0;
    await both(
      tester,
      'card_picked',
      () => onMap(
        PickedPointCard(
          point: const LatLng(55.7539, 37.6208),
          label:
              'улица Большая Якиманка, 24 — Москва, район Якиманка, '
              'Центральный административный округ',
          onFrom: () {},
          onTo: () {},
          onClose: () {},
          onAddStop: () {},
          onSave: () => saved++,
        ),
      ),
    );
    expect(find.text('Сюда'), findsOneWidget);
    await tester.tap(find.text('Сохранить место'));
    expect(saved, 1);
    for (final button in ['Сюда', 'Отсюда', 'Заехать', 'Сохранить место']) {
      expect(
        tester
            .getSize(
              find
                  .ancestor(
                    of: find.text(button),
                    matching: find.bySubtype<ButtonStyleButton>(),
                  )
                  .first,
            )
            .height,
        greaterThanOrEqualTo(52),
        reason: button,
      );
    }
    // A bare map point has no "add to the trip" until there is a trip.
    await shoot(
      tester,
      'card_picked_point',
      onMap(
        PickedPointCard(
          point: const LatLng(55.7539, 37.6208),
          onFrom: () {},
          onTo: () {},
          onClose: () {},
          onSave: () {},
        ),
      ),
      tab: 1,
    );
    expect(find.text('Заехать'), findsNothing);
  });

  testWidgets('route card: asks for a start when there is none', (
    tester,
  ) async {
    final c = RouteController()
      ..setTo(const LatLng(55.9726, 37.4146), label: 'Аэропорт Шереметьево');
    addTearDown(c.dispose);
    var planned = 0;
    await both(
      tester,
      'card_route_no_start',
      () => onMap(RoutePanel(controller: c, onPlan: () => planned++)),
    );
    expect(find.text('Откуда поедем?'), findsOneWidget);
    await tester.tap(find.text('Выбрать'));
    expect(planned, 1);
    // Nothing to drive yet.
    expect(
      tester
          .widget<FilledButton>(
            find.ancestor(
              of: find.text('Поехали'),
              matching: find.bySubtype<FilledButton>(),
            ),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('route card: building, and a failure', (tester) async {
    final all = routes();
    final c = RouteController()
      ..debugSetRoutes(
        const [],
        from: all.first.shape.first,
        to: all.first.shape.last,
        loading: true,
      );
    addTearDown(c.dispose);
    await shoot(
      tester,
      'card_route_loading',
      onMap(RoutePanel(controller: c, onPlan: () {})),
      tab: 1,
    );
    expect(find.text('Строю маршрут…'), findsOneWidget);
    c.debugSetRoutes(
      const [],
      from: all.first.shape.first,
      to: all.first.shape.last,
      error: 'Рядом с остановкой 3 «Озеро Виштынецкое» нет дороги',
    );
    await both(
      tester,
      'card_route_error',
      () => onMap(RoutePanel(controller: c, onPlan: () {})),
    );
    expect(find.textContaining('нет дороги'), findsOneWidget);
  });

  testWidgets('route card: three alternatives with traffic times', (
    tester,
  ) async {
    final all = routes();
    final c = RouteController()
      ..debugSetRoutes(
        all,
        from: all.first.shape.first,
        to: all.first.shape.last,
        stops: [
          const RouteStop.myPosition(),
          RouteStop(
            all.first.shape.last,
            label: 'Зеленоградск, Курортный проспект',
          ),
        ],
        trafficTimes: const [
          Duration(hours: 1, minutes: 47),
          Duration(hours: 2, minutes: 5),
          null,
        ],
      );
    addTearDown(c.dispose);
    await both(
      tester,
      'card_route',
      () => onMap(RoutePanel(controller: c, onPlan: () {}, now: noon)),
    );
    expect(find.text('1 ч 47 мин'), findsOneWidget);
    expect(find.textContaining('прибытие в 14:27'), findsOneWidget);
    expect(find.textContaining('без пробок 33 мин'), findsOneWidget);
    // Another alternative is one tap.
    await tester.ensureVisible(find.textContaining('2 ч 5 мин'));
    await tester.pump();
    await tester.tap(find.textContaining('2 ч 5 мин'));
    expect(c.selectedIndex, 1);
    await tester.tap(find.text('Поехали'));
    expect(c.guiding, isTrue);
  });

  testWidgets('route card: a trip with stops', (tester) async {
    final route = twoLegs();
    final c = RouteController()
      ..debugSetRoutes(
        [route],
        from: route.shape.first,
        to: route.shape.last,
        stops: [
          RouteStop(route.shape.first, label: 'Южный вокзал'),
          RouteStop(route.legs[1].shape.first, label: 'Музей янтаря'),
          RouteStop(route.shape.last, label: 'Остров Канта'),
        ],
      )
      ..setCostingForTest(RouteCosting.pedestrian);
    addTearDown(c.dispose);
    await shoot(
      tester,
      'card_route_stops',
      onMap(RoutePanel(controller: c, onPlan: () {}, now: noon)),
      tab: 1,
    );
    expect(
      find.text('Южный вокзал — 1 остановка — Остров Канта'),
      findsOneWidget,
    );
  });

  testWidgets('guidance stepped by hand', (tester) async {
    final all = routes();
    final c = RouteController()
      ..debugSetRoutes(
        all,
        from: all.first.shape.first,
        to: all.first.shape.last,
      )
      ..startGuidance()
      ..goToStep(3);
    addTearDown(c.dispose);
    await both(
      tester,
      'guidance_manual',
      () => onMap(GuidanceBanner(controller: c), top: true, width: 520),
    );
    expect(find.byTooltip('Следующий манёвр'), findsOneWidget);
    await tester.tap(find.byTooltip('Следующий манёвр'));
    expect(c.step, 4);
  });

  testWidgets('guidance following a position', (tester) async {
    final all = routes();
    final route = all.first;
    final c = RouteController()
      ..debugSetRoutes(all, from: route.shape.first, to: route.shape.last)
      ..startGuidance()
      ..updateMyPosition(
        route.shape[route.shape.length ~/ 3],
        accuracyM: 10,
        speedMps: 16.7,
      );
    addTearDown(c.dispose);
    expect(c.progress, isNotNull);
    expect(c.step, greaterThan(0));
    await both(
      tester,
      'guidance_driving',
      () => onMap(
        GuidanceBanner(controller: c, now: noon),
        top: true,
        width: 520,
      ),
    );
    expect(find.textContaining('прибытие в '), findsOneWidget);
    // The speed lives in its own badge on the map, not in the banner.
    expect(find.textContaining('км/ч'), findsNothing);
    // No manual stepping while a position drives the banner.
    expect(find.byTooltip('Следующий манёвр'), findsNothing);
    // The distance to the maneuver is the largest text of the banner.
    final sizes = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(GuidanceBanner),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.style?.fontSize ?? 0)
        .toList();
    expect(sizes.first, sizes.reduce((a, b) => a > b ? a : b));
  });

  testWidgets('ending the route takes a second, deliberate tap', (
    tester,
  ) async {
    final all = routes();
    final route = all.first;
    final c = RouteController()
      ..debugSetRoutes(all, from: route.shape.first, to: route.shape.last)
      ..startGuidance()
      ..updateMyPosition(route.shape[40], accuracyM: 10, speedMps: 12);
    addTearDown(c.dispose);
    var asking = false;
    Widget banner() => StatefulBuilder(
      builder: (context, setState) => onMap(
        GuidanceBanner(
          controller: c,
          now: noon,
          confirmingEnd: asking,
          onAskEnd: () => setState(() => asking = true),
          onCancelEnd: () => setState(() => asking = false),
        ),
        top: true,
        width: 520,
      ),
    );
    await shoot(tester, 'guidance_end_closed', banner(), tab: 1);
    // The cross is small and only asks.
    final cross = find.byTooltip('Завершить маршрут');
    expect(tester.getSize(cross).shortestSide, lessThanOrEqualTo(48));
    await tester.tap(cross);
    await tester.pumpAndSettle();
    expect(c.guiding, isTrue);
    await snap(tester, 'guidance_end_confirm');
    await tester.tap(find.text('Нет, едем'));
    await tester.pumpAndSettle();
    expect(c.guiding, isTrue);
    expect(find.text('Завершить'), findsNothing);
    await tester.tap(cross);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Завершить'));
    expect(c.guiding, isFalse);
  });

  testWidgets('a camera ahead, and driving over its limit', (tester) async {
    final all = routes();
    final route = all.first;
    final at = route.shape[60];
    final path = buildFixture(
      [],
      extra: (db) => addCamera(db, 1, at.latitude, at.longitude, maxspeed: 60),
    );
    final places = PlacesDatabase.open(path);
    addTearDown(() {
      places.close();
      File(path).parent.deleteSync(recursive: true);
    });
    final c = RouteController()
      ..places = places
      ..debugSetRoutes(all, from: route.shape.first, to: route.shape.last)
      ..startGuidance()
      ..updateMyPosition(route.shape[52], accuracyM: 5, speedMps: 15);
    addTearDown(c.dispose);
    expect(c.nextCamera, isNotNull);
    Widget banner() =>
        onMap(GuidanceBanner(controller: c, now: noon), top: true, width: 520);
    await shoot(tester, 'guidance_camera', banner(), tab: 1);
    expect(find.textContaining('лимит 60'), findsOneWidget);
    // Much too fast, closer to the camera.
    c.updateMyPosition(route.shape[56], accuracyM: 5, speedMps: 27);
    c.updateMyPosition(route.shape[57], accuracyM: 5, speedMps: 27);
    await both(tester, 'guidance_speeding', banner);
    if (c.speeding) {
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    }
  });

  testWidgets('an intermediate stop is announced, then arrival', (
    tester,
  ) async {
    final route = twoLegs();
    final first = route.legs.first;
    final c = RouteController()
      ..debugSetRoutes(
        [route],
        from: route.shape.first,
        to: route.shape.last,
        stops: [
          RouteStop(route.shape.first, label: 'Южный вокзал'),
          RouteStop(first.shape.last, label: 'Музей янтаря'),
          RouteStop(route.shape.last, label: 'Остров Канта'),
        ],
      )
      ..startGuidance()
      ..updateMyPosition(route.shape[2], accuracyM: 5, speedMps: 1.4)
      ..updateMyPosition(
        first.shape[first.shape.length - 4],
        accuracyM: 5,
        speedMps: 1.4,
      );
    addTearDown(c.dispose);
    Widget banner() =>
        onMap(GuidanceBanner(controller: c, now: noon), top: true, width: 520);
    await shoot(tester, 'guidance_stop_ahead', banner(), tab: 1);
    expect(find.textContaining('остановка: Музей янтаря'), findsOneWidget);
    c.updateMyPosition(first.shape.last, accuracyM: 5, speedMps: 0.5);
    await shoot(tester, 'guidance_stop_reached', banner(), tab: 1);
    expect(find.text('Остановка 2: Музей янтаря'), findsOneWidget);

    for (var i = first.shape.length; i < route.shape.length; i += 2) {
      c.updateMyPosition(route.shape[i], accuracyM: 5, speedMps: 1.4);
    }
    c.updateMyPosition(route.shape.last, accuracyM: 5);
    final arrival = c.arrival!;
    var done = 0;
    await both(
      tester,
      'card_arrival',
      () => onMap(ArrivalCard(summary: arrival, onDone: () => done++)),
    );
    expect(find.text('Вы приехали'), findsOneWidget);
    expect(find.text('Остров Канта'), findsOneWidget);
    await tester.tap(find.text('Готово'));
    expect(done, 1);
  });

  test('every maneuver type has an arrow', () {
    for (final type in ManeuverType.values) {
      expect(maneuverIcon(type), isNotNull);
    }
    expect(maneuverIcon(ManeuverType.left), Icons.turn_left);
    expect(maneuverIcon(ManeuverType.right), Icons.turn_right);
    expect(maneuverIcon(ManeuverType.uturnLeft), Icons.u_turn_left);
    expect(maneuverIcon(ManeuverType.destination), Icons.flag);
    expect(maneuverIcon(ManeuverType.roundaboutEnter), Icons.roundabout_left);
  });

  testWidgets('the speed badge and the limit sign', (tester) async {
    await both(
      tester,
      'speedometer',
      () => onMap(
        const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Speedometer(speedKmh: 47),
            SizedBox(height: 12),
            Speedometer(speedKmh: 58, limitKmh: 60),
            SizedBox(height: 12),
            Speedometer(speedKmh: 72, limitKmh: 60),
            SizedBox(height: 12),
            Speedometer(speedKmh: 127, limitKmh: 100),
          ],
        ),
      ),
    );
    expect(find.byType(SpeedLimitSign), findsNWidgets(3));
    expect(find.text('100'), findsOneWidget);
  });
}
