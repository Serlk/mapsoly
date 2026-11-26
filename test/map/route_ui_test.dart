import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/map/route_controller.dart';
import 'package:mapsoly/map/route_panel.dart';
import 'package:mapsoly/routing/valhalla_client.dart';

/// Renders the route UI at the Titan 2's logical size (720x686 as reported by
/// the compositor: 1440 px panel at scale 2, minus the status bar) and fails on
/// layout overflow. With `UI_SHOTS=dir` it also writes PNGs for inspection.
void main() {
  final shots = Platform.environment['UI_SHOTS'];

  setUpAll(() async {
    // Real fonts so the screenshots are readable (tests default to boxes).
    Future<void> load(String family, String path) async {
      final file = File(path);
      if (!file.existsSync()) return;
      final loader = FontLoader(family)
        ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
      await loader.load();
    }

    final text = Platform.environment['UI_FONT'];
    if (text != null) await load('Roboto', text);
    final icons = Platform.environment['UI_ICON_FONT'];
    if (icons != null) await load('MaterialIcons', icons);
  });

  List<Route> routes() => RouteResult.fromJson(
    jsonDecode(
          File(
            'test/routing/fixtures/route_auto_alternates.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>,
  ).routes;

  Future<void> show(
    WidgetTester tester,
    String name,
    Widget child, {
    Alignment alignment = Alignment.bottomLeft,
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
            body: Padding(
              padding: const EdgeInsets.all(8),
              child: Align(alignment: alignment, child: child),
            ),
          ),
        ),
      ),
    );
    // Let the theme change settle so the dark variant is really dark.
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '$name overflows');
    if (shots == null) return;
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$shots/$name.png')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  // The planner sits at the bottom left, clear of the buttons on the right.
  Widget planner(Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 28, right: 64),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 380),
      child: child,
    ),
  );

  testWidgets('picked point card with a long name', (tester) async {
    await show(
      tester,
      'picked_point',
      planner(
        PickedPointCard(
          point: const LatLng(55.7539, 37.6208),
          label:
              'улица Большая Якиманка, 24 — Москва, район Якиманка, '
              'Центральный административный округ',
          onFrom: () {},
          onTo: () {},
          onClose: () {},
        ),
      ),
    );
  });

  testWidgets('planner with only a destination', (tester) async {
    final c = RouteController()..setTo(const LatLng(55.9726, 37.4146));
    addTearDown(c.dispose);
    await show(tester, 'planner_no_start', planner(RoutePanel(controller: c)));
    expect(find.text('Откуда: не выбрано'), findsOneWidget);
  });

  testWidgets('planner with three alternatives and traffic times', (
    tester,
  ) async {
    final all = routes();
    final c = RouteController()
      ..debugSetRoutes(
        [...all, all.first].take(3).toList(),
        from: all.first.shape.first,
        to: all.first.shape.last,
        trafficTimes: const [
          Duration(hours: 1, minutes: 47),
          Duration(hours: 2, minutes: 5),
          null,
        ],
      );
    addTearDown(c.dispose);
    await show(tester, 'planner_routes', planner(RoutePanel(controller: c)));
    expect(find.text('Поехали'), findsOneWidget);
    await show(
      tester,
      'planner_routes_dark',
      planner(RoutePanel(controller: c)),
      brightness: Brightness.dark,
    );
  });

  Widget banner(RouteController c) => Padding(
    padding: const EdgeInsets.only(right: 56),
    child: GuidanceBanner(controller: c),
  );

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
    await show(
      tester,
      'guidance_manual',
      banner(c),
      alignment: Alignment.topCenter,
    );
    expect(find.byTooltip('Следующий манёвр'), findsOneWidget);
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
    await show(
      tester,
      'guidance_driving',
      banner(c),
      alignment: Alignment.topCenter,
    );
    expect(find.textContaining('Через '), findsOneWidget);
    expect(find.textContaining('60 км/ч'), findsOneWidget);
    // No manual stepping while a position drives the banner.
    expect(find.byTooltip('Следующий манёвр'), findsNothing);
  });
}
