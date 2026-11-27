/// A diagnostics journal of what the receiver said and what the spoofing
/// check made of it, one line per epoch. It answers "why did the position
/// go away on that road" after the fact, which nothing else can.
library;

import 'dart:io';

import 'gnss_sanity.dart';
import 'models.dart';

/// Writes the journal to a CSV file on this device. Nothing is ever sent
/// anywhere, and nothing is written while the engine reports a private
/// area.
///
/// Off unless asked for: the file is a track of where the device has been.
/// It is asked for by the `MAPSOLY_POS_LOG=<file>` environment variable or
/// by a file named `positioning-journal.on` next to the database (then the
/// journal is `positioning-journal.csv` beside it).
class PositionJournal {
  PositionJournal(this.path, {this.maxBytes = 20 * 1024 * 1024});

  /// The journal asked for by the environment or the marker file, or null.
  static PositionJournal? requested(String dbPath) {
    final env = Platform.environment['MAPSOLY_POS_LOG'];
    if (env != null && env.isNotEmpty) return PositionJournal(env);
    final dir = File(dbPath).parent.path;
    if (File('$dir/positioning-journal.on').existsSync()) {
      return PositionJournal('$dir/positioning-journal.csv');
    }
    return null;
  }

  final String path;

  /// At this size the file becomes `<path>.1` (replacing the previous one)
  /// and a new one is started.
  final int maxBytes;

  RandomAccessFile? _out;
  int _written = 0;
  bool _failed = false;

  static const header =
      'time,lat,lon,acc,speed,course,gnss_time,sats,cn0_mean,cn0_std,'
      'verdict,usable,anomalies,radio_source,radio_lat,radio_lon,radio_acc,'
      'radio_age_s,out_source,out_lat,out_lon,out_acc';

  static String _n(double? v, [int digits = 1]) =>
      v == null ? '' : v.toStringAsFixed(digits);

  /// One epoch. [private] leaves out every coordinate.
  void gnss(
    GnssFix fix,
    GnssHealth health, {
    PositionEstimate? radio,
    PositionEstimate? output,
    bool private = false,
  }) {
    if (_failed) return;
    final at = fix.receivedAt;
    final hide = private;
    final line = [
      at.toUtc().toIso8601String(),
      hide ? '' : _n(fix.lat, 6),
      hide ? '' : _n(fix.lon, 6),
      _n(fix.accuracyM),
      _n(fix.speedMps),
      _n(fix.courseDeg, 0),
      fix.time?.toUtc().toIso8601String() ?? '',
      fix.satellites.length,
      _n(health.cn0Mean),
      _n(health.cn0StdDev),
      health.verdict.name,
      health.usable ? 1 : 0,
      health.anomalies.map((a) => a.name).join('+'),
      radio?.source.name ?? '',
      hide ? '' : _n(radio?.lat, 6),
      hide ? '' : _n(radio?.lon, 6),
      _n(radio?.accuracyM, 0),
      radio == null ? '' : at.difference(radio.timestamp).inSeconds,
      output?.source.name ?? '',
      hide ? '' : _n(output?.lat, 6),
      hide ? '' : _n(output?.lon, 6),
      _n(output?.accuracyM, 0),
    ].join(',');
    _write(line);
  }

  void _write(String line) {
    try {
      var out = _out;
      if (out == null || _written > maxBytes) {
        out?.closeSync();
        _out = null;
        final file = File(path);
        if (file.existsSync() && file.lengthSync() > maxBytes) {
          file.renameSync('$path.1');
        }
        final fresh = !file.existsSync();
        out = _out = file.openSync(mode: FileMode.append);
        _written = out.lengthSync();
        if (fresh) out.writeStringSync('$header\n');
      }
      // A line or two a second: written through at once, so that the tail
      // survives the app being killed.
      out.writeStringSync('$line\n');
      _written += line.length + 1;
    } on Object {
      // Diagnostics must never get in the way of positioning.
      _failed = true;
    }
  }

  Future<void> close() async {
    final out = _out;
    _out = null;
    try {
      out?.closeSync();
    } on Object {
      // Nothing to do about it.
    }
  }
}
