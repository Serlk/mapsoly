/// Debug hook `MAPSOLY_STATS=<seconds>`: every so often prints how many
/// times the busy places of the app ran, to find what keeps the processor
/// awake. Costs one map increment per event when on, nothing when off.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

abstract final class DebugStats {
  static final int? _period = int.tryParse(
    Platform.environment['MAPSOLY_STATS'] ?? '',
  );
  static final Map<String, int> _counts = {};
  static Timer? _timer;

  static void count(String what) {
    final period = _period;
    if (period == null || period <= 0) return;
    _counts[what] = (_counts[what] ?? 0) + 1;
    _timer ??= Timer.periodic(Duration(seconds: period), (_) {
      final keys = _counts.keys.toList()..sort();
      debugPrint(
        'stats/${period}s: ${[for (final k in keys) '$k=${_counts[k]}'].join(' ')}',
      );
      _counts.clear();
    });
  }
}
