// Builds a small places.sqlite for tests, with the same schema as
// tool/places/build_places.py (keep the DDL in sync with SCHEMA there).
import 'dart:io';

import 'package:mapsoly/places/normalize.dart';
import 'package:sqlite3/sqlite3.dart';

const fixtureSchema = '''
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID;
CREATE TABLE category(id INTEGER PRIMARY KEY, code TEXT NOT NULL,
  label TEXT NOT NULL, kind INTEGER NOT NULL, syn TEXT);
CREATE TABLE place(id INTEGER PRIMARY KEY, kind INTEGER NOT NULL,
  cat INTEGER NOT NULL, name TEXT NOT NULL, alt TEXT, loc INTEGER, ctx TEXT,
  addr TEXT, lat INTEGER NOT NULL, lon INTEGER NOT NULL, w INTEGER NOT NULL);
CREATE VIRTUAL TABLE place_fts USING fts5(name, alt, ctx, tag, content='',
  detail=column, columnsize=0, prefix='1 2 3',
  tokenize="unicode61 remove_diacritics 2");
CREATE TABLE house(street INTEGER NOT NULL, hn TEXT NOT NULL,
  lat INTEGER NOT NULL, lon INTEGER NOT NULL,
  PRIMARY KEY(street, hn)) WITHOUT ROWID;
CREATE TABLE camera(id INTEGER PRIMARY KEY, type TEXT NOT NULL,
  lat REAL NOT NULL, lon REAL NOT NULL, bearing INTEGER,
  bidir INTEGER NOT NULL DEFAULT 0, maxspeed INTEGER,
  maxspeed_from_road INTEGER NOT NULL DEFAULT 0,
  end_lat REAL, end_lon REAL, osm TEXT);
CREATE VIRTUAL TABLE camera_rtree USING rtree(id, min_lat, max_lat,
  min_lon, max_lon);
''';

const catCity = 1, catVillage = 2, catStreet = 3, catFuel = 4, catPharmacy = 5;
const catCafe = 6, catStation = 7;

class FixturePlace {
  FixturePlace(
    this.kind,
    this.cat,
    this.name,
    this.lat,
    this.lon,
    this.w, {
    this.alt = const [],
    this.loc,
    this.ctx,
    this.addr,
    this.houses = const {},
  });
  final int kind, cat, w;
  final String name;
  final double lat, lon;
  final List<String> alt;

  /// Index (in the list given to [buildFixture]) of the locality.
  final int? loc;
  final String? ctx, addr;

  /// Raw house number → (lat, lon).
  final Map<String, (double, double)> houses;
}

String _cells(int lat5, int lon5) {
  final y = lat5 + 9000000, x = lon5 + 18000000;
  return 'm${y ~/ 1250}x${x ~/ 2500} f${y ~/ 5000}x${x ~/ 10000} '
      'c${y ~/ 40000}x${x ~/ 80000}';
}

/// Writes a fixture database to a new temp file and returns its path.
/// Ids follow the builder's rule: descending weight.
String buildFixture(
  List<FixturePlace> places, {
  void Function(Database db)? extra,
}) {
  final dir = Directory.systemTemp.createTempSync('mapsoly_places_test');
  final path = '${dir.path}/places.sqlite';
  final db = sqlite3.open(path);
  db.execute(fixtureSchema);
  db.execute(
    "INSERT INTO meta VALUES ('schema_version','1'),"
    "('norm_version','$normVersion'),('bbox','20.0,54.0,21.0,55.0')",
  );
  final cats = [
    (catCity, 'city', 'Город', 0, null),
    (catVillage, 'village', 'Село', 0, null),
    (catStreet, 'street', 'Улица', 1, null),
    (catFuel, 'fuel', 'АЗС', 2, 'азс заправка бензин топливо'),
    (catPharmacy, 'pharmacy', 'Аптека', 2, 'аптека'),
    (catCafe, 'cafe', 'Кафе', 2, 'кафе кофейня'),
    (
      catStation,
      'station',
      'Ж/д станция',
      2,
      'ж д станция вокзал платформа жд',
    ),
  ];
  for (final c in cats) {
    db.execute('INSERT INTO category VALUES (?,?,?,?,?)', [
      c.$1,
      c.$2,
      c.$3,
      c.$4,
      c.$5,
    ]);
  }
  final order = List.generate(places.length, (i) => i)
    ..sort((a, b) {
      final c = places[b].w.compareTo(places[a].w);
      return c != 0 ? c : a.compareTo(b);
    });
  final id = List.filled(places.length, 0);
  for (var r = 0; r < order.length; r++) {
    id[order[r]] = r + 1;
  }
  final synOf = {for (final c in cats) c.$1: c.$5};
  for (final i in order) {
    final p = places[i];
    final lat5 = (p.lat * 1e5).round(), lon5 = (p.lon * 1e5).round();
    db.execute('INSERT INTO place VALUES (?,?,?,?,?,?,?,?,?,?,?)', [
      id[i],
      p.kind,
      p.cat,
      p.name,
      p.alt.isEmpty ? null : p.alt.join('; '),
      p.loc == null ? null : id[p.loc!],
      p.ctx,
      p.addr,
      lat5,
      lon5,
      p.w,
    ]);
    final nameTokens = normalizeTokens(p.name);
    final alt = <String>{
      for (final a in p.alt) ...normalizeTokens(a),
      if (p.kind == 2) ...?synOf[p.cat]?.split(' '),
    }..removeAll(nameTokens);
    final ctx = <String>{
      if (p.loc != null) ...normalizeTokens(places[p.loc!].name),
      if (p.loc != null && places[p.loc!].ctx != null)
        ...normalizeTokens(places[p.loc!].ctx!),
      if (p.ctx != null) ...normalizeTokens(p.ctx!),
    };
    db.execute(
      'INSERT INTO place_fts(rowid, name, alt, ctx, tag) VALUES (?,?,?,?,?)',
      [
        id[i],
        nameTokens.join(' '),
        alt.join(' '),
        ctx.join(' '),
        'k${p.kind} ${_cells(lat5, lon5)}',
      ],
    );
    p.houses.forEach((hn, pt) {
      db.execute('INSERT INTO house VALUES (?,?,?,?)', [
        id[i],
        normalizeHouseNumber(hn),
        (pt.$1 * 1e5).round(),
        (pt.$2 * 1e5).round(),
      ]);
    });
  }
  extra?.call(db);
  db.dispose();
  return path;
}

/// Inserts a camera row (+ r-tree entry).
void addCamera(
  Database db,
  int id,
  double lat,
  double lon, {
  String type = 'maxspeed',
  int? bearing,
  bool bidir = false,
  int? maxspeed,
  double? endLat,
  double? endLon,
}) {
  db.execute('INSERT INTO camera VALUES (?,?,?,?,?,?,?,0,?,?,?)', [
    id,
    type,
    lat,
    lon,
    bearing,
    bidir ? 1 : 0,
    maxspeed,
    endLat,
    endLon,
    'n$id',
  ]);
  db.execute('INSERT INTO camera_rtree VALUES (?,?,?,?,?)', [
    id,
    lat,
    lat,
    lon,
    lon,
  ]);
}
