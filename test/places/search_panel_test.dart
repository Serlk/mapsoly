import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/places/photon_geocoder.dart';
import 'package:mapsoly/places/places_database.dart';
import 'package:mapsoly/places/search_panel.dart';

import 'fixture.dart';

const _near = LatLng(54.71, 20.51);

List<FixturePlace> _places() => [
  FixturePlace(0, catCity, 'Приморск', 54.71, 20.51, 110),
  FixturePlace(
    1,
    catStreet,
    'улица Ленина',
    54.712,
    20.512,
    50,
    loc: 0,
    houses: {'5': (54.7121, 20.5121), '7': (54.7124, 20.5124)},
  ),
  FixturePlace(1, catStreet, 'Ленинский проспект', 54.705, 20.505, 60, loc: 0),
  FixturePlace(1, catStreet, 'Ленинградская улица', 54.72, 20.52, 50, loc: 0),
  for (var i = 0; i < 30; i++)
    FixturePlace(
      2,
      catCafe,
      'Кафе Ленинград $i',
      54.71 + i * 0.001,
      20.51,
      35,
      loc: 0,
    ),
];

void main() {
  late PlacesDatabase db;
  late String path;

  setUpAll(() {
    path = buildFixture(_places());
    db = PlacesDatabase.open(path);
  });
  tearDownAll(() {
    db.close();
    File(path).parent.deleteSync(recursive: true);
  });

  Future<void> pump(
    WidgetTester tester, {
    PlacesDatabase? database,
    PhotonGeocoder? online,
    required ValueChanged<PlaceResult> onSelected,
    VoidCallback? onClose,
    Brightness brightness = Brightness.light,
  }) async {
    // The Titan 2 screen: 1440×1440 px at 3.0 → 480×480 dp.
    tester.view.physicalSize = const Size(1440, 1440);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: brightness,
          ),
        ),
        home: Scaffold(
          body: SearchPanel(
            database: database,
            online: online,
            near: _near,
            onSelected: onSelected,
            onClose: onClose,
            onlineDelay: const Duration(milliseconds: 50),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('typing shows results; arrows and Enter select', (tester) async {
    PlaceResult? picked;
    await pump(tester, database: db, onSelected: (r) => picked = r);
    expect(find.text(SearchPanelTexts.typeToSearch), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'ленин');
    await tester.pump();
    expect(find.text('Ленинский проспект'), findsOneWidget);
    expect(find.text('улица Ленина'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final expected = db.search('ленин', near: _near, limit: 20);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(picked, isNotNull);
    expect(picked!.name, expected[1].name);
  });

  testWidgets('Enter without moving picks the top result', (tester) async {
    PlaceResult? picked;
    await pump(tester, database: db, onSelected: (r) => picked = r);
    await tester.enterText(find.byType(TextField), 'ленина 5');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(picked!.kind, PlaceKind.house);
    expect(picked!.name, 'улица Ленина, 5');
  });

  testWidgets('highlight stays visible in a long list and stops at the ends', (
    tester,
  ) async {
    PlaceResult? picked;
    await pump(tester, database: db, onSelected: (r) => picked = r);
    await tester.enterText(find.byType(TextField), 'кафе');
    await tester.pump();
    final expected = db.search('кафе', near: _near, limit: 20);
    expect(expected, hasLength(20));
    for (var i = 0; i < 25; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    }
    await tester.pump();
    // The last row is scrolled into view and highlighted.
    expect(find.text(expected.last.name), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(picked!.name, expected.last.name);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tap selects, Esc and the back button close', (tester) async {
    PlaceResult? picked;
    var closed = 0;
    await pump(
      tester,
      database: db,
      onSelected: (r) => picked = r,
      onClose: () => closed++,
    );
    await tester.enterText(find.byType(TextField), 'ленинский');
    await tester.pump();
    await tester.tap(find.text('Ленинский проспект'));
    expect(picked!.name, 'Ленинский проспект');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(closed, 1);
    await tester.tap(find.byTooltip(SearchPanelTexts.close));
    expect(closed, 2);
  });

  testWidgets('clear button empties the field', (tester) async {
    await pump(tester, database: db, onSelected: (_) {});
    await tester.enterText(find.byType(TextField), 'ленин');
    await tester.pump();
    await tester.tap(find.byTooltip(SearchPanelTexts.clear));
    await tester.pump();
    expect(find.text('Ленинский проспект'), findsNothing);
    expect(find.text(SearchPanelTexts.typeToSearch), findsOneWidget);
  });

  testWidgets('nothing found offline, no online geocoder', (tester) async {
    await pump(tester, database: db, onSelected: (_) {});
    await tester.enterText(find.byType(TextField), 'ыыыыы');
    await tester.pump();
    expect(find.text(SearchPanelTexts.nothingFound), findsOneWidget);
  });

  testWidgets('no pack: online fallback fills the list', (tester) async {
    PlaceResult? picked;
    final online = PhotonGeocoder(
      client: MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(
            '{"features":[{"properties":{"type":"street",'
            '"name":"улица Мира","city":"Гусев"},'
            '"geometry":{"coordinates":[22.2,54.59]}}]}',
          ),
          200,
        ),
      ),
    );
    await pump(tester, online: online, onSelected: (r) => picked = r);
    expect(find.text(SearchPanelTexts.noPack), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'мира');
    await tester.pump();
    expect(find.text(SearchPanelTexts.searchingOnline), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump();
    expect(find.text('улица Мира'), findsOneWidget);
    expect(find.text(SearchPanelTexts.onlineResults), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(picked!.online, isTrue);
  });

  testWidgets('online failure is reported softly', (tester) async {
    final online = PhotonGeocoder(
      client: MockClient((_) async => http.Response('down', 502)),
    );
    await pump(tester, online: online, onSelected: (_) {});
    await tester.enterText(find.byType(TextField), 'мира');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump();
    expect(find.textContaining(SearchPanelTexts.onlineFailed), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no pack and no online geocoder', (tester) async {
    await pump(tester, onSelected: (_) {});
    expect(find.text(SearchPanelTexts.noPackNoOnline), findsOneWidget);
  });

  testWidgets('renders in the dark theme without overflow', (tester) async {
    await pump(
      tester,
      database: db,
      onSelected: (_) {},
      brightness: Brightness.dark,
    );
    await tester.enterText(find.byType(TextField), 'кафе ленинград');
    await tester.pump();
    expect(find.textContaining('Кафе Ленинград'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  test('distance wording', () {
    expect(SearchPanelTexts.distance(347), '350 м');
    expect(SearchPanelTexts.distance(2340), '2,3 км');
    expect(SearchPanelTexts.distance(45200), '45 км');
  });
}
