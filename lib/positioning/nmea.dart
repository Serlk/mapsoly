/// NMEA 0183 parser: GGA, RMC, VTG, GSA, GSV and GST from any talker
/// (GP, GL, GA, GB/BD, GQ, GI, GN), assembled into one [GnssFix] per epoch.
library;

import 'dart:math' as math;

import 'models.dart';

/// A checksum-verified NMEA sentence split into fields.
class NmeaSentence {
  NmeaSentence._(this.talker, this.type, this.fields);

  /// Two-letter talker id (`GP`, `GN`, ...); `P` for proprietary sentences.
  final String talker;

  /// Three-letter sentence type (`GGA`, ...), or the full proprietary tag.
  final String type;

  /// Data fields after the address field.
  final List<String> fields;

  /// Parses one line. Returns null for anything that is not a well-formed
  /// sentence with a correct checksum (a missing checksum is tolerated only
  /// when [requireChecksum] is false).
  static NmeaSentence? parse(String line, {bool requireChecksum = true}) {
    var s = line.trim();
    final start = s.indexOf(r'$');
    if (start < 0) return null;
    s = s.substring(start + 1);
    final star = s.lastIndexOf('*');
    if (star >= 0) {
      if (star + 3 > s.length) return null;
      final want = int.tryParse(s.substring(star + 1, star + 3), radix: 16);
      if (want == null) return null;
      var sum = 0;
      for (var i = 0; i < star; i++) {
        sum ^= s.codeUnitAt(i);
      }
      if (sum != want) return null;
      s = s.substring(0, star);
    } else if (requireChecksum) {
      return null;
    }
    final parts = s.split(',');
    final addr = parts.first;
    if (addr.length < 4) return null;
    if (addr.startsWith('P')) {
      return NmeaSentence._('P', addr, parts.sublist(1));
    }
    if (addr.length != 5) return null;
    return NmeaSentence._(
      addr.substring(0, 2),
      addr.substring(2),
      parts.sublist(1),
    );
  }

  String field(int i) => i < fields.length ? fields[i] : '';
  double? doubleAt(int i) => double.tryParse(field(i));
  int? intAt(int i) => int.tryParse(field(i));
}

/// Computes the two-digit hex checksum for a sentence body (between `$` and
/// `*`). Useful for tests and simulators.
String nmeaChecksum(String body) {
  var sum = 0;
  for (var i = 0; i < body.length; i++) {
    sum ^= body.codeUnitAt(i);
  }
  return sum.toRadixString(16).toUpperCase().padLeft(2, '0');
}

/// Converts `ddmm.mmmm` / `dddmm.mmmm` plus hemisphere to signed degrees.
double? parseNmeaCoordinate(String value, String hemisphere) {
  if (value.isEmpty || hemisphere.isEmpty) return null;
  final v = double.tryParse(value);
  if (v == null) return null;
  final deg = (v / 100).truncateToDouble();
  final min = v - deg * 100;
  if (min >= 60) return null;
  var out = deg + min / 60.0;
  switch (hemisphere) {
    case 'S' || 'W':
      out = -out;
    case 'N' || 'E':
      break;
    default:
      return null;
  }
  return out;
}

GnssSystem _systemFromTalker(String talker) => switch (talker) {
  'GP' => GnssSystem.gps,
  'GL' => GnssSystem.glonass,
  'GA' => GnssSystem.galileo,
  'GB' || 'BD' => GnssSystem.beidou,
  'GQ' || 'QZ' => GnssSystem.qzss,
  'GI' => GnssSystem.navic,
  _ => GnssSystem.unknown,
};

/// NMEA 4.10/4.11 system id (GSA field 18).
GnssSystem _systemFromId(int id) => switch (id) {
  1 => GnssSystem.gps,
  2 => GnssSystem.glonass,
  3 => GnssSystem.galileo,
  4 => GnssSystem.beidou,
  5 => GnssSystem.qzss,
  6 => GnssSystem.navic,
  _ => GnssSystem.unknown,
};

/// Guesses the constellation from legacy NMEA satellite numbering, used when
/// a combined `GN` talker gives no system id.
GnssSystem _systemFromPrn(int prn) {
  if (prn >= 1 && prn <= 32) return GnssSystem.gps;
  if (prn >= 33 && prn <= 64) return GnssSystem.sbas;
  if (prn >= 65 && prn <= 96) return GnssSystem.glonass;
  if (prn >= 193 && prn <= 202) return GnssSystem.qzss;
  if (prn >= 201 && prn <= 264) return GnssSystem.beidou;
  if (prn >= 301 && prn <= 336) return GnssSystem.galileo;
  return GnssSystem.unknown;
}

class _Epoch {
  String? timeOfDay;
  bool haveGga = false, haveRmc = false, emitted = false;
  bool? rmcValid;
  int? quality;
  double? lat, lon, alt, hdop, speed, course;
  int? satsUsed;
  DateTime? utc;
  double? gstSigma;
}

/// Stateful assembler. Feed it lines with [addLine]; it returns a [GnssFix]
/// whenever an epoch is complete.
///
/// An epoch is complete when both RMC and GGA with the same UTC time have
/// been seen, or - for receivers that send only one of them - when a
/// sentence with a newer time arrives. Satellites come from the most recent
/// complete GSV cycles and are marked `used` from GSA.
///
/// Accuracy: NMEA carries no accuracy. If GST is present its lat/lon sigmas
/// are used; otherwise `accuracy = HDOP * uereM` with [uereM] defaulting to
/// 5 m (typical single-frequency user range error), floored at 3 m. With
/// neither HDOP nor GST the accuracy is [defaultAccuracyM].
class NmeaParser {
  NmeaParser({
    this.uereM = 5.0,
    this.defaultAccuracyM = 25.0,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final double uereM;
  final double defaultAccuracyM;
  final DateTime Function() _now;

  _Epoch _epoch = _Epoch();

  // GSV bookkeeping, keyed by "talker/signalId".
  final Map<String, List<GnssSatellite>> _gsvBuilding = {};
  final Map<String, List<GnssSatellite>> _gsvDone = {};
  final Map<String, DateTime> _gsvSeen = {};

  // Satellites used in the solution: "system.index/prn".
  final Set<String> _usedBuilding = {};
  Set<String> _used = {};
  double? _pdopHdop;

  /// Number of lines rejected (bad checksum / malformed).
  int rejected = 0;

  /// Number of sentences accepted.
  int accepted = 0;

  /// Feeds one line; returns a fix if this line completed an epoch.
  GnssFix? addLine(String line) {
    final s = NmeaSentence.parse(line);
    if (s == null) {
      if (line.trim().isNotEmpty) rejected++;
      return null;
    }
    accepted++;
    switch (s.type) {
      case 'GGA':
        return _gga(s);
      case 'RMC':
        return _rmc(s);
      case 'VTG':
        _vtg(s);
      case 'GSA':
        _gsa(s);
      case 'GSV':
        _gsv(s);
      case 'GST':
        return _gst(s);
    }
    return null;
  }

  /// Emits the pending epoch if it has not been emitted yet (for example at
  /// end of stream).
  GnssFix? flush() {
    if (_epoch.emitted || !(_epoch.haveGga || _epoch.haveRmc)) return null;
    return _emit();
  }

  /// Starts a new epoch if [timeOfDay] differs from the current one and
  /// returns the previous epoch if it still has to be emitted.
  GnssFix? _advance(String timeOfDay) {
    if (timeOfDay.isEmpty) return null;
    if (_epoch.timeOfDay == null || _epoch.timeOfDay == timeOfDay) {
      _epoch.timeOfDay = timeOfDay;
      return null;
    }
    GnssFix? pending;
    if (_epoch.timeOfDay != null &&
        !_epoch.emitted &&
        (_epoch.haveGga || _epoch.haveRmc)) {
      pending = _emit();
    }
    _epoch = _Epoch()..timeOfDay = timeOfDay;
    if (_usedBuilding.isNotEmpty) {
      _used = Set.of(_usedBuilding);
      _usedBuilding.clear();
    }
    return pending;
  }

  GnssFix? _gga(NmeaSentence s) {
    // time, lat, N, lon, E, quality, numSats, hdop, alt, M, geoid, M, age, id
    final pending = _advance(s.field(0));
    final e = _epoch;
    e.haveGga = true;
    e.quality = s.intAt(5) ?? 0;
    final lat = parseNmeaCoordinate(s.field(1), s.field(2));
    final lon = parseNmeaCoordinate(s.field(3), s.field(4));
    if (lat != null && lon != null) {
      e.lat = lat;
      e.lon = lon;
    }
    e.satsUsed = s.intAt(6);
    e.hdop = s.doubleAt(7) ?? e.hdop;
    e.alt = s.doubleAt(8);
    return pending ?? _maybeEmit();
  }

  GnssFix? _rmc(NmeaSentence s) {
    // time, status, lat, N, lon, E, speed kn, course, date, magvar, E, mode
    final pending = _advance(s.field(0));
    final e = _epoch;
    e.haveRmc = true;
    e.rmcValid = s.field(1) == 'A';
    final lat = parseNmeaCoordinate(s.field(2), s.field(3));
    final lon = parseNmeaCoordinate(s.field(4), s.field(5));
    if (lat != null && lon != null) {
      e.lat = lat;
      e.lon = lon;
    }
    final knots = s.doubleAt(6);
    if (knots != null) e.speed = knots * 0.514444;
    e.course = s.doubleAt(7) ?? e.course;
    e.utc = _utc(s.field(8), s.field(0));
    return pending ?? _maybeEmit();
  }

  void _vtg(NmeaSentence s) {
    // courseTrue, T, courseMag, M, speedKn, N, speedKmh, K, mode
    final e = _epoch;
    final course = s.doubleAt(0);
    if (course != null) e.course = course;
    final kmh = s.doubleAt(6);
    final knots = s.doubleAt(4);
    if (kmh != null) {
      e.speed = kmh / 3.6;
    } else if (knots != null) {
      e.speed = knots * 0.514444;
    }
  }

  void _gsa(NmeaSentence s) {
    // mode, fixType, 12 x prn, pdop, hdop, vdop[, systemId]
    final sysId = s.fields.length > 17 ? s.intAt(17) : null;
    final talkerSys = _systemFromTalker(s.talker);
    for (var i = 2; i < 14; i++) {
      final prn = s.intAt(i);
      if (prn == null || prn == 0) continue;
      final sys = sysId != null
          ? _systemFromId(sysId)
          : (talkerSys != GnssSystem.unknown ? talkerSys : _systemFromPrn(prn));
      _usedBuilding.add('${sys.index}/$prn');
    }
    final hdop = s.doubleAt(15);
    if (hdop != null && hdop > 0 && hdop < 99) {
      _pdopHdop = hdop;
      _epoch.hdop ??= hdop;
    }
  }

  void _gsv(NmeaSentence s) {
    // total, index, satsInView, then 4 x (prn, elev, az, cn0)[, signalId]
    final total = s.intAt(0), index = s.intAt(1);
    if (total == null || index == null) return;
    final n = s.fields.length - 3;
    final hasSignalId = n % 4 == 1;
    final signalId = hasSignalId
        ? int.tryParse(s.fields.last, radix: 16)
        : null;
    final key = '${s.talker}/${signalId ?? '-'}';
    if (index == 1) _gsvBuilding[key] = [];
    final list = _gsvBuilding[key];
    if (list == null) return; // joined mid-cycle
    final sys = _systemFromTalker(s.talker);
    final blocks = (n - (hasSignalId ? 1 : 0)) ~/ 4;
    for (var b = 0; b < blocks; b++) {
      final o = 3 + b * 4;
      final prn = s.intAt(o);
      if (prn == null) continue;
      list.add(
        GnssSatellite(
          system: sys != GnssSystem.unknown ? sys : _systemFromPrn(prn),
          prn: prn,
          elevationDeg: s.doubleAt(o + 1),
          azimuthDeg: s.doubleAt(o + 2),
          cn0: s.doubleAt(o + 3),
          signalId: signalId,
        ),
      );
    }
    if (index >= total) {
      _gsvDone[key] = list;
      _gsvSeen[key] = _now();
      _gsvBuilding.remove(key);
    }
  }

  GnssFix? _gst(NmeaSentence s) {
    // time, rms, major, minor, orient, latSigma, lonSigma, altSigma
    final pending = _advance(s.field(0));
    final la = s.doubleAt(5), lo = s.doubleAt(6);
    if (la != null && lo != null) {
      _epoch.gstSigma = math.sqrt(la * la + lo * lo);
    }
    return pending;
  }

  GnssFix? _maybeEmit() {
    final e = _epoch;
    if (e.emitted || !(e.haveGga && e.haveRmc)) return null;
    return _emit();
  }

  GnssFix _emit() {
    final e = _epoch;
    e.emitted = true;
    final valid =
        (e.rmcValid ?? true) &&
        (!e.haveGga || (e.quality ?? 0) > 0) &&
        e.lat != null &&
        e.lon != null;
    final hdop = e.hdop ?? _pdopHdop;
    double? accuracy;
    if (valid) {
      if (e.gstSigma != null) {
        accuracy = e.gstSigma! < 1.0 ? 1.0 : e.gstSigma!;
      } else if (hdop != null && hdop > 0 && hdop < 99) {
        accuracy = hdop * uereM;
        if (accuracy < 3.0) accuracy = 3.0;
      } else {
        accuracy = defaultAccuracyM;
      }
    }
    final now = _now();
    final used = _usedBuilding.isNotEmpty ? _usedBuilding : _used;
    final sats = <GnssSatellite>[];
    for (final entry in _gsvDone.entries) {
      final seen = _gsvSeen[entry.key];
      // Drop constellations that stopped being reported.
      if (seen != null && now.difference(seen).inSeconds > 10) continue;
      for (final sat in entry.value) {
        sats.add(
          GnssSatellite(
            system: sat.system,
            prn: sat.prn,
            elevationDeg: sat.elevationDeg,
            azimuthDeg: sat.azimuthDeg,
            cn0: sat.cn0,
            signalId: sat.signalId,
            used: used.contains('${sat.system.index}/${sat.prn}'),
          ),
        );
      }
    }
    return GnssFix(
      valid: valid,
      receivedAt: now,
      lat: e.lat,
      lon: e.lon,
      altitudeM: e.alt,
      accuracyM: accuracy,
      speedMps: valid ? e.speed : null,
      courseDeg: valid ? e.course : null,
      time: e.utc,
      hdop: hdop,
      fixQuality: e.quality,
      satellitesUsed: e.satsUsed,
      satellites: sats,
    );
  }

  static DateTime? _utc(String date, String time) {
    if (date.length != 6 || time.length < 6) return null;
    final d = int.tryParse(date.substring(0, 2));
    final mo = int.tryParse(date.substring(2, 4));
    final y = int.tryParse(date.substring(4, 6));
    final h = int.tryParse(time.substring(0, 2));
    final mi = int.tryParse(time.substring(2, 4));
    final sec = double.tryParse(time.substring(4));
    if (d == null ||
        mo == null ||
        y == null ||
        h == null ||
        mi == null ||
        sec == null) {
      return null;
    }
    final whole = sec.floor();
    return DateTime.utc(
      2000 + y,
      mo,
      d,
      h,
      mi,
      whole,
      ((sec - whole) * 1000).round(),
    );
  }
}
