/// Cell measurements from ModemManager over the system D-Bus.
library;

import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';

import '../models.dart';
import 'dbus_decode.dart';
import 'sources.dart';

const _mmName = 'org.freedesktop.ModemManager1';
const _mmModem = 'org.freedesktop.ModemManager1.Modem';
const _mmLocation = 'org.freedesktop.ModemManager1.Modem.Location';

/// How the last poll of a modem obtained its data (for diagnostics).
enum CellBackendMode { cellInfo, locationMethod, locationProperty, none }

/// ModemManager client.
///
/// Per modem and per poll it tries, in order:
///  1. `Modem.GetCellInfo()` - serving + neighbours with levels and TA;
///  2. `Modem.Location.GetLocation()` - serving cell identity only;
///  3. the `Location` property - same data, but ModemManager only fills it
///     when `SignalsLocation` is true.
///
/// A method that fails with Unsupported / AccessDenied / Unauthorized is not
/// retried for [retryUnsupportedAfter], to avoid hammering the bus.
///
/// State on the Titan 2 on 2026-11-26 (see docs/positioning.md):
///  * root: GetCellInfo -> `Core.Unsupported`; GetLocation works.
///  * serlk: GetCellInfo -> D-Bus `AccessDenied` (bus policy), GetLocation ->
///    `Core.Unauthorized` (polkit action `...ModemManager1.Location`), the
///    `Location` property is empty. So the app gets no cell data today.
class ModemManagerCellSource implements CellSource {
  ModemManagerCellSource({
    DBusClient? client,
    this.retryUnsupportedAfter = const Duration(minutes: 5),
  }) : _client = client ?? DBusClient.system(),
       _ownsClient = client == null;

  final DBusClient _client;
  final bool _ownsClient;
  final Duration retryUnsupportedAfter;

  final Map<String, DateTime> _cellInfoFailed = {};
  final Map<String, DateTime> _getLocationFailed = {};

  /// Result of the last poll, by modem object path.
  final Map<String, CellBackendMode> lastMode = {};

  /// Last error text per modem (for the diagnostics screen / reports).
  final Map<String, String> lastError = {};

  @override
  String get backend => 'ModemManager';

  bool _skip(Map<String, DateTime> failed, String path) {
    final t = failed[path];
    return t != null && DateTime.now().difference(t) < retryUnsupportedAfter;
  }

  @override
  Future<List<CellObservation>> getCells() async {
    final out = <CellObservation>[];
    Map<DBusObjectPath, Map<String, Map<String, DBusValue>>> objects;
    try {
      final reply = await _client.callMethod(
        destination: _mmName,
        path: DBusObjectPath('/org/freedesktop/ModemManager1'),
        interface: 'org.freedesktop.DBus.ObjectManager',
        name: 'GetManagedObjects',
        replySignature: DBusSignature('a{oa{sa{sv}}}'),
      );
      objects = reply.returnValues[0].asDict().map(
        (k, v) => MapEntry(
          k.asObjectPath(),
          v.asDict().map(
            (i, p) => MapEntry(i.asString(), p.asStringVariantDict()),
          ),
        ),
      );
    } on DBusMethodResponseException catch (e) {
      lastError['*'] = '$e';
      return out;
    } on SocketException catch (e) {
      lastError['*'] = '$e';
      return out;
    }

    final paths = objects.keys.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    for (final path in paths) {
      final ifaces = objects[path]!;
      final modemProps = ifaces[_mmModem];
      if (modemProps == null) continue;
      final index = int.tryParse(path.value.split('/').last);
      final tech = dbusInt(modemProps['AccessTechnologies']);
      final obj = DBusRemoteObject(_client, name: _mmName, path: path);
      var mode = CellBackendMode.none;
      var cells = <CellObservation>[];

      if (!_skip(_cellInfoFailed, path.value)) {
        try {
          final r = await obj.callMethod(
            _mmModem,
            'GetCellInfo',
            const [],
            replySignature: DBusSignature('aa{sv}'),
          );
          cells = [
            for (final d in r.returnValues[0].asArray())
              ?decodeMmCellInfo(d.asStringVariantDict(), modem: index),
          ];
          mode = CellBackendMode.cellInfo;
          _cellInfoFailed.remove(path.value);
        } on DBusMethodResponseException catch (e) {
          _cellInfoFailed[path.value] = DateTime.now();
          lastError[path.value] = 'GetCellInfo: ${e.response.errorName}';
        }
      }

      if (mode == CellBackendMode.none) {
        Map<int, DBusValue>? loc;
        if (!_skip(_getLocationFailed, path.value)) {
          try {
            final r = await obj.callMethod(
              _mmLocation,
              'GetLocation',
              const [],
              replySignature: DBusSignature('a{uv}'),
            );
            loc = _uvDict(r.returnValues[0]);
            mode = CellBackendMode.locationMethod;
            _getLocationFailed.remove(path.value);
          } on DBusMethodResponseException catch (e) {
            _getLocationFailed[path.value] = DateTime.now();
            lastError[path.value] =
                '${lastError[path.value] ?? ''}; '
                'GetLocation: ${e.response.errorName}';
          }
        }
        if (loc == null) {
          final prop = ifaces[_mmLocation]?['Location'];
          if (prop != null) {
            loc = _uvDict(prop);
            if (loc.isNotEmpty) mode = CellBackendMode.locationProperty;
          }
        }
        if (loc != null) {
          final c = decodeMmLocation(
            loc,
            accessTechnologies: tech,
            modem: index,
          );
          if (c != null) cells = [c];
        }
      }
      lastMode[path.value] = mode;
      out.addAll(cells);
    }
    return out;
  }

  static Map<int, DBusValue> _uvDict(DBusValue v) =>
      v.asDict().map((k, val) => MapEntry(k.asUint32(), val.asVariant()));

  @override
  Future<void> close() async {
    if (_ownsClient) await _client.close();
  }
}
