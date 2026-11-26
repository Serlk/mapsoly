import 'dart:async';
import 'dart:convert';

import 'obd_data.dart';
import 'transport.dart';

/// The adapter answered, but not with usable data.
class ElmException implements Exception {
  ElmException(this.message);

  final String message;

  @override
  String toString() => 'ElmException: $message';
}

/// Talks the ELM327 AT/OBD command protocol over an [ObdTransport].
///
/// One command at a time: every command ends when the adapter prints its
/// `>` prompt.
class Elm327 {
  Elm327(this._transport) {
    _sub = _transport.input.listen(
      _onData,
      onError: (Object e) => _fail(ElmException('link error: $e')),
      onDone: () => _fail(ElmException('link closed')),
    );
  }

  final ObdTransport _transport;
  late final StreamSubscription<List<int>> _sub;
  final _buffer = StringBuffer();
  Completer<String>? _pending;
  bool _closed = false;

  /// Identification string from the reset, e.g. `ELM327 v1.5`.
  String? version;

  /// Protocol the adapter settled on, as it names it (e.g. `ISO 15765-4
  /// (CAN 11/500)`), and whether that is a CAN protocol.
  String? protocol;
  bool isCan = true;

  /// Whether `010D1` (stop waiting after one reply) works on this adapter;
  /// it roughly doubles the polling rate. Cheap clones reject it.
  bool _countSuffix = true;

  void _onData(List<int> bytes) {
    // Adapters send 7-bit ASCII; some clones add NUL bytes.
    _buffer.write(
      ascii.decode(bytes.where((b) => b != 0).toList(), allowInvalid: true),
    );
    final text = _buffer.toString();
    final prompt = text.indexOf('>');
    if (prompt < 0) return;
    _buffer
      ..clear()
      ..write(text.substring(prompt + 1));
    final pending = _pending;
    _pending = null;
    pending?.complete(text.substring(0, prompt));
  }

  void _fail(ElmException e) {
    _closed = true;
    final pending = _pending;
    _pending = null;
    pending?.completeError(e);
  }

  /// Sends [command] and returns the reply lines, without echo and prompt.
  Future<List<String>> command(
    String command, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (_closed) throw ElmException('link closed');
    if (_pending != null) throw StateError('a command is already in flight');
    _buffer.clear();
    final pending = _pending = Completer<String>();
    _transport.write(ascii.encode('$command\r'));
    final String raw;
    try {
      raw = await pending.future.timeout(timeout);
    } on TimeoutException {
      _pending = null;
      throw ElmException('no reply to $command');
    }
    return [
      for (final line in raw.split(RegExp(r'[\r\n]+')))
        if (line.trim().isNotEmpty && line.trim() != command) line.trim(),
    ];
  }

  /// Resets the adapter and prepares it for compact replies, then makes it
  /// find the vehicle's protocol. Throws [ElmException] when the adapter or
  /// the car does not answer.
  Future<void> initialize() async {
    // A reset can take a while and may print garbage first.
    final id = await command('ATZ', timeout: const Duration(seconds: 5));
    version = id.where((l) => l.toUpperCase().contains('ELM')).firstOrNull;
    for (final setup in const ['ATE0', 'ATL0', 'ATS0', 'ATH0', 'ATSP0']) {
      final reply = await command(setup);
      if (!reply.any((l) => l.toUpperCase().contains('OK'))) {
        throw ElmException('$setup rejected: ${reply.join(' ')}');
      }
    }
    // Adaptive timing is optional: clones may not know it.
    await command('ATAT1');
    // The first request triggers the protocol search, which can be slow.
    final probe = await command('0100', timeout: const Duration(seconds: 12));
    if (parseReply(probe, mode: 0x01, pid: 0x00) == null) {
      throw ElmException('vehicle does not answer: ${probe.join(' ')}');
    }
    // "A6" = automatic, protocol 6; 6 and above are the CAN family.
    final number = (await command('ATDPN')).firstOrNull ?? '';
    final digit = int.tryParse(
      number.replaceFirst(RegExp('^A'), ''),
      radix: 16,
    );
    if (digit != null) isCan = digit >= 6;
    protocol = (await command('ATDP')).firstOrNull;
  }

  /// Data bytes of a mode 01 PID, or null when the ECU has no answer.
  Future<List<int>?> query(int pid) async {
    final hex = pid.toRadixString(16).padLeft(2, '0').toUpperCase();
    return parseReply(await command('01$hex'), mode: 0x01, pid: pid);
  }

  /// PIDs the engine ECU supports, walking the 0x00/0x20/0x40 bitmasks.
  Future<Set<int>> readSupportedPids() async {
    final all = <int>{};
    for (var base = 0; base <= 0x40; base += 0x20) {
      final mask = await query(base);
      if (mask == null || mask.length < 4) break;
      final found = supportedPids(base, mask);
      all.addAll(found);
      if (!found.contains(base + 0x20)) break;
    }
    return all;
  }

  Future<String?> readVin() async =>
      vinFrom(await command('0902', timeout: const Duration(seconds: 5)));

  Future<List<String>> readTroubleCodes() async => troubleCodesFrom(
    await command('03', timeout: const Duration(seconds: 5)),
    can: isCan,
  );

  /// Voltage at the diagnostic connector, measured by the adapter itself.
  Future<double?> readBatteryVolts() async {
    final reply = (await command('ATRV')).firstOrNull ?? '';
    return double.tryParse(reply.replaceAll(RegExp('[^0-9.]'), ''));
  }

  /// Vehicle speed in km/h (whole numbers, as the ECU reports it), or null
  /// when the ECU has no answer right now (ignition off, bus asleep).
  Future<int?> readSpeedKmh() async {
    var reply = await command(_countSuffix ? '010D1' : '010D');
    if (_countSuffix && reply.any((l) => l.contains('?'))) {
      _countSuffix = false;
      reply = await command('010D');
    }
    final data = parseReply(reply, mode: 0x01, pid: 0x0D);
    return data == null || data.isEmpty ? null : data[0];
  }

  Future<void> close() async {
    _closed = true;
    await _sub.cancel();
    await _transport.close();
  }

  /// Extracts the data bytes of the reply to mode [mode], PID [pid] from the
  /// adapter's lines, or null when there is none ("NO DATA", errors, noise).
  ///
  /// Handles replies with and without spaces, a leading "SEARCHING...", and
  /// several ECUs answering (the first valid one wins).
  static List<int>? parseReply(
    List<String> lines, {
    required int mode,
    required int pid,
  }) {
    String hex2(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
    final head = '${hex2(mode + 0x40)}${hex2(pid)}';
    for (final line in lines) {
      final compact = line.replaceAll(' ', '').toUpperCase();
      final at = compact.indexOf(head);
      if (at < 0) continue;
      final payload = compact.substring(at + head.length);
      if (payload.length.isOdd || !RegExp(r'^[0-9A-F]*$').hasMatch(payload)) {
        continue;
      }
      return [
        for (var i = 0; i < payload.length; i += 2)
          int.parse(payload.substring(i, i + 2), radix: 16),
      ];
    }
    return null;
  }
}
