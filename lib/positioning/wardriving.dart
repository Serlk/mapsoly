/// Wardriving collector: while a trustworthy GNSS fix is available, turns
/// radio observations into transmitter position samples.
library;

import 'dart:math' as math;

import 'geo.dart';
import 'location_db.dart';
import 'models.dart';
import 'signal_model.dart';

/// Tunables of the collector.
class WardrivingConfig {
  const WardrivingConfig({
    this.maxFixAccuracyM = 25,
    this.maxFixGap = const Duration(seconds: 3),
    this.maxSpeedMps = 45,
    this.maxObservationAge = const Duration(seconds: 12),
    this.minSampleSpacingM = 5,
    this.keepRawSamples = false,
  });

  /// Fixes worse than this are not used.
  final double maxFixAccuracyM;

  /// The observation time must be within this of a GNSS fix (or between two
  /// fixes no further apart than twice this).
  final Duration maxFixGap;

  /// Above this speed (162 km/h) scan timing errors dominate; skip.
  final double maxSpeedMps;

  /// Observations older than this are dropped: their position is too stale.
  final Duration maxObservationAge;

  /// A transmitter is not sampled again until we moved this far (or its
  /// signal improved), so standing still does not pile up identical samples.
  final double minSampleSpacingM;

  /// Also store raw samples in the `sample` table.
  final bool keepRawSamples;
}

class _Last {
  _Last(this.lat, this.lon, this.dbm);
  double lat, lon;
  double? dbm;
}

/// Feeds the location database from GNSS + radio observations.
///
/// The caller is responsible for only passing fixes that passed the GNSS
/// sanity check (the engine does). A spoofed fix would poison the database,
/// so [addFix] additionally drops fixes that are invalid or too inaccurate.
class WardrivingCollector {
  WardrivingCollector(
    this.db, {
    this.config = const WardrivingConfig(),
    this.model = const PathLossModel(),
  });

  final LocationDb db;
  final WardrivingConfig config;
  final PathLossModel model;

  final List<GnssFix> _fixes = [];
  final Map<String, _Last> _last = {};

  /// Samples written since creation.
  int samplesWritten = 0;

  /// Forgets buffered fixes (call when GNSS becomes untrusted).
  void reset() => _fixes.clear();

  /// Buffers a trusted fix.
  void addFix(GnssFix fix) {
    final acc = fix.accuracyM;
    if (!fix.hasPosition || acc == null || acc > config.maxFixAccuracyM) {
      return;
    }
    final v = fix.speedMps;
    if (v != null && v > config.maxSpeedMps) return;
    _fixes.add(fix);
    final cutoff = fix.receivedAt.subtract(const Duration(seconds: 60));
    while (_fixes.isNotEmpty && _fixes.first.receivedAt.isBefore(cutoff)) {
      _fixes.removeAt(0);
    }
  }

  /// Position at [t], interpolated between buffered fixes; null when no fix
  /// is close enough in time. Returns (lat, lon, accuracy).
  (double, double, double)? positionAt(DateTime t) {
    GnssFix? before, after;
    for (final f in _fixes) {
      if (!f.receivedAt.isAfter(t)) {
        before = f;
      } else {
        after = f;
        break;
      }
    }
    final gap = config.maxFixGap;
    if (before != null && after != null) {
      final span = after.receivedAt.difference(before.receivedAt);
      if (span <= gap * 2 && span.inMicroseconds > 0) {
        final k =
            t.difference(before.receivedAt).inMicroseconds /
            span.inMicroseconds;
        final acc = before.accuracyM! > after.accuracyM!
            ? before.accuracyM!
            : after.accuracyM!;
        return (
          before.lat! + (after.lat! - before.lat!) * k,
          before.lon! + (after.lon! - before.lon!) * k,
          acc,
        );
      }
    }
    final near = before != null && t.difference(before.receivedAt) <= gap
        ? before
        : (after != null && after.receivedAt.difference(t) <= gap
              ? after
              : null);
    if (near == null) return null;
    return (near.lat!, near.lon!, near.accuracyM!);
  }

  bool _shouldSample(String key, double lat, double lon, double? dbm) {
    final l = _last[key];
    if (l == null) {
      _last[key] = _Last(lat, lon, dbm);
      return true;
    }
    final moved =
        haversineM(l.lat, l.lon, lat, lon) >= config.minSampleSpacingM;
    final stronger = dbm != null && (l.dbm == null || dbm > l.dbm! + 3);
    if (!moved && !stronger) return false;
    l
      ..lat = lat
      ..lon = lon
      ..dbm = dbm;
    return true;
  }

  /// Records a Wi-Fi scan taken at [now]. Returns the number of samples
  /// stored.
  int addWifi(List<WifiObservation> scan, DateTime now) {
    final samples = <TransmitterSample>[];
    for (final o in scan) {
      if (o.optedOut || o.age > config.maxObservationAge) continue;
      final t = now.subtract(o.age);
      final pos = positionAt(t);
      if (pos == null) continue;
      final dbm = o.effectiveDbm;
      if (!_shouldSample('w${o.bssid}', pos.$1, pos.$2, dbm)) continue;
      final range = model.wifiDistanceM(
        dbm ?? unknownWifiDbm,
        frequencyMhz: o.frequencyMhz,
      );
      samples.add(
        TransmitterSample(
          kind: TransmitterKind.wifi,
          id: o.bssid,
          lat: pos.$1,
          lon: pos.$2,
          // Inverse-square of the estimated range: a sample taken next to
          // the AP says far more about its position than a distant one.
          weight: 1 / (range * range + pos.$3 * pos.$3 + 1),
          fixAccuracyM: pos.$3,
          signalDbm: dbm,
          rangeM: range,
          time: t,
        ),
      );
    }
    return _store(samples);
  }

  /// Records the cells seen at [now]. Only cells with a full identity can be
  /// stored. With a timing advance the sample carries the range, otherwise
  /// the record is the centroid of where the cell was heard.
  int addCells(List<CellObservation> cells, DateTime now) {
    final pos = positionAt(now);
    if (pos == null) return 0;
    final samples = <TransmitterSample>[];
    for (final c in cells) {
      final key = c.key;
      if (key == null) continue;
      if (!_shouldSample('c$key', pos.$1, pos.$2, c.signalDbm)) continue;
      final dbm = c.signalDbm;
      // Stronger signal -> closer to the mast -> more weight. 1 at -110 dBm,
      // 10 at -90, 100 at -70 (amplitude-like scale; RSRP spans ~-140..-60).
      final w = dbm == null
          ? 1.0
          : math
                .pow(10.0, (dbm.clamp(-130.0, -60.0) + 110.0) / 20.0)
                .toDouble();
      samples.add(
        TransmitterSample(
          kind: TransmitterKind.cell,
          id: key,
          lat: pos.$1,
          lon: pos.$2,
          weight: w,
          fixAccuracyM: pos.$3,
          signalDbm: dbm,
          rangeM: timingAdvanceMeters(c.radio, c.timingAdvance),
          time: now,
        ),
      );
    }
    return _store(samples);
  }

  /// Records BLE advertisers with public (stable) addresses.
  int addBle(List<BleObservation> scan, DateTime now) {
    final samples = <TransmitterSample>[];
    for (final o in scan) {
      if (o.randomAddress || o.age > config.maxObservationAge) continue;
      final id = normalizeMac(o.address);
      if (id == null) continue;
      final t = now.subtract(o.age);
      final pos = positionAt(t);
      if (pos == null) continue;
      if (!_shouldSample('b$id', pos.$1, pos.$2, o.rssiDbm)) continue;
      // BLE transmits ~10 dB weaker than Wi-Fi.
      final range = model
          .wifiDistanceM((o.rssiDbm ?? -90) + 10)
          .clamp(1.0, 100.0);
      samples.add(
        TransmitterSample(
          kind: TransmitterKind.ble,
          id: id,
          lat: pos.$1,
          lon: pos.$2,
          weight: 1 / (range * range + pos.$3 * pos.$3 + 1),
          fixAccuracyM: pos.$3,
          signalDbm: o.rssiDbm,
          rangeM: range,
          time: t,
        ),
      );
    }
    return _store(samples);
  }

  int _store(List<TransmitterSample> samples) {
    if (samples.isEmpty) return 0;
    db.addSamples(samples, keepRawSamples: config.keepRawSamples);
    samplesWritten += samples.length;
    if (_last.length > 20000) _last.clear();
    return samples.length;
  }
}
