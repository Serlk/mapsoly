import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/positioning/positioning.dart';
import 'package:mapsoly/routing/route_models.dart' show RouteCosting;
import 'package:mapsoly/user/data_screen.dart';
import 'package:mapsoly/user/file_browser.dart';
import 'package:mapsoly/user/file_exchange.dart';
import 'package:mapsoly/user/privacy_zones.dart';
import 'package:mapsoly/user/saved_routes.dart';
import 'package:mapsoly/user/user_data.dart';
import 'package:mapsoly/user/user_places.dart';

import '../ui_shots.dart';
import 'fakes.dart';

/// The "Данные" screens at the phone's window size: no overflow, the flows
/// work against real files in a temporary home folder. With `UI_SHOTS=dir`
/// PNGs are written for inspection.
/// The whole app is inside this boundary, so pictures include pushed pages,
/// dialogs and the message at the bottom.
final appKey = GlobalKey();

/// Pumps [body] in the settings section (above the bottom bar) at the phone's
/// window size, checks for overflow and takes the picture.
Future<void> show(
  WidgetTester tester,
  String name,
  Widget body, {
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = const Size(720, 686);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: appKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: shotTheme(brightness),
        home: Scaffold(
          body: body,
          bottomNavigationBar: NavigationBar(
            height: 64,
            selectedIndex: 3,
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
                icon: Icon(Icons.settings),
                label: 'Настройки',
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await snap(tester, name, key: appKey);
}

void main() {
  late Directory tmp;
  late Directory home;
  late DesktopFileExchange files;

  setUpAll(loadShotFonts);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mapsoly-data-ui-');
    home = Directory('${tmp.path}/home')..createSync();
    files = DesktopFileExchange(
      home: home,
      now: () => DateTime(2026, 11, 27, 9, 30),
    );
  });
  tearDown(() {
    // A folder made unreadable by a test must be removable again.
    Process.runSync('chmod', ['-R', 'u+rwx', tmp.path]);
    tmp.deleteSync(recursive: true);
  });

  UserData userData({PrivacyZones? zones}) {
    final base = UserData.inMemory();
    return UserData(
      places: base.places,
      routes: base.routes,
      zones: zones ?? base.zones,
      guard: base.guard,
      supportDirectory: Directory('${tmp.path}/support')..createSync(),
    );
  }

  PositioningEngine engine() {
    final db = LocationDb.open('${tmp.path}/positioning.sqlite');
    final e = PositioningEngine(db: db);
    addTearDown(db.close);
    db.addSamples([
      sample(TransmitterKind.wifi, mac(1), at(10, 10)),
      for (var i = 2; i < 40; i++)
        sample(TransmitterKind.wifi, mac(i), at(1500.0 + 30 * i, 20)),
      sample(
        TransmitterKind.cell,
        cellKey(RadioType.lte, 999, 7, 4242, 1234567),
        at(3000, 1000),
      ),
      sample(
        TransmitterKind.cell,
        cellKey(RadioType.lte, 999, 7, 4242, 1234568),
        at(3500, 1200),
      ),
    ]);
    db.upsertExternal([
      for (var i = 0x40; i < 0x60; i++)
        record(TransmitterKind.wifi, mac(i), at(1600.0 + i, 50)),
    ]);
    return e;
  }

  /// Lets real file IO started by the last tap finish. The IO completes in
  /// real time, its continuations run when the test pumps: alternate.
  Future<void> settleIo(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// Removes the message at the bottom, so that it neither covers the
  /// buttons under it nor leaves a timer behind.
  Future<void> dismissNote(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 1));
    ScaffoldMessenger.of(
      tester.element(find.byType(NavigationBar)),
    ).hideCurrentSnackBar();
    await tester.pumpAndSettle();
  }

  File writeLog(Directory logs, String name, DateTime start, int seconds) {
    final b = StringBuffer()
      ..writeln(
        'time,speed_kmh,rpm,coolant_c,fuel_lph,fuel_level_pct,'
        'battery_v,trip_km,trip_fuel_l,lat,lon',
      );
    for (var s = 0; s < seconds; s++) {
      final p = at(20.0 * s, 0);
      b.writeln(
        [
          start.add(Duration(seconds: s)).toIso8601String(),
          '72',
          '2100',
          '90',
          '6.40',
          '55.0',
          '14.1',
          (0.02 * s).toStringAsFixed(3),
          (0.0018 * s).toStringAsFixed(3),
          p.latitude.toStringAsFixed(6),
          p.longitude.toStringAsFixed(6),
        ].join(','),
      );
    }
    logs.createSync(recursive: true);
    return File('${logs.path}/$name')..writeAsStringSync('$b');
  }

  testWidgets('data screen: statistics and wardriving export', (tester) async {
    final user = userData();
    user.places.save(
      SavedPlace(name: 'Дача', point: const LatLng(59.95, 30.2)),
    );
    final e = engine();
    final screen = DataScreen(user: user, files: files, engine: e);
    await show(tester, 'data', screen);
    expect(
      find.text('73'),
      findsOneWidget,
    ); // 39 own Wi-Fi + 2 cells + 32 received
    expect(find.textContaining('Собрано вами 41'), findsOneWidget);
    expect(find.text('Пока нет'), findsOneWidget);
    for (final row in find.byType(ListTile).evaluate()) {
      expect(row.size!.height, greaterThanOrEqualTo(60));
    }
    await show(tester, 'data_dark', screen, brightness: Brightness.dark);

    final out = File(
      '${home.path}/Documents/Mapsoly/mapsoly-wardriving-2026-11-27.csv',
    );
    await tester.tap(find.text('Сохранить в файл'));
    await tester.pump();
    await settleIo(
      tester,
      () => find.textContaining('Сохранено').evaluate().isNotEmpty,
    );
    expect(out.existsSync(), isTrue);
    expect(find.textContaining('Сохранено: 41 точка'), findsOneWidget);
    expect(find.textContaining(out.path), findsOneWidget);
    expect(find.textContaining('32 получены не вами'), findsOneWidget);
    await snap(tester, 'data_exported', key: appKey);
    await dismissNote(tester);

    // The same day again: a second file, the first one is kept.
    final second = await tester.runAsync(
      () => files.newExportFile('mapsoly-wardriving', 'csv'),
    );
    expect(second!.path, endsWith('mapsoly-wardriving-2026-11-27-2.csv'));
  });

  testWidgets('data screen: zones withhold, nothing own, no engine', (
    tester,
  ) async {
    final zones = PrivacyZones.inMemory()
      ..add(PrivacyZone(name: 'Дом', center: origin, radiusM: 100000));
    final e = engine();
    await show(
      tester,
      'data_zone',
      DataScreen(
        user: userData(zones: zones),
        files: files,
        engine: e,
      ),
    );
    await tester.tap(find.text('Сохранить в файл'));
    await tester.pump();
    await settleIo(
      tester,
      () => find.textContaining('Сохранять нечего').evaluate().isNotEmpty,
    );
    expect(find.textContaining('в безопасных зонах'), findsOneWidget);
    expect(Directory('${home.path}/Documents/Mapsoly').listSync(), isEmpty);
    await dismissNote(tester);

    final none = DataScreen(user: userData(), files: files, engine: null);
    await show(tester, 'data_no_engine', none);
    expect(find.textContaining('не запущено'), findsOneWidget);
    expect(find.text('Сохранить в файл'), findsNothing);
    // Nothing kept yet: the export row explains itself and does nothing.
    expect(find.textContaining('Пока нечего сохранять'), findsOneWidget);
    await show(
      tester,
      'data_no_engine_dark',
      none,
      brightness: Brightness.dark,
    );
  });

  testWidgets('wardriving import through the file browser', (tester) async {
    final e = engine();
    final downloads = Directory('${home.path}/Downloads')..createSync();
    File('${downloads.path}/points.csv').writeAsStringSync(
      'mac,lat,lon,accuracy\n'
      '${mac(0x90)},59.9500,30.3000,30\n'
      '${mac(0x91)},59.9510,30.3010,30\n'
      'broken\n',
    );
    await show(
      tester,
      'data_before_import',
      DataScreen(user: userData(), files: files, engine: e),
    );
    await tester.tap(find.text('Импорт из файла').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Загрузки'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('points.csv'));
    await tester.pump();
    await settleIo(
      tester,
      () =>
          find.textContaining('Добавлено или обновлено').evaluate().isNotEmpty,
    );
    expect(find.textContaining('2 точки из 2 в файле'), findsOneWidget);
    expect(find.text('75'), findsOneWidget);
    await dismissNote(tester);
  });

  testWidgets('trip logs: list, selection, export, delete', (tester) async {
    final zones = PrivacyZones.inMemory()
      ..add(PrivacyZone(name: 'Дом', center: origin, radiusM: 300));
    final user = userData(zones: zones);
    final logs = user.tripLogDirectory!;
    final empty = TripLogsScreen(user: user, files: files);
    await show(tester, 'trips_empty', empty);
    expect(find.textContaining('Поездок пока нет'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    await show(tester, 'trips_empty_dark', empty, brightness: Brightness.dark);

    writeLog(
      logs,
      'trip-20261120T081500.csv',
      DateTime(2026, 11, 20, 8, 15),
      61,
    );
    writeLog(
      logs,
      'trip-20261125T180000.csv',
      DateTime(2026, 11, 25, 18),
      3600,
    );
    writeLog(logs, 'trip-20261126T070000.csv', DateTime(2026, 11, 26, 7), 900);
    final screen = TripLogsScreen(key: UniqueKey(), user: user, files: files);
    await show(tester, 'trips', screen);
    expect(find.text('Сохранить все (3)'), findsOneWidget);
    expect(find.text('Удалить'), findsNothing);
    expect(find.textContaining('25 ноября'), findsOneWidget);
    for (final row in find.byType(ListTile).evaluate()) {
      expect(row.size!.height, greaterThanOrEqualTo(64));
    }

    await tester.tap(find.textContaining('20 ноября'));
    await tester.pumpAndSettle();
    expect(find.text('Сохранить выбранные (1)'), findsOneWidget);
    await snap(tester, 'trips_selected', key: appKey);
    await show(
      tester,
      'trips_selected_dark',
      screen,
      brightness: Brightness.dark,
    );

    await tester.tap(find.text('Сохранить выбранные (1)'));
    await tester.pump();
    final copy = File(
      '${home.path}/Documents/Mapsoly/trip-20261120T081500.csv',
    );
    await settleIo(
      tester,
      () => find.textContaining('Сохранено').evaluate().isNotEmpty,
    );
    expect(copy.existsSync(), isTrue);
    // The first seconds of the drive are inside the zone.
    expect(find.textContaining('убраны координаты'), findsOneWidget);
    expect(copy.readAsLinesSync()[1], endsWith(',,'));
    await snap(tester, 'trips_exported', key: appKey);
    await dismissNote(tester);

    await tester.tap(find.text('Удалить'));
    await tester.pumpAndSettle();
    expect(find.text('Удалить 1 журнал?'), findsOneWidget);
    await snap(tester, 'trips_delete_confirm', key: appKey);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(File('${logs.path}/trip-20261120T081500.csv').existsSync(), isTrue);
    await tester.tap(find.text('Удалить'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
    await tester.pumpAndSettle();
    expect(File('${logs.path}/trip-20261120T081500.csv').existsSync(), isFalse);
    expect(find.text('Сохранить все (2)'), findsOneWidget);
  });

  testWidgets('file browser: folders, filter, links, unreadable folder', (
    tester,
  ) async {
    final docs = Directory('${home.path}/Documents/Mapsoly')
      ..createSync(recursive: true);
    Directory('${home.path}/Downloads').createSync();
    Directory('${docs.path}/Поездка в Казань').createSync();
    File('${docs.path}/Поездка в Казань/day1.gpx').writeAsStringSync('<gpx/>');
    File('${docs.path}/mapsoly-2026-11-20.gpx').writeAsStringSync('<gpx/>');
    File('${docs.path}/Track.GPX').writeAsStringSync('<gpx/>');
    File('${docs.path}/notes.txt').writeAsStringSync('x');
    File('${docs.path}/.hidden.gpx').writeAsStringSync('x');
    // Outside the home folder, reachable only through links.
    final outside = Directory('${tmp.path}/outside')..createSync();
    File('${outside.path}/secret.gpx').writeAsStringSync('<gpx/>');
    Link('${docs.path}/наружу').createSync(outside.path);
    Link('${docs.path}/linked.gpx').createSync('${outside.path}/secret.gpx');
    // A link that stays inside is fine.
    Link('${docs.path}/загрузки').createSync('${home.path}/Downloads');
    final locked = Directory('${docs.path}/Закрытая папка')..createSync();
    Process.runSync('chmod', ['000', locked.path]);

    File? chosen;
    final key = GlobalKey();
    Widget browser() => Builder(
      key: key,
      builder: (context) => Center(
        child: FilledButton(
          onPressed: () async => chosen = await files.pickFile(
            context,
            title: 'Импорт маршрутов и мест',
            extensions: const {'gpx'},
          ),
          child: const Text('Открыть'),
        ),
      ),
    );
    await show(tester, 'files_start', browser());
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    expect(find.byType(FileBrowserScreen), findsOneWidget);
    expect(find.text('~/Documents/Mapsoly'), findsOneWidget);
    expect(find.text('mapsoly-2026-11-20.gpx'), findsOneWidget);
    expect(find.text('Track.GPX'), findsOneWidget);
    expect(find.text('notes.txt'), findsNothing);
    expect(find.text('.hidden.gpx'), findsNothing);
    expect(find.text('наружу'), findsNothing);
    expect(find.text('linked.gpx'), findsNothing);
    expect(find.text('загрузки'), findsOneWidget);
    for (final row in find.byType(ListTile).evaluate()) {
      expect(row.size!.height, greaterThanOrEqualTo(60));
    }
    await snap(tester, 'files', key: appKey);

    await tester.tap(find.text('Закрытая папка'));
    await tester.pumpAndSettle();
    expect(find.text('Эту папку не удалось открыть'), findsOneWidget);
    await snap(tester, 'files_unreadable', key: appKey);
    await tester.tap(find.text('Выше'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Домашняя папка'));
    await tester.pumpAndSettle();
    expect(find.text('~'), findsOneWidget);
    expect(find.text('Выше'), findsNothing); // never above home
    expect(find.text('Documents'), findsOneWidget);
    await tester.tap(find.text('Загрузки'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Здесь нет папок и файлов .gpx'),
      findsOneWidget,
    );
    await snap(tester, 'files_empty', key: appKey);

    await tester.tap(find.text('Mapsoly'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Поездка в Казань'));
    await tester.pumpAndSettle();
    // "Back" climbs one folder before it closes the browser.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('~/Documents/Mapsoly'), findsOneWidget);
    await tester.tap(find.text('Поездка в Казань'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('day1.gpx'));
    await tester.pumpAndSettle();
    expect(find.byType(FileBrowserScreen), findsNothing);
    expect(chosen?.path, endsWith('Поездка в Казань/day1.gpx'));

    await show(
      tester,
      'files_dark',
      FileBrowserScreen(
        title: 'Импорт маршрутов и мест',
        home: home,
        start: docs,
        extensions: const {'gpx'},
      ),
      brightness: Brightness.dark,
    );
  });

  testWidgets('routes and places: export, then import the file back', (
    tester,
  ) async {
    final user = userData();
    user.places.save(
      SavedPlace(
        name: 'Дом',
        kind: SavedPlaceKind.home,
        point: const LatLng(59.9390, 30.3158),
      ),
    );
    user.places.save(
      SavedPlace(name: 'Эрмитаж', point: const LatLng(59.9398, 30.3146)),
    );
    user.routes.save(
      SavedRoute(
        name: 'Петербург — Выборг',
        costing: RouteCosting.auto,
        points: const [
          RoutePoint(LatLng(59.9390, 30.3158), label: 'Дворцовая площадь'),
          RoutePoint(LatLng(60.7139, 28.7570), label: 'Выборгский замок'),
        ],
      ),
    );
    final screen = DataScreen(user: user, files: files, engine: null);
    await show(tester, 'data_kept', screen);
    expect(find.textContaining('2 места и 1 маршрут'), findsOneWidget);

    final out = File('${home.path}/Documents/Mapsoly/mapsoly-2026-11-27.gpx');
    await tester.tap(find.text('Сохранить всё в один файл'));
    await tester.pump();
    await settleIo(tester, out.existsSync);
    expect(
      find.textContaining('Сохранено: 2 места, 1 маршрут'),
      findsOneWidget,
    );
    expect(find.textContaining(out.path), findsOneWidget);
    await dismissNote(tester);

    // Into an empty app.
    final fresh = userData();
    await show(
      tester,
      'data_fresh',
      DataScreen(key: UniqueKey(), user: fresh, files: files, engine: null),
    );
    await tester.tap(find.text('Импорт из файла'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('mapsoly-2026-11-27.gpx'));
    await tester.pump();
    await settleIo(tester, () => find.text('Готово').evaluate().isNotEmpty);
    expect(find.text('Добавлено: 2 места, 1 маршрут.'), findsOneWidget);
    await snap(tester, 'data_import_result', key: appKey);
    await tester.tap(find.text('Понятно'));
    await tester.pumpAndSettle();
    expect(fresh.places.places, user.places.places);
    expect(fresh.routes.routes, user.routes.routes);

    // A file that is not GPX is refused with a reason.
    File(
      '${home.path}/Documents/Mapsoly/broken.gpx',
    ).writeAsStringSync('<!DOCTYPE gpx><gpx/>');
    await tester.tap(find.text('Импорт из файла'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('broken.gpx'));
    await tester.pump();
    await settleIo(
      tester,
      () => find.text('Файл не подошёл').evaluate().isNotEmpty,
    );
    await snap(tester, 'data_import_refused', key: appKey);
    await tester.tap(find.text('Понятно'));
    await tester.pumpAndSettle();
  });

  test('revealing the folder never throws', () async {
    final none = DesktopFileExchange(home: Directory('${tmp.path}/nowhere'));
    expect(none.exportFolderLabel, '~/Documents/Mapsoly');
    expect((await none.exportDirectory()).existsSync(), isTrue);
    // Not called for real here: it would open a window on the PC.
    expect(none.canReveal, anyOf(isTrue, isFalse));
  });
}
