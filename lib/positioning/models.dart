/// Data model of the positioning subsystem: radio observations, GNSS fixes
/// and the resulting position estimate.
library;

/// Kind of transmitter stored in the location database.
enum TransmitterKind { wifi, cell, ble }

/// Cellular radio access technology.
enum RadioType { gsm, umts, lte, nr, cdma, unknown }

/// Where a [PositionEstimate] came from.
enum PositionSource { gnss, wifi, cell, fused, deadReckoning }

/// Normalises a MAC/BSSID to lower-case, colon-separated, zero-padded form
/// (`0:21:5a:..` as returned by Apple, `AA-BB-..`, `aabbcc..` are accepted).
/// Returns null when [raw] is not a 48-bit MAC address.
String? normalizeMac(String raw) {
  final s = raw.trim().toLowerCase();
  List<String> parts;
  if (s.contains(':') || s.contains('-')) {
    parts = s.split(RegExp('[:-]'));
  } else if (s.length == 12) {
    parts = [for (var i = 0; i < 12; i += 2) s.substring(i, i + 2)];
  } else {
    return null;
  }
  if (parts.length != 6) return null;
  final out = <String>[];
  for (final p in parts) {
    if (p.isEmpty || p.length > 2) return null;
    final v = int.tryParse(p, radix: 16);
    if (v == null) return null;
    out.add(v.toRadixString(16).padLeft(2, '0'));
  }
  return out.join(':');
}

/// Formats six raw bytes as a normalised MAC string.
String macFromBytes(List<int> bytes) =>
    bytes.map((b) => (b & 0xff).toRadixString(16).padLeft(2, '0')).join(':');

/// One Wi-Fi access point as seen in a scan.
class WifiObservation {
  const WifiObservation({
    required this.bssid,
    this.frequencyMhz,
    this.signalDbm,
    this.signalPercent,
    this.age = Duration.zero,
    this.ssid,
  });

  /// Normalised BSSID (see [normalizeMac]).
  final String bssid;

  /// Channel centre frequency in MHz, null when unknown.
  final int? frequencyMhz;

  /// Measured signal in dBm, null when the platform only reports percent.
  final double? signalDbm;

  /// Signal quality 0..100 as reported by NetworkManager, null when unknown.
  final int? signalPercent;

  /// Time since the AP was last heard.
  final Duration age;

  /// SSID if known. Only used to honour the `_nomap` opt-out; never sent to
  /// any online service.
  final String? ssid;

  /// Best available dBm value: the measured one, otherwise an approximation
  /// reconstructed from NetworkManager's percentage (see [percentToDbm]).
  double? get effectiveDbm =>
      signalDbm ??
      (signalPercent == null ? null : percentToDbm(signalPercent!));

  /// True when the owner opted out of location databases.
  bool get optedOut =>
      ssid != null && (ssid!.endsWith('_nomap') || ssid!.contains('_optout'));

  @override
  String toString() =>
      'Wifi($bssid ${frequencyMhz ?? '?'}MHz '
      '${signalDbm?.toStringAsFixed(0) ?? '~${effectiveDbm?.toStringAsFixed(0)}'}dBm '
      'age ${age.inSeconds}s)';
}

/// Inverse of NetworkManager's `nm_wifi_utils_level_to_quality()`:
/// quality = 100 - 100 * (-40 - dBm) / 60, clamped to dBm in [-100, -40].
///
/// Verified on the Titan 2 on 2026-11-26 by comparing `iw scan dump` (dBm)
/// with `nmcli` (percent) for the same APs: -90 -> 17, -78 -> 37, -69 -> 52.
/// 100 % only means "-40 dBm or stronger".
double percentToDbm(int percent) => 0.6 * percent.clamp(0, 100) - 100.0;

/// One cell (serving or neighbour) reported by the modem.
///
/// Every nullable field is null when the modem did not report it. A value of
/// 0 is never used as "unknown".
class CellObservation {
  const CellObservation({
    required this.radio,
    this.mcc,
    this.mnc,
    this.area,
    this.cellId,
    this.pci,
    this.arfcn,
    this.signalDbm,
    this.rsrq,
    this.timingAdvance,
    this.serving = false,
    this.modem,
  });

  final RadioType radio;
  final int? mcc;
  final int? mnc;

  /// LAC (GSM/UMTS) or TAC (LTE/NR).
  final int? area;

  /// Full cell identity: CI (GSM, 16 bit), UTRAN cell id (28 bit),
  /// E-UTRAN cell identity (28 bit) or NR cell identity (36 bit).
  final int? cellId;

  /// Physical cell id (LTE/NR), PSC (UMTS) or BSIC (GSM).
  final int? pci;

  /// ARFCN / UARFCN / EARFCN / NR-ARFCN.
  final int? arfcn;

  /// RSRP (LTE/NR), RSCP (UMTS) or RSSI (GSM) in dBm.
  final double? signalDbm;

  /// RSRQ in dB (LTE/NR) or Ec/Io (UMTS).
  final double? rsrq;

  /// Raw timing advance exactly as reported by the modem; convert with
  /// [timingAdvanceMeters].
  final int? timingAdvance;

  final bool serving;

  /// Index of the modem (SIM) that reported the cell.
  final int? modem;

  /// True when the cell can be looked up in a database.
  bool get hasFullId =>
      mcc != null && mnc != null && area != null && cellId != null;

  /// Database key `radio:mcc:mnc:area:cid`, null without a full identity.
  String? get key =>
      hasFullId ? cellKey(radio, mcc!, mnc!, area!, cellId!) : null;

  @override
  String toString() =>
      'Cell(${radio.name} $mcc-$mnc area $area ci $cellId pci $pci '
      '${signalDbm ?? '?'}dBm ta $timingAdvance${serving ? ' serving' : ''})';
}

/// Database key of a cell.
String cellKey(RadioType radio, int mcc, int mnc, int area, int cellId) =>
    '${radio.name}:$mcc:$mnc:$area:$cellId';

/// Metres of one-way distance per timing-advance unit.
///
/// * LTE: one TA unit is 16 Ts = 16 / (15000 * 2048) s = 0.5208 us of round
///   trip, i.e. c * 16 Ts / 2 = 78.12 m.
/// * NR: 16 * 64 * Tc / 2^mu; for 15 kHz subcarrier spacing (mu = 0) this is
///   the same 78.12 m. Higher numerologies halve it each step, so this value
///   is an upper bound for NR. ASSUMPTION until the modem team documents the
///   unit they report.
/// * GSM: one bit period (48/13 us) of round trip = 553.46 m.
double? timingAdvanceUnitMeters(RadioType radio) => switch (radio) {
  RadioType.lte || RadioType.nr => 78.12,
  RadioType.gsm => 553.46,
  _ => null,
};

/// Converts a raw timing advance to an approximate distance in metres, or
/// null when the radio type has no defined conversion.
double? timingAdvanceMeters(RadioType radio, int? raw) {
  final unit = timingAdvanceUnitMeters(radio);
  if (unit == null || raw == null || raw < 0) return null;
  return raw * unit;
}

/// One Bluetooth LE advertiser.
class BleObservation {
  const BleObservation({
    required this.address,
    this.rssiDbm,
    this.age = Duration.zero,
    this.randomAddress = false,
  });

  final String address;
  final double? rssiDbm;
  final Duration age;

  /// Random (private) addresses rotate and are useless for positioning.
  final bool randomAddress;
}

/// GNSS constellation, derived from the NMEA talker or system id.
enum GnssSystem { gps, glonass, galileo, beidou, qzss, navic, sbas, unknown }

/// One satellite from GSV.
class GnssSatellite {
  const GnssSatellite({
    required this.system,
    required this.prn,
    this.elevationDeg,
    this.azimuthDeg,
    this.cn0,
    this.signalId,
    this.used = false,
  });

  final GnssSystem system;
  final int prn;
  final double? elevationDeg;
  final double? azimuthDeg;

  /// Carrier-to-noise density in dB-Hz, null when not tracked.
  final double? cn0;

  /// NMEA 4.10+ signal id (1 = L1 C/A for GPS ...), null on older receivers.
  final int? signalId;

  /// True when the satellite is listed in GSA as used in the solution.
  final bool used;
}

/// One GNSS epoch.
class GnssFix {
  const GnssFix({
    required this.valid,
    required this.receivedAt,
    this.lat,
    this.lon,
    this.altitudeM,
    this.accuracyM,
    this.speedMps,
    this.courseDeg,
    this.time,
    this.hdop,
    this.fixQuality,
    this.satellitesUsed,
    this.satellites = const [],
  });

  /// True when the receiver itself reports a valid position.
  final bool valid;
  final double? lat;
  final double? lon;
  final double? altitudeM;

  /// Horizontal accuracy radius in metres (about 68 %), see NmeaParser.
  final double? accuracyM;
  final double? speedMps;

  /// Course over ground in degrees, null when not moving / not reported.
  final double? courseDeg;

  /// UTC time of the fix from the receiver, null before the first RMC.
  final DateTime? time;

  /// Local clock when the epoch was completed. Never taken from the receiver,
  /// so a spoofed GNSS time cannot disturb the filter timing.
  final DateTime receivedAt;
  final double? hdop;

  /// GGA quality: 0 none, 1 autonomous, 2 differential, 4/5 RTK, 6 estimated.
  final int? fixQuality;
  final int? satellitesUsed;
  final List<GnssSatellite> satellites;

  bool get hasPosition => valid && lat != null && lon != null;

  @override
  String toString() =>
      'GnssFix(${valid ? 'valid' : 'invalid'} $lat,$lon '
      '±${accuracyM?.toStringAsFixed(0)}m v=$speedMps crs=$courseDeg '
      'sats=${satellites.length})';
}

/// Result of the estimator / fusion filter.
class PositionEstimate {
  const PositionEstimate({
    required this.lat,
    required this.lon,
    required this.accuracyM,
    required this.source,
    required this.timestamp,
    this.speedMps,
    this.courseDeg,
    this.transmittersUsed = 0,
  });

  final double lat;
  final double lon;

  /// Radius in metres expected to contain the true position about 68 % of
  /// the time. See docs/positioning.md for how each source derives it.
  final double accuracyM;
  final PositionSource source;
  final DateTime timestamp;
  final double? speedMps;
  final double? courseDeg;

  /// Number of transmitters that contributed (0 for GNSS / dead reckoning).
  final int transmittersUsed;

  @override
  String toString() =>
      'Position(${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)} '
      '±${accuracyM.toStringAsFixed(0)}m ${source.name}'
      '${speedMps == null ? '' : ' v=${speedMps!.toStringAsFixed(1)}m/s'}'
      '${courseDeg == null ? '' : ' crs=${courseDeg!.toStringAsFixed(0)}'})';
}

/// Privacy hook: returns true when the circle of [radiusM] metres around a
/// point touches an area where nothing may be recorded or sent out (a
/// user-defined "safe zone"). A radius of 0 asks about the point itself.
///
/// The positioning code does not know where the zones come from; the app
/// installs the hook (see `PositioningEngine.privacyFilter`).
typedef PrivacyFilter = bool Function(double lat, double lon, double radiusM);
