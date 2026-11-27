/// What the settings screen offers to save out of the app: the user's own
/// wardriving data and the OBD trip logs. Everything passes the privacy
/// zones once more on the way out, so data recorded before a zone existed
/// is protected too.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:latlong2/latlong.dart';

import '../positioning/importers.dart' show wigleAggregatedMarker;
import '../positioning/location_db.dart';
import '../positioning/models.dart';
import 'privacy_zones.dart';

// ------------------------------------------------------------ wardriving

/// Outcome of [exportWardriving].
class WardrivingExportResult {
  /// The written file; null when there was nothing to export (no file is
  /// created then).
  File? file;

  /// Transmitters written.
  int exported = 0;
  int wifi = 0;
  int cells = 0;
  int ble = 0;

  /// Left out because their stored position is inside a privacy zone.
  int withheldByZones = 0;

  /// Left out because they were not learnt by the user's own wardriving
  /// (imports, Apple / beaconDB answers, and wardriving records that were
  /// started from such an answer). Always 0 with `onlyOwn: false`.
  int notOwn = 0;

  @override
  String toString() =>
      'WardrivingExportResult(exported $exported: wifi $wifi, cells $cells, '
      'ble $ble; withheld by zones $withheldByZones; not own $notOwn)';
}

const _wigleRadio = {'gsm': 'GSM', 'umts': 'WCDMA', 'lte': 'LTE', 'nr': 'NR'};

/// WiGLE's cell key `<mcc><mnc>_<lac>_<cid>` and type for a database cell
/// key (`radio:mcc:mnc:area:cell`); null when the key is not one.
(String, String)? _wigleCell(String key) {
  final p = key.split(':');
  if (p.length != 5) return null;
  final type = _wigleRadio[p[0]];
  final mcc = int.tryParse(p[1]), mnc = int.tryParse(p[2]);
  final area = int.tryParse(p[3]), cell = int.tryParse(p[4]);
  if (type == null ||
      mcc == null ||
      mnc == null ||
      area == null ||
      cell == null ||
      mcc < 0 ||
      mcc > 999 ||
      mnc < 0 ||
      mnc > 999) {
    return null;
  }
  final operator =
      '${mcc.toString().padLeft(3, '0')}'
      '${mnc.toString().padLeft(2, '0')}';
  return ('${operator}_${area}_$cell', type);
}

String _wigleTime(DateTime t) {
  final u = t.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${u.year}-${two(u.month)}-${two(u.day)} '
      '${two(u.hour)}:${two(u.minute)}:${two(u.second)}';
}

/// Writes the transmitters of [db] to [out] as a WiGLE CSV file
/// (`WigleWifi-1.6` layout), one row per transmitter: its estimated
/// position, the uncertainty of that position in `AccuracyMeters`, the
/// strongest signal seen in `RSSI` and the time of the last observation in
/// `FirstSeen`. SSID, channel and altitude are not stored by the app and
/// stay empty. The first line carries [wigleAggregatedMarker], by which
/// `importWigleCsv` recognises the one-row-per-transmitter form and reads
/// the records back unchanged.
///
/// With [onlyOwn] (default) only what the user's own wardriving learnt is
/// written (`TransmitterRecord.isOwn`): nothing cached from Apple or
/// beaconDB and nothing imported.
///
/// Transmitters whose stored position lies inside a privacy zone are never
/// written, whatever their source and whenever they were recorded.
///
/// Throws [FileSystemException] when [out] cannot be written; a partial
/// file is not left behind.
Future<WardrivingExportResult> exportWardriving(
  LocationDb db,
  PrivacyZones zones,
  File out, {
  bool onlyOwn = true,
}) async {
  final result = WardrivingExportResult();
  final lines = <String>[
    'WigleWifi-1.6,$wigleAggregatedMarker,model=,release=,device=,display=,'
        'board=,brand=,star=Sol,body=3,subBody=0',
    'MAC,SSID,AuthMode,FirstSeen,Channel,Frequency,RSSI,CurrentLatitude,'
        'CurrentLongitude,AltitudeMeters,AccuracyMeters,RCOIs,MfgrId,Type',
  ];
  out.parent.createSync(recursive: true);
  final tmp = File('${out.path}.tmp');
  final sink = tmp.openWrite();
  try {
    var seen = 0;
    for (final r in db.records(
      source: onlyOwn ? TransmitterSource.wardriving : null,
    )) {
      if (++seen % 2000 == 0) {
        sink.writeAll(lines, '\n');
        sink.write('\n');
        lines.clear();
        await sink.flush();
      }
      if (onlyOwn && !r.isOwn) {
        result.notOwn++;
        continue;
      }
      String mac, type;
      switch (r.kind) {
        case TransmitterKind.wifi:
          mac = r.id;
          type = 'WIFI';
        case TransmitterKind.ble:
          mac = r.id;
          type = 'BLE';
        case TransmitterKind.cell:
          final cell = _wigleCell(r.id);
          if (cell == null) continue;
          (mac, type) = cell;
      }
      if (zones.contains(LatLng(r.lat, r.lon))) {
        result.withheldByZones++;
        continue;
      }
      lines.add(
        [
          mac,
          '', // SSID
          '', // AuthMode
          _wigleTime(r.updated),
          '', // Channel
          '', // Frequency
          r.bestSignalDbm?.round() ?? '',
          r.lat,
          r.lon,
          '', // AltitudeMeters
          r.accuracyM.toStringAsFixed(1),
          '', // RCOIs
          '', // MfgrId
          type,
        ].join(','),
      );
      result.exported++;
      switch (r.kind) {
        case TransmitterKind.wifi:
          result.wifi++;
        case TransmitterKind.cell:
          result.cells++;
        case TransmitterKind.ble:
          result.ble++;
      }
    }
    if (lines.isNotEmpty) {
      sink.writeAll(lines, '\n');
      sink.write('\n');
    }
    await sink.flush();
    await sink.close();
    if (onlyOwn) {
      // Imported and cached records were not even read; count them.
      final stats = db.stats();
      for (final e in stats.bySource.entries) {
        if (e.key != TransmitterSource.wardriving) result.notOwn += e.value;
      }
    }
    if (result.exported == 0) {
      tmp.deleteSync();
    } else {
      tmp.renameSync(out.path);
      result.file = out;
    }
  } catch (_) {
    await sink.close().catchError((Object _) {});
    if (tmp.existsSync()) tmp.deleteSync();
    rethrow;
  }
  return result;
}

// -------------------------------------------------------------- trip logs

/// A trip log file written by `ObdSession` (`trip-<start>.csv`).
class TripLogInfo {
  const TripLogInfo({
    required this.file,
    required this.start,
    required this.sizeBytes,
    this.duration,
    this.distanceKm,
  });

  final File file;

  /// Time of the first row; if the file has none yet, the time in its name,
  /// or else its modification time. Local time.
  final DateTime start;

  /// From the first to the last row; null for a file without two rows.
  final Duration? duration;

  /// Distance driven according to the odometer column (`trip_km`, the
  /// integrated vehicle speed); null when the file does not have it.
  final double? distanceKm;
  final int sizeBytes;

  String get name => file.uri.pathSegments.last;

  @override
  String toString() =>
      'TripLogInfo($name, $start, $duration, $distanceKm km, $sizeBytes B)';
}

final _tripName = RegExp(r'^trip-(\d{8})T(\d{6})\.csv$');

/// At most [max] bytes from the start (or the end) of [file], as text.
String _chunk(RandomAccessFile file, int length, int max, {required bool end}) {
  final n = length < max ? length : max;
  file.setPositionSync(end ? length - n : 0);
  return utf8.decode(file.readSync(n), allowMalformed: true);
}

TripLogInfo _tripInfo(File file) {
  final stat = file.statSync();
  final name = file.uri.pathSegments.last;
  DateTime? start, last;
  double? firstKm, lastKm;

  // Only the two ends of the file are read: logs grow by a row a second.
  final raf = file.openSync();
  try {
    final head = const LineSplitter().convert(
      _chunk(raf, stat.size, 4096, end: false),
    );
    final wholeFile = stat.size <= 4096;
    final tail = wholeFile
        ? head
        : const LineSplitter().convert(_chunk(raf, stat.size, 4096, end: true));
    if (head.isNotEmpty) {
      final columns = head.first.split(',');
      final timeAt = columns.indexOf('time');
      final kmAt = columns.indexOf('trip_km');
      (DateTime?, double?) read(String line) {
        final f = line.split(',');
        // A torn last line (the log is being written) has fewer fields.
        if (f.length != columns.length) return (null, null);
        return (
          timeAt < 0 ? null : DateTime.tryParse(f[timeAt]),
          kmAt < 0 ? null : double.tryParse(f[kmAt]),
        );
      }

      // The head chunk may end in a cut line unless it is the whole file.
      final headRows = head.sublist(
        1,
        wholeFile || head.length < 2 ? head.length : head.length - 1,
      );
      for (final line in headRows) {
        final (t, km) = read(line);
        if (t == null) continue;
        start = t;
        firstKm = km;
        break;
      }
      // The first line of the tail chunk may be cut as well.
      final tailRows = wholeFile ? head.sublist(1) : tail.sublist(1);
      for (final line in tailRows.reversed) {
        final (t, km) = read(line);
        if (t == null) continue;
        last = t;
        lastKm = km;
        break;
      }
    }
  } finally {
    raf.closeSync();
  }

  if (start == null) {
    final m = _tripName.firstMatch(name);
    if (m != null) start = DateTime.tryParse('${m[1]}T${m[2]}');
  }
  return TripLogInfo(
    file: file,
    start: start ?? stat.modified,
    sizeBytes: stat.size,
    duration: start != null && last != null && !last.isBefore(start)
        ? last.difference(start)
        : null,
    distanceKm: firstKm != null && lastKm != null && lastKm >= firstKm
        ? lastKm - firstKm
        : null,
  );
}

/// The trip logs in [logs] (`trip-*.csv`), newest first. A missing
/// directory gives an empty list; a file that cannot be read is listed with
/// what is known about it.
List<TripLogInfo> listTripLogs(Directory logs) {
  if (!logs.existsSync()) return const [];
  final out = <TripLogInfo>[];
  for (final f in logs.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    if (!name.startsWith('trip-') || !name.endsWith('.csv')) continue;
    try {
      out.add(_tripInfo(f));
    } on FileSystemException {
      continue; // deleted meanwhile
    }
  }
  out.sort((a, b) {
    final t = b.start.compareTo(a.start);
    return t != 0 ? t : b.name.compareTo(a.name);
  });
  return out;
}

/// Outcome of [exportTripLogs].
class TripExportResult {
  /// Copies written, in the order of the input.
  final List<File> files = [];

  /// Data rows written in all files.
  int rows = 0;

  /// Rows that had coordinates and were written without them because the
  /// position is inside a privacy zone (or could not be understood).
  int rowsBlanked = 0;

  /// Logs that were not exported: file name -> reason (in Russian).
  final Map<String, String> failed = {};

  @override
  String toString() =>
      'TripExportResult(${files.length} files, rows $rows, blanked '
      '$rowsBlanked, failed $failed)';
}

/// Copies [logs] into [out] under their own names with the coordinates of
/// every row inside a privacy zone removed; the vehicle data of those rows
/// is kept. The rows are checked here again, whatever was or was not
/// filtered when the log was written.
///
/// A file whose header has no `lat` / `lon` columns is not a trip log this
/// function understands and is refused rather than copied unchecked.
Future<TripExportResult> exportTripLogs(
  List<File> logs,
  PrivacyZones zones,
  Directory out,
) async {
  final result = TripExportResult();
  for (final log in logs) {
    final name = log.uri.pathSegments.last;
    final target = File('${out.path}/$name');
    if (target.absolute.path == log.absolute.path) {
      result.failed[name] = 'Папка назначения совпадает с папкой журналов';
      continue;
    }
    final tmp = File('${target.path}.tmp');
    IOSink? sink;
    try {
      out.createSync(recursive: true);
      sink = tmp.openWrite();
      int? latAt, lonAt;
      var width = 0;
      var rows = 0, blanked = 0;
      var understood = true;
      await for (final line
          in log
              .openRead()
              .transform(const Utf8Decoder(allowMalformed: true))
              .transform(const LineSplitter())) {
        if (latAt == null) {
          final columns = line.split(',').map((c) => c.trim()).toList();
          final lat = columns.indexOf('lat'), lon = columns.indexOf('lon');
          if (lat < 0 || lon < 0) {
            understood = false;
            break;
          }
          latAt = lat;
          lonAt = lon;
          width = columns.length;
          sink.writeln(line);
          continue;
        }
        if (line.isEmpty) continue;
        final f = line.split(',');
        // A row of another shape cannot be trusted to have its coordinates
        // where the header says: drop it.
        if (f.length != width) continue;
        final rawLat = f[latAt].trim(), rawLon = f[lonAt!].trim();
        if (rawLat.isNotEmpty || rawLon.isNotEmpty) {
          final lat = double.tryParse(rawLat), lon = double.tryParse(rawLon);
          if (lat == null || lon == null || zones.contains(LatLng(lat, lon))) {
            f[latAt] = '';
            f[lonAt] = '';
            blanked++;
          }
        }
        sink.writeln(f.join(','));
        rows++;
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (!understood || latAt == null) {
        tmp.deleteSync();
        result.failed[name] = 'Это не журнал поездки';
        continue;
      }
      tmp.renameSync(target.path);
      result.files.add(target);
      result.rows += rows;
      result.rowsBlanked += blanked;
    } on FileSystemException {
      await sink?.close().catchError((Object _) {});
      if (tmp.existsSync()) tmp.deleteSync();
      result.failed[name] = 'Файл не удалось скопировать';
    }
  }
  return result;
}

/// Deletes a trip log. Returns false when it could not be deleted (it is
/// gone already, or the disk is read-only).
bool deleteTripLog(File log) {
  try {
    log.deleteSync();
    return true;
  } on FileSystemException {
    return false;
  }
}
