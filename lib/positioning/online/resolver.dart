/// Online resolution of unknown transmitters into the local database, and
/// region preloading for offline use.
library;

import 'dart:async';
import 'dart:math' as math;

import '../geo.dart';
import '../location_db.dart';
import '../models.dart';
import 'apple_wps.dart';
import 'beacondb.dart';

/// Geographic bounding box.
class GeoBounds {
  const GeoBounds({
    required this.south,
    required this.west,
    required this.north,
    required this.east,
  });

  /// Box of [radiusM] around a point.
  factory GeoBounds.around(double lat, double lon, double radiusM) {
    final dLat = radToDeg(radiusM / earthRadiusM);
    final dLon = dLat / math.cos(degToRad(lat)).abs().clamp(0.01, 1.0);
    return GeoBounds(
      south: lat - dLat,
      west: lon - dLon,
      north: lat + dLat,
      east: lon + dLon,
    );
  }

  final double south, west, north, east;

  bool contains(double lat, double lon) =>
      lat >= south && lat <= north && lon >= west && lon <= east;
}

/// Progress / result of [OnlineResolver.preloadRegion].
class PreloadProgress {
  PreloadProgress();

  /// Requests sent so far.
  int requests = 0;

  /// Distinct APs stored (inside the region).
  int stored = 0;

  /// Grid cells of the region already expanded / still queued.
  int cellsDone = 0;
  int cellsQueued = 0;

  /// Why the run ended: `complete`, `requestCap`, `apCap`, `cancelled`,
  /// `noSeeds` or `errors`.
  String? finished;

  @override
  String toString() =>
      'Preload(requests $requests, stored $stored, cells $cellsDone done / '
      '$cellsQueued queued, ${finished ?? 'running'})';
}

/// Resolves transmitters through the key-less online services and caches
/// every answer in the [LocationDb]:
///  * Wi-Fi BSSIDs -> Apple WPS (which also returns up to ~400 neighbours);
///  * cells -> beaconDB, one cell per request so the answer is that cell's
///    own position and range;
///  * whole-scan fallback -> beaconDB geolocate (not cacheable per AP).
///
/// Ids the services do not know go to a negative cache
/// ([negativeCacheTtl]). Requests are spaced by [minInterval].
class OnlineResolver {
  OnlineResolver(
    this.db, {
    AppleWps? apple,
    BeaconDb? beaconDb,
    this.minInterval = const Duration(seconds: 1),
    DateTime Function()? now,
  }) : apple = apple ?? AppleWps(),
       beaconDb = beaconDb ?? BeaconDb(),
       _now = now ?? DateTime.now;

  final LocationDb db;
  final AppleWps apple;
  final BeaconDb beaconDb;
  final Duration minInterval;
  final DateTime Function() _now;

  DateTime? _lastRequest;
  Future<void> _chain = Future.value();

  /// When set, [preloadRegion] never uses a transmitter whose stored
  /// position is private as a seed: naming it in a request would tell the
  /// service that this device cares about that place. (The automatic
  /// lookups are gated by the engine, which knows where the device is.)
  PrivacyFilter? privacyFilter;

  /// Counters for diagnostics.
  int requests = 0;
  int failures = 0;
  String? lastError;

  /// Serialises requests and enforces [minInterval] between them.
  Future<T> _throttled<T>(Future<T> Function() request) {
    final c = Completer<T>();
    _chain = _chain.then((_) async {
      final last = _lastRequest;
      if (last != null) {
        final wait = minInterval - DateTime.now().difference(last);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      try {
        requests++;
        c.complete(await request());
      } on Object catch (e, st) {
        c.completeError(e, st);
      } finally {
        _lastRequest = DateTime.now();
      }
    });
    return c.future;
  }

  int _storeApple(List<AppleWifiLocation> found, {GeoBounds? within}) {
    final stamp = _now();
    return db.upsertExternal([
      for (final a in found)
        if (within == null || within.contains(a.lat, a.lon))
          TransmitterRecord(
            kind: TransmitterKind.wifi,
            id: a.bssid,
            lat: a.lat,
            lon: a.lon,
            accuracyM: a.accuracyM,
            source: TransmitterSource.apple,
            updated: stamp,
          ),
    ]);
  }

  /// Resolves the BSSIDs of [scan] that are neither in the database nor in
  /// the negative cache. One request: the strongest unknown AP goes first so
  /// Apple returns its neighbourhood, which usually covers the next scans
  /// too. Returns the number of records written.
  Future<int> resolveWifi(List<WifiObservation> scan) async {
    final candidates =
        [
          for (final o in scan)
            if (!o.optedOut) o,
        ]..sort(
          (a, b) => (b.effectiveDbm ?? -200).compareTo(a.effectiveDbm ?? -200),
        );
    final ids = candidates.map((o) => o.bssid).toList();
    if (ids.isEmpty) return 0;
    final known = db.lookup(TransmitterKind.wifi, ids);
    final skip = db.recentlyUnknown(TransmitterKind.wifi, ids, _now());
    final ask = [
      for (final id in ids)
        if (!known.containsKey(id) && !skip.contains(id)) id,
    ];
    if (ask.isEmpty) return 0;
    final r = await _throttled(() => apple.lookup(ask));
    if (!r.ok) {
      failures++;
      lastError = 'apple: ${r.error}';
      return 0;
    }
    final written = _storeApple(r.found);
    final got = {for (final a in r.found) a.bssid};
    // Only what Apple explicitly reported unknown (or silently dropped from
    // a successful answer) is negative-cached.
    db.markUnknown(TransmitterKind.wifi, [
      for (final id in ask.take(AppleWps.maxBssidsPerRequest))
        if (!got.contains(id)) id,
    ], _now());
    return written;
  }

  /// Resolves unknown cells with a full identity through beaconDB, at most
  /// [maxRequests] per call. Returns the number of records written.
  Future<int> resolveCells(
    List<CellObservation> cells, {
    int maxRequests = 4,
  }) async {
    final byKey = <String, CellObservation>{
      for (final c in cells)
        if (c.key != null) c.key!: c,
    };
    if (byKey.isEmpty) return 0;
    final known = db.lookup(TransmitterKind.cell, byKey.keys);
    final skip = db.recentlyUnknown(TransmitterKind.cell, byKey.keys, _now());
    var written = 0, sent = 0;
    for (final e in byKey.entries) {
      if (known.containsKey(e.key) || skip.contains(e.key)) continue;
      if (sent++ >= maxRequests) break;
      // Strip measurements: we want the cell's own position, and there is no
      // reason to tell the service how strong it is here.
      final bare = CellObservation(
        radio: e.value.radio,
        mcc: e.value.mcc,
        mnc: e.value.mnc,
        area: e.value.area,
        cellId: e.value.cellId,
      );
      final r = await _throttled(() => beaconDb.geolocate(cells: [bare]));
      final fix = r.fix;
      if (fix != null) {
        written += db.upsertExternal([
          TransmitterRecord(
            kind: TransmitterKind.cell,
            id: e.key,
            lat: fix.lat,
            lon: fix.lon,
            accuracyM: fix.accuracyM,
            source: TransmitterSource.beacondb,
            updated: _now(),
          ),
        ]);
      } else if (r.notFound) {
        db.markUnknown(TransmitterKind.cell, [e.key], _now());
      } else {
        failures++;
        lastError = 'beacondb: ${r.error}';
        break; // network trouble: stop for now
      }
    }
    return written;
  }

  /// Asks beaconDB to locate a whole scan. Used when the local database
  /// cannot produce a fix. Needs at least two APs or one cell.
  Future<PositionEstimate?> geolocate({
    List<WifiObservation> wifi = const [],
    List<CellObservation> cells = const [],
  }) async {
    final aps = wifi.where((o) => !o.optedOut).toList();
    final towers = cells.where((c) => c.hasFullId).toList();
    if (aps.length < 2 && towers.isEmpty) return null;
    final r = await _throttled(
      () => beaconDb.geolocate(
        wifi: aps.length >= 2 ? aps : const [],
        cells: towers,
      ),
    );
    final fix = r.fix;
    if (fix == null) {
      if (!r.notFound) {
        failures++;
        lastError = 'beacondb: ${r.error}';
      }
      return null;
    }
    // Accuracies of a few hundred metres and better can only come from Wi-Fi.
    final fromWifi = aps.length >= 2 && fix.accuracyM < 300;
    return PositionEstimate(
      lat: fix.lat,
      lon: fix.lon,
      accuracyM: math.max(fix.accuracyM, 25),
      source: fromWifi ? PositionSource.wifi : PositionSource.cell,
      timestamp: _now(),
      transmittersUsed: fromWifi ? aps.length : towers.length,
    );
  }

  /// Pre-caches the Wi-Fi APs of [bounds] for offline use by "snowballing"
  /// through Apple WPS: each request returns the neighbourhood (about 300 m)
  /// of one seed AP; new APs inside the region become seeds for areas that
  /// were not expanded yet.
  ///
  /// The region is divided into a grid of [gridM] metre cells and at most
  /// one seed per cell is expanded (the known AP nearest to the cell
  /// centre), so the number of requests is bounded by the region area /
  /// gridM^2, by [maxRequests] (hard cap) and by [maxAps]. Requests are
  /// spaced by [minInterval] (default 1/s).
  ///
  /// The default grid of 150 m matches what the service returns in a dense
  /// city (400 APs = everything within roughly 100-200 m of the seed,
  /// measured live in Berlin on 2026-11-26): about 45 requests per km^2.
  ///
  /// [seeds] are BSSIDs believed to be inside the region (e.g. the current
  /// scan); APs already in the database inside [bounds] are used as seeds as
  /// well. Coverage is best-effort: areas not connected to a seed through
  /// chains of known APs (rivers, parks, gaps > ~300 m) are not reached.
  Future<PreloadProgress> preloadRegion(
    GeoBounds bounds, {
    Iterable<String> seeds = const [],
    int maxRequests = 300,
    int maxAps = 100000,
    double gridM = 150,
    int maxConsecutiveErrors = 3,
    void Function(PreloadProgress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final progress = PreloadProgress();
    final midLat = (bounds.south + bounds.north) / 2;
    final proj = LocalProjection(midLat, (bounds.west + bounds.east) / 2);
    (int, int) cellIndex(double lat, double lon) =>
        ((proj.x(lon) / gridM).floor(), (proj.y(lat) / gridM).floor());
    String cellOf(double lat, double lon) {
      final (ix, iy) = cellIndex(lat, lon);
      return '$ix,$iy';
    }

    final expanded = <String>{}; // grid cells already expanded
    // Grid cell -> best seed so far and its distance to the cell centre.
    // Seeding from the AP nearest to the centre matters: Apple lists the
    // neighbours of the seed, so a seed at the edge of a cell mostly returns
    // what the adjacent cell already gave us.
    final queued = <String, (String, double)>{};
    final blind = <String>[]; // seeds with unknown position
    final asked = <String>{};
    final storedIds = <String>{};

    void offer(String bssid, double lat, double lon) {
      if (!bounds.contains(lat, lon) || asked.contains(bssid)) return;
      if (privacyFilter?.call(lat, lon, 0) ?? false) return;
      final (ix, iy) = cellIndex(lat, lon);
      final cell = '$ix,$iy';
      if (expanded.contains(cell)) return;
      final dx = proj.x(lon) - (ix + 0.5) * gridM;
      final dy = proj.y(lat) - (iy + 0.5) * gridM;
      final d = dx * dx + dy * dy;
      final current = queued[cell];
      if (current == null || d < current.$2) queued[cell] = (bssid, d);
    }

    for (final rec in db.inBounds(
      south: bounds.south,
      west: bounds.west,
      north: bounds.north,
      east: bounds.east,
      kind: TransmitterKind.wifi,
      limit: 20000,
    )) {
      offer(rec.id, rec.lat, rec.lon);
    }
    for (final s in seeds) {
      final id = normalizeMac(s);
      if (id == null) continue;
      final rec = db.get(TransmitterKind.wifi, id);
      if (rec != null) {
        offer(id, rec.lat, rec.lon);
      } else {
        blind.add(id);
      }
    }

    var errors = 0;
    while (true) {
      progress
        ..cellsDone = expanded.length
        ..cellsQueued = queued.length;
      onProgress?.call(progress);
      if (isCancelled?.call() ?? false) {
        progress.finished = 'cancelled';
        break;
      }
      if (progress.requests >= maxRequests) {
        progress.finished = 'requestCap';
        break;
      }
      if (storedIds.length >= maxAps) {
        progress.finished = 'apCap';
        break;
      }
      String seed;
      String? seedCell;
      if (blind.isNotEmpty) {
        seed = blind.removeLast();
      } else if (queued.isNotEmpty) {
        seedCell = queued.keys.first;
        seed = queued.remove(seedCell)!.$1;
      } else {
        progress.finished = progress.requests == 0 ? 'noSeeds' : 'complete';
        break;
      }
      if (!asked.add(seed)) continue;
      final r = await _throttled(() => apple.lookup([seed]));
      progress.requests++;
      if (!r.ok) {
        failures++;
        lastError = 'apple: ${r.error}';
        if (++errors >= maxConsecutiveErrors) {
          progress.finished = 'errors';
          break;
        }
        continue;
      }
      errors = 0;
      if (seedCell != null) expanded.add(seedCell);
      for (final a in r.found) {
        if (a.bssid == seed) expanded.add(cellOf(a.lat, a.lon));
      }
      _storeApple(r.found, within: bounds);
      for (final a in r.found) {
        if (bounds.contains(a.lat, a.lon)) storedIds.add(a.bssid);
        offer(a.bssid, a.lat, a.lon);
      }
      queued.removeWhere((cell, _) => expanded.contains(cell));
      progress.stored = storedIds.length;
    }
    progress
      ..cellsDone = expanded.length
      ..cellsQueued = queued.length;
    onProgress?.call(progress);
    return progress;
  }

  void close() {
    apple.close();
    beaconDb.close();
  }
}
