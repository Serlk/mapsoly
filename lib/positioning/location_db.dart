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

  static const int schemaVersion = 1;

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
        PRIMARY KEY(kind, id)
      ) WITHOUT ROWID''');
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
  );

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
        source = excluded.source, updated = excluded.updated
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
      'source FROM transmitter WHERE kind = ? AND id = ?',
    );
    final put = _db.prepare('''
      INSERT OR REPLACE INTO transmitter(kind, id, lat, lon, accuracy, samples,
        wsum, scatter, best_signal, best_range, source, updated)
      VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''');
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
