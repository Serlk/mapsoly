import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/places/normalize.dart';
import 'package:mapsoly/places/places_database.dart';

import 'fixture.dart';

// A toy region: a city (index 0), a town 30 km north (1), a village (2).
const _city = LatLng(54.71, 20.51);
const _town = LatLng(54.98, 20.51);

List<FixturePlace> _places() => [
  /* 0 */ FixturePlace(
    0,
    catCity,
    'Приморск',
    54.71,
    20.51,
    110,
    ctx: 'Приморский район',
  ),
  /* 1 */ FixturePlace(
    0,
    catCity,
    'Озёрск',
    54.98,
    20.51,
    95,
    ctx: 'Озёрский район',
  ),
  /* 2 */ FixturePlace(
    0,
    catVillage,
    'Ленино',
    54.60,
    20.80,
    65,
    ctx: 'Приморский район',
  ),
  /* 3 */ FixturePlace(
    1,
    catStreet,
    'улица Ленина',
    54.712,
    20.512,
    50,
    loc: 0,
    houses: {
      '5': (54.7121, 20.5121),
      '5А': (54.7122, 20.5122),
      '5 к2': (54.7123, 20.5123),
      '51': (54.7130, 20.5130),
      '7': (54.7124, 20.5124),
    },
  ),
  /* 4 */ FixturePlace(
    1,
    catStreet,
    'улица Ленина',
    54.982,
    20.512,
    50,
    loc: 1,
    houses: {'5': (54.9821, 20.5121), '9': (54.9822, 20.5122)},
  ),
  /* 5 */ FixturePlace(
    1,
    catStreet,
    'Ленинский проспект',
    54.705,
    20.505,
    60,
    loc: 0,
    alt: ['Lenin Avenue'],
    houses: {'30': (54.7051, 20.5051)},
  ),
  /* 6 */ FixturePlace(1, catStreet, 'проспект Мира', 54.72, 20.48, 60, loc: 0),
  /* 7 */ FixturePlace(1, catStreet, 'улица Мира', 54.985, 20.515, 50, loc: 1),
  /* 8 */ FixturePlace(
    1,
    catStreet,
    'Озёрная улица',
    54.715,
    20.52,
    50,
    loc: 0,
    houses: {'12': (54.7151, 20.5201)},
  ),
  /* 9 */ FixturePlace(
    1,
    catStreet,
    'улица 9 Мая',
    54.716,
    20.53,
    50,
    loc: 0,
    houses: {'12': (54.7161, 20.5301)},
  ),
  /* 10 */ FixturePlace(
    1,
    catStreet,
    'Большая Якиманка',
    54.717,
    20.54,
    50,
    loc: 0,
    houses: {'24': (54.7171, 20.5401)},
  ),
  /* 11 */ FixturePlace(2, catFuel, 'Лукойл', 54.70, 20.50, 45, loc: 0),
  /* 12 */ FixturePlace(2, catFuel, 'АЗС', 54.99, 20.50, 45, loc: 1),
  /* 13 */ FixturePlace(
    2,
    catPharmacy,
    'Аптека 36,6',
    54.711,
    20.511,
    40,
    loc: 0,
    addr: 'улица Ленина, 7',
  ),
  /* 14 */ FixturePlace(2, catCafe, 'Приморск', 54.713, 20.513, 35, loc: 0),
  /* 15 */ FixturePlace(
    2,
    catStation,
    'Приморск-Пассажирский',
    54.70,
    20.52,
    50,
    loc: 0,
    alt: ['Южный вокзал'],
  ),
  /* 16 */ FixturePlace(
    0,
    catVillage,
    'Ивановка',
    54.65,
    20.60,
    65,
    ctx: 'Приморский район',
    houses: {'3': (54.6501, 20.6001)},
  ),
  /* 17 */ FixturePlace(
    2,
    catCafe,
    'Café Königsberg',
    54.714,
    20.514,
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

  List<String> names(String q, {LatLng? near = _city, int limit = 10}) => [
    for (final r in db.search(q, near: near, limit: limit))
      '${r.name}|${r.context ?? ''}',
  ];

  test('opens and exposes meta', () {
    expect(db.meta['schema_version'], '1');
    expect(db.bbox, [20.0, 54.0, 21.0, 55.0]);
  });

  test('rejects a database with another schema version', () {
    final p = buildFixture(
      const [],
      extra: (d) =>
          d.execute("UPDATE meta SET value='99' WHERE key='schema_version'"),
    );
    expect(() => PlacesDatabase.open(p), throwsA(isA<PlacesFormatException>()));
    expect(PlacesDatabase.tryOpen(p), isNull);
    expect(PlacesDatabase.tryOpen('/nonexistent/places.sqlite'), isNull);
    File(p).parent.deleteSync(recursive: true);
  });

  test('exact house match comes first, in any word order and spelling', () {
    for (final q in [
      'ленина 5',
      '5 ленина',
      'ул. Ленина, 5',
      'УЛИЦА ЛЕНИНА ДОМ 5',
      'ленина д.5',
    ]) {
      final res = db.search(q, near: _city);
      expect(res.first.kind, PlaceKind.house, reason: q);
      expect(res.first.name, 'улица Ленина, 5', reason: q);
      expect(res.first.context, 'Приморск', reason: q);
      expect(res.first.point.latitude, closeTo(54.7121, 1e-5), reason: q);
    }
  });

  test('proximity decides between equal houses', () {
    expect(db.search('ленина 5', near: _town).first.context, 'Озёрск');
    expect(db.search('ленина 5', near: _city).first.context, 'Приморск');
  });

  test('locality word disambiguates', () {
    final res = db.search('ленина 5 озерск', near: _city);
    expect(res.first.name, 'улица Ленина, 5');
    expect(res.first.context, 'Озёрск');
    expect(names('озёрск ленина').first, 'улица Ленина|Озёрск');
  });

  test(
    'while typing the number, same-number variants follow the exact one',
    () {
      final res = db
          .search('ленина 5', near: _city)
          .map((r) => r.name)
          .toList();
      expect(res.first, 'улица Ленина, 5');
      expect(res, containsAll(['улица Ленина, 5А', 'улица Ленина, 5 к2']));
      expect(
        res.indexOf('улица Ленина, 5А'),
        lessThan(res.indexOf('улица Ленина, 51')),
      );
      // A finished number (trailing space) no longer offers 51.
      final done = db.search('ленина 5 ', near: _city).map((r) => r.name);
      expect(done, isNot(contains('улица Ленина, 51')));
    },
  );

  test('building suffixes', () {
    expect(
      db.search('ленина 5 к2', near: _city).first.name,
      'улица Ленина, 5 к2',
    );
    expect(
      db.search('ленина 5 корпус 2', near: _city).first.name,
      'улица Ленина, 5 к2',
    );
    expect(db.search('ленина 5а', near: _city).first.name, 'улица Ленина, 5А');
  });

  test('a missing house falls back to the street', () {
    final res = db.search('ленина 99', near: _city);
    expect(res, isNotEmpty);
    expect(res.first.kind, PlaceKind.street);
    expect(res.first.name, 'улица Ленина');
  });

  test('abbreviations and status words', () {
    expect(names('ленинский пр-т 30').first, 'Ленинский проспект, 30|Приморск');
    expect(names('пр мира').first, 'проспект Мира|Приморск');
    expect(names('проспект мира', near: _town).first, 'проспект Мира|Приморск');
    expect(names('ул мира', near: _city).first, 'улица Мира|Озёрск');
  });

  test('ё equals е, case is ignored, diacritics fold', () {
    expect(names('озерная 12').first, 'Озёрная улица, 12|Приморск');
    expect(names('ОЗЁРНАЯ').first, 'Озёрная улица|Приморск');
    expect(names('озерск').first, startsWith('Озёрск|'));
    expect(names('konigsberg').first, startsWith('Café Königsberg|'));
  });

  test('prefix search on the last word', () {
    expect(
      names('лен'),
      containsAll(['улица Ленина|Приморск', 'Ленинский проспект|Приморск']),
    );
    expect(names('ленинс').first, 'Ленинский проспект|Приморск');
    // A finished word does not prefix-match.
    expect(names('лен '), isEmpty);
  });

  test('numeric street names', () {
    expect(names('9 мая 12').first, 'улица 9 Мая, 12|Приморск');
    expect(names('9 мая').first, 'улица 9 Мая|Приморск');
  });

  test('an initial stands for a word', () {
    expect(names('б. якиманка 24').first, 'Большая Якиманка, 24|Приморск');
  });

  test('type priority: the city before a café of the same name', () {
    final res = names('приморск');
    expect(res.first, startsWith('Приморск|Приморский район'));
    expect(res, contains('Приморск|Приморск'));
  });

  test('category words find POIs, nearest first', () {
    expect(names('азс').first, 'Лукойл|Приморск');
    expect(names('азс', near: _town).first, 'АЗС|Озёрск');
    expect(names('заправка лукойл').first, 'Лукойл|Приморск');
    final r = db.search('аптека', near: _city).first;
    expect(r.kind, PlaceKind.poi);
    expect(r.category, 'pharmacy');
    expect(r.categoryLabel, 'Аптека');
    expect(r.context, 'улица Ленина, 7, Приморск');
  });

  test('alternative names are searchable', () {
    expect(names('южный вокзал').first, startsWith('Приморск-Пассажирский|'));
    expect(names('lenin avenue').first, 'Ленинский проспект|Приморск');
  });

  test('addresses without a street hang on the locality', () {
    final r = db.search('ивановка 3', near: _city).first;
    expect(r.kind, PlaceKind.house);
    expect(r.name, 'Ивановка, 3');
    expect(r.context, 'Приморский район');
  });

  test('results carry distance and respect the limit', () {
    final res = db.search('лен', near: _city, limit: 2);
    expect(res, hasLength(2));
    expect(res.first.distanceM, isNotNull);
    expect(db.search('лен', limit: 3).first.distanceM, isNull);
  });

  test('garbage input is harmless', () {
    for (final q in [
      '',
      '   ',
      '"',
      '" OR 1',
      "'; DROP TABLE place; --",
      '***',
      '5',
      'NEAR(a b)',
      '{name}: x',
    ]) {
      expect(() => db.search(q, near: _city), returnsNormally, reason: q);
    }
    expect(db.search('', near: _city), isEmpty);
  });

  test('match expression', () {
    final plain = parseQuery('ул ленина').first;
    expect(PlacesDatabase.matchExpression(plain), '{name alt}: "ленина"*');
    final two = parseQuery('ленина озерск ').first;
    expect(
      PlacesDatabase.matchExpression(two),
      '{name alt ctx}: ("ленина" AND "озерск") AND {name alt}: ("ленина" OR "озерск")',
    );
    expect(
      PlacesDatabase.cellTokens(const LatLng(54.71, 20.51), 1),
      contains('f2894x2005'),
    );
  });
}
