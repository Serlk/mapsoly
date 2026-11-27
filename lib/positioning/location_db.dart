/// Local SQLite database of transmitter positions (Wi-Fi APs by BSSID, cells
/// by full identity, BLE beacons by address).
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

import 'geo.dart';
import 'models.dart';

/// Origin of a database record. Lower index = more trusted; an import from a
/// less trusted source never overwrites a more trusted record.
enum TransmitterSource { wardriving, wigle, csv, beacondb, apple }

/// One known transmitter.
class TransmitterRecord {
  const TransmitterRecord({
    required this.kind,
    required this.id,
    required this.lat,
    required this.lon,
    required this.accuracyM,
    required this.source,
    required this.updated,
    this.samples = 1,
    this.weightSum = 0,
    this.scatterM2 = 0,
    this.bestSignalDbm,
    this.seedSource,
  });

  final TransmitterKind kind;

  /// Normalised BSSID / BLE address, or [cellKey].
  final String id;
  final double lat;
  final double lon;

  /// Uncertainty of the stored position in metres. For cells from online
  /// databases this is the reported coverage radius.
  final double accuracyM;
  final TransmitterSource source;
  final DateTime updated;

  /// Number of observations merged into the running estimate.
  final int samples;

  /// Sum of sample weights (running weighted mean state).
  final double weightSum;

  /// Weighted sum of squared distances to the mean, m^2 (running variance).
  final double scatterM2;

  /// Strongest signal ever recorded for this transmitter.
  final double? bestSignalDbm;

  /// For a [TransmitterSource.wardriving] record: the source of the external
  /// record its running estimate was started from (the external position
  /// served as a prior worth one sample), or null when the position comes
  /// from own observations only. Always null for other sources. Records
  /// written before schema version 2 have null here even if they were
  /// seeded: that was not stored then.
  final TransmitterSource? seedSource;

  /// Learnt by own wardriving without a prior from an online service
  /// (Apple, beaconDB).
  bool get isOwn =>
      source == TransmitterSource.wardriving &&
      seedSource != TransmitterSource.apple &&
      seedSource != TransmitterSource.beacondb;
}

/// One wardriving sample to merge into the database.
class TransmitterSample {
  const TransmitterSample({
    required this.kind,
    required this.id,
    required this.lat,
    required this.lon,
    required this.weight,
    required this.fixAccuracyM,
    this.signalDbm,
    this.rangeM,
    required this.time,
  });

  final TransmitterKind kind;
  final String id;
  final double lat;
  final double lon;

  /// Relative weight (> 0), larger when the transmitter is believed closer.
  final double weight;
  final double fixAccuracyM;
  final double? signalDbm;

  /// Estimated distance to the transmitter at this sample, if known.
  final double? rangeM;
  final DateTime time;
}

/// Aggregate database statistics for the UI.
class DbStats {
  const DbStats({
    required this.wifi,
    required this.cells,
    required this.ble,
    required this.bySource,
    required this.rawSamples,
    required this.fileBytes,
  });

  final int wifi;
  final int cells;
  final int ble;
  final Map<TransmitterSource, int> bySource;
  final int rawSamples;
  final int fileBytes;

  int get total => wifi + cells + ble;

  @override
  String toString() =>
      'DbStats(wifi $wifi, cells $cells, ble $ble, raw $rawSamples, '
      '${bySource.map((k, v) => MapEntry(k.name, v))})';
}

var _openConfigured = false;

/// package:sqlite3 2.x opens `libsqlite3.so` on Linux, a name that only
/// exists when the SQLite development package is installed. Fall back to the
/// runtime soname so a plain `sqlite-libs` (Alpine) / `sqlite` (Arch) works.
void _configureSqliteOpen() {
  if (_openConfigured) return;
  _openConfigured = true;
  if (!Platform.isLinux) return;
  sqlite_open.open.overrideFor(sqlite_open.OperatingSystem.linux, () {
    final self = DynamicLibrary.executable();
    if (self.providesSymbol(
      'sqlite3_flutter_libs_plugin_register_with_registrar',
    )) {
      return self;
    }
    Object? lastError;
    for (final name in const ['libsqlite3.so', 'libsqlite3.so.0']) {
      try {
        return DynamicLibrary.open(name);
      } on ArgumentError catch (e) {
        lastError = e;
      }
    }
    throw StateError('cannot load system SQLite: $lastError');
  });
}

/// Minimum plausible accuracy stored for a wardriven transmitter, metres.
const double minWifiAccuracyM = 10.0;
const double minCellAccuracyM = 300.0;

/// A Wi-Fi AP observed further than this from its stored position is assumed
/// to have moved (or to be a mobile hotspot): the running estimate restarts.
const double wifiMovedThresholdM = 400.0;

/// Same for cells; larger than any real cell so only re-used identities or
/// bad imports trigger it.
const double cellMovedThresholdM = 50000.0;

/// Negative-cache lifetime: how long an id that online services did not know
/// is not asked again.
const Duration negativeCacheTtl = Duration(days: 14);

/// The transmitter location database.
///
/// All calls are synchronous (package:sqlite3). Lookups of a scan's worth of
/// ids take well under a millisecond; bulk imports should be chunked by the
/// caller (the importers do) to keep the UI responsive.
class LocationDb {
  LocationDb._(this._db, this.path) {
    _migrate();
  }

  /// Opens (and creates if needed) the database file at [path].
  factory LocationDb.open(String path) {
    _configureSqliteOpen();
    return LocationDb._(sqlite3.open(path), path);
  }

  /// In-memory database for tests.
  factory LocationDb.inMemory() {
    _configureSqliteOpen();
    return LocationDb._(sqlite3.openInMemory(), null);
  }

  final Database _db;
  final String? path;

  /// 2 added `transmitter.seed_source` (see [TransmitterRecord.seedSource]).
  static const int schemaVersion = 2;

  void _migrate() {
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = NORMAL');
    final v = _db.select('PRAGMA user_version').first.values.first as int;
    if (v >= schemaVersion) return;
    _db.execute('BEGIN');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS transmitter(
        kind INTEGER NOT NULL,        -- TransmitterKind.index
        id TEXT NOT NULL,             -- bssid / cell key / ble address
        lat REAL NOT NULL,
        lon REAL NOT NULL,
        accuracy REAL NOT NULL,       -- metres
        samples INTEGER NOT NULL DEFAULT 1,
        wsum REAL NOT NULL DEFAULT 0, -- running sum of weights
        scatter REAL NOT NULL DEFAULT 0, -- weighted sum of squared dist, m^2
        best_signal REAL,             -- strongest dBm seen
        best_range REAL,              -- smallest estimated range seen, m
        source INTEGER NOT NULL,      -- TransmitterSource.index
        updated INTEGER NOT NULL,     -- unix seconds
        seed_source INTEGER,          -- external source a wardriving record
                                      -- was started from, NULL = own only
        PRIMARY KEY(kind, id)
      ) WITHOUT ROWID''');
    // Version 1 databases have the table without the column.
    final columns = _db
        .select('PRAGMA table_info(transmitter)')
        .map((r) => r['name'] as String);
    if (!columns.contains('seed_source')) {
      _db.execute('ALTER TABLE transmitter ADD COLUMN seed_source INTEGER');
    }
    _db.execute(
      'CREATE INDEX IF NOT EXISTS transmitter_pos ON transmitter(lat, lon)',
    );
    _db.execute('''
      CREATE TABLE IF NOT EXISTS sample(
        kind INTEGER NOT NULL,
        id TEXT NOT NULL,
        lat REAL NOT NULL,
        lon REAL NOT NULL,
        fix_accuracy REAL NOT NULL,
        signal REAL,
        time INTEGER NOT NULL
      )''');
    _db.execute('CREATE INDEX IF NOT EXISTS sample_id ON sample(kind, id)');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS unknown(
        kind INTEGER NOT NULL,
        id TEXT NOT NULL,
        checked INTEGER NOT NULL,     -- unix seconds
        PRIMARY KEY(kind, id)
      ) WITHOUT ROWID''');
    _db.execute('PRAGMA user_version = $schemaVersion');
    _db.execute('COMMIT');
  }

  static TransmitterRecord _row(Row r) => TransmitterRecord(
    kind: TransmitterKind.values[r['kind'] as int],
    id: r['id'] as String,
    lat: (r['lat'] as num).toDouble(),
    lon: (r['lon'] as num).toDouble(),
    accuracyM: (r['accuracy'] as num).toDouble(),
    samples: r['samples'] as int,
    weightSum: (r['wsum'] as num).toDouble(),
    scatterM2: (r['scatter'] as num).toDouble(),
    bestSignalDbm: (r['best_signal'] as num?)?.toDouble(),
    source: TransmitterSource.values[r['source'] as int],
    updated: DateTime.fromMillisecondsSinceEpoch(
      (r['updated'] as int) * 1000,
      isUtc: true,
    ),
    seedSource: switch (r['seed_source']) {
      final int i when i >= 0 && i < TransmitterSource.values.length =>
        TransmitterSource.values[i],
      _ => null,
    },
  );

  /// All records in primary-key order, read in pages so a large database is
  /// never held in memory at once. With [source], only that source.
  ///
  /// The database may be written between pages (the iteration is keyset
  /// based); records changed meanwhile are seen in either state.
  Iterable<TransmitterRecord> records({
    TransmitterSource? source,
    int pageSize = 2000,
  }) sync* {
    var kind = -1;
    var id = '';
    while (true) {
      final rows = _db.select(
        'SELECT * FROM transmitter WHERE (kind > ?1 OR (kind = ?1 AND id > ?2)) '
        '${source == null ? '' : 'AND source = ?4 '}'
        'ORDER BY kind, id LIMIT ?3',
        [kind, id, pageSize, if (source != null) source.index],
      );
      if (rows.isEmpty) return;
      for (final r in rows) {
        yield _row(r);
      }
      kind = rows.last['kind'] as int;
      id = rows.last['id'] as String;
      if (rows.length < pageSize) return;
    }
  }

  /// Deletes (or with [dryRun] only counts) what lies inside any of
  /// [circles] (latitude, longitude, radius in metres): transmitter records
  /// by their stored position and raw wardriving samples by the position
  /// they were taken at. With [sources], only transmitter records from
  /// those sources; raw samples are own wardriving data and are included
  /// when [sources] is null or contains [TransmitterSource.wardriving].
  ///
  /// Returns (transmitter records, raw samples); something inside several
  /// circles is counted once.
  (int, int) deleteWithin(
    Iterable<(double, double, double)> circles, {
    Set<TransmitterSource>? sources,
    bool dryRun = false,
  }) {
    final keys = <(int, String)>{};
    final sampleRows = <int>{};
    final withSamples =
        sources == null || sources.contains(TransmitterSource.wardriving);
    for (final (lat, lon, radiusM) in circles) {
      // Bounding box first (uses the position index), exact distance after.
      final dLat = radToDeg(radiusM / earthRadiusM);
      final cos = math.cos(degToRad(lat)).abs();
      final wide = cos < 1e-6 || dLat / cos >= 180;
      final dLon = wide ? 360.0 : dLat / cos;
      // Near the antimeridian the box wraps: do not filter by longitude.
      final wraps = wide || lon - dLon < -180 || lon + dLon > 180;
      final where =
          'lat BETWEEN ?1 AND ?2'
          '${wraps ? '' : ' AND lon BETWEEN ?3 AND ?4'}';
      final args = [
        lat - dLat,
        lat + dLat,
        if (!wraps) ...[lon - dLon, lon + dLon],
      ];
      bool inside(Row r) =>
          haversineM(
            lat,
            lon,
            (r['lat'] as num).toDouble(),
            (r['lon'] as num).toDouble(),
          ) <=
          radiusM;

      for (final r in _db.select(
        'SELECT kind, id, lat, lon, source FROM transmitter WHERE $where',
        args,
      )) {
        if (inside(r) &&
            (sources == null ||
                sources.any((s) => s.index == r['source'] as int))) {
          keys.add((r['kind'] as int, r['id'] as String));
        }
      }
      if (withSamples) {
        for (final r in _db.select(
          'SELECT rowid AS rid, lat, lon FROM sample WHERE $where',
          args,
        )) {
          if (inside(r)) sampleRows.add(r['rid'] as int);
        }
      }
    }
    if (!dryRun && (keys.isNotEmpty || sampleRows.isNotEmpty)) {
      final delT = _db.prepare(
        'DELETE FROM transmitter WHERE kind = ? AND id = ?',
      );
      final delS = _db.prepare('DELETE FROM sample WHERE rowid = ?');
      try {
        transaction(() {
          for (final (kind, id) in keys) {
            delT.execute([kind, id]);
          }
          for (final rid in sampleRows) {
            delS.execute([rid]);
          }
        });
      } finally {
        delT.dispose();
        delS.dispose();
      }
    }
    return (keys.length, sampleRows.length);
  }

  /// Bulk lookup: returns the known records among [ids], keyed by id.
  Map<String, TransmitterRecord> lookup(
    TransmitterKind kind,
    Iterable<String> ids,
  ) {
    final out = <String, TransmitterRecord>{};
    final list = ids.toSet().toList();
    const chunk = 500; // stay far below SQLITE_MAX_VARIABLE_NUMBER
    for (var i = 0; i < list.length; i += chunk) {
      final part = list.sublist(i, math.min(i + chunk, list.length));
      final marks = List.filled(part.length, '?').join(',');
      final rows = _db.select(
        'SELECT * FROM transmitter WHERE kind = ? AND id IN ($marks)',
        [kind.index, ...part],
      );
      for (final r in rows) {
        final rec = _row(r);
        out[rec.id] = rec;
      }
    }
    return out;
  }

  TransmitterRecord? get(TransmitterKind kind, String id) =>
      lookup(kind, [id])[id];

  /// Records inside a bounding box (uses the lat/lon index).
  List<TransmitterRecord> inBounds({
    required double south,
    required double west,
    required double north,
    required double east,
    TransmitterKind? kind,
    int limit = 5000,
  }) {
    final rows = _db.select(
      'SELECT * FROM transmitter WHERE lat BETWEEN ? AND ? '
      'AND lon BETWEEN ? AND ? ${kind == null ? '' : 'AND kind = ?'} LIMIT ?',
      [south, north, west, east, if (kind != null) kind.index, limit],
    );
    return rows.map(_row).toList();
  }

  /// Runs [body] in one transaction.
  T transaction<T>(T Function() body) {
    _db.execute('BEGIN');
    try {
      final r = body();
      _db.execute('COMMIT');
      return r;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Inserts or replaces position records from an external source (import or
  /// online lookup). A record from a more trusted source (lower
  /// [TransmitterSource] index, e.g. our own wardriving) is kept; returns the
  /// number of rows written.
  int upsertExternal(Iterable<TransmitterRecord> records) {
    final stmt = _db.prepare('''
      INSERT INTO transmitter(kind, id, lat, lon, accuracy, samples, wsum,
                              scatter, best_signal, source, updated)
      VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
      ON CONFLICT(kind, id) DO UPDATE SET
        lat = excluded.lat, lon = excluded.lon, accuracy = excluded.accuracy,
        samples = excluded.samples, wsum = excluded.wsum,
        scatter = excluded.scatter, best_signal = excluded.best_signal,
        source = excluded.source, updated = excluded.updated,
        seed_source = NULL
      WHERE excluded.source <= transmitter.source''');
    final clear = _db.prepare('DELETE FROM unknown WHERE kind = ? AND id = ?');
    var n = 0;
    try {
      transaction(() {
        for (final r in records) {
          if (!_plausible(r.lat, r.lon)) continue;
          stmt.execute([
            r.kind.index,
            r.id,
            r.lat,
            r.lon,
            r.accuracyM,
            r.samples,
            r.weightSum,
            r.scatterM2,
            r.bestSignalDbm,
            r.source.index,
            r.updated.millisecondsSinceEpoch ~/ 1000,
          ]);
          n += _db.updatedRows;
          clear.execute([r.kind.index, r.id]);
        }
      });
    } finally {
      stmt.dispose();
      clear.dispose();
    }
    return n;
  }

  static bool _plausible(double lat, double lon) =>
      lat.isFinite &&
      lon.isFinite &&
      lat.abs() <= 90 &&
      lon.abs() <= 180 &&
      !(lat == 0 && lon == 0);

  /// Merges wardriving samples into the running position estimates.
  ///
  /// Each transmitter keeps a weighted mean position plus the weighted
  /// scatter of the sample positions around it (Welford's incremental
  /// update), so no raw points are needed. The stored accuracy is
  /// `sqrt(scatter / wsum + bestRange^2)` (where we stood, spread, plus how
  /// far the transmitter was at best), floored per kind. With
  /// [keepRawSamples] the raw points are also appended to the `sample`
  /// table for later re-processing.
  ///
  /// A record from an external source is used as a weak prior (weight of
  /// one typical sample) and then becomes a wardriving record. A sample far
  /// beyond [wifiMovedThresholdM] / [cellMovedThresholdM] restarts the
  /// estimate: the transmitter has moved.
  void addSamples(
    Iterable<TransmitterSample> samples, {
    bool keepRawSamples = false,
  }) {
    final sel = _db.prepare(
      'SELECT lat, lon, samples, wsum, scatter, best_signal, best_range, '
      'source, seed_source FROM transmitter WHERE kind = ? AND id = ?',
    );
    final put = _db.prepare('''
      INSERT OR REPLACE INTO transmitter(kind, id, lat, lon, accuracy, samples,
        wsum, scatter, best_signal, best_range, source, updated, seed_source)
      VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''');
    final raw = keepRawSamples
        ? _db.prepare('INSERT INTO sample VALUES(?, ?, ?, ?, ?, ?, ?)')
        : null;
    try {
      transaction(() {
        for (final s in samples) {
          if (!_plausible(s.lat, s.lon) || !(s.weight > 0)) continue;
          final t = s.time.millisecondsSinceEpoch ~/ 1000;
          raw?.execute([
            s.kind.index,
            s.id,
            s.lat,
            s.lon,
            s.fixAccuracyM,
            s.signalDbm,
            t,
          ]);
          final isCell = s.kind == TransmitterKind.cell;
          final floor = isCell ? minCellAccuracyM : minWifiAccuracyM;
          final moved = isCell ? cellMovedThresholdM : wifiMovedThresholdM;
          final rows = sel.select([s.kind.index, s.id]);

          var lat = s.lat, lon = s.lon;
          var n = 1;
          var wsum = s.weight;
          var scatter = s.weight * s.fixAccuracyM * s.fixAccuracyM;
          var bestSignal = s.signalDbm;
          var bestRange = s.rangeM;
          // Null unless the estimate continues from an external record.
          int? seed;

          if (rows.isNotEmpty) {
            final r = rows.first;
            final oLat = (r['lat'] as num).toDouble();
            final oLon = (r['lon'] as num).toDouble();
            final dist = haversineM(oLat, oLon, s.lat, s.lon);
            if (dist <= moved) {
              var oW = (r['wsum'] as num).toDouble();
              var oScatter = (r['scatter'] as num).toDouble();
              var oN = r['samples'] as int;
              if (r['source'] != TransmitterSource.wardriving.index) {
                // External record: weak prior worth one sample like this one.
                oW = s.weight;
                oScatter = 0;
                oN = 1;
                seed = r['source'] as int;
              } else {
                seed = r['seed_source'] as int?;
              }
              final proj = LocalProjection(oLat, oLon);
              final dx = proj.x(s.lon), dy = proj.y(s.lat);
              wsum = oW + s.weight;
              final f = s.weight / wsum;
              final mx = dx * f, my = dy * f;
              // Welford: S += w * (x - oldMean) . (x - newMean)
              scatter =
                  oScatter +
                  s.weight * (dx * (dx - mx) + dy * (dy - my)) +
                  s.weight * s.fixAccuracyM * s.fixAccuracyM;
              lat = proj.lat(my);
              lon = proj.lon(mx);
              n = oN + 1;
              final oSig = (r['best_signal'] as num?)?.toDouble();
              if (oSig != null && (bestSignal == null || oSig > bestSignal)) {
                bestSignal = oSig;
              }
              final oRange = (r['best_range'] as num?)?.toDouble();
              if (oRange != null && (bestRange == null || oRange < bestRange)) {
                bestRange = oRange;
              }
            }
          }
          final range = bestRange ?? 0;
          var acc = math.sqrt(scatter / wsum + range * range);
          if (acc < floor) acc = floor;
          put.execute([
            s.kind.index,
            s.id,
            lat,
            lon,
            acc,
            n,
            wsum,
            scatter,
            bestSignal,
            bestRange,
            TransmitterSource.wardriving.index,
            t,
            seed,
          ]);
        }
      });
    } finally {
      sel.dispose();
      put.dispose();
      raw?.dispose();
    }
  }

  /// Remembers that online services do not know [ids].
  void markUnknown(TransmitterKind kind, Iterable<String> ids, DateTime now) {
    final stmt = _db.prepare('INSERT OR REPLACE INTO unknown VALUES(?, ?, ?)');
    try {
      transaction(() {
        for (final id in ids) {
          stmt.execute([kind.index, id, now.millisecondsSinceEpoch ~/ 1000]);
        }
      });
    } finally {
      stmt.dispose();
    }
  }

  /// Subset of [ids] that was reported unknown within [negativeCacheTtl].
  Set<String> recentlyUnknown(
    TransmitterKind kind,
    Iterable<String> ids,
    DateTime now,
  ) {
    final list = ids.toSet().toList();
    final out = <String>{};
    final since = now.subtract(negativeCacheTtl).millisecondsSinceEpoch ~/ 1000;
    for (var i = 0; i < list.length; i += 500) {
      final part = list.sublist(i, math.min(i + 500, list.length));
      final rows = _db.select(
        'SELECT id FROM unknown WHERE kind = ? AND checked >= ? AND id IN '
        '(${List.filled(part.length, '?').join(',')})',
        [kind.index, since, ...part],
      );
      out.addAll(rows.map((r) => r['id'] as String));
    }
    return out;
  }

  /// Deletes every record that came from [source]; returns the row count.
  int deleteBySource(TransmitterSource source) {
    _db.execute('DELETE FROM transmitter WHERE source = ?', [source.index]);
    return _db.updatedRows;
  }

  DbStats stats() {
    final byKind = <int, int>{};
    final bySource = <TransmitterSource, int>{};
    for (final r in _db.select(
      'SELECT kind, source, COUNT(*) AS n FROM transmitter '
      'GROUP BY kind, source',
    )) {
      final n = r['n'] as int;
      byKind[r['kind'] as int] = (byKind[r['kind'] as int] ?? 0) + n;
      final src = TransmitterSource.values[r['source'] as int];
      bySource[src] = (bySource[src] ?? 0) + n;
    }
    final raw =
        _db.select('SELECT COUNT(*) AS n FROM sample').first['n'] as int;
    var bytes = 0;
    final p = path;
    if (p != null) {
      try {
        bytes = File(p).lengthSync();
      } on FileSystemException {
        bytes = 0;
      }
    }
    return DbStats(
      wifi: byKind[TransmitterKind.wifi.index] ?? 0,
      cells: byKind[TransmitterKind.cell.index] ?? 0,
      ble: byKind[TransmitterKind.ble.index] ?? 0,
      bySource: bySource,
      rawSamples: raw,
      fileBytes: bytes,
    );
  }

  void close() => _db.dispose();
}
