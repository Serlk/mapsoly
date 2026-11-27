import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/obd/obd_service.dart';
import 'package:mapsoly/obd/obd_widgets.dart';
import 'package:mapsoly/settings.dart';
import 'package:mapsoly/settings_screen.dart';
import 'package:mapsoly/traffic/traffic.dart';
import 'package:mapsoly/user/file_exchange.dart';
import 'package:mapsoly/user/privacy_zones.dart';
import 'package:mapsoly/user/user_data.dart';
import 'package:mapsoly/user/user_places.dart';

import 'package:mapsoly/map/ui_kit.dart';

import '../obd/fake_elm.dart';
import '../ui_shots.dart';

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

  testWidgets('settings: a short first screen, the rest one level down', (
    tester,
  ) async {
    final settings = (await tester.runAsync(AppSettings.load))!;
    final traffic = TrafficController();
    addTearDown(traffic.dispose);
    final user = UserData.inMemory();
    user.places
      ..save(
        SavedPlace(
          name: 'Дом',
          kind: SavedPlaceKind.home,
          point: const LatLng(59.9390, 30.3158),
        ),
      )
      ..save(SavedPlace(name: 'Дача', point: const LatLng(60.02, 30.6)));
    user.zones.add(
      PrivacyZone(
        name: 'Дом',
        center: const LatLng(59.9390, 30.3158),
        radiusM: 300,
      ),
    );
    final home = Directory.systemTemp.createTempSync('mapsoly_settings');
    addTearDown(() => home.deleteSync(recursive: true));
    final obd = ObdService(logDirectory: Directory.systemTemp);
    addTearDown(obd.dispose);
    Widget screen() => Navigator(
      onGenerateRoute: (_) => MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          settings: settings,
          traffic: traffic,
          positioning: null,
          obd: obd,
          onOpenPacks: () {},
          user: user,
          services: FakeMapServices(),
          files: DesktopFileExchange(home: home),
          canTilt: true,
        ),
      ),
    );
    await shoot(tester, 'settings', screen(), tab: 3);
    // The blocks, in their order.
    const blocks = [
      'Оформление',
      'Пробки',
      'Карты',
      'Мои места',
      'Местоположение',
      'Безопасные зоны',
      'Автомобиль',
      'Данные',
    ];
    final list = find.byType(Scrollable).first;
    final rows =
        (tester.widget<ListView>(find.byType(ListView).first).childrenDelegate
                as SliverChildListDelegate)
            .children;
    expect(rows.whereType<SectionHeader>().map((h) => h.text), blocks);
    await tester.scrollUntilVisible(
      find.text('Файлы и собранные данные'),
      80,
      scrollable: list,
    );
    await snap(tester, 'settings_bottom');
    expect(find.text('Дом, 1 место'), findsOneWidget);
    expect(find.text('1 зона'), findsOneWidget);
    // Every tappable row is finger-sized.
    for (final element in find.byType(ListTile).evaluate()) {
      expect(element.size!.height, greaterThanOrEqualTo(64));
    }
    // The existing controls still work.
    await tester.drag(list, const Offset(0, 2000));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Тёмная'));
    expect(settings.themeMode, ThemeMode.dark);
    settings.themeMode = ThemeMode.system;
    await tester.tap(find.text('Яндекс'));
    expect(traffic.source, TrafficSource.yandex);
    traffic.select(TrafficSource.off);
    expect(
      tester.getSize(find.byType(SegmentedButton<ThemeMode>)).height,
      greaterThanOrEqualTo(56),
    );
    final was = settings.drive3d;
    await tester.scrollUntilVisible(
      find.text('Объёмная карта в движении'),
      80,
      scrollable: list,
    );
    await tester.tap(find.text('Объёмная карта в движении'));
    expect(settings.drive3d, !was);
    settings.drive3d = was;

    // Each bigger block opens its own screen; back returns.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).last);
    for (final (row, title) in [
      ('Дом, работа, места', 'Мои места'),
      ('Как определяется', 'Местоположение'),
      ('Где ничего не записывать', 'Безопасные зоны'),
      ('Связь с автомобилем', 'Автомобиль'),
      ('Файлы и собранные данные', 'Данные'),
    ]) {
      await tester.scrollUntilVisible(find.text(row), 80, scrollable: list);
      await tester.tap(find.text(row));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Назад'), findsOneWidget, reason: title);
      expect(find.text(title), findsWidgets);
      expect(tester.takeException(), isNull, reason: title);
      await snap(tester, 'settings_sub_${blocks.indexOf(title)}');
      await navigator.maybePop();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Назад'), findsNothing);
    }
    await shoot(
      tester,
      'settings_dark',
      screen(),
      tab: 3,
      brightness: Brightness.dark,
    );
    await shoot(
      tester,
      'settings_tall',
      screen(),
      tab: 3,
      size: const Size(380, 800),
    );
  });

  testWidgets('car section, map chip and vehicle sheet with a live adapter', (
    tester,
  ) async {
    final settings = (await tester.runAsync(AppSettings.load))!;
    final fake =
        FakeElm(
            speedKmh: 72,
            pids: {0x01, 0x05, 0x0C, 0x2F, 0x51, 0x5E},
            troubleCodes: const ['0133'],
          )
          ..fuelRateLph = 4.6
          ..coolantC = 92;
    final service = ObdService(
      logDirectory: Directory.systemTemp,
      connector: (_) =>
          () async => fake,
    );
    addTearDown(service.dispose);
    const config = ObdConfig(
      enabled: true,
      address: 'AA:BB:CC:00:00:01',
      fuel: true,
      vehicleInfo: true,
    );
    settings.obd = config;
    // Let the emulated adapter connect and report every value once.
    await tester.runAsync(() async {
      await service.apply(config);
      for (var i = 0; i < 200; i++) {
        final t = service.telemetry;
        if (service.connected &&
            t.fuelRateLph != null &&
            t.rpm != null &&
            t.coolantC != null &&
            t.fuelLevelPercent != null &&
            t.batteryVolts != null) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    expect(service.connected, isTrue);

    await show(
      tester,
      'settings_car',
      SingleChildScrollView(
        child: ObdSettingsSection(settings: settings, service: service),
      ),
      3,
    );
    expect(find.textContaining('Подключено'), findsOneWidget);

    await show(
      tester,
      'vehicle_chip',
      Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: VehicleChip(service: service),
        ),
      ),
      1,
    );
    // Check-engine codes turn the chip into a warning.
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.textContaining('л/100'), findsOneWidget);

    await show(tester, 'vehicle_sheet', VehicleSheet(service: service), 1);
    expect(find.text('WVWZZZ1JZXW000001'), findsOneWidget);
    expect(find.textContaining('P0133'), findsOneWidget);
    expect(find.text('72 км/ч'), findsOneWidget);
    // Stop the polling loop before the test ends.
    await tester.runAsync(() => service.apply(const ObdConfig()));
  });

  testWidgets('no adapter: the chip takes no space', (tester) async {
    final service = ObdService(logDirectory: Directory.systemTemp);
    await show(
      tester,
      'vehicle_chip_absent',
      Align(
        alignment: Alignment.topLeft,
        child: VehicleChip(service: service),
      ),
      1,
    );
    expect(tester.getSize(find.byType(VehicleChip)), Size.zero);
  });
}
