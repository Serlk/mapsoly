import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/map/point_picker.dart';
import 'package:mapsoly/map/route_controller.dart';
import 'package:mapsoly/map/routes_screen.dart';
import 'package:mapsoly/routing/valhalla_client.dart';
import 'package:mapsoly/user/file_exchange.dart';
import 'package:mapsoly/user/gpx.dart';
import 'package:mapsoly/user/saved_routes.dart';
import 'package:mapsoly/user/user_data.dart';
import 'package:mapsoly/user/user_places.dart';

import '../ui_shots.dart';
import 'fake_routing.dart';

/// The trip planner and the saved routes: every state rendered at the Titan
/// 2's window size (and on a tall phone), and the flows a user goes through.
void main() {
  setUpAll(loadShotFonts);

  // Public landmarks along the Baltic coast.
  const station = LatLng(54.6941, 20.4996);
  const museum = LatLng(54.7227, 20.5225);
  const lake = LatLng(54.4270, 22.7250);
  const spit = LatLng(54.9578, 20.4752);

  Route trip(int stops) => RouteResult.fromJson(
    jsonDecode(tripWithStops(stops)) as Map<String, dynamic>,
  ).best;

  late RouteController route;
  late UserData user;
  late FakeMapServices services;
  late Directory home;
  late DesktopFileExchange files;
  late ValueNotifier<int> tab;
  var went = 0;

  setUp(() {
    route = RouteController()..debounce = Duration.zero;
    user = UserData.inMemory();
    services = FakeMapServices();
    home = Directory.systemTemp.createTempSync('mapsoly_planner');
    files = DesktopFileExchange(home: home);
    tab = ValueNotifier(0);
    went = 0;
  });
  tearDown(() {
    route.dispose();
    tab.dispose();
    home.deleteSync(recursive: true);
  });

  Widget screen() => Navigator(
    onGenerateRoute: (_) => MaterialPageRoute<void>(
      builder: (_) => RoutesScreen(
        route: route,
        user: user,
        services: services,
        files: files,
        tab: tab,
        onGo: () => went++,
      ),
    ),
  );

  Future<void> both(
    WidgetTester tester,
    String name, {
    Size size = const Size(720, 686),
  }) async {
    await shoot(tester, name, screen(), tab: 2, size: size);
    await shoot(
      tester,
      '${name}_dark',
      screen(),
      tab: 2,
      size: size,
      brightness: Brightness.dark,
    );
  }

  void planFour() {
    final r = trip(4);
    route.debugSetRoutes(
      [r],
      from: station,
      to: spit,
      stops: const [
        RouteStop.myPosition(station),
        RouteStop(museum, label: 'Музей янтаря'),
        RouteStop(
          lake,
          label: 'Виштынецкое озеро, база отдыха «У трёх границ»',
        ),
        RouteStop(spit, label: 'Куршская коса, визит-центр'),
      ],
      trafficTimes: const [Duration(hours: 5, minutes: 20)],
    );
  }

  testWidgets('empty: one sentence and one button', (tester) async {
    await both(tester, 'planner_empty');
    expect(find.text('Добавить остановку'), findsOneWidget);
    expect(find.text('Поехали'), findsNothing);
  });

  testWidgets('a four-stop trip: legs, totals, actions', (tester) async {
    planFour();
    await both(tester, 'planner_trip');
    expect(find.text('Моё местоположение'), findsOneWidget);
    expect(find.text('5 ч 20 мин'), findsOneWidget);
    expect(find.textContaining('от предыдущей'), findsNWidgets(3));
    // Rows and their controls are finger-sized.
    for (final title in ['Музей янтаря', 'Куршская коса, визит-центр']) {
      final row = find.ancestor(
        of: find.text(title),
        matching: find.byType(InkWell),
      );
      expect(tester.getSize(row.first).height, greaterThanOrEqualTo(64));
    }
    for (final tip in ['Выше', 'Ниже', 'Убрать остановку']) {
      expect(tester.getSize(find.byTooltip(tip).first).height, 48);
    }
    for (final label in ['Поехали', 'Сохранить', 'Добавить остановку']) {
      final button = find.ancestor(
        of: find.text(label),
        matching: find.bySubtype<ButtonStyleButton>(),
      );
      expect(tester.getSize(button.first).height, greaterThanOrEqualTo(52));
    }
    // A tall, narrow phone gets the same things in two lines.
    await both(tester, 'planner_trip_tall', size: const Size(380, 800));
  });

  testWidgets('building, a failed stop, and a missing start', (tester) async {
    planFour();
    route.debugSetRoutes(
      const [],
      from: station,
      to: spit,
      stops: route.stops,
      loading: true,
    );
    await shoot(tester, 'planner_loading', screen(), tab: 2);
    expect(find.text('Строю маршрут…'), findsOneWidget);
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

    route.debugSetRoutes(
      const [],
      from: station,
      to: spit,
      stops: route.stops,
      error:
          'Рядом с остановкой 3 «Виштынецкое озеро, база отдыха '
          '«У трёх границ»» нет дороги',
      errorStop: 2,
    );
    await both(tester, 'planner_error');
    expect(find.text('Сюда не получается проехать'), findsOneWidget);

    route.clear();
    route.addStop(spit, label: 'Куршская коса, визит-центр');
    expect(route.needStart, isTrue);
    await both(tester, 'planner_need_start');
    expect(find.text('Выберите, откуда ехать'), findsNWidgets(2));
  });

  testWidgets('planning a four-stop trip, step by step', (tester) async {
    final routing = FakeRouting();
    route.debugClient = routing.client;
    services.myPosition = station;
    route.updateMyPosition(station);
    user.places.save(
      SavedPlace(name: 'Дача', point: lake, kind: SavedPlaceKind.favorite),
    );
    await shoot(tester, 'flow_0_empty', screen(), tab: 2);

    // 1. Add the first stop: found by search.
    services.searchAnswer = const PickedPlace(museum, label: 'Музей янтаря');
    await tester.tap(find.text('Добавить остановку'));
    await tester.pumpAndSettle();
    await snap(tester, 'flow_1_choose');
    expect(find.text('Куда поедем?'), findsOneWidget);
    expect(find.text('Найти'), findsOneWidget);
    expect(find.text('На карте'), findsOneWidget);
    // The trip will start from here anyway.
    expect(find.text('Моё местоположение'), findsNothing);
    await tester.tap(find.text('Найти'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Результат поиска'));
    await settleIo(tester);
    expect(route.stops.map(stopTitle), ['Моё местоположение', 'Музей янтаря']);

    // 2. A saved place, one tap on its chip.
    await tester.tap(find.text('Добавить остановку'));
    await tester.pumpAndSettle();
    await snap(tester, 'flow_1b_choose_saved');
    await tester.tap(find.text('Дача'));
    await tester.pumpAndSettle();

    // 3. A point picked on the map.
    services.mapAnswer = const PickedPlace(spit);
    await tester.tap(find.text('Добавить остановку'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('На карте'));
    await settleIo(tester);
    expect(services.mapPicks, 1);
    expect(route.stops.length, 4);
    expect(route.selected, isNotNull);
    expect(route.selected!.legs.length, 3);
    await snap(tester, 'flow_2_four_stops');
    expect(find.textContaining('от предыдущей'), findsNWidgets(3));

    // 4. The map point goes before the saved place: one tap on "up".
    await tester.tap(find.byTooltip('Выше').last);
    await settleIo(tester);
    expect(route.stops[2].point, spit);
    expect(route.stops[3].label, 'Дача');

    // 5. Remove a stop, and take that back.
    await tester.tap(find.byTooltip('Убрать остановку').at(1));
    await tester.pumpAndSettle();
    expect(route.stops.length, 3);
    await snap(tester, 'flow_3_removed_undo');
    await tester.tap(find.text('Вернуть'));
    await settleIo(tester);
    expect(route.stops.length, 4);
    expect(route.stops[1].label, 'Музей янтаря');

    // 6. Save it under the offered name.
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    await snap(tester, 'flow_4_save_name');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Дача',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
    await tester.pumpAndSettle();
    final saved = user.routes.routes.single;
    expect(saved.name, 'Дача');
    expect(saved.points.length, 4);
    expect(saved.points.first.point, station);
    expect(saved.geometry, isNotEmpty);

    // 7. Go.
    await tester.tap(find.text('Поехали'));
    expect(route.guiding, isTrue);
    expect(went, 1);
  });

  testWidgets('clearing can be undone; sharing writes a GPX file', (
    tester,
  ) async {
    planFour();
    await shoot(tester, 'planner_actions', screen(), tab: 2);
    await tester.tap(find.text('Поделиться файлом'));
    await settleIo(tester);
    await snap(tester, 'planner_shared');
    final written = Directory('${home.path}/Documents/Mapsoly')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.gpx'))
        .toList();
    expect(written.length, 1);
    final back = importGpx(written.single.readAsStringSync());
    expect(back.routes.single.points.length, 4);
    expect(find.textContaining(written.single.path), findsOneWidget);

    await tester.tap(find.text('Очистить'));
    await tester.pumpAndSettle();
    expect(route.active, isFalse);
    await tester.tap(find.text('Вернуть'));
    await tester.pumpAndSettle();
    expect(route.stops.length, 4);
  });

  testWidgets('saved routes: open, rename, delete with undo', (tester) async {
    tab.value = 1;
    await both(tester, 'saved_empty');
    expect(find.text('Импорт из файла'), findsOneWidget);

    user.routes
      ..save(
        SavedRoute(
          name: 'Калининград — Куршская коса',
          created: DateTime.utc(2026, 11, 20),
          points: const [
            RoutePoint(station, label: 'Южный вокзал'),
            RoutePoint(museum, label: 'Музей янтаря'),
            RoutePoint(spit, label: 'Куршская коса'),
          ],
          lengthMeters: 78400,
        ),
      )
      ..save(
        SavedRoute(
          name: 'На озеро через все заправки и смотровые площадки побережья',
          created: DateTime.utc(2026, 11, 25),
          costing: RouteCosting.bicycle,
          points: const [RoutePoint(station), RoutePoint(lake)],
          lengthMeters: 182000,
        ),
      );
    await both(tester, 'saved_list');
    expect(find.text('3 остановки · 78 км'), findsOneWidget);
    for (final tip in ['Переименовать', 'Поделиться файлом', 'Удалить']) {
      expect(tester.getSize(find.byTooltip(tip).first).height, 48);
    }

    // Delete, then undo.
    await tester.tap(find.byTooltip('Удалить').first);
    await tester.pumpAndSettle();
    expect(user.routes.routes.length, 1);
    await tester.tap(find.text('Вернуть'));
    await tester.pumpAndSettle();
    expect(user.routes.routes.length, 2);

    // Rename.
    await tester.tap(find.byTooltip('Переименовать').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'К маяку');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(user.routes.routes.map((r) => r.name), contains('К маяку'));

    // A tap opens the route in the planner.
    await tester.tap(find.text('К маяку'));
    await tester.pumpAndSettle();
    expect(tab.value, 0);
    expect(route.stops.map(stopTitle), [
      'Южный вокзал',
      'Музей янтаря',
      'Куршская коса',
    ]);
    await snap(tester, 'saved_opened_in_planner');
    await shoot(
      tester,
      'saved_list_tall',
      screen(),
      tab: 2,
      size: const Size(380, 800),
    );
  });
}
