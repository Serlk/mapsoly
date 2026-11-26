import 'dart:convert';

/// Fuel type reported by PID 0x51 (only the common values are named).
enum FuelType { unknown, petrol, diesel, lpg, cng, electric, hybrid, other }

FuelType fuelTypeFromCode(int code) => switch (code) {
  1 => FuelType.petrol,
  4 => FuelType.diesel,
  5 => FuelType.lpg,
  6 => FuelType.cng,
  8 => FuelType.electric,
  >= 16 && <= 23 => FuelType.hybrid,
  0 => FuelType.unknown,
  _ => FuelType.other,
};

/// Which of 32 consecutive PIDs an ECU supports, from the 4-byte bitmask
/// returned by PID [base] (0x00, 0x20, 0x40...). Bit 7 of the first byte is
/// PID base+1.
Set<int> supportedPids(int base, List<int> mask) => {
  for (var i = 0; i < mask.length * 8 && i < 32; i++)
    if (mask[i ~/ 8] & (0x80 >> (i % 8)) != 0) base + i + 1,
};

/// Engine speed in rpm from PID 0x0C.
double rpmFrom(List<int> d) => (d[0] * 256 + d[1]) / 4;

/// Coolant temperature in °C from PID 0x05.
int coolantFrom(List<int> d) => d[0] - 40;

/// Fuel tank level in percent from PID 0x2F.
double fuelLevelFrom(List<int> d) => d[0] * 100 / 255;

/// Fuel flow in litres per hour from PID 0x5E (reported directly by the ECU).
double fuelRateFrom(List<int> d) => (d[0] * 256 + d[1]) / 20;

/// Air mass flow in grams per second from PID 0x10.
double mafFrom(List<int> d) => (d[0] * 256 + d[1]) / 100;

/// Fuel flow in L/h estimated from air mass flow, assuming the engine burns
/// at the stoichiometric ratio. Reasonable for petrol engines; diesels run
/// lean, so for them this is not usable and null is returned.
double? fuelRateFromMaf(double mafGramsPerSecond, FuelType fuel) {
  const petrolAirFuelRatio = 14.7, petrolGramsPerLitre = 745.0;
  if (fuel == FuelType.diesel || fuel == FuelType.electric) return null;
  return mafGramsPerSecond * 3600 / (petrolAirFuelRatio * petrolGramsPerLitre);
}

/// Malfunction lamp state and number of stored codes from PID 0x01.
({bool milOn, int codes}) monitorStatusFrom(List<int> d) =>
    (milOn: d[0] & 0x80 != 0, codes: d[0] & 0x7F);

/// Decodes stored trouble codes (mode 03) from the adapter's reply lines.
///
/// CAN replies carry a count byte after `43`; older protocols do not and pad
/// with zero pairs instead. [can] tells which layout to expect.
List<String> troubleCodesFrom(List<String> lines, {required bool can}) {
  const letters = ['P', 'C', 'B', 'U'];
  final codes = <String>[];
  for (final line in lines) {
    var hex = line.replaceAll(' ', '').toUpperCase();
    // Multi-frame CAN replies prefix each line with "0:", "1:"...
    final colon = hex.indexOf(':');
    if (colon >= 0 && colon <= 2) hex = hex.substring(colon + 1);
    final at = hex.indexOf('43');
    if (at < 0 || !RegExp(r'^[0-9A-F]+$').hasMatch(hex)) continue;
    var payload = hex.substring(at + 2);
    if (can && payload.length >= 2) payload = payload.substring(2);
    for (var i = 0; i + 4 <= payload.length; i += 4) {
      final a = int.parse(payload.substring(i, i + 2), radix: 16);
      final rest = payload.substring(i + 2, i + 4);
      if (a == 0 && rest == '00') continue; // padding
      codes.add(
        '${letters[a >> 6]}${(a >> 4) & 3}'
        '${(a & 0xF).toRadixString(16).toUpperCase()}$rest',
      );
    }
  }
  return codes;
}

/// Decodes the VIN (mode 09, PID 02) from the adapter's reply lines, or null.
///
/// CAN adapters print a length line and numbered frames (`0:490201...`);
/// older protocols print five lines `4902 NN xx xx xx xx`.
String? vinFrom(List<String> lines) {
  final bytes = <int>[];
  final numbered = lines.any((l) => RegExp(r'^\s*[0-9A-Fa-f]:').hasMatch(l));
  if (numbered) {
    final joined = StringBuffer();
    for (final line in lines) {
      final m = RegExp(r'^\s*[0-9A-Fa-f]:(.*)$').firstMatch(line);
      if (m != null) joined.write(m[1]!.replaceAll(' ', ''));
    }
    final hex = joined.toString().toUpperCase();
    final at = hex.indexOf('4902');
    if (at < 0) return null;
    // Skip "4902" and the item count byte.
    for (var i = at + 6; i + 2 <= hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
  } else {
    for (final line in lines) {
      final hex = line.replaceAll(' ', '').toUpperCase();
      final at = hex.indexOf('4902');
      if (at < 0) continue;
      // Skip "4902" and the sequence (or count) byte.
      for (var i = at + 6; i + 2 <= hex.length; i += 2) {
        bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
      }
    }
  }
  final text = ascii
      .decode(bytes.where((b) => b >= 0x20 && b < 0x7F).toList())
      .trim();
  return text.length == 17 ? text : null;
}

/// Facts about the vehicle that do not change during a trip.
class VehicleInfo {
  const VehicleInfo({
    this.vin,
    this.fuelType = FuelType.unknown,
    this.milOn,
    this.troubleCodes = const [],
    this.adapter,
    this.protocol,
  });

  final String? vin;
  final FuelType fuelType;

  /// Malfunction indicator lamp; null when the ECU did not say.
  final bool? milOn;
  final List<String> troubleCodes;
  final String? adapter;
  final String? protocol;
}

/// Live readings beyond speed. Any field is null when the ECU does not
/// provide it.
class ObdTelemetry {
  const ObdTelemetry({
    this.rpm,
    this.coolantC,
    this.fuelLevelPercent,
    this.fuelRateLph,
    this.fuelRateEstimated = false,
    this.consumptionLPer100km,
    this.tripFuelL = 0,
    this.tripDistanceKm = 0,
    this.batteryVolts,
  });

  final double? rpm;
  final int? coolantC;
  final double? fuelLevelPercent;

  /// Fuel flow in L/h; [fuelRateEstimated] is true when it was derived from
  /// air flow rather than reported by the ECU.
  final double? fuelRateLph;
  final bool fuelRateEstimated;

  /// Instant consumption; null while standing still (see [fuelRateLph]).
  final double? consumptionLPer100km;

  /// Fuel burnt and distance covered since the session started.
  final double tripFuelL, tripDistanceKm;
  final double? batteryVolts;

  /// Average consumption over the trip, once it is long enough to mean
  /// something.
  double? get tripConsumptionLPer100km =>
      tripDistanceKm < 0.5 ? null : tripFuelL / tripDistanceKm * 100;
}
