/// Pure decoding of D-Bus property dictionaries into observation models.
///
/// Kept free of any bus I/O so it can be unit-tested against dictionaries
/// captured on the phone.
library;

import 'package:dbus/dbus.dart';

import '../models.dart';

/// Reads any D-Bus integer type as int; null for other types.
int? dbusInt(DBusValue? v) {
  if (v == null) return null;
  if (v is DBusVariant) return dbusInt(v.value);
  return switch (v) {
    DBusByte() => v.value,
    DBusInt16() => v.value,
    DBusUint16() => v.value,
    DBusInt32() => v.value,
    DBusUint32() => v.value,
    DBusInt64() => v.value,
    DBusUint64() => v.value,
    _ => null,
  };
}

/// Reads a D-Bus double or integer as double.
double? dbusDouble(DBusValue? v) {
  if (v == null) return null;
  if (v is DBusVariant) return dbusDouble(v.value);
  if (v is DBusDouble) return v.value;
  return dbusInt(v)?.toDouble();
}

String? dbusString(DBusValue? v) {
  if (v == null) return null;
  if (v is DBusVariant) return dbusString(v.value);
  return v is DBusString ? v.value : null;
}

bool? dbusBool(DBusValue? v) {
  if (v == null) return null;
  if (v is DBusVariant) return dbusBool(v.value);
  return v is DBusBoolean ? v.value : null;
}

List<int>? dbusBytes(DBusValue? v) {
  if (v == null) return null;
  if (v is DBusVariant) return dbusBytes(v.value);
  if (v is! DBusArray) return null;
  final out = <int>[];
  for (final c in v.children) {
    final b = dbusInt(c);
    if (b == null) return null;
    out.add(b);
  }
  return out;
}

String? _ssid(DBusValue? v) {
  final bytes = dbusBytes(v);
  if (bytes == null || bytes.isEmpty) return null;
  return String.fromCharCodes(bytes);
}

/// Decodes `org.freedesktop.NetworkManager.AccessPoint` properties.
///
/// [boottimeSeconds] is the current CLOCK_BOOTTIME; `LastSeen` is expressed
/// on the same clock (-1 = never seen). NetworkManager only gives `Strength`
/// in percent.
WifiObservation? decodeNmAccessPoint(
  Map<String, DBusValue> props, {
  required double boottimeSeconds,
}) {
  final hw = dbusString(props['HwAddress']);
  final bssid = hw == null ? null : normalizeMac(hw);
  if (bssid == null) return null;
  final lastSeen = dbusInt(props['LastSeen']);
  if (lastSeen == null || lastSeen < 0) return null;
  var ageS = boottimeSeconds - lastSeen;
  if (ageS < 0) ageS = 0;
  final freq = dbusInt(props['Frequency']);
  return WifiObservation(
    bssid: bssid,
    frequencyMhz: freq == null || freq == 0 ? null : freq,
    signalPercent: dbusInt(props['Strength']),
    age: Duration(milliseconds: (ageS * 1000).round()),
    ssid: _ssid(props['Ssid']),
  );
}

/// Decodes `fi.w1.wpa_supplicant1.BSS` properties (`Signal` is dBm, `Age`
/// is seconds since the BSS was last seen).
WifiObservation? decodeWpaBss(Map<String, DBusValue> props) {
  final raw = dbusBytes(props['BSSID']);
  if (raw == null || raw.length != 6) return null;
  final signal = dbusInt(props['Signal']);
  final freq = dbusInt(props['Frequency']);
  final age = dbusInt(props['Age']);
  return WifiObservation(
    bssid: macFromBytes(raw),
    frequencyMhz: freq == null || freq == 0 ? null : freq,
    // wpa_supplicant reports 0 when the driver gave no level at all.
    signalDbm: signal == null || signal >= 0 ? null : signal.toDouble(),
    age: Duration(seconds: age ?? 0),
    ssid: _ssid(props['SSID']),
  );
}

/// ModemManager `MMModemAccessTechnology` bitmask to a radio type (the
/// technology that owns the registered cell identity).
RadioType radioFromAccessTechnologies(int? mask) {
  if (mask == null || mask == 0) return RadioType.unknown;
  // LTE, LTE Cat-M, LTE NB-IoT. Checked before NR on purpose: in NSA mode
  // both bits are set and the registered cell identity is the LTE anchor.
  if (mask & ((1 << 14) | (1 << 16) | (1 << 17)) != 0) return RadioType.lte;
  if (mask & (1 << 15) != 0) return RadioType.nr;
  // UMTS, HSDPA, HSUPA, HSPA, HSPA+
  if (mask & 0x3e0 != 0) return RadioType.umts;
  // GSM, GSM compact, GPRS, EDGE
  if (mask & 0x1e != 0) return RadioType.gsm;
  // 1xRTT, EVDO0/A/B
  if (mask & 0x3c00 != 0) return RadioType.cdma;
  return RadioType.unknown;
}

int? _hex(String? s) {
  if (s == null) return null;
  var t = s.trim();
  if (t.startsWith('0x') || t.startsWith('0X')) t = t.substring(2);
  if (t.isEmpty) return null;
  return int.tryParse(t, radix: 16);
}

/// Parses a 3GPP operator id ("25020" / "310260") into (mcc, mnc).
(int, int)? parseOperatorId(String? id) {
  if (id == null) return null;
  final t = id.trim();
  if (t.length < 5 || t.length > 6) return null;
  final mcc = int.tryParse(t.substring(0, 3));
  final mnc = int.tryParse(t.substring(3));
  if (mcc == null || mnc == null) return null;
  return (mcc, mnc);
}

/// Decodes the `Modem.Location` dictionary (`a{uv}`), using only source 1
/// (`MM_MODEM_LOCATION_SOURCE_3GPP_LAC_CI`), a string
/// `"MCC,MNC,LAC,CI,TAC"` with LAC, CI and TAC in upper-case hex without
/// prefix. Captured on the Titan 2: `250,20,0,1A2B3C4,1F40`.
///
/// LAC and TAC are mutually exclusive in practice: ModemManager reports 0
/// for the one that does not apply. [accessTechnologies] (the `Modem`
/// property) decides the radio type; when it is unknown a non-zero TAC is
/// taken as LTE.
CellObservation? decodeMmLocation(
  Map<int, DBusValue> location, {
  int? accessTechnologies,
  int? modem,
}) {
  final s = dbusString(location[1]);
  if (s == null) return null;
  final p = s.split(',');
  if (p.length < 4) return null;
  final mcc = int.tryParse(p[0]), mnc = int.tryParse(p[1]);
  final lac = _hex(p[2]), ci = _hex(p[3]);
  final tac = p.length > 4 ? _hex(p[4]) : null;
  if (mcc == null || mnc == null || ci == null || ci == 0) return null;
  var radio = radioFromAccessTechnologies(accessTechnologies);
  final hasTac = tac != null && tac != 0;
  final hasLac = lac != null && lac != 0;
  if (radio == RadioType.unknown) {
    radio = hasTac
        ? (ci > 0x0fffffff ? RadioType.nr : RadioType.lte)
        : (ci > 0xffff ? RadioType.umts : RadioType.gsm);
  }
  final usesTac = radio == RadioType.lte || radio == RadioType.nr;
  final area = usesTac
      ? (hasTac ? tac : (hasLac ? lac : null))
      : (hasLac ? lac : (hasTac ? tac : null));
  return CellObservation(
    radio: radio,
    mcc: mcc,
    mnc: mnc,
    area: area,
    cellId: ci,
    serving: true,
    modem: modem,
  );
}

/// Decodes one dictionary returned by `Modem.GetCellInfo()` (`aa{sv}`).
///
/// Written against the documented ModemManager 1.20+ API (`MMCellInfo*`):
/// `cell-type` (u: 1 CDMA, 2 GSM, 3 UMTS, 4 TD-SCDMA, 5 LTE, 6 5GNR),
/// `serving` (b), `operator-id` (s), `lac`/`tac`/`ci`/`physical-ci`/`psc`/
/// `base-station-id` (s, hex without prefix), `arfcn`/`uarfcn`/`earfcn`/
/// `nrarfcn` (u), `rsrp`/`rsrq`/`rscp`/`ecio`/`sinr` (d), `rx-level` (u,
/// GSM RXLEV 0..63), `timing-advance` (u, raw).
///
/// ASSUMPTION (not verifiable on the phone yet): identifier strings are hex.
/// Numeric D-Bus types are accepted too, in case the plugin sends integers.
/// A missing key stays null; nothing is defaulted to 0.
CellObservation? decodeMmCellInfo(Map<String, DBusValue> d, {int? modem}) {
  final type = dbusInt(d['cell-type']);
  final radio = switch (type) {
    1 => RadioType.cdma,
    2 => RadioType.gsm,
    3 || 4 => RadioType.umts,
    5 => RadioType.lte,
    6 => RadioType.nr,
    _ => RadioType.unknown,
  };
  if (radio == RadioType.unknown || radio == RadioType.cdma) return null;
  int? id(String key) {
    final v = d[key];
    if (v == null) return null;
    return dbusInt(v) ?? _hex(dbusString(v));
  }

  final op = parseOperatorId(dbusString(d['operator-id']));
  final usesTac = radio == RadioType.lte || radio == RadioType.nr;
  final pci = switch (radio) {
    RadioType.lte || RadioType.nr => id('physical-ci'),
    RadioType.umts => id('psc'),
    RadioType.gsm => id('base-station-id'),
    _ => null,
  };
  final arfcn = dbusInt(
    d[switch (radio) {
      RadioType.lte => 'earfcn',
      RadioType.nr => 'nrarfcn',
      RadioType.umts => 'uarfcn',
      _ => 'arfcn',
    }],
  );
  double? signal;
  switch (radio) {
    case RadioType.lte || RadioType.nr:
      signal = dbusDouble(d['rsrp']);
    case RadioType.umts:
      signal = dbusDouble(d['rscp']);
    case RadioType.gsm:
      // 3GPP TS 45.008: RXLEV n means -110 + n dBm (n = 0 is "< -110").
      final rx = dbusInt(d['rx-level']);
      signal = rx == null ? null : -110.0 + rx;
    default:
      signal = null;
  }
  final quality = switch (radio) {
    RadioType.umts => dbusDouble(d['ecio']),
    _ => dbusDouble(d['rsrq']),
  };
  return CellObservation(
    radio: radio,
    mcc: op?.$1,
    mnc: op?.$2,
    area: id(usesTac ? 'tac' : 'lac'),
    cellId: id('ci'),
    pci: pci,
    arfcn: arfcn,
    signalDbm: signal,
    rsrq: quality,
    timingAdvance: dbusInt(d['timing-advance']),
    serving: dbusBool(d['serving']) ?? false,
    modem: modem,
  );
}
