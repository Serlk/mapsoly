/// The accuracy radius as drawn on the map.
library;

/// Takes the breathing out of the accuracy circle.
///
/// Between two Wi-Fi scans (15 s apart on Linux, 35 s on Android) the
/// positioning filter honestly widens its estimate, and the next scan pulls
/// it back: drawn as it is, the circle pulses with every scan, which says
/// nothing to the person looking at it. The circle shows the smallest radius
/// of the last [window] instead: what the fixes are good for. Only when
/// nothing has confirmed the position for that long does it grow.
class SteadyAccuracy {
  SteadyAccuracy({this.window = const Duration(seconds: 45)});

  final Duration window;
  final List<(DateTime, double)> _recent = [];

  /// The radius to draw for an estimate of [accuracyM] at [now]; null in,
  /// null out (and the history is forgotten: there is no position).
  double? of(double? accuracyM, DateTime now) {
    if (accuracyM == null) {
      _recent.clear();
      return null;
    }
    _recent.removeWhere((e) => now.difference(e.$1) > window);
    // Keep only what can still be a minimum later: values not larger than
    // every newer one.
    while (_recent.isNotEmpty && _recent.last.$2 >= accuracyM) {
      _recent.removeLast();
    }
    _recent.add((now, accuracyM));
    return _recent.first.$2;
  }
}
