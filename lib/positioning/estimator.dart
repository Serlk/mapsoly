/// Radio position estimator: current Wi-Fi / cell observations plus known
/// transmitter positions -> [PositionEstimate].
library;

import 'dart:math' as math;

import 'geo.dart';
import 'location_db.dart';
import 'models.dart';
import 'signal_model.dart';

/// Tunables of the radio estimator. Rationale for every constant is in
/// docs/positioning.md.
class EstimatorConfig {
  const EstimatorConfig({
    this.model = const PathLossModel(),
    this.maxWifiAge = const Duration(seconds: 30),
    this.clusterRadiusM = 250,
    this.modelNoiseM = 20,
    this.accuracyScale = 1.5,
    this.minWifiAccuracyM = 15,
    this.minCellSigmaM = 300,
    this.neighbourCellPenalty = 1.5,
    this.minCellAccuracyM = 150,
  });

  final PathLossModel model;

  /// APs last heard longer ago than this are ignored.
  final Duration maxWifiAge;

  /// An AP further than this (plus its own stored accuracy) from the
  /// weighted median of all heard APs is an outlier: Wi-Fi does not carry
  /// further, so it has moved or is a mobile hotspot.
  final double clusterRadiusM;

  /// Irreducible error of the "we are near this AP" assumption, metres.
  final double modelNoiseM;

  /// Safety factor on the formal inverse-variance accuracy; AP errors are
  /// correlated (same buildings, same wardriving tracks), so the formal
  /// value is optimistic.
  final double accuracyScale;
  final double minWifiAccuracyM;

  /// Smallest uncertainty assumed for a cell without timing advance.
  final double minCellSigmaM;

  /// Neighbour cells are weaker evidence than the serving cell.
  final double neighbourCellPenalty;
  final double minCellAccuracyM;
}

/// Everything the estimator derived from one set of observations.
class RadioEstimate {
  const RadioEstimate({
    this.wifi,
    this.cell,
    this.best,
    this.wifiSeen = 0,
    this.wifiKnown = 0,
    this.wifiUsed = 0,
    this.wifiRejected = 0,
    this.cellsSeen = 0,
    this.cellsKnown = 0,
    this.wifiCellConflict = false,
  });

  /// Wi-Fi-only estimate, null when impossible.
  final PositionEstimate? wifi;

  /// Cell-only estimate, null when impossible.
  final PositionEstimate? cell;

  /// The estimate to use: Wi-Fi when available and consistent with the
  /// cells, otherwise the cell estimate.
  final PositionEstimate? best;

  final int wifiSeen;
  final int wifiKnown;
  final int wifiUsed;

  /// APs dropped as outliers.
  final int wifiRejected;
  final int cellsSeen;
  final int cellsKnown;

  /// True when the Wi-Fi estimate was discarded because it contradicts the
  /// cell estimate (travelling hotspots, stale database).
  final bool wifiCellConflict;
}

class _Ap {
  _Ap(this.x, this.y, this.sigma2, this.recAcc);
  final double x, y, sigma2, recAcc;
  double get w => 1 / sigma2;
}

/// Stateless estimator.
class RadioEstimator {
  const RadioEstimator({this.config = const EstimatorConfig()});

  final EstimatorConfig config;

  /// Convenience: looks the transmitters up in [db] and estimates.
  RadioEstimate estimate({
    required LocationDb db,
    List<WifiObservation> wifi = const [],
    List<CellObservation> cells = const [],
    required DateTime now,
  }) {
    final wifiDb = db.lookup(TransmitterKind.wifi, wifi.map((o) => o.bssid));
    final cellDb = db.lookup(TransmitterKind.cell, [
      for (final c in cells)
        if (c.key != null) c.key!,
    ]);
    return estimateWith(
      wifi: wifi,
      cells: cells,
      wifiDb: wifiDb,
      cellDb: cellDb,
      now: now,
    );
  }

  /// Estimates from observations and already looked-up records.
  RadioEstimate estimateWith({
    List<WifiObservation> wifi = const [],
    List<CellObservation> cells = const [],
    Map<String, TransmitterRecord> wifiDb = const {},
    Map<String, TransmitterRecord> cellDb = const {},
    required DateTime now,
  }) {
    final w = _wifi(wifi, wifiDb, now);
    final c = estimateCells(cells, cellDb, now);
    var best = w.$1 ?? c;
    var conflict = false;
    final we = w.$1;
    if (we != null && c != null) {
      final d = haversineM(we.lat, we.lon, c.lat, c.lon);
      // The cell estimate is coarse but hard to fool; Wi-Fi far outside the
      // cell's plausible area is wrong.
      if (d > 3 * c.accuracyM + we.accuracyM + 500) {
        best = c;
        conflict = true;
      }
    }
    return RadioEstimate(
      wifi: we,
      cell: c,
      best: best,
      wifiSeen: wifi.length,
      wifiKnown: w.$2,
      wifiUsed: we?.transmittersUsed ?? 0,
      wifiRejected: w.$3,
      cellsSeen: cells.length,
      cellsKnown: cells.where((x) => cellDb.containsKey(x.key)).length,
      wifiCellConflict: conflict,
    );
  }

  /// Wi-Fi estimate only (see [RadioEstimate.wifi]).
  PositionEstimate? estimateWifi(
    List<WifiObservation> scan,
    Map<String, TransmitterRecord> known,
    DateTime now,
  ) => _wifi(scan, known, now).$1;

  /// Returns (estimate, known count, rejected count).
  (PositionEstimate?, int, int) _wifi(
    List<WifiObservation> scan,
    Map<String, TransmitterRecord> known,
    DateTime now,
  ) {
    // Strongest observation per BSSID, fresh and known.
    final byId = <String, WifiObservation>{};
    for (final o in scan) {
      if (o.age > config.maxWifiAge || o.optedOut) continue;
      if (!known.containsKey(o.bssid)) continue;
      final prev = byId[o.bssid];
      if (prev == null ||
          (o.effectiveDbm ?? -200) > (prev.effectiveDbm ?? -200)) {
        byId[o.bssid] = o;
      }
    }
    if (byId.isEmpty) return (null, 0, 0);

    final first = known[byId.keys.first]!;
    final proj = LocalProjection(first.lat, first.lon);
    var aps = <_Ap>[];
    var ageSumMs = 0;
    for (final o in byId.values) {
      final rec = known[o.bssid]!;
      final d = config.model.wifiDistanceM(
        o.effectiveDbm ?? unknownWifiDbm,
        frequencyMhz: o.frequencyMhz,
      );
      aps.add(
        _Ap(
          proj.x(rec.lon),
          proj.y(rec.lat),
          d * d +
              rec.accuracyM * rec.accuracyM +
              config.modelNoiseM * config.modelNoiseM,
          rec.accuracyM,
        ),
      );
      ageSumMs += o.age.inMilliseconds;
    }
    final knownCount = aps.length;

    // Outlier rejection around the weighted median.
    var rejected = 0;
    if (aps.length >= 3) {
      final ws = [for (final a in aps) a.w];
      final mx = weightedMedian([for (final a in aps) a.x], ws);
      final my = weightedMedian([for (final a in aps) a.y], ws);
      final kept = [
        for (final a in aps)
          if (_dist(a.x - mx, a.y - my) <= config.clusterRadiusM + a.recAcc) a,
      ];
      rejected = aps.length - kept.length;
      if (kept.isEmpty) return (null, knownCount, rejected);
      aps = kept;
    } else if (aps.length == 2) {
      final d = _dist(aps[0].x - aps[1].x, aps[0].y - aps[1].y);
      if (d > 2 * config.clusterRadiusM + aps[0].recAcc + aps[1].recAcc) {
        // Two APs that cannot be heard from one place and no majority to
        // tell which one is wrong: refuse rather than guess.
        return (null, knownCount, 2);
      }
    }

    var sw = 0.0, sx = 0.0, sy = 0.0;
    for (final a in aps) {
      sw += a.w;
      sx += a.w * a.x;
      sy += a.w * a.y;
    }
    final x = sx / sw, y = sy / sw;
    var spread2 = 0.0;
    for (final a in aps) {
      final dx = a.x - x, dy = a.y - y;
      spread2 += a.w * (dx * dx + dy * dy);
    }
    spread2 /= sw;
    final formal = config.accuracyScale * math.sqrt(1 / sw);
    var acc = math.sqrt(formal * formal + spread2 / aps.length);
    if (acc < config.minWifiAccuracyM) acc = config.minWifiAccuracyM;

    return (
      PositionEstimate(
        lat: proj.lat(y),
        lon: proj.lon(x),
        accuracyM: acc,
        source: PositionSource.wifi,
        timestamp: now.subtract(Duration(milliseconds: ageSumMs ~/ knownCount)),
        transmittersUsed: aps.length,
      ),
      knownCount,
      rejected,
    );
  }

  /// Uncertainty (metres) of "we are at this cell's stored position".
  ///
  /// The stored position is where the cell is *heard* (centroid), not the
  /// mast, and [TransmitterRecord.accuracyM] is its coverage radius.
  ///  * Without timing advance: the coverage radius, at least
  ///    [EstimatorConfig.minCellSigmaM].
  ///  * With timing advance: `sqrt(range^2 + (radius/2)^2) + unit/2`, i.e.
  ///    the measured distance to the mast, the unknown offset between mast
  ///    and stored centroid, and half a quantisation step.
  double cellSigmaM(CellObservation c, TransmitterRecord rec) {
    final range = timingAdvanceMeters(c.radio, c.timingAdvance);
    double sigma;
    if (c.serving && range != null) {
      final unit = timingAdvanceUnitMeters(c.radio)!;
      sigma =
          math.sqrt(range * range + rec.accuracyM * rec.accuracyM / 4) +
          unit / 2;
      if (sigma < config.minCellAccuracyM) sigma = config.minCellAccuracyM;
    } else {
      sigma = math.max(rec.accuracyM, config.minCellSigmaM);
    }
    if (!c.serving) sigma *= config.neighbourCellPenalty;
    return sigma;
  }

  /// Cell-only estimate: inverse-variance weighted mean of the known cells.
  ///
  /// The accuracy is `max(0.6 * min(sigma), sqrt(1 / sum(1/sigma^2)))`:
  /// several cells often sit on the same mast, so their errors are far from
  /// independent and the result is never claimed to be much better than the
  /// best single cell.
  PositionEstimate? estimateCells(
    List<CellObservation> cells,
    Map<String, TransmitterRecord> known,
    DateTime now,
  ) {
    final seen = <String>{};
    final items = <(TransmitterRecord, double)>[];
    for (final c in cells) {
      final key = c.key;
      if (key == null || !seen.add(key)) continue;
      final rec = known[key];
      if (rec == null) continue;
      items.add((rec, cellSigmaM(c, rec)));
    }
    if (items.isEmpty) return null;
    final proj = LocalProjection(items.first.$1.lat, items.first.$1.lon);
    var sw = 0.0, sx = 0.0, sy = 0.0, minSigma = double.infinity;
    for (final (rec, sigma) in items) {
      final w = 1 / (sigma * sigma);
      sw += w;
      sx += w * proj.x(rec.lon);
      sy += w * proj.y(rec.lat);
      if (sigma < minSigma) minSigma = sigma;
    }
    final acc = math.max(0.6 * minSigma, math.sqrt(1 / sw));
    return PositionEstimate(
      lat: proj.lat(sy / sw),
      lon: proj.lon(sx / sw),
      accuracyM: math.max(acc, config.minCellAccuracyM),
      source: PositionSource.cell,
      timestamp: now,
      transmittersUsed: items.length,
    );
  }

  static double _dist(double dx, double dy) => math.sqrt(dx * dx + dy * dy);
}
