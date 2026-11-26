/// Linux Wi-Fi scanners over the system D-Bus: wpa_supplicant (real dBm,
/// preferred when the bus policy lets us talk to it) and NetworkManager
/// (percent only, always available to the session user on the Titan 2).
library;

import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';

import '../models.dart';
import 'dbus_decode.dart';
import 'sources.dart';

/// Reads CLOCK_BOOTTIME in seconds from /proc/uptime (the first field is
/// boot-time based, i.e. it keeps counting during suspend, like
/// NetworkManager's `LastSeen`).
double readBoottimeSeconds() {
  try {
    final s = File('/proc/uptime').readAsStringSync();
    return double.parse(s.split(' ').first);
  } catch (_) {
    return double.nan;
  }
}

const _nmName = 'org.freedesktop.NetworkManager';
const _nmDevice = 'org.freedesktop.NetworkManager.Device';
const _nmWireless = 'org.freedesktop.NetworkManager.Device.Wireless';
const _nmAp = 'org.freedesktop.NetworkManager.AccessPoint';

/// NetworkManager backend.
///
/// Facts verified on the Titan 2 (2026-11-26, as user serlk): `GetDevices`,
/// `GetAllAccessPoints`, AP properties and `RequestScan` are all allowed
/// (polkit rule for group netdev). A full scan takes about 8 s; NM refuses
/// or ignores requests more often than every ~10 s.
class NetworkManagerWifiScanner implements WifiScanner {
  NetworkManagerWifiScanner({DBusClient? client, double Function()? boottime})
    : _client = client ?? DBusClient.system(),
      _ownsClient = client == null,
      _boottime = boottime ?? readBoottimeSeconds;

  final DBusClient _client;
  final bool _ownsClient;
  final double Function() _boottime;
  List<DBusRemoteObject>? _devices;

  @override
  String get backend => 'NetworkManager';

  @override
  bool get reportsDbm => false;

  Future<List<DBusRemoteObject>> _wifiDevices() async {
    final cached = _devices;
    if (cached != null && cached.isNotEmpty) return cached;
    final nm = DBusRemoteObject(
      _client,
      name: _nmName,
      path: DBusObjectPath('/org/freedesktop/NetworkManager'),
    );
    final reply = await nm.callMethod(
      _nmName,
      'GetDevices',
      const [],
      replySignature: DBusSignature('ao'),
    );
    final out = <DBusRemoteObject>[];
    for (final p in reply.returnValues[0].asObjectPathArray()) {
      final dev = DBusRemoteObject(_client, name: _nmName, path: p);
      try {
        final type = dbusInt(await dev.getProperty(_nmDevice, 'DeviceType'));
        if (type == 2) out.add(dev); // NM_DEVICE_TYPE_WIFI
      } on DBusMethodResponseException {
        // Device vanished between the two calls.
      }
    }
    return _devices = out;
  }

  /// True when NetworkManager is reachable and has a Wi-Fi device.
  Future<bool> isAvailable() async {
    try {
      return (await _wifiDevices()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> requestScan() async {
    var ok = false;
    try {
      for (final dev in await _wifiDevices()) {
        try {
          await dev.callMethod(_nmWireless, 'RequestScan', [
            DBusDict.stringVariant(const {}),
          ], replySignature: DBusSignature(''));
          ok = true;
        } on DBusMethodResponseException {
          // "Scanning not allowed immediately following previous scan" or
          // a polkit refusal: the previous results stay valid.
        }
      }
    } catch (_) {
      _devices = null;
    }
    return ok;
  }

  @override
  Future<List<WifiObservation>> getObservations({
    Duration maxAge = const Duration(seconds: 30),
  }) async {
    final out = <WifiObservation>[];
    try {
      for (final dev in await _wifiDevices()) {
        final reply = await dev.callMethod(
          _nmWireless,
          'GetAllAccessPoints',
          const [],
          replySignature: DBusSignature('ao'),
        );
        final now = _boottime();
        final results = await Future.wait(
          reply.returnValues[0].asObjectPathArray().map((p) async {
            try {
              final props = await DBusRemoteObject(
                _client,
                name: _nmName,
                path: p,
              ).getAllProperties(_nmAp);
              return decodeNmAccessPoint(props, boottimeSeconds: now);
            } on DBusMethodResponseException {
              return null; // AP removed meanwhile
            }
          }),
        );
        for (final o in results) {
          if (o != null && o.age <= maxAge) out.add(o);
        }
      }
    } on DBusMethodResponseException {
      _devices = null;
    } on SocketException {
      _devices = null;
    }
    return out;
  }

  @override
  Future<void> close() async {
    if (_ownsClient) await _client.close();
  }
}

const _wpaName = 'fi.w1.wpa_supplicant1';
const _wpaIface = 'fi.w1.wpa_supplicant1.Interface';
const _wpaBss = 'fi.w1.wpa_supplicant1.BSS';

/// wpa_supplicant backend: BSS `Signal` in dBm and `Age` in seconds.
///
/// On the Titan 2 the stock bus policy only lets root talk to
/// `fi.w1.wpa_supplicant1` (verified 2026-11-26: AccessDenied for serlk), so
/// [isAvailable] returns false there until the policy is opened.
class WpaSupplicantWifiScanner implements WifiScanner {
  WpaSupplicantWifiScanner({DBusClient? client})
    : _client = client ?? DBusClient.system(),
      _ownsClient = client == null;

  final DBusClient _client;
  final bool _ownsClient;
  List<DBusRemoteObject>? _interfaces;

  @override
  String get backend => 'wpa_supplicant';

  @override
  bool get reportsDbm => true;

  Future<List<DBusRemoteObject>> _ifaces() async {
    final cached = _interfaces;
    if (cached != null && cached.isNotEmpty) return cached;
    final root = DBusRemoteObject(
      _client,
      name: _wpaName,
      path: DBusObjectPath('/fi/w1/wpa_supplicant1'),
    );
    final v = await root.getProperty(_wpaName, 'Interfaces');
    return _interfaces = [
      for (final p in v.asObjectPathArray())
        DBusRemoteObject(_client, name: _wpaName, path: p),
    ];
  }

  /// True when the bus policy lets this user read wpa_supplicant.
  Future<bool> isAvailable() async {
    try {
      return (await _ifaces()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Starts a scan. [frequenciesMhz] restricts it to those channels, which
  /// is several times faster than a full sweep.
  ///
  /// UNVERIFIED as a non-root user (needs the bus policy change). Scanning
  /// behind NetworkManager's back is supported by wpa_supplicant; NM simply
  /// sees the new BSS list.
  @override
  Future<bool> requestScan({List<int>? frequenciesMhz}) async {
    var ok = false;
    try {
      for (final iface in await _ifaces()) {
        final args = <String, DBusValue>{'Type': const DBusString('active')};
        if (frequenciesMhz != null && frequenciesMhz.isNotEmpty) {
          args['Channels'] = DBusArray(DBusSignature('(uu)'), [
            for (final f in frequenciesMhz)
              DBusStruct([DBusUint32(f), const DBusUint32(20)]),
          ]);
        }
        try {
          await iface.callMethod(_wpaIface, 'Scan', [
            DBusDict.stringVariant(args),
          ], replySignature: DBusSignature(''));
          ok = true;
        } on DBusMethodResponseException {
          // Busy or denied.
        }
      }
    } catch (_) {
      _interfaces = null;
    }
    return ok;
  }

  @override
  Future<List<WifiObservation>> getObservations({
    Duration maxAge = const Duration(seconds: 30),
  }) async {
    final out = <WifiObservation>[];
    try {
      for (final iface in await _ifaces()) {
        final bss = await iface.getProperty(_wpaIface, 'BSSs');
        final results = await Future.wait(
          bss.asObjectPathArray().map((p) async {
            try {
              final props = await DBusRemoteObject(
                _client,
                name: _wpaName,
                path: p,
              ).getAllProperties(_wpaBss);
              return decodeWpaBss(props);
            } on DBusMethodResponseException {
              return null;
            }
          }),
        );
        for (final o in results) {
          if (o != null && o.age <= maxAge) out.add(o);
        }
      }
    } on DBusMethodResponseException {
      _interfaces = null;
    } on SocketException {
      _interfaces = null;
    }
    return out;
  }

  @override
  Future<void> close() async {
    if (_ownsClient) await _client.close();
  }
}

/// Picks wpa_supplicant when it is accessible, NetworkManager otherwise.
///
/// Scans are always requested through NetworkManager when possible (it owns
/// the radio policy and the call is authorised by polkit); results are read
/// from wpa_supplicant for dBm when the bus policy allows. Access to
/// wpa_supplicant is re-probed every [reprobeInterval], so a later policy
/// change on the phone is picked up without an app update.
class LinuxWifiScanner implements WifiScanner {
  LinuxWifiScanner({
    DBusClient? client,
    this.reprobeInterval = const Duration(minutes: 10),
  }) : _client = client ?? DBusClient.system(),
       _ownsClient = client == null {
    _nm = NetworkManagerWifiScanner(client: _client);
    _wpa = WpaSupplicantWifiScanner(client: _client);
  }

  final DBusClient _client;
  final bool _ownsClient;
  final Duration reprobeInterval;
  late final NetworkManagerWifiScanner _nm;
  late final WpaSupplicantWifiScanner _wpa;
  bool? _wpaOk;
  DateTime? _probedAt;

  Future<bool> _useWpa() async {
    final now = DateTime.now();
    if (_wpaOk == null ||
        (_wpaOk == false && now.difference(_probedAt!) > reprobeInterval)) {
      _wpaOk = await _wpa.isAvailable();
      _probedAt = now;
    }
    return _wpaOk!;
  }

  @override
  String get backend => _wpaOk == true ? _wpa.backend : _nm.backend;

  @override
  bool get reportsDbm => _wpaOk == true;

  @override
  Future<bool> requestScan() async {
    if (await _nm.requestScan()) return true;
    if (await _useWpa()) return _wpa.requestScan();
    return false;
  }

  @override
  Future<List<WifiObservation>> getObservations({
    Duration maxAge = const Duration(seconds: 30),
  }) async {
    if (await _useWpa()) {
      final list = await _wpa.getObservations(maxAge: maxAge);
      if (list.isNotEmpty) return list;
    }
    return _nm.getObservations(maxAge: maxAge);
  }

  @override
  Future<void> close() async {
    if (_ownsClient) await _client.close();
  }
}
