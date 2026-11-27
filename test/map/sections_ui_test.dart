import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/map/route_controller.dart';
import 'package:mapsoly/map/routes_screen.dart';
import 'package:mapsoly/routing/valhalla_client.dart';
import 'package:mapsoly/settings.dart';
import 'package:mapsoly/settings_screen.dart';
import 'package:mapsoly/traffic/traffic.dart';

/// Renders the settings and routes sections above a bottom bar at the Titan
/// 2's window size and fails on layout overflow. With `UI_SHOTS=dir` it
/// also writes PNGs for inspection.
void main() {
  final shots = Platform.environment['UI_SHOTS'];

  setUpAll(() async {
    Future<void> load(String family, String? path) async {
      if (path == null || !File(path).existsSync()) return;
      final loader = FontLoader(family)
        ..addFont(
          Future.value(ByteData.sublistView(File(path).readAsBytesSync())),
        );
      await loader.load();
    }

    await load('Roboto', Platform.environment['UI_FONT']);
    await load('MaterialIcons', Platform.environment['UI_ICON_FONT']);
  });

  Future<void> show(
    WidgetTester tester,
    String name,
    Widget body,
    int tab, {
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = const Size(720, 686);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF2E7D6B),
          brightness: brightness,
          fontFamily: 'Roboto',
        ),
        home: RepaintBoundary(
          key: key,
          child: Scaffold(
            body: SafeArea(child: body),
            bottomNavigationBar: NavigationBar(
              height: 64,
              selectedIndex: tab,
              destinations: const [
                NavigationDestination(icon: Icon(Icons.search), label: 'Поиск'),
                NavigationDestination(
                  icon: Icon(Icons.navigation_outlined),
                  label: 'Навигатор',
                ),
                NavigationDestination(
                  icon: Icon(Icons.alt_route),
                  label: 'Маршруты',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  label: 'Настройки',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '$name overflows');
    if (shots == null) return;
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$shots/$name.png')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  testWidgets('settings section', (tester) async {
    final settings = await tester.runAsync(AppSettings.load);
    final traffic = TrafficController();
    addTearDown(traffic.dispose);
    final screen = SettingsScreen(
      settings: settings!,
      traffic: traffic,
      positioning: null,
      onOpenPacks: () {},
    );
    await show(tester, 'settings', screen, 3);
    expect(find.text('Оформление'), findsOneWidget);
    expect(find.text('Карты для работы без сети'), findsOneWidget);
    // Every tappable row is at least 56 px tall.
    for (final element in find.byType(ListTile).evaluate()) {
      expect(element.size!.height, greaterThanOrEqualTo(56));
    }
    await show(tester, 'settings_dark', screen, 3, brightness: Brightness.dark);
  });

  testWidgets('routes section without and with a route', (tester) async {
    final empty = RouteController();
    addTearDown(empty.dispose);
    await show(
      tester,
      'routes_empty',
      RoutesScreen(route: empty, onShowOnMap: () {}, onSearch: () {}),
      2,
    );
    expect(find.text('Маршрут не задан'), findsOneWidget);

    final routes = RouteResult.fromJson(
      jsonDecode(
            File(
              'test/routing/fixtures/route_auto_alternates.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>,
    ).routes;
    final planned = RouteController()
      ..debugSetRoutes(
        routes,
        from: routes.first.shape.first,
        to: routes.first.shape.last,
      );
    addTearDown(planned.dispose);
    await show(
      tester,
      'routes_planned',
      RoutesScreen(route: planned, onShowOnMap: () {}, onSearch: () {}),
      2,
    );
    expect(find.text('На карте'), findsOneWidget);
    expect(find.text('Сбросить'), findsOneWidget);
  });
}
