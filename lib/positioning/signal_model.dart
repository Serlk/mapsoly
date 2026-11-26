/// Signal-strength to distance model shared by the estimator and the
/// wardriving collector.
library;

import 'dart:math' as math;

/// Log-distance path-loss model: `rssi(d) = p0 - 10 * n * log10(d / 1 m)`.
///
/// Constants (documented in docs/positioning.md):
///  * [p0At2400] = -40 dBm at 1 m for 2.4 GHz: ~20 dBm EIRP minus 40 dB
///    free-space loss at 1 m, minus ~20 dB of typical antenna/body/first-wall
///    losses of a phone in a pocket or car.
///  * 5/6 GHz reference levels are lowered by the free-space difference
///    `20 * log10(f / 2437)` (about -6.7 dB at 5.2 GHz).
///  * [exponent] = 2.7: between free space (2.0) and dense indoor (3.5-4),
///    a common compromise for mixed outdoor/indoor urban reception.
///
/// The absolute distances are crude (walls can cost 10-20 dB), so they are
/// used only for relative weighting and for accuracy radii, never as ranges
/// for trilateration.
class PathLossModel {
  const PathLossModel({this.p0At2400 = -40.0, this.exponent = 2.7});

  final double p0At2400;
  final double exponent;

  /// Estimated distance in metres for [dbm] at [frequencyMhz], clamped to
  /// [1, 300] m (beyond ~300 m consumer Wi-Fi is practically never heard).
  double wifiDistanceM(double dbm, {int? frequencyMhz}) {
    var p0 = p0At2400;
    if (frequencyMhz != null && frequencyMhz > 3000) {
      p0 -= 20 * math.log(frequencyMhz / 2437.0) / math.ln10;
    }
    final d = math.pow(10.0, (p0 - dbm) / (10.0 * exponent)).toDouble();
    return d.clamp(1.0, 300.0);
  }
}

/// Signal assumed for an AP whose level is unknown (weak but usable).
const double unknownWifiDbm = -85.0;
