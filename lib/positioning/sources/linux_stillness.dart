/// "The device lies still" on Linux, from the kernel's IIO accelerometer.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

/// Decides stillness from the spread of |acceleration| over the last few
/// seconds; the same rule and thresholds as StillnessBridge.kt on Android.
///
/// "Still" is strict on purpose: the spread must be down at the sensor's
/// own noise. A table gives that; a hand, a pocket or a car does not.
class StillnessDetector {
  StillnessDetector({
    this.window = 16,
    this.stillBelow = 0.04,
    this.movingAbove = 0.07,
  }) : _values = List.filled(window, 0);

  /// Readings looked at (about three seconds at five a second).
  final int window;

  /// Standard deviation of |acceleration|, m/s^2: below the first the
  /// device is still; once still it stays so until above the second.
  final double stillBelow;
  final double movingAbove;

  final List<double> _values;
  int _filled = 0, _next = 0;

  /// Null until the window has filled once.
  bool? still;

  /// Adds one reading (m/s^2); returns the new state when it changed.
  bool? add(double x, double y, double z) {
    _values[_next] = math.sqrt(x * x + y * y + z * z);
    _next = (_next + 1) % window;
    if (_filled < window) {
      _filled++;
      if (_filled < window) return null;
    }
    final mean = _values.reduce((a, b) => a + b) / window;
    var variance = 0.0;
    for (final v in _values) {
      variance += (v - mean) * (v - mean);
    }
    final deviation = math.sqrt(variance / window);
    final now = deviation < (still == true ? movingAbove : stillBelow);
    if (now == still) return null;
    return still = now;
  }
}

/// Reads the accelerometer from sysfs five times a second while listened
/// to. The stream carries true/false whenever the state changes; it stays
/// silent when there is no accelerometer.
class IioStillness {
  IioStillness({
    this.root = '/sys/bus/iio/devices',
    this.period = const Duration(milliseconds: 200),
  });

  final String root;
  final Duration period;

  /// The accelerometer's directory: a device with raw acceleration axes,
  /// the plain one rather than "linear acceleration" (gravity removed)
  /// where both exist. Null when there is none.
  static Directory? find(String root) {
    final dir = Directory(root);
    if (!dir.existsSync()) return null;
    Directory? fallback;
    final entries = dir.listSync().map((e) => e.path).toList()..sort();
    for (final path in entries) {
      if (!File('$path/in_accel_x_raw').existsSync()) continue;
      var name = '';
      try {
        name = File('$path/name').readAsStringSync().trim();
      } on Object {
        // Unnamed: still an accelerometer.
      }
      if (!name.contains('linear')) return Directory(path);
      fallback ??= Directory(path);
    }
    return fallback;
  }

  /// m/s^2 per raw unit. From `in_accel_scale` when the driver gives one;
  /// otherwise guessed from gravity: a resting reading of about 9800 means
  /// the driver reports mm/s^2 (the Titan 2 sensor hub does).
  static double scaleOf(Directory device, double rawMagnitude) {
    try {
      final s = double.tryParse(
        File('${device.path}/in_accel_scale').readAsStringSync().trim(),
      );
      if (s != null && s > 0) return s;
    } on Object {
      // No scale attribute.
    }
    if (rawMagnitude > 3000 && rawMagnitude < 30000) return 0.001;
    return 1;
  }

  Stream<bool> get states {
    late StreamController<bool> out;
    Timer? timer;
    out = StreamController<bool>(
      onListen: () {
        final device = find(root);
        if (device == null) return;
        final detector = StillnessDetector();
        double? scale;
        double? axis(String a) => double.tryParse(
          File('${device.path}/in_accel_${a}_raw').readAsStringSync().trim(),
        );
        timer = Timer.periodic(period, (_) {
          try {
            final x = axis('x'), y = axis('y'), z = axis('z');
            if (x == null || y == null || z == null) return;
            final k = scale ??= scaleOf(
              device,
              math.sqrt(x * x + y * y + z * z),
            );
            final changed = detector.add(x * k, y * k, z * k);
            if (changed != null) out.add(changed);
          } on Object {
            // The sensor went away for a moment: no reading, no change.
          }
        });
      },
      onCancel: () => timer?.cancel(),
    );
    return out.stream;
  }
}
