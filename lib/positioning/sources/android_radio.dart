/// Wi-Fi and cell observations on Android, from RadioBridge.kt.
///
/// The platform side passes its numbers on untouched; everything that makes
/// them fit the engine's model (placeholders, "unavailable" markers, value
/// ranges) is here.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../platform/android_bridge.dart';
import '../models.dart';
import 'sources.dart';

/// What Android puts in place of the real BSSID when the app may not see
/// it, and the all-zero address some drivers report for a broken entry.
const _placeholderBssids = {'02:00:00:00:00:00', '00:00:00:00:00:00'};

/// One row of `wifiScan`: `[bssid, rssi dBm, frequency MHz, age ms, ssid]`.
/// Null when the row does not name an access point.
@visibleForTesting
WifiObservation? wifiFromAndroid(Object? row) {
  if (row is! List || row.length < 4) return null;
  final raw = row[0];
  if (raw is! String) return null;
  final bssid = normalizeMac(raw);
  if (bssid == null || _placeholderBssids.contains(bssid)) return null;
  final rssi = row[1], frequency = row[2], age = row[3];
  final ssid = row.length > 4 ? row[4] : null;
  return WifiObservation(
    bssid: bssid,
    // 0 and positive levels are driver glitches, not measurements.
    signalDbm: rssi is num && rssi < 0 && rssi > -128 ? rssi.toDouble() : null,
    frequencyMhz: frequency is num && frequency > 0 ? frequency.toInt() : null,
    // A timestamp from before a clock hiccup must not look like the future.
    age: Duration(milliseconds: age is num && age > 0 ? age.toInt() : 0),
    // Hidden networks come as an empty name or a placeholder. The name is
    // only ever used for the `_nomap` opt-out.
    ssid: ssid is String && ssid.isNotEmpty && ssid != '<unknown ssid>'
        ? ssid
        : null,
  );
}

/// The access points Android has heard.
///
/// Reading is free: the list is the system's own cache, filled by every
/// scan on the device, each entry with its own age. Asking for a scan is
/// rationed by the system to four per two minutes for an app on screen
/// (Android 9 and later), so [requestScan] passes on at most one request
/// per [minScanInterval] and stays quiet for longer after a refusal.
class AndroidWifiScanner implements WifiScanner {
  AndroidWifiScanner({
    MethodChannel channel = androidChannel,
    this.minScanInterval = const Duration(seconds: 31),
    this.refusedBackoff = const Duration(minutes: 1),
    DateTime Function()? now,
  }) : _channel = channel,
       _now = now ?? DateTime.now;

  final MethodChannel _channel;
  final DateTime Function() _now;

  /// Four requests fit into two minutes with a second to spare.
  final Duration minScanInterval;

  /// After the system said no (allowance used up by an earlier run of the
  /// app, Wi-Fi scanning switched off): how long before asking again.
  final Duration refusedBackoff;

  DateTime? _nextScan;

  @override
  String get backend => 'Android';

  @override
  bool get reportsDbm => true;

  @override
  Future<bool> requestScan() async {
    final now = _now();
    final next = _nextScan;
    if (next != null && now.isBefore(next)) return false;
    // Reserved before the call, so overlapping polls do not ask twice.
    _nextScan = now.add(minScanInterval);
    try {
      final started =
          await _channel.invokeMethod<bool>('wifiRequestScan') ?? false;
      if (!started) _nextScan = now.add(refusedBackoff);
      return started;
    } on Exception {
      _nextScan = now.add(refusedBackoff);
      return false;
    }
  }

  @override
  Future<List<WifiObservation>> getObservations({
    Duration maxAge = const Duration(seconds: 30),
  }) async {
    final List<Object?> rows;
    try {
      rows = await _channel.invokeListMethod<Object?>('wifiScan') ?? const [];
    } on MissingPluginException {
      return const [];
    }
    // Strongest entry per access point: a scan may list one twice.
    final byId = <String, WifiObservation>{};
    for (final row in rows) {
      final o = wifiFromAndroid(row);
      if (o == null || o.age > maxAge) continue;
      final seen = byId[o.bssid];
      if (seen == null || (o.signalDbm ?? -200) > (seen.signalDbm ?? -200)) {
        byId[o.bssid] = o;
      }
    }
    return byId.values.toList();
  }

  @override
  Future<void> close() async {}
}

/// Android's "no value": `Integer.MAX_VALUE`, and `Long.MAX_VALUE` for the
/// 36-bit NR cell identity.
const _intUnavailable = 0x7fffffff, _longUnavailable = 0x7fffffffffffffff;

int? _int(Object? v, int min, int max, {int unavailable = _intUnavailable}) {
  if (v is! int || v == unavailable) return null;
  return v < min || v > max ? null : v;
}

/// One entry of `cells` (see RadioBridge.describe). Null for a kind of
/// radio the engine has no model for.
///
/// Identity fields outside their defined range become null, so a neighbour
/// known only by its physical id never passes for a full identity, and the
/// reserved "no cell" values (LAC 0 and 0xFFFE/0xFFFF, GSM CID 0xFFFF, LTE
/// CI 0xFFFFFFF) never reach the database.
@visibleForTesting
CellObservation? cellFromAndroid(Object? entry) {
  if (entry is! Map) return null;
  final radio = switch (entry['radio']) {
    'gsm' => RadioType.gsm,
    'umts' => RadioType.umts,
    'lte' => RadioType.lte,
    'nr' => RadioType.nr,
    _ => null,
  };
  if (radio == null) return null;
  final maxCellId = switch (radio) {
    RadioType.gsm => 0xfffe,
    RadioType.nr => 0xfffffffff,
    _ => 0xffffffe,
  };
  final dbm = entry['dbm'], rsrq = entry['rsrq'];
  return CellObservation(
    radio: radio,
    mcc: _int(entry['mcc'], 1, 999),
    mnc: _int(entry['mnc'], 0, 999),
    area: _int(entry['area'], 1, radio == RadioType.nr ? 0xfffffd : 0xfffd),
    cellId: _int(
      entry['cid'],
      radio == RadioType.gsm ? 0 : 1,
      maxCellId,
      // 0x7fffffff is an ordinary value among 36-bit identities.
      unavailable: radio == RadioType.nr ? _longUnavailable : _intUnavailable,
    ),
    pci: _int(entry['pci'], 0, 1007),
    arfcn: _int(entry['arfcn'], 0, 3279165),
    signalDbm: dbm is int && dbm < -20 && dbm > -160 ? dbm.toDouble() : null,
    rsrq: rsrq is int && rsrq <= 0 && rsrq > -50 ? rsrq.toDouble() : null,
    // LTE: 0..1282 steps of 16 Ts; GSM: 0..219 bit periods.
    timingAdvance: _int(entry['ta'], 0, 1282),
    serving: entry['serving'] == true,
  );
}

/// The cells the modem reports: the registered one and its neighbours. A
/// device without a modem, or without a SIM that registers, reports none.
class AndroidCellSource implements CellSource {
  AndroidCellSource({MethodChannel channel = androidChannel})
    : _channel = channel;

  final MethodChannel _channel;

  @override
  String get backend => 'Android';

  @override
  Future<List<CellObservation>> getCells() async {
    final List<Object?> entries;
    try {
      entries = await _channel.invokeListMethod<Object?>('cells') ?? const [];
    } on MissingPluginException {
      return const [];
    }
    // Dual-SIM phones report a shared cell once per SIM.
    final seen = <String>{};
    return [
      for (final entry in entries)
        if (cellFromAndroid(entry) case final c?)
          if (c.key == null || seen.add(c.key!)) c,
    ];
  }

  @override
  Future<void> close() async {}
}
