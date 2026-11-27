import 'dart:async';

import 'package:flutter/services.dart';

import '../platform/android_bridge.dart';
import 'rfcomm_transport.dart';
import 'transport.dart';

/// The user has not let the app use Bluetooth ("nearby devices").
class BluetoothPermissionDenied implements Exception {
  const BluetoothPermissionDenied();

  @override
  String toString() => 'Bluetooth permission not granted';
}

/// Bluetooth Classic on Android, through BluetoothBridge.kt: the paired
/// devices and serial (SPP) links to them.
///
/// NOT TESTED ON HARDWARE: the emulator has no Bluetooth radio. The Dart
/// side is covered by tests against a fake channel.
class AndroidBluetooth {
  AndroidBluetooth({
    MethodChannel channel = androidChannel,
    EventChannel events = const EventChannel('mapsoly/android/bluetooth'),
  }) : _channel = channel,
       _events = events,
       _permissions = AndroidPermissions(channel);

  /// The one the app uses: links share its event stream.
  static final instance = AndroidBluetooth();

  final MethodChannel _channel;
  final EventChannel _events;
  final AndroidPermissions _permissions;
  final _links = <int, AndroidRfcommTransport>{};
  StreamSubscription<Object?>? _sub;
  bool _asked = false;

  /// Holds the permission, asking for it when [ask]ed to. Reconnection
  /// attempts in the background ask only once per run of the app.
  Future<void> _ensurePermission({required bool ask}) async {
    if (await _permissions.has(AndroidPermissions.bluetooth)) return;
    if (ask || !_asked) {
      _asked = true;
      final answer = await _permissions.request(AndroidPermissions.bluetooth);
      if (answer == PermissionAnswer.granted) return;
    }
    throw const BluetoothPermissionDenied();
  }

  /// Devices paired in the system's Bluetooth settings, by name.
  ///
  /// Throws [BluetoothPermissionDenied], or [PlatformException] when
  /// Bluetooth is missing or switched off.
  Future<List<BluetoothDevice>> devices() async {
    await _ensurePermission(ask: true);
    final raw = await _channel.invokeListMethod<Object?>('btBonded') ?? [];
    final devices = [
      for (final d in raw)
        if (d is Map && d['address'] is String)
          BluetoothDevice(
            d['address'] as String,
            d['name'] as String? ?? d['address'] as String,
            paired: true,
          ),
    ];
    devices.sort((a, b) => a.name.compareTo(b.name));
    return devices;
  }

  /// Opens a serial link to the paired device at [address].
  Future<AndroidRfcommTransport> connect(String address) async {
    await _ensurePermission(ask: false);
    _sub ??= _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object _) {},
    );
    final id = await _channel.invokeMethod<int>('btConnect', address);
    if (id == null) throw StateError('Bluetooth link not opened');
    return _links[id] = AndroidRfcommTransport._(this, id);
  }

  void _onEvent(Object? event) {
    if (event is! Map) return;
    final link = _links[event['id']];
    if (link == null) return;
    final data = event['data'];
    if (data is Uint8List) link._input.add(data);
    if (event['closed'] == true) {
      _links.remove(event['id']);
      unawaited(link._input.close());
    }
  }
}

/// A serial link to an ELM327 adapter over Android's BluetoothSocket.
class AndroidRfcommTransport implements ObdTransport {
  AndroidRfcommTransport._(this._bluetooth, this._id);

  final AndroidBluetooth _bluetooth;
  final int _id;
  final _input = StreamController<List<int>>();
  bool _closed = false;

  static Future<AndroidRfcommTransport> connect(String address) =>
      AndroidBluetooth.instance.connect(address);

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  void write(List<int> bytes) {
    if (_closed || bytes.isEmpty) return;
    // The platform side queues writes per link, so the order holds.
    unawaited(
      _bluetooth._channel
          .invokeMethod<void>('btWrite', {
            'id': _id,
            'data': Uint8List.fromList(bytes),
          })
          .catchError((Object _) {}),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _bluetooth._channel.invokeMethod<void>('btClose', _id);
    } on Exception {
      // Already gone.
    }
    // The platform reports the end once its reader has stopped.
    await _input.done.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _bluetooth._links.remove(_id);
        unawaited(_input.close());
      },
    );
  }
}
