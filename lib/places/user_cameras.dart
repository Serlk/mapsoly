/// User-supplied cameras: a separate writable database plus importers.
///
/// Two text formats are understood (see `docs/places.md`):
///  * plain CSV `lat,lon,type,speed,direction` (header optional);
///  * the "SpeedCam.txt" format of iGO-style navigators
///    `X,Y,TYPE,SPEED,DirType,Direction` (optionally with a leading IDX).
///
/// The SpeedCam field meanings follow community descriptions of the format,
/// not an official specification, and were not checked against a real
/// third-party file: treat them as unverified.
library;

import 'dart:convert';
import 'dart:io';

import 'package:latlong2/latlong.dart';
import 'package:sqlite3/sqlite3.dart';

import 'cameras.dart';
import 'sqlite_loader.dart';

enum CameraFileFormat { csv, speedCam }

class CameraImportReport {
  CameraImportReport(this.format);
  final CameraFileFormat format;
  int imported = 0;
  int skipped = 0;

  /// First few problems, as "line N: reason".
  final List<String> errors = [];

  void _fail(int line, String why) {
    skipped++;
    if (errors.length < 20) errors.add('line $line: $why');
  }

  @override
  String toString() =>
      'CameraImportReport(${format.name}, imported $imported, skipped $skipped)';
}

/// One parsed camera record.
class ParsedCamera {
  const ParsedCamera({
    required this.point,
    required this.type,
    this.maxSpeedKmh,
    this.bearing,
    this.bidirectional = false,
  });
  final LatLng point;
  final String type;
  final int? maxSpeedKmh;
  final int? bearing;
  final bool bidirectional;
}

/// SpeedCam TYPE codes → `camera.type` values (unverified, see library doc):
/// 1 speed, 2 built into traffic lights (red light + speed), 3 red light,
/// 4 section (average speed), 5 mobile radar; anything else → "other".
const Map<int, String> speedCamTypes = {
  1: 'maxspeed',
  2: 'traffic_signals;maxspeed',
  3: 'traffic_signals',
  4: 'average_speed',
  5: 'maxspeed',
};

const Map<String, String> _csvTypes = {
  '': 'maxspeed',
  'speed': 'maxspeed',
  'maxspeed': 'maxspeed',
  'average': 'average_speed',
  'average_speed': 'average_speed',
  'section': 'average_speed',
  'redlight': 'traffic_signals',
  'red_light': 'traffic_signals',
  'traffic_signals': 'traffic_signals',
  'bus_lane': 'access',
  'access': 'access',
  'road_marking': 'road_marking',
  'mindistance': 'mindistance',
  'other': 'other',
};

List<String> _split(String line) {
  final sep = line.contains(';') && !line.contains(',')
      ? ';'
      : (line.contains('\t') && !line.contains(',') ? '\t' : ',');
  return line.split(sep).map((f) {
    var v = f.trim();
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      v = v.substring(1, v.length - 1);
    }
    return v;
  }).toList();
}

bool _validPoint(double? lat, double? lon) =>
    lat != null &&
    lon != null &&
    lat.abs() <= 90 &&
    lon.abs() <= 180 &&
    !(lat == 0 && lon == 0);

/// Guesses the format from the header / first data line.
CameraFileFormat detectCameraFormat(String content) {
  for (final raw in const LineSplitter().convert(content)) {
    final line = raw.trim().toLowerCase();
    if (line.isEmpty || line.startsWith('#')) continue;
    final f = _split(line);
    if (f.contains('dirtype') ||
        f.contains('x') ||
        f.contains('longitude') &&
            f.indexOf('longitude') < f.indexOf('latitude')) {
      return CameraFileFormat.speedCam;
    }
    if (f.contains('lat') || f.contains('latitude')) {
      return CameraFileFormat.csv;
    }
    // No header: SpeedCam rows have 6–7 numeric fields, CSV rows up to 5.
    return f.length >= 6 ? CameraFileFormat.speedCam : CameraFileFormat.csv;
  }
  return CameraFileFormat.csv;
}

/// Parses camera text in either format. [onError] gets (line number, reason).
List<ParsedCamera> parseCameraText(
  String content, {
  CameraFileFormat? format,
  void Function(int line, String reason)? onError,
}) {
  final fmt = format ?? detectCameraFormat(content);
  final out = <ParsedCamera>[];
  // Column positions; defaults for files without a header.
  var iLat = fmt == CameraFileFormat.csv ? 0 : 1;
  var iLon = fmt == CameraFileFormat.csv ? 1 : 0;
  var iType = 2, iSpeed = 3;
  var iDirType = fmt == CameraFileFormat.csv ? -1 : 4;
  var iDir = fmt == CameraFileFormat.csv ? 4 : 5;
  var sawData = false;
  var lineNo = 0;
  for (final raw in const LineSplitter().convert(content)) {
    lineNo++;
    final line = raw.replaceAll('﻿', '').trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) continue;
    final f = _split(line);
    if (double.tryParse(f[0]) == null) {
      if (sawData) {
        onError?.call(lineNo, 'not a number: "${f[0]}"');
        continue;
      }
      // Header line: locate columns by name.
      final h = f.map((s) => s.toLowerCase()).toList();
      int find(List<String> names, int dflt) {
        for (final n in names) {
          final i = h.indexOf(n);
          if (i >= 0) return i;
        }
        return dflt;
      }

      iLat = find(const ['lat', 'latitude', 'y'], -2);
      iLon = find(const ['lon', 'lng', 'long', 'longitude', 'x'], -2);
      iType = find(const ['type'], -1);
      iSpeed = find(const ['speed', 'maxspeed', 'limit'], -1);
      iDirType = find(const ['dirtype'], -1);
      iDir = find(const ['direction', 'dir', 'bearing', 'course', 'angle'], -1);
      if (iLat == -2 || iLon == -2) {
        onError?.call(lineNo, 'header without lat/lon (or X/Y) columns');
        return out;
      }
      continue;
    }
    // Header-less SpeedCam file with a leading IDX column (7 fields).
    if (!sawData &&
        fmt == CameraFileFormat.speedCam &&
        iLon == 0 &&
        f.length >= 7) {
      iLon = 1;
      iLat = 2;
      iType = 3;
      iSpeed = 4;
      iDirType = 5;
      iDir = 6;
    }
    sawData = true;
    String? at(int i) =>
        i >= 0 && i < f.length && f[i].isNotEmpty ? f[i] : null;
    final lat = double.tryParse(at(iLat) ?? '');
    final lon = double.tryParse(at(iLon) ?? '');
    if (!_validPoint(lat, lon)) {
      onError?.call(lineNo, 'bad coordinates');
      continue;
    }
    final speed = double.tryParse(at(iSpeed) ?? '')?.round();
    final dir = double.tryParse(at(iDir) ?? '')?.round();
    String type;
    int? bearing = dir == null ? null : ((dir % 360) + 360) % 360;
    var bidir = false;
    if (fmt == CameraFileFormat.speedCam) {
      type = speedCamTypes[int.tryParse(at(iType) ?? '')] ?? 'other';
      // DirType: 0 all directions, 1 one direction, 2 both directions.
      final dirType = int.tryParse(at(iDirType) ?? '') ?? 0;
      if (dirType == 0) {
        bearing = null;
      } else if (dirType == 2) {
        bidir = true;
      }
    } else {
      final t = (at(iType) ?? '').toLowerCase();
      type = _csvTypes[t] ?? (int.tryParse(t) != null ? 'other' : t);
    }
    out.add(
      ParsedCamera(
        point: LatLng(lat!, lon!),
        type: type,
        maxSpeedKmh: speed != null && speed > 0 && speed <= 200 ? speed : null,
        bearing: bearing,
        bidirectional: bidir,
      ),
    );
  }
  return out;
}

/// Writable camera database kept apart from region packs (survives pack
/// updates). Same schema as the pack's camera tables.
class UserCameraDatabase {
  UserCameraDatabase._(this._db) {
    _db.execute(cameraSchemaSql);
    cameras = CameraStore(_db, CameraSource.user);
  }

  /// Opens (creating if needed) the database at [path].
  factory UserCameraDatabase.open(String path) {
    ensureSqliteLoadable();
    return UserCameraDatabase._(sqlite3.open(path));
  }

  factory UserCameraDatabase.inMemory() {
    ensureSqliteLoadable();
    return UserCameraDatabase._(sqlite3.openInMemory());
  }

  final Database _db;

  /// Queries (`near`, `along`) over the user cameras.
  late final CameraStore cameras;

  int get count => cameras.count;

  /// Imports camera text, auto-detecting the format unless [format] is given.
  /// Records closer than ~5 m to an existing user camera of the same type
  /// are skipped as duplicates.
  CameraImportReport importText(String content, {CameraFileFormat? format}) {
    final fmt = format ?? detectCameraFormat(content);
    final report = CameraImportReport(fmt);
    final parsed = parseCameraText(content, format: fmt, onError: report._fail);
    final ins = _db.prepare(
      'INSERT INTO camera(type, lat, lon, bearing, bidir, maxspeed) '
      'VALUES (?,?,?,?,?,?)',
    );
    final rt = _db.prepare('INSERT INTO camera_rtree VALUES (?,?,?,?,?)');
    final dup = _db.prepare(
      'SELECT 1 FROM camera_rtree r JOIN camera c ON c.id = r.id '
      'WHERE r.max_lat >= ? AND r.min_lat <= ? AND r.max_lon >= ? '
      'AND r.min_lon <= ? AND c.type = ? AND c.bearing IS ? LIMIT 1',
    );
    _db.execute('BEGIN');
    try {
      for (final c in parsed) {
        final lat = c.point.latitude, lon = c.point.longitude;
        const e = 0.00005;
        if (dup.select([
          lat - e,
          lat + e,
          lon - e,
          lon + e,
          c.type,
          c.bearing,
        ]).isNotEmpty) {
          report.skipped++;
          continue;
        }
        ins.execute([
          c.type,
          lat,
          lon,
          c.bearing,
          c.bidirectional ? 1 : 0,
          c.maxSpeedKmh,
        ]);
        final id = _db.lastInsertRowId;
        rt.execute([id, lat, lat, lon, lon]);
        report.imported++;
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    } finally {
      ins.dispose();
      rt.dispose();
      dup.dispose();
    }
    return report;
  }

  /// Imports a file (UTF-8, falling back to Latin-1 for odd encodings).
  CameraImportReport importFile(String path, {CameraFileFormat? format}) {
    final bytes = File(path).readAsBytesSync();
    String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      text = latin1.decode(bytes);
    }
    return importText(text, format: format);
  }

  /// Deletes all user cameras; returns how many there were.
  int clear() {
    final n = count;
    _db.execute('DELETE FROM camera');
    _db.execute('DELETE FROM camera_rtree');
    return n;
  }

  void close() {
    cameras.dispose();
    _db.dispose();
  }
}

/// Merges route cameras from several stores (pack + user) into one list
/// ordered along the route; a user camera within [dedupeM] of a pack camera
/// of the same type is dropped.
List<RouteCamera> mergeRouteCameras(
  List<List<RouteCamera>> lists, {
  double dedupeM = 40,
}) {
  final out = <RouteCamera>[];
  for (final list in lists) {
    for (final c in list) {
      final clash = out.any(
        (o) =>
            o.camera.type == c.camera.type &&
            (o.alongM - c.alongM).abs() <= dedupeM,
      );
      if (!clash) out.add(c);
    }
  }
  out.sort((a, b) => a.alongM.compareTo(b.alongM));
  return out;
}
