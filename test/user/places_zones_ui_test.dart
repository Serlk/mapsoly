import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/map/point_picker.dart';
import 'package:mapsoly/positioning/positioning.dart';
import 'package:mapsoly/user/places_screen.dart';
import 'package:mapsoly/user/privacy_zones.dart';
import 'package:mapsoly/user/user_data.dart';
import 'package:mapsoly/user/user_places.dart';
import 'package:mapsoly/user/zones_screen.dart';

import '../ui_shots.dart';
import 'fakes.dart';

/// "Мои места" and "Безопасные зоны" at the phone's window size: layout,
/// the flows through them, and pictures for review (`UI_SHOTS=dir`).
///
/// All data is made up; the coordinates are public landmarks.
void main() {
  setUpAll(loadShotFonts);

  // Public landmarks.
  const redSquare = LatLng(55.7539, 37.6208);
  const vdnh = LatLng(55.8263, 37.6377);
  const luzhniki = LatLng(55.7158, 37.5537);
  const gorkyPark = LatLng(55.7298, 37.6019);
  const sparrowHills = LatLng(55.7103, 37.5420);

  /// A section's own navigator, as on the main screen.
  Widget host(Widget page) => Navigator(
    key: UniqueKey(),
    onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => page),
  );

  /// Like [snap], but of the whole window: dialogs lie above the boundary
  /// [snap] photographs.
  Future<void> snapAll(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull, reason: '$name overflows');
    final shots = shotsDirectory;
    if (shots == null) return;
    await tester.runAsync(() async {
      final view = tester.binding.renderViews.first;
      final layer = view.debugLayer! as OffsetLayer;
      final image = await layer.toImage(
        Offset.zero & view.size,
        pixelRatio: 1.5,
      );
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$shots/$name.png')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  NavigatorState nested(WidgetTester tester) =>
      tester.state<NavigatorState>(find.byType(Navigator).last);

  UserData typicalPlaces() {
    final user = UserData.inMemory();
    user.places
      ..save(
        SavedPlace(
          name: 'Дом',
          kind: SavedPlaceKind.home,
          point: redSquare,
          address: 'Красная площадь, 1',
        ),
      )
      ..save(SavedPlace(name: 'Работа', kind: SavedPlaceKind.work, point: vdnh))
      ..save(SavedPlace(name: 'Дача', point: sparrowHills))
      ..save(
        SavedPlace(
          name: 'Заправка у стадиона, где всегда свободная мойка',
          point: luzhniki,
          address:
              'улица Лужники, 24, район Хамовники, Центральный '
              'административный округ, Москва',
        ),
      )
      ..save(
        SavedPlace(name: 'Парк', point: gorkyPark, address: 'Крымский Вал, 9'),
      );
    return user;
  }

  group('saved places', () {
    testWidgets('empty: home and work ask to be set', (tester) async {
      final user = UserData.inMemory();
      final services = FakeMapServices();
      final page = PlacesScreen(user: user, services: services);
      await shoot(tester, 'places_empty', host(page), tab: 3);
      expect(find.text('Нажмите, чтобы указать место'), findsNWidgets(2));
      expect(find.text('Добавить место'), findsOneWidget);
      await shoot(
        tester,
        'places_empty_dark',
        host(page),
        tab: 3,
        brightness: Brightness.dark,
      );
    });

    testWidgets('typical list, long names, tall rows', (tester) async {
      final user = typicalPlaces();
      SavedPlace? went;
      final page = PlacesScreen(
        user: user,
        services: FakeMapServices(),
        onGo: (p) => went = p,
      );
      await shoot(tester, 'places_typical', host(page), tab: 3);
      for (final name in ['Дом', 'Работа', 'Дача', 'Парк']) {
        expect(find.text(name), findsOneWidget);
      }
      // Rows and their buttons are finger-sized.
      for (final e in find.byType(InkWell).evaluate()) {
        expect(e.size!.height, greaterThanOrEqualTo(48));
      }
      expect(
        tester.getSize(find.byTooltip('Удалить «Дача»')).height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.text('Дача'));
      expect(went?.name, 'Дача');
      await shoot(
        tester,
        'places_typical_dark',
        host(page),
        tab: 3,
        brightness: Brightness.dark,
      );
    });

    testWidgets('delete is immediate and can be undone', (tester) async {
      final user = typicalPlaces();
      await shoot(
        tester,
        'places_typical',
        host(PlacesScreen(user: user, services: FakeMapServices())),
        tab: 3,
      );
      final park = user.places.favorites.firstWhere((p) => p.name == 'Парк');
      await tester.tap(find.byTooltip('Удалить «Парк»'));
      await tester.pumpAndSettle();
      expect(user.places.byId(park.id), isNull);
      expect(find.text('«Парк» удалено'), findsOneWidget);
      await snap(tester, 'places_deleted_undo');
      await tester.tap(find.text('Вернуть'));
      await tester.pumpAndSettle();
      expect(user.places.byId(park.id), park);
    });

    testWidgets('home is set straight from the chooser', (tester) async {
      final user = UserData.inMemory();
      final services = FakeMapServices(mapAnswer: const PickedPlace(redSquare));
      await shoot(
        tester,
        'places_empty',
        host(PlacesScreen(user: user, services: services)),
        tab: 3,
      );
      await tester.tap(find.text('Дом'));
      await tester.pumpAndSettle();
      await snap(tester, 'places_choose_home');
      await tester.tap(find.text('На карте'));
      await tester.pumpAndSettle();
      expect(services.mapPicks, 1);
      expect(user.places.home?.point, redSquare);
      expect(find.text('Мои места'), findsOneWidget);
    });

    testWidgets('add a favourite: chooser, then name and kind', (tester) async {
      final user = typicalPlaces();
      final services = FakeMapServices(
        searchAnswer: const PickedPlace(gorkyPark, label: 'Кафе у пруда'),
      );
      await shoot(
        tester,
        'places_typical',
        host(PlacesScreen(user: user, services: services)),
        tab: 3,
      );
      await tester.tap(find.text('Добавить место'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Найти'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Результат поиска'));
      await tester.pumpAndSettle();
      expect(find.text('Сохранить место'), findsOneWidget);
      await snapAll(tester, 'places_save_dialog');
      // Choosing "home" warns that the present home is replaced.
      await tester.tap(
        find.descendant(
          of: find.byType(SegmentedButton<SavedPlaceKind>),
          matching: find.text('Дом'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Заменит прежний «Дом»'), findsOneWidget);
      await snapAll(tester, 'places_save_dialog_replaces');
      await tester.tap(
        find.descendant(
          of: find.byType(SegmentedButton<SavedPlaceKind>),
          matching: find.text('Место'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Заменит прежний «Дом»'), findsNothing);
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(
        user.places.favorites.where((p) => p.name == 'Кафе у пруда'),
        hasLength(1),
      );
      expect(user.places.home?.point, redSquare);
    });

    testWidgets('edit dialog keeps the id; dark dialog', (tester) async {
      final user = typicalPlaces();
      final dacha = user.places.favorites.firstWhere((p) => p.name == 'Дача');
      await shoot(
        tester,
        'places_typical_dark',
        host(PlacesScreen(user: user, services: FakeMapServices())),
        tab: 3,
        brightness: Brightness.dark,
      );
      await tester.tap(find.byTooltip('Изменить «Дача»'));
      await tester.pumpAndSettle();
      expect(find.text('Изменить место'), findsOneWidget);
      await snapAll(tester, 'places_edit_dialog_dark');
      await tester.enterText(find.byType(TextField), 'Дача у реки');
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(user.places.byId(dacha.id)?.name, 'Дача у реки');
      expect(user.places.byId(dacha.id)?.point, dacha.point);
    });

    testWidgets('a cancelled dialog saves nothing', (tester) async {
      final places = UserPlaces.inMemory();
      SavedPlace? result;
      await shoot(
        tester,
        'places_dialog_host',
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () async => result = await savePlaceDialog(
                context,
                places,
                point: vdnh,
                name: 'Павильон',
                address: 'проспект Мира, 119',
              ),
              child: const Text('open'),
            ),
          ),
        ),
        tab: 1,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('проспект Мира, 119'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(places.places, isEmpty);
    });
  });

  group('privacy zones', () {
    UserData withHome() {
      final user = UserData.inMemory();
      user.places.save(
        SavedPlace(
          name: 'Дом',
          kind: SavedPlaceKind.home,
          point: origin,
          address: 'Дворцовая площадь, 2',
        ),
      );
      return user;
    }

    testWidgets('empty: one sentence, one button', (tester) async {
      final page = ZonesScreen(
        user: UserData.inMemory(),
        services: FakeMapServices(),
        engine: null,
      );
      await shoot(tester, 'zones_empty', host(page), tab: 3);
      expect(find.text('Добавить зону'), findsOneWidget);
      expect(find.textContaining('не сохраняется'), findsOneWidget);
      expect(find.textContaining('Отметьте места'), findsOneWidget);
      await shoot(
        tester,
        'zones_empty_dark',
        host(page),
        tab: 3,
        brightness: Brightness.dark,
      );
    });

    testWidgets('typical list with the explanation', (tester) async {
      final user = UserData.inMemory();
      user.zones
        ..add(PrivacyZone(name: 'Дом', center: origin, radiusM: 300))
        ..add(PrivacyZone(name: 'Дача', center: at(40000, 0), radiusM: 1500))
        ..add(
          PrivacyZone(
            name: 'Гараж и мастерская на набережной',
            center: at(3000, 500),
            radiusM: 500,
          ),
        );
      final page = ZonesScreen(
        user: user,
        services: FakeMapServices(),
        engine: null,
      );
      await shoot(tester, 'zones_typical', host(page), tab: 3);
      expect(find.text('Радиус 300 м'), findsOneWidget);
      expect(find.text('Радиус 1,5 км'), findsOneWidget);
      expect(find.text('Добавить зону'), findsOneWidget);
      // 64 px less the desktop's compact density.
      for (final e in find.byType(ListTile).evaluate()) {
        expect(e.size!.height, greaterThanOrEqualTo(60));
      }
      await shoot(
        tester,
        'zones_typical_dark',
        host(page),
        tab: 3,
        brightness: Brightness.dark,
      );
    });

    testWidgets('damaged file: banner, list, confirm', (tester) async {
      final dir = Directory.systemTemp.createTempSync('mapsoly_zones_ui');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/privacy_zones.json').writeAsStringSync(
        '{"version":1,"zones":[{"id":"z1","name":"Дом","center":[$lat0,$lon0],'
        '"radiusM":300},{"id":"z2","name":"Сломанная","center":"нет"}]}',
      );
      final zones = PrivacyZones.load(dir);
      expect(zones.unconfirmed, isTrue);
      expect(zones.contains(at(90000, 0)), isTrue);
      final user = UserData(
        places: UserPlaces.inMemory(),
        routes: UserData.inMemory().routes,
        zones: zones,
        guard: UserData.inMemory().guard,
      );
      final page = ZonesScreen(
        user: user,
        services: FakeMapServices(),
        engine: null,
      );
      await shoot(tester, 'zones_unconfirmed', host(page), tab: 3);
      expect(find.textContaining(zones.loadError!), findsOneWidget);
      expect(find.text('Дом'), findsOneWidget);
      await shoot(
        tester,
        'zones_unconfirmed_dark',
        host(page),
        tab: 3,
        brightness: Brightness.dark,
      );
      await tester.tap(find.text('Подтвердить список'));
      await tester.pumpAndSettle();
      expect(zones.unconfirmed, isFalse);
      expect(zones.contains(at(90000, 0)), isFalse);
      expect(zones.contains(origin), isTrue);
      expect(find.text('Подтвердить список'), findsNothing);
    });

    testWidgets('add a zone around home: shifted centre, presets, fine '
        'adjust, back one level', (tester) async {
      final user = withHome();
      final services = FakeMapServices(myPosition: at(5000, 0));
      await shoot(
        tester,
        'zones_empty',
        host(ZonesScreen(user: user, services: services, engine: null)),
        tab: 3,
      );
      await tester.tap(find.text('Добавить зону'));
      await tester.pumpAndSettle();
      expect(find.text('Вокруг дома'), findsOneWidget);
      expect(find.text('Моё местоположение'), findsOneWidget);
      await snap(tester, 'zone_edit_center');

      await tester.tap(find.text('Вокруг дома'));
      await tester.pumpAndSettle();
      expect(find.text('Новая зона'), findsOneWidget);
      expect(find.text('300 м'), findsNWidgets(2)); // the figure and the preset
      await snap(tester, 'zone_edit_new');

      // Back from the form: the centre step again, not out of the editor.
      await nested(tester).maybePop();
      await tester.pumpAndSettle();
      expect(find.text('Что скрыть'), findsOneWidget);
      await tester.tap(find.text('Вокруг дома'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('1 км'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Увеличить радиус'));
      await tester.pumpAndSettle();
      expect(find.text('1,1 км'), findsOneWidget);
      await tester.tap(find.byTooltip('Уменьшить радиус'));
      await tester.tap(find.byTooltip('Уменьшить радиус'));
      await tester.pumpAndSettle();
      expect(find.text('950 м'), findsOneWidget);
      await snap(tester, 'zone_edit_new_adjusted');
      await tester.tap(find.text('500 м'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Сохранить зону'));
      await tester.pumpAndSettle();
      final zone = user.zones.zones.single;
      expect(zone.name, 'Дом');
      expect(zone.radiusM, 500);
      // The home is inside, and not in the middle.
      expect(zone.touches(origin), isTrue);
      expect(zone.center, isNot(origin));
      expect(find.text('Безопасные зоны'), findsOneWidget);
      expect(find.text('Радиус 500 м'), findsOneWidget);
    });

    testWidgets('new zone: dark form, centre from the map, rename', (
      tester,
    ) async {
      final user = UserData.inMemory();
      final services = FakeMapServices(mapAnswer: PickedPlace(at(2000, 0)));
      await shoot(
        tester,
        'zones_empty_dark',
        host(ZonesScreen(user: user, services: services, engine: null)),
        tab: 3,
        brightness: Brightness.dark,
      );
      await tester.tap(find.text('Добавить зону'));
      await tester.pumpAndSettle();
      expect(find.text('Вокруг дома'), findsNothing);
      expect(find.text('Моё местоположение'), findsNothing);
      await snap(tester, 'zone_edit_center_dark');
      await tester.tap(find.text('На карте'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Название'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Гараж');
      await tester.tap(find.text('Готово'));
      await tester.pumpAndSettle();
      expect(find.text('Гараж'), findsOneWidget);
      await snap(tester, 'zone_edit_new_dark');
      await tester.tap(find.text('Сохранить зону'));
      await tester.pumpAndSettle();
      expect(user.zones.zones.single.name, 'Гараж');
      expect(user.zones.zones.single.touches(at(2000, 0)), isTrue);
    });

    testWidgets('what was recorded in the zone: counted first, deleted only '
        'on consent', (tester) async {
      final db = LocationDb.inMemory();
      final engine = PositioningEngine(db: db);
      addTearDown(engine.dispose);
      db.addSamples([
        sample(TransmitterKind.wifi, mac(1), at(20, 0)),
        sample(TransmitterKind.wifi, mac(2), at(-30, 40)),
        sample(TransmitterKind.wifi, mac(3), at(9000, 0)), // far away
      ], keepRawSamples: true);
      final before = db.stats();
      final user = withHome();
      await shoot(
        tester,
        'zones_empty',
        host(
          ZonesScreen(user: user, services: FakeMapServices(), engine: engine),
        ),
        tab: 3,
      );

      Future<void> addHomeZone() async {
        await tester.tap(find.text('Добавить зону'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Вокруг дома'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Сохранить зону'));
        await tester.pumpAndSettle();
      }

      await addHomeZone();
      // Two transmitters and their two raw samples lie in the zone.
      expect(find.textContaining('уже записано 4 точки'), findsOneWidget);
      await snapAll(tester, 'zones_purge_offer');
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(db.stats().total, before.total);
      expect(db.stats().rawSamples, before.rawSamples);

      // Asked again after the next zone; this time the user agrees.
      await addHomeZone();
      expect(find.textContaining('уже записано 4 точки'), findsOneWidget);
      await tester.tap(find.text('Удалить'));
      await tester.pumpAndSettle();
      expect(find.text('Удалено: 4 точки'), findsOneWidget);
      expect(db.get(TransmitterKind.wifi, mac(1)), isNull);
      expect(db.get(TransmitterKind.wifi, mac(2)), isNull);
      expect(db.get(TransmitterKind.wifi, mac(3)), isNotNull);
      expect(db.stats().rawSamples, 1);
    });

    testWidgets('nothing recorded in the zone: nothing is asked', (
      tester,
    ) async {
      final db = LocationDb.inMemory();
      final engine = PositioningEngine(db: db);
      addTearDown(engine.dispose);
      db.addSamples([sample(TransmitterKind.wifi, mac(3), at(9000, 0))]);
      final user = withHome();
      await shoot(
        tester,
        'zones_empty',
        host(
          ZonesScreen(user: user, services: FakeMapServices(), engine: engine),
        ),
        tab: 3,
      );
      await tester.tap(find.text('Добавить зону'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Вокруг дома'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить зону'));
      await tester.pumpAndSettle();
      expect(user.zones.zones, hasLength(1));
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('edit: radius and name change, the centre stays; delete '
        'asks first', (tester) async {
      final user = UserData.inMemory();
      final zone = user.zones.add(
        PrivacyZone(name: 'Дом', center: origin, radiusM: 300),
      );
      final page = ZonesScreen(
        user: user,
        services: FakeMapServices(),
        engine: null,
      );
      await shoot(tester, 'zones_one', host(page), tab: 3);
      await tester.tap(find.text('Дом'));
      await tester.pumpAndSettle();
      expect(find.text('Удалить зону'), findsOneWidget);
      await snap(tester, 'zone_edit_existing');
      await tester.tap(find.text('2 км'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(user.zones.byId(zone.id)!.radiusM, 2000);
      expect(user.zones.byId(zone.id)!.center, origin);

      // Back leaves the editor without saving.
      await tester.tap(find.text('Дом'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('300 м'));
      await tester.pumpAndSettle();
      await nested(tester).maybePop();
      await tester.pumpAndSettle();
      expect(find.text('Безопасные зоны'), findsOneWidget);
      expect(user.zones.byId(zone.id)!.radiusM, 2000);

      await tester.tap(find.text('Дом'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить зону'));
      await tester.pumpAndSettle();
      expect(find.text('Удалить зону «Дом»?'), findsOneWidget);
      await snapAll(tester, 'zone_edit_delete_confirm');
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(user.zones.zones, hasLength(1));
      await tester.tap(find.text('Удалить зону'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить'));
      await tester.pumpAndSettle();
      expect(user.zones.zones, isEmpty);
      expect(find.text('Безопасные зоны'), findsOneWidget);
    });

    testWidgets('existing zone, dark', (tester) async {
      final user = UserData.inMemory();
      user.zones.add(PrivacyZone(name: 'Дача', center: origin, radiusM: 1500));
      await shoot(
        tester,
        'zones_one_dark',
        host(
          ZonesScreen(user: user, services: FakeMapServices(), engine: null),
        ),
        tab: 3,
        brightness: Brightness.dark,
      );
      await tester.tap(find.text('Дача'));
      await tester.pumpAndSettle();
      expect(find.text('1,5 км'), findsOneWidget);
      await snap(tester, 'zone_edit_existing_dark');
    });
  });

  test('zone radius is written the way people say it', () {
    expect(formatZoneRadius(50), '50 м');
    expect(formatZoneRadius(950), '950 м');
    expect(formatZoneRadius(1000), '1 км');
    expect(formatZoneRadius(1500), '1,5 км');
    expect(formatZoneRadius(2000), '2 км');
    expect(formatZoneRadius(50000), '50 км');
  });
}
