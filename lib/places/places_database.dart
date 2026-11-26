/// Offline search over a region pack's `places.sqlite`.
///
/// The file is built on the PC by `tool/build_places.sh`; schema, text
/// normalisation and the ranking formula are documented in `docs/places.md`.
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';
import 'package:sqlite3/sqlite3.dart';

import 'cameras.dart';
import 'geo.dart';
import 'normalize.dart';
import 'sqlite_loader.dart';

/// Kind of a search result.
enum PlaceKind {
  /// City, town, village, suburb, district…
  locality,

  /// Street (all same-named ways of one locality) or named addressing area.
  street,

  /// One house on a street: "улица Ленина, 5".
  house,

  /// Point of interest with a category.
  poi,
}

/// One search result (offline or online).
class PlaceResult {
  const PlaceResult({
    required this.kind,
    required this.name,
    required this.point,
    required this.category,
    required this.categoryLabel,
    this.context,
    this.score = 0,
    this.distanceM,
    this.id,
    this.online = false,
  });

  final PlaceKind kind;

  /// Display name: "улица Ленина", "улица Ленина, 5", "Аптека 36,6".
  final String name;

  /// Disambiguation line: locality, district ("Светлогорск, …").
  final String? context;

  /// Centre of the object.
  final LatLng point;

  /// Category code ("street", "city", "fuel", "pharmacy", …, "house").
  final String category;

  /// Russian category label ("Улица", "АЗС", …).
  final String categoryLabel;

  /// Ranking score, higher is better (only comparable within one search).
  final double score;

  /// Distance from the `near` point of the search, if one was given.
  final double? distanceM;

  /// Row id in the pack (`place.id`; for houses the id of the street).
  final int? id;

  /// True for results of the online geocoder.
  final bool online;

  @override
  String toString() => 'PlaceResult($kind, $name, $context, $score)';
}

/// Weights of the ranking formula, see `docs/places.md`.
class RankWeights {
  const RankWeights._();
  static const double text = 4.0;
  static const double type = 1.0;
  static const double proximity = 0.8;
  static const double proximityScaleKm = 15.0;
  static const double exactHouse = 2.0;
  static const double houseSameNumber = 1.0;
  static const double houseOtherNumber = 0.3;
  static const double streetOfMissingHouse = -1.0;
}

class _Category {
  const _Category(this.code, this.label, this.kind, this.synonyms);
  final String code;
  final String label;
  final int kind;

  /// Normalised words that find any object of the category ("азс").
  final Set<String> synonyms;
}

/// Thrown when a file is not a usable places database.
class PlacesFormatException implements Exception {
  PlacesFormatException(this.message);
  final String message;
  @override
  String toString() => 'PlacesFormatException: $message';
}

/// A read-only `places.sqlite`.
///
/// All calls are synchronous (sqlite3 FFI). Search takes a few milliseconds
/// (see docs/places.md), so it can be called from the UI thread while typing.
class PlacesDatabase {
  PlacesDatabase._(this._db, this.path, this.meta, this._cats)
    : cameras = CameraStore(_db, CameraSource.pack);

  /// Schema version this code understands.
  static const int supportedSchema = 1;

  /// Opens [path]; throws [PlacesFormatException] or [SqliteException] when
  /// the file is missing, damaged or from an incompatible version.
  factory PlacesDatabase.open(String path) {
    ensureSqliteLoadable();
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      final meta = <String, String>{
        for (final r in db.select('SELECT key, value FROM meta'))
          r.columnAt(0) as String: r.columnAt(1) as String,
      };
      final v = int.tryParse(meta['schema_version'] ?? '');
      if (v != supportedSchema) {
        throw PlacesFormatException('schema_version $v, need $supportedSchema');
      }
      if (int.tryParse(meta['norm_version'] ?? '') != normVersion) {
        throw PlacesFormatException(
          'norm_version ${meta['norm_version']}, need $normVersion',
        );
      }
      final cats = <int, _Category>{
        for (final r in db.select(
          'SELECT id, code, label, kind, syn FROM category',
        ))
          r.columnAt(0) as int: _Category(
            r.columnAt(1) as String,
            r.columnAt(2) as String,
            r.columnAt(3) as int,
            ((r.columnAt(4) as String?) ?? '')
                .split(' ')
                .where((t) => t.isNotEmpty)
                .toSet(),
          ),
      };
      try {
        // The system SQLite must have FTS5 and R-tree compiled in.
        db.select(
          'SELECT rowid FROM place_fts WHERE place_fts MATCH ? '
          'LIMIT 1',
          ['"a"'],
        );
        db.select('SELECT id FROM camera_rtree LIMIT 1');
      } on SqliteException catch (e) {
        throw PlacesFormatException(
          'SQLite ${sqlite3.version.libVersion} cannot read the pack '
          '(FTS5/R-tree missing?): ${e.message}',
        );
      }
      return PlacesDatabase._(db, path, meta, cats);
    } catch (_) {
      db.dispose();
      rethrow;
    }
  }

  /// Like [PlacesDatabase.open] but returns null on any failure.
  static PlacesDatabase? tryOpen(String path) {
    try {
      return PlacesDatabase.open(path);
    } catch (_) {
      return null;
    }
  }

  final Database _db;
  final String path;

  /// The `meta` table: schema_version, source_date, bbox, count_*.
  final Map<String, String> meta;
  final Map<int, _Category> _cats;

  /// Camera queries on this pack.
  final CameraStore cameras;

  PreparedStatement? _textStmt;
  PreparedStatement? _houseStmt;
  PreparedStatement? _housePrefixStmt;

  /// Pack bounding box as (west, south, east, north), if recorded.
  List<double>? get bbox {
    final parts = (meta['bbox'] ?? '').split(',');
    if (parts.length != 4) return null;
    final v = parts.map(double.tryParse).toList();
    return v.contains(null) ? null : v.cast<double>();
  }

  void close() {
    _textStmt?.dispose();
    _houseStmt?.dispose();
    _housePrefixStmt?.dispose();
    cameras.dispose();
    _db.dispose();
  }

  // ---------------------------------------------------------------- cameras

  /// Cameras within [radiusM] of [p], nearest first; with [courseDeg] only
  /// those that apply to that direction of travel.
  List<NearbyCamera> camerasNear(
    LatLng p,
    double radiusM, {
    double? courseDeg,
  }) => cameras.near(p, radiusM, courseDeg: courseDeg);

  /// Cameras that apply to travel along [route], with distance along it.
  List<RouteCamera> camerasAlong(List<LatLng> route, {double corridorM = 35}) =>
      cameras.along(route, corridorM: corridorM);

  // ----------------------------------------------------------------- search

  static const int _nearLimit = 150;
  static const int _globalLimit = 150;
  static const int _houseStreetLimit = 3000;
  static const int _houseRows = 40;

  /// Searches addresses, streets, localities and POIs.
  ///
  /// [near] (usually the current position or the map centre) biases results
  /// towards nearby objects. The last word of [query] is matched as a prefix
  /// unless the query ends with a space or punctuation.
  List<PlaceResult> search(String query, {LatLng? near, int limit = 20}) {
    final readings = parseQuery(query);
    if (readings.first.tokens.isEmpty) return const [];
    final found = <String, PlaceResult>{};
    void add(String key, PlaceResult r) {
      final old = found[key];
      if (old == null || old.score < r.score) found[key] = r;
    }

    for (final reading in readings.skip(1)) {
      final n = _searchHouses(reading, near, add);
      if (n < 3) {
        // The street exists but (maybe) not this house: offer the street.
        _searchText(
          reading,
          near,
          add,
          bonus: RankWeights.streetOfMissingHouse,
          streetsOnly: true,
        );
      }
    }
    _searchText(readings.first, near, add);
    final out = found.values.toList()
      ..sort((a, b) {
        final c = b.score.compareTo(a.score);
        return c != 0 ? c : a.name.compareTo(b.name);
      });
    return out.length > limit ? out.sublist(0, limit) : out;
  }

  /// Geo-cell tokens around [near] as stored in the FTS `tag` column
  /// (mirrors `cell_tokens` in tool/places/build_places.py): the 3×3 block
  /// of cells centred on the point. [level] 0 = micro (0.0125°×0.025°,
  /// ≈1.4×1.6 km), 1 = fine (0.05°×0.1°), 2 = coarse (0.4°×0.8°).
  static List<String> cellTokens(LatLng near, int level) {
    const latSize = [1250, 5000, 40000];
    const lonSize = [2500, 10000, 80000];
    const prefix = ['m', 'f', 'c'];
    final y = (near.latitude * 1e5).round() + 9000000;
    final x = (near.longitude * 1e5).round() + 18000000;
    final cy = y ~/ latSize[level];
    final cx = x ~/ lonSize[level];
    final p = prefix[level];
    return [
      for (var dy = -1; dy <= 1; dy++)
        for (var dx = -1; dx <= 1; dx++) '$p${cy + dy}x${cx + dx}',
    ];
  }

  /// A single letter stands for any word starting with it: "б. якиманка"
  /// finds "Большая Якиманка".
  static bool isInitial(String token) =>
      token.length == 1 && token.codeUnitAt(0) > 0x39;

  /// FTS5 MATCH expression for a reading, or null when there is nothing to
  /// match. Every word must occur in the name, alternative names or context;
  /// at least one of them in the object's own names. Generic words ("улица")
  /// are not required, they only affect ranking. [cells] restricts the
  /// match to geo cells, [streetsOnly] to localities and streets.
  static String? matchExpression(
    QueryReading r, {
    List<String>? cells,
    bool streetsOnly = false,
  }) {
    final toks = r.tokens;
    if (toks.isEmpty) return null;
    final required = <String>[];
    final optional = <String>[];
    for (var i = 0; i < toks.length; i++) {
      final t = toks[i];
      final last = i == toks.length - 1 && r.lastIsPrefix;
      String term;
      if (last && r.lastRaw != null) {
        term = '("${r.lastRaw}"* OR "$t")';
      } else {
        term = last || isInitial(t) ? '"$t"*' : '"$t"';
      }
      (genericWords.contains(t) ? optional : required).add(term);
    }
    if (required.isEmpty) {
      required.addAll(optional);
      optional.clear();
    }
    final sb = StringBuffer();
    if (required.length == 1) {
      sb.write('{name alt}: ${required.first}');
    } else {
      sb
        ..write('{name alt ctx}: (${required.join(' AND ')})')
        ..write(' AND {name alt}: (${required.join(' OR ')})');
    }
    if (streetsOnly) sb.write(' AND tag: ("k0" OR "k1")');
    if (cells != null) {
      sb.write(' AND tag: (${cells.map((c) => '"$c"').join(' OR ')})');
    }
    return sb.toString();
  }

  double _proximity(double? distM) => distM == null
      ? 0
      : 1.0 / (1.0 + distM / 1000.0 / RankWeights.proximityScaleKm);

  /// Text relevance in 0..1 of a candidate for a reading: the best of its
  /// name and (slightly discounted) alternative names. [altNames] is the
  /// `place.alt` value ("; "-separated), [synonyms] the category words.
  static double textScore(
    QueryReading r,
    String name,
    String? contextName, {
    String? altNames,
    Set<String> synonyms = const {},
    List<String> Function(String) tokenize = normalizeTokens,
  }) {
    var required = <String>[];
    final generic = <String>[];
    var lastTyped = false;
    for (var i = 0; i < r.tokens.length; i++) {
      final t = r.tokens[i];
      if (genericWords.contains(t)) {
        generic.add(t);
      } else {
        required.add(t);
        lastTyped = r.lastIsPrefix && i == r.tokens.length - 1;
      }
    }
    if (required.isEmpty) {
      required = List.of(generic);
      generic.clear();
      lastTyped = r.lastIsPrefix;
    }
    final ct = contextName == null ? const <String>[] : tokenize(contextName);
    var best = _scoreName(
      r,
      required,
      generic,
      lastTyped,
      tokenize(name),
      ct,
      synonyms,
    );
    if (altNames != null && best < 0.99) {
      for (final alt in altNames.split(';')) {
        final s =
            0.95 *
            _scoreName(
              r,
              required,
              generic,
              lastTyped,
              tokenize(alt),
              ct,
              synonyms,
            );
        if (s > best) best = s;
      }
    }
    return best;
  }

  static double _scoreName(
    QueryReading r,
    List<String> required,
    List<String> generic,
    bool lastTyped,
    List<String> nt,
    List<String> ct,
    Set<String> synonyms,
  ) {
    // A pure category query ("аптека", "азс") fits every object of the
    // category equally well, whatever its name: proximity decides.
    if (synonyms.isNotEmpty) {
      var all = true;
      for (var i = 0; i < required.length && all; i++) {
        final t = required[i];
        final prefix = (lastTyped && i == required.length - 1) || isInitial(t);
        all =
            synonyms.contains(t) ||
            (prefix && synonyms.any((w) => w.startsWith(t)));
      }
      if (all) return 0.9;
    }
    final used = List<bool>.filled(nt.length, false);
    var cov = 0.0;
    var covered = 0;
    for (var i = 0; i < required.length; i++) {
      final t = required[i];
      final prefix = (lastTyped && i == required.length - 1) || isInitial(t);
      final raw = prefix && !isInitial(t) ? r.lastRaw : null;
      bool starts(String word) =>
          word.startsWith(t) || (raw != null && word.startsWith(raw));
      var best = 0.0;
      var bestIdx = -1;
      for (var k = 0; k < nt.length; k++) {
        if (used[k]) continue;
        double s = 0;
        if (nt[k] == t) {
          s = 1.0;
        } else if (prefix && starts(nt[k])) {
          s = 0.85;
        }
        if (s > best) {
          best = s;
          bestIdx = k;
        }
      }
      if (bestIdx >= 0) {
        used[bestIdx] = true;
        covered++;
        cov += best;
      } else if (synonyms.contains(t) || (prefix && synonyms.any(starts))) {
        covered++;
        cov += 0.8; // category word: "азс", "аптека"
      } else if (ct.any((c) => c == t || (prefix && starts(c)))) {
        cov += 0.6; // locality context
      } else {
        cov += 0.3; // matched some other name of the object
      }
    }
    cov /= required.length;
    var extra = 0;
    for (var k = 0; k < nt.length; k++) {
      if (!used[k] && !genericWords.contains(nt[k])) extra++;
    }
    final exact = covered / required.length / (1 + extra);
    double genericPart;
    if (generic.isEmpty) {
      genericPart = cov;
    } else {
      var hit = 0;
      for (final g in generic) {
        if (nt.contains(g) || ct.contains(g)) hit++;
      }
      genericPart = hit / generic.length;
    }
    return 0.55 * cov + 0.25 * exact + 0.2 * genericPart;
  }

  String? _context(int kind, String? ctx, String? addr, Row r, int locOffset) {
    final locName = r.columnAt(locOffset) as String?;
    final locCtx = r.columnAt(locOffset + 1) as String?;
    final locCat = r.columnAt(locOffset + 2) as int?;
    final parts = <String>[];
    if (addr != null) parts.add(addr);
    if (locName != null) {
      parts.add(locName);
      final code = _cats[locCat]?.code;
      if (locCtx != null && code != 'city' && code != 'town') {
        parts.add(locCtx.split(', ').first);
      }
    } else if (ctx != null) {
      parts.add(ctx);
    }
    return parts.isEmpty ? null : parts.join(', ');
  }

  /// Match expressions of the search stages: the whole pack (null) first,
  /// then 3×3 blocks of micro, fine and coarse cells around [near]
  /// (level 0..2).
  List<(String, int?)> _stages(
    QueryReading reading,
    LatLng? near, {
    required bool streetsOnly,
  }) => [
    (matchExpression(reading, streetsOnly: streetsOnly)!, null),
    if (near != null)
      for (var level = 0; level < 3; level++)
        (
          matchExpression(
            reading,
            cells: cellTokens(near, level),
            streetsOnly: streetsOnly,
          )!,
          level,
        ),
  ];

  final Map<String, List<String>> _tokenCache = {};

  /// [normalizeTokens] with a small cache: while typing, consecutive
  /// searches score mostly the same candidates.
  List<String> _tokens(String text) {
    final hit = _tokenCache[text];
    if (hit != null) return hit;
    if (_tokenCache.length > 4000) _tokenCache.clear();
    return _tokenCache[text] = normalizeTokens(text);
  }

  void _searchText(
    QueryReading reading,
    LatLng? near,
    void Function(String, PlaceResult) add, {
    double bonus = 0,
    bool streetsOnly = false,
  }) {
    final stmt = _textStmt ??= _db.prepare('''
SELECT p.id, p.kind, p.cat, p.name, p.ctx, p.addr, p.lat, p.lon, p.w,
       l.name, l.ctx, l.cat, p.alt
FROM (SELECT rowid FROM place_fts WHERE place_fts MATCH ?1
      ORDER BY rowid LIMIT ?2) f
JOIN place p ON p.id = f.rowid
LEFT JOIN place l ON l.id = p.loc''');
    // Rows come most important first (ids are assigned by weight), so a
    // LIMIT keeps the best of each stage. The whole pack is searched first:
    // an important far object (a city) is never lost, and when everything
    // that matches fits the limit there is nothing more to look for.
    // Otherwise the surroundings of [near] are searched, widening the area
    // only while the narrower one did not fill its limit.
    var saturated = false;
    for (final (expr, level) in _stages(
      reading,
      near,
      streetsOnly: streetsOnly,
    )) {
      if (level != null && saturated) break;
      // The street-of-a-missing-house fallback looks nearby and globally.
      if (streetsOnly && (level == 0 || level == 2)) continue;
      final lim = level != null
          ? _nearLimit
          : (near == null ? _globalLimit * 2 : _globalLimit);
      final ResultSet rows;
      try {
        rows = stmt.select([expr, lim]);
      } on SqliteException {
        continue; // malformed MATCH (should not happen with our tokens)
      }
      if (level == null) {
        if (rows.length < lim) saturated = true; // got every match already
      } else if (rows.length >= lim) {
        saturated = true;
      }
      for (final r in rows) {
        final id = r.columnAt(0) as int;
        final kind = r.columnAt(1) as int;
        final cat = _cats[r.columnAt(2) as int];
        final name = r.columnAt(3) as String;
        final point = LatLng(
          (r.columnAt(6) as int) / 1e5,
          (r.columnAt(7) as int) / 1e5,
        );
        final dist = near == null ? null : distanceM(near, point);
        final text = textScore(
          reading,
          name,
          r.columnAt(9) as String?,
          altNames: r.columnAt(12) as String?,
          tokenize: _tokens,
          synonyms: kind == 2 ? (cat?.synonyms ?? const {}) : const {},
        );
        final score =
            RankWeights.text * text +
            RankWeights.type * (r.columnAt(8) as int) / 120.0 +
            RankWeights.proximity * _proximity(dist) +
            bonus;
        add(
          'p$id',
          PlaceResult(
            kind: kind == 0
                ? PlaceKind.locality
                : kind == 1
                ? PlaceKind.street
                : PlaceKind.poi,
            name: name,
            context: _context(
              kind,
              r.columnAt(4) as String?,
              r.columnAt(5) as String?,
              r,
              9,
            ),
            point: point,
            category: cat?.code ?? '',
            categoryLabel: cat?.label ?? '',
            score: score,
            distanceM: dist,
            id: id,
          ),
        );
      }
    }
  }

  static String _houseSql(String cond, int limit) =>
      '''
SELECT p.id, p.kind, p.name, p.ctx, h.hn, h.lat, h.lon, l.name, l.ctx, l.cat,
       p.alt
FROM (SELECT rowid FROM place_fts WHERE place_fts MATCH ?1
      ORDER BY rowid LIMIT ?2) f
JOIN place p ON p.id = f.rowid
JOIN house h ON h.street = p.id AND $cond
LEFT JOIN place l ON l.id = p.loc
ORDER BY abs(h.lat - ?4) + abs(h.lon - ?5) * ?6
LIMIT $limit''';

  int _searchHouses(
    QueryReading reading,
    LatLng? near,
    void Function(String, PlaceResult) add,
  ) {
    final house = reading.house;
    if (house == null) return 0;
    var count = 0;
    void emit(ResultSet rows) {
      for (final r in rows) {
        final street = r.columnAt(2) as String;
        final hn = r.columnAt(4) as String;
        final point = LatLng(
          (r.columnAt(5) as int) / 1e5,
          (r.columnAt(6) as int) / 1e5,
        );
        final dist = near == null ? null : distanceM(near, point);
        double houseBonus;
        if (hn == house) {
          houseBonus = RankWeights.exactHouse;
        } else {
          final c = hn.codeUnitAt(house.length);
          houseBonus = c >= 0x30 && c <= 0x39
              ? RankWeights.houseOtherNumber
              : RankWeights.houseSameNumber;
        }
        final score =
            RankWeights.text *
                textScore(
                  reading,
                  street,
                  r.columnAt(7) as String?,
                  altNames: r.columnAt(10) as String?,
                  tokenize: _tokens,
                ) +
            RankWeights.type +
            RankWeights.proximity * _proximity(dist) +
            houseBonus;
        count++;
        add(
          'h${r.columnAt(0)}/$hn',
          PlaceResult(
            kind: PlaceKind.house,
            name: '$street, ${displayHouseNumber(hn)}',
            context: _context(1, r.columnAt(3) as String?, null, r, 7),
            point: point,
            category: 'house',
            categoryLabel: 'Дом',
            score: score,
            distanceM: dist,
            id: r.columnAt(0) as int,
          ),
        );
      }
    }

    // Streets matching the words (most important first, up to a limit),
    // joined with their houses; the nearest houses are kept. Only a
    // half-typed short street word can match more streets than the limit;
    // then the area around [near] is searched first.
    final exact = _houseStmt ??= _db.prepare(
      _houseSql('h.hn = ?3', _houseRows),
    );
    final prefix = _housePrefixStmt ??= _db.prepare(
      _houseSql('h.hn > ?3 AND h.hn < ?7', _houseRows),
    );
    final lat5 = near == null ? 0 : (near.latitude * 1e5).round();
    final lon5 = near == null ? 0 : (near.longitude * 1e5).round();
    final cosLat = near == null ? 0.0 : math.cos(near.latitude * math.pi / 180);
    final exprs = <String>[
      if (near != null && reading.lastIsPrefix)
        matchExpression(
          reading,
          cells: cellTokens(near, 1),
          streetsOnly: true,
        )!,
      matchExpression(reading, streetsOnly: true)!,
    ];
    for (final expr in exprs) {
      try {
        emit(
          exact.select([expr, _houseStreetLimit, house, lat5, lon5, cosLat]),
        );
        if (reading.houseIsPrefix) {
          emit(
            prefix.select([
              expr,
              _houseStreetLimit,
              house,
              lat5,
              lon5,
              cosLat,
              '$house\u{10FFFF}',
            ]),
          );
        }
      } on SqliteException {
        // malformed MATCH expression: no house results
      }
    }
    return count;
  }
}
