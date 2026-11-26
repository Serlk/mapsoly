/// Importers for transmitter positions: WiGLE CSV (the WiGLE WiFi Wardriving
/// app's own export) and generic / MLS-style CSV files.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'geo.dart';
import 'location_db.dart';
import 'models.dart';
import 'signal_model.dart';

/// Outcome of an import.
class ImportResult {
  ImportResult();

  /// Data rows read.
  int rows = 0;

  /// Rows skipped (malformed, no position, opted out, unsupported type).
  int skipped = 0;

  /// Distinct transmitters found in the file.
  int transmitters = 0;

  /// Records actually written (others were kept because the database holds a
  /// more trusted record).
  int written = 0;

  @override
  String toString() =>
      'ImportResult(rows $rows, skipped $skipped, transmitters '
      '$transmitters, written $written)';
}

/// Splits one CSV line honouring double quotes ("" escapes a quote).
List<String> splitCsvLine(String line) {
  final out = <String>[];
  final sb = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          sb.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        sb.write(c);
      }
    } else if (c == '"' && sb.isEmpty) {
      quoted = true;
    } else if (c == ',') {
      out.add(sb.toString());
      sb.clear();
    } else {
      sb.write(c);
    }
  }
  out.add(sb.toString());
  return out;
}

class _Acc {
  _Acc(this.kind, this.lat0, this.lon0) : proj = LocalProjection(lat0, lon0);
  final TransmitterKind kind;
  final double lat0, lon0;
  final LocalProjection proj;
  double w = 0, sx = 0, sy = 0, sxx = 0, syy = 0, fix2 = 0;
  int n = 0;
  double? best;
  double? bestRange;

  void add(
    double lat,
    double lon,
    double weight,
    double fixAcc,
    double? dbm,
    double? range,
  ) {
    final x = proj.x(lon), y = proj.y(lat);
    w += weight;
    sx += weight * x;
    sy += weight * y;
    sxx += weight * x * x;
    syy += weight * y * y;
    fix2 += weight * fixAcc * fixAcc;
    n++;
    if (dbm != null && (best == null || dbm > best!)) best = dbm;
    if (range != null && (bestRange == null || range < bestRange!)) {
      bestRange = range;
    }
  }

  TransmitterRecord record(String id, TransmitterSource source, DateTime now) {
    final mx = sx / w, my = sy / w;
    final scatter = math.max(0.0, sxx - w * mx * mx + syy - w * my * my) + fix2;
    final range = bestRange ?? 0;
    var acc = math.sqrt(scatter / w + range * range);
    final floor = kind == TransmitterKind.cell
        ? minCellAccuracyM
        : minWifiAccuracyM;
    if (acc < floor) acc = floor;
    return TransmitterRecord(
      kind: kind,
      id: id,
      lat: proj.lat(my),
      lon: proj.lon(mx),
      accuracyM: acc,
      samples: n,
      weightSum: w,
      scatterM2: scatter,
      bestSignalDbm: best,
      source: source,
      updated: now,
    );
  }
}

RadioType? _wigleRadio(String type) => switch (type.toUpperCase()) {
  'GSM' => RadioType.gsm,
  'WCDMA' || 'UMTS' => RadioType.umts,
  'LTE' => RadioType.lte,
  'NR' => RadioType.nr,
  _ => null,
};

/// Parses a WiGLE cell key `"<mcc><mnc>_<lac>_<cid>"` (operator is 5 or 6
/// digits; WiGLE does not say which split applies, so 3-digit MCC + rest is
/// used, as everywhere else in 3GPP).
String? wigleCellKey(String mac, RadioType radio) {
  final p = mac.split('_');
  if (p.length != 3 || p[0].length < 5 || p[0].length > 6) return null;
  final mcc = int.tryParse(p[0].substring(0, 3));
  final mnc = int.tryParse(p[0].substring(3));
  final lac = int.tryParse(p[1]), cid = int.tryParse(p[2]);
  if (mcc == null || mnc == null || lac == null || cid == null) return null;
  return cellKey(radio, mcc, mnc, lac, cid);
}

/// Imports a WiGLE CSV export.
///
/// Format (verified against the WiGLE app documentation, versions 1.4-1.6):
/// first line `WigleWifi-1.x,appRelease=...`, second line the column header
/// (`MAC,SSID,AuthMode,FirstSeen,Channel,[Frequency,]RSSI,CurrentLatitude,
/// CurrentLongitude,AltitudeMeters,AccuracyMeters,[RCOIs,MfgrId,]Type`),
/// then one row per *observation*. Columns are located by header name, so
/// both layouts work. Rows of the same transmitter are merged into one
/// signal-weighted position exactly like live wardriving.
///
/// Rows with `AccuracyMeters` above [maxFixAccuracyM], zero coordinates or a
/// `_nomap` SSID are skipped. BT (classic) rows are ignored; BLE rows are
/// stored as BLE transmitters.
Future<ImportResult> importWigleCsv(
  LocationDb db,
  Stream<String> lines, {
  double maxFixAccuracyM = 50,
  PathLossModel model = const PathLossModel(),
  DateTime? now,
}) async {
  final result = ImportResult();
  final accs = <String, _Acc>{};
  Map<String, int>? col;
  var lineNo = 0;
  await for (final line in lines) {
    lineNo++;
    if (line.isEmpty) continue;
    if (lineNo == 1 && line.startsWith('WigleWifi')) continue;
    var f = splitCsvLine(line);
    if (col == null) {
      col = {for (var i = 0; i < f.length; i++) f[i].trim(): i};
      if (!col.containsKey('MAC') || !col.containsKey('CurrentLatitude')) {
        throw const FormatException('not a WiGLE CSV file (no MAC column)');
      }
      continue;
    }
    result.rows++;
    final width = col.length;
    if (f.length > width) {
      // Unquoted commas inside the SSID: fold the surplus back into it.
      final extra = f.length - width;
      final si = col['SSID'] ?? 1;
      f = [
        ...f.sublist(0, si),
        f.sublist(si, si + extra + 1).join(','),
        ...f.sublist(si + extra + 1),
      ];
    }
    if (f.length < width) {
      result.skipped++;
      continue;
    }
    String get(String name) {
      final i = col![name];
      return i == null ? '' : f[i].trim();
    }

    final lat = double.tryParse(get('CurrentLatitude'));
    final lon = double.tryParse(get('CurrentLongitude'));
    final fixAcc = double.tryParse(get('AccuracyMeters')) ?? 0;
    final rssi = double.tryParse(get('RSSI'));
    final type = get('Type').toUpperCase();
    final ssid = get('SSID');
    if (lat == null ||
        lon == null ||
        (lat == 0 && lon == 0) ||
        lat.abs() > 90 ||
        lon.abs() > 180 ||
        fixAcc > maxFixAccuracyM ||
        ssid.endsWith('_nomap')) {
      result.skipped++;
      continue;
    }
    TransmitterKind kind;
    String? id;
    double weight;
    double? range;
    final dbm = rssi != null && rssi < 0 ? rssi : null;
    switch (type) {
      case 'WIFI':
        kind = TransmitterKind.wifi;
        id = normalizeMac(get('MAC'));
        final freq = int.tryParse(get('Frequency'));
        range = model.wifiDistanceM(
          dbm ?? unknownWifiDbm,
          frequencyMhz: freq ?? _channelToMhz(int.tryParse(get('Channel'))),
        );
        weight = 1 / (range * range + fixAcc * fixAcc + 1);
      case 'BLE':
        kind = TransmitterKind.ble;
        id = normalizeMac(get('MAC'));
        range = model.wifiDistanceM((dbm ?? -90) + 10).clamp(1.0, 100.0);
        weight = 1 / (range * range + fixAcc * fixAcc + 1);
      default:
        final radio = _wigleRadio(type);
        if (radio == null) {
          result.skipped++;
          continue;
        }
        kind = TransmitterKind.cell;
        id = wigleCellKey(get('MAC'), radio);
        weight = 1;
    }
    if (id == null) {
      result.skipped++;
      continue;
    }
    final key = '${kind.index}|$id';
    (accs[key] ??= _Acc(
      kind,
      lat,
      lon,
    )).add(lat, lon, weight, fixAcc, dbm, range);
    if (result.rows % 5000 == 0) await Future<void>.delayed(Duration.zero);
  }
  if (col == null) throw const FormatException('empty WiGLE CSV file');
  final stamp = now ?? DateTime.now();
  result.transmitters = accs.length;
  final records = <TransmitterRecord>[];
  for (final e in accs.entries) {
    records.add(
      e.value.record(
        e.key.substring(e.key.indexOf('|') + 1),
        TransmitterSource.wigle,
        stamp,
      ),
    );
    if (records.length >= 2000) {
      result.written += db.upsertExternal(records);
      records.clear();
      await Future<void>.delayed(Duration.zero);
    }
  }
  result.written += db.upsertExternal(records);
  return result;
}

int? _channelToMhz(int? channel) {
  if (channel == null || channel <= 0) return null;
  if (channel > 1000) return channel; // some exports put MHz here
  if (channel == 14) return 2484;
  if (channel <= 13) return 2407 + 5 * channel;
  if (channel >= 32 && channel <= 177) return 5000 + 5 * channel;
  return null;
}

RadioType? _radioFromName(String s) => switch (s.trim().toLowerCase()) {
  'gsm' => RadioType.gsm,
  'umts' || 'wcdma' => RadioType.umts,
  'lte' => RadioType.lte,
  'nr' || '5g' => RadioType.nr,
  _ => null,
};

/// Imports a generic CSV file with a header line. One row = one transmitter
/// position (not an observation).
///
/// Recognised columns (case-insensitive, any order):
///  * position: `lat`/`latitude`, `lon`/`lng`/`longitude` (required);
///  * accuracy: `accuracy`/`range`/`radius` in metres (optional);
///  * `samples` (optional);
///  * Wi-Fi/BLE: `bssid`/`mac`/`id`/`address`, optional `type`/`kind`
///    (`wifi` default, `ble`);
///  * cells, MLS / OpenCelliD export layout: `radio`, `mcc`,
///    `net`/`mnc`, `area`/`lac`/`tac`, `cell`/`cid`/`cellid`.
///
/// A row is treated as a cell when the file has `mcc` and a cell-id column
/// and the row has no MAC.
Future<ImportResult> importGenericCsv(
  LocationDb db,
  Stream<String> lines, {
  TransmitterSource source = TransmitterSource.csv,
  double defaultWifiAccuracyM = 50,
  double defaultCellAccuracyM = 2000,
  DateTime? now,
}) async {
  final result = ImportResult();
  Map<String, int>? col;
  final stamp = now ?? DateTime.now();
  final batch = <TransmitterRecord>[];
  final seen = <String>{};
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final f = splitCsvLine(line);
    if (col == null) {
      col = {for (var i = 0; i < f.length; i++) f[i].trim().toLowerCase(): i};
      continue;
    }
    result.rows++;
    String? get(List<String> names) {
      for (final n in names) {
        final i = col![n];
        if (i != null && i < f.length && f[i].trim().isNotEmpty) {
          return f[i].trim();
        }
      }
      return null;
    }

    final lat = double.tryParse(get(const ['lat', 'latitude']) ?? '');
    final lon = double.tryParse(get(const ['lon', 'lng', 'longitude']) ?? '');
    if (lat == null || lon == null) {
      result.skipped++;
      continue;
    }
    final acc = double.tryParse(
      get(const ['accuracy', 'range', 'radius']) ?? '',
    );
    final samples = int.tryParse(get(const ['samples']) ?? '') ?? 1;
    final macRaw = get(const ['bssid', 'mac', 'id', 'address']);
    final mac = macRaw == null ? null : normalizeMac(macRaw);
    TransmitterKind kind;
    String? id;
    if (mac != null) {
      final t = (get(const ['type', 'kind']) ?? 'wifi').toLowerCase();
      kind = t.startsWith('ble') || t.startsWith('bt')
          ? TransmitterKind.ble
          : TransmitterKind.wifi;
      id = mac;
    } else {
      kind = TransmitterKind.cell;
      final radio = _radioFromName(get(const ['radio', 'type']) ?? '');
      final mcc = int.tryParse(get(const ['mcc']) ?? '');
      final mnc = int.tryParse(get(const ['net', 'mnc']) ?? '');
      final area = int.tryParse(get(const ['area', 'lac', 'tac']) ?? '');
      final cid = int.tryParse(get(const ['cell', 'cid', 'cellid']) ?? '');
      if (radio != null &&
          mcc != null &&
          mnc != null &&
          area != null &&
          cid != null) {
        id = cellKey(radio, mcc, mnc, area, cid);
      }
    }
    if (id == null) {
      result.skipped++;
      continue;
    }
    if (seen.add('${kind.index}|$id')) result.transmitters++;
    batch.add(
      TransmitterRecord(
        kind: kind,
        id: id,
        lat: lat,
        lon: lon,
        accuracyM: acc != null && acc > 0
            ? acc
            : (kind == TransmitterKind.cell
                  ? defaultCellAccuracyM
                  : defaultWifiAccuracyM),
        samples: samples,
        source: source,
        updated: stamp,
      ),
    );
    if (batch.length >= 2000) {
      result.written += db.upsertExternal(batch);
      batch.clear();
      await Future<void>.delayed(Duration.zero);
    }
  }
  if (col == null) throw const FormatException('empty CSV file');
  result.written += db.upsertExternal(batch);
  return result;
}

/// Reads [file] as UTF-8 lines (malformed bytes are replaced, WiGLE SSIDs
/// are not always valid UTF-8).
Stream<String> csvLines(File file) => file
    .openRead()
    .transform(const Utf8Decoder(allowMalformed: true))
    .transform(const LineSplitter());
