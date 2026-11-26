import 'dart:async';
import 'dart:convert';

import 'package:mapsoly/obd/transport.dart';

/// A scripted stand-in for an ELM327 adapter plugged into a car.
class FakeElm implements ObdTransport {
  FakeElm({
    this.version = 'ELM327 v1.5',
    this.speedKmh = 60,
    this.supportsCountSuffix = true,
    this.spaces = false,
    this.vehicleAnswers = true,
    this.searchingFirst = false,
    this.can = true,
    this.pids = const {0x0D},
    this.fuelTypeCode = 1,
    this.troubleCodes = const [],
  });

  /// CAN vehicle (protocol 6) or an old K-line one (protocol 3).
  final bool can;

  /// Mode 01 PIDs the ECU supports, besides the bitmask PIDs themselves.
  final Set<int> pids;
  final int fuelTypeCode;

  /// Stored trouble codes as raw two-byte hex, e.g. `0133`.
  final List<String> troubleCodes;

  /// Raw values the ECU reports.
  double rpm = 2000;
  int coolantC = 90;
  double fuelRateLph = 6;
  double mafGps = 10;
  double fuelLevelPercent = 50;

  final String version;

  /// Null makes the ECU answer "NO DATA" to speed requests.
  int? speedKmh;
  final bool supportsCountSuffix;
  bool spaces;
  bool vehicleAnswers;
  bool searchingFirst;

  final _out = StreamController<List<int>>();
  final received = <String>[];
  bool _echo = true;
  bool closed = false;
  var _line = '';

  @override
  Stream<List<int>> get input => _out.stream;

  @override
  void write(List<int> bytes) {
    for (final char in ascii.decode(bytes).split('')) {
      if (char != '\r') {
        _line += char;
        continue;
      }
      final command = _line;
      _line = '';
      received.add(command);
      // Reply asynchronously and in two chunks, like a real serial link.
      final reply = '${_echo ? '$command\r' : ''}${_reply(command)}\r\r>';
      final cut = reply.length ~/ 2;
      scheduleMicrotask(() {
        if (closed) return;
        _out.add(ascii.encode(reply.substring(0, cut)));
        scheduleMicrotask(() {
          if (!closed) _out.add(ascii.encode(reply.substring(cut)));
        });
      });
    }
  }

  String _hex(String compact) => spaces
      ? [
          for (var i = 0; i < compact.length; i += 2)
            compact.substring(i, i + 2),
        ].join(' ')
      : compact;

  String _reply(String command) {
    switch (command) {
      case 'ATZ':
        _echo = true;
        spaces = true;
        return '\r$version';
      case 'ATE0':
        _echo = false;
        return 'OK';
      case 'ATS0':
        spaces = false;
        return 'OK';
      case 'ATAT1':
        return version.contains('v1.') ? 'OK' : '?';
      case 'ATL0' || 'ATH0' || 'ATSP0':
        return 'OK';
    }
    if (!vehicleAnswers) return 'UNABLE TO CONNECT';
    final prefix = searchingFirst ? 'SEARCHING...\r' : '';
    searchingFirst = false;
    if (command == 'ATDPN') return can ? 'A6' : 'A3';
    if (command == 'ATDP') {
      return can ? 'AUTO, ISO 15765-4 (CAN 11/500)' : 'AUTO, ISO 9141-2';
    }
    if (command == 'ATRV') return '12.6V';
    String h2(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
    String h4(int v) => v.toRadixString(16).padLeft(4, '0').toUpperCase();
    // Supported-PID bitmasks for 0x01-0x20, 0x21-0x40, 0x41-0x60.
    for (final base in const [0x00, 0x20, 0x40]) {
      if (command != '01${h2(base)}') continue;
      var mask = 0;
      for (final p in {...pids, if (base < 0x40) base + 0x20}) {
        if (p > base && p <= base + 0x20) mask |= 1 << (32 - (p - base));
      }
      return '$prefix${_hex('41${h2(base)}${mask.toRadixString(16).padLeft(8, '0').toUpperCase()}')}';
    }
    if (command.startsWith('01') && command.length == 4) {
      final pid = int.parse(command.substring(2), radix: 16);
      if (pid != 0x0D && !pids.contains(pid)) return 'NO DATA';
      switch (pid) {
        case 0x01:
          return _hex(
            '4101${h2((troubleCodes.isEmpty ? 0 : 0x80) | troubleCodes.length)}070000',
          );
        case 0x05:
          return _hex('4105${h2(coolantC + 40)}');
        case 0x0C:
          return _hex('410C${h4((rpm * 4).round())}');
        case 0x10:
          return _hex('4110${h4((mafGps * 100).round())}');
        case 0x2F:
          return _hex('412F${h2((fuelLevelPercent * 255 / 100).round())}');
        case 0x51:
          return _hex('4151${h2(fuelTypeCode)}');
        case 0x5E:
          return _hex('415E${h4((fuelRateLph * 20).round())}');
      }
    }
    if (command == '03') {
      final body = troubleCodes.join();
      return can
          ? _hex('43${h2(troubleCodes.length)}$body')
          : _hex('43${body.padRight(12, '0')}');
    }
    if (command == '0902') {
      // VIN "WVWZZZ1JZXW000001".
      return can
          ? '014\r0:490201575657\r1:5A5A5A314A5A58\r2:57303030303031'
          : '49020100000057\r49020256575A5A\r4902035A314A5A\r49020458573030\r49020530303031';
    }
    if (command == '010D1' && !supportsCountSuffix) return '?';
    if (command == '010D' || command == '010D1') {
      final v = speedKmh;
      return v == null
          ? 'NO DATA'
          : _hex('410D${v.toRadixString(16).padLeft(2, '0').toUpperCase()}');
    }
    return '?';
  }

  /// The adapter loses power or the link drops.
  void drop() {
    closed = true;
    _out.close();
  }

  @override
  Future<void> close() async {
    closed = true;
    if (!_out.isClosed) await _out.close();
  }
}
