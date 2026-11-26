import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dbus/dbus.dart';

import 'transport.dart';

/// A Bluetooth device known to the system.
class BluetoothDevice {
  const BluetoothDevice(this.address, this.name, {required this.paired});

  /// `AA:BB:CC:DD:EE:FF`.
  final String address;
  final String name;
  final bool paired;

  /// ELM327 adapters usually announce themselves with one of these names.
  bool get looksLikeObd => RegExp(
    'obd|elm|vlink|v-link|icar|konnwei',
    caseSensitive: false,
  ).hasMatch(name);
}

/// Devices BlueZ knows about (paired ones first). Pairing itself is done in
/// the system's Bluetooth settings; most adapters use PIN 1234 or 0000.
Future<List<BluetoothDevice>> listBluetoothDevices() async {
  final client = DBusClient.system();
  try {
    final reply = await client.callMethod(
      destination: 'org.bluez',
      path: DBusObjectPath('/'),
      interface: 'org.freedesktop.DBus.ObjectManager',
      name: 'GetManagedObjects',
      replySignature: DBusSignature('a{oa{sa{sv}}}'),
    );
    final devices = <BluetoothDevice>[];
    final objects = reply.returnValues[0].asDict();
    for (final interfaces in objects.values) {
      final device = interfaces.asDict()[const DBusString('org.bluez.Device1')];
      if (device == null) continue;
      final props = device.asStringVariantDict();
      final address = props['Address']?.asString();
      if (address == null) continue;
      devices.add(
        BluetoothDevice(
          address,
          props['Alias']?.asString() ?? props['Name']?.asString() ?? address,
          paired: props['Paired']?.asBoolean() ?? false,
        ),
      );
    }
    devices.sort((a, b) {
      if (a.paired != b.paired) return a.paired ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    return devices;
  } finally {
    await client.close();
  }
}

/// Bytes of a `sockaddr_rc` for [address] and RFCOMM [channel]:
/// family (AF_BLUETOOTH, native order), the address least significant byte
/// first, the channel, one padding byte.
Uint8List rfcommSockaddr(String address, int channel) {
  final parts = address.split(':');
  if (parts.length != 6 ||
      parts.any((p) => !RegExp(r'^[0-9A-Fa-f]{2}$').hasMatch(p))) {
    throw FormatException('Not a Bluetooth address: $address');
  }
  if (channel < 1 || channel > 30) {
    throw RangeError.range(channel, 1, 30, 'channel');
  }
  final out = Uint8List(10);
  ByteData.sublistView(out).setUint16(0, _afBluetooth, Endian.host);
  for (var i = 0; i < 6; i++) {
    out[2 + i] = int.parse(parts[5 - i], radix: 16);
  }
  out[8] = channel;
  return out;
}

const _afBluetooth = 31, _sockStream = 1, _btprotoRfcomm = 3;
const _shutRdwr = 2;

final _libc = DynamicLibrary.process();
final _socket = _libc
    .lookupFunction<
      Int32 Function(Int32, Int32, Int32),
      int Function(int, int, int)
    >('socket');
final _connect = _libc
    .lookupFunction<
      Int32 Function(Int32, Pointer<Uint8>, Uint32),
      int Function(int, Pointer<Uint8>, int)
    >('connect');
final _read = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)
    >('read');
final _write = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)
    >('write');
final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'close',
);
final _shutdown = _libc
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'shutdown',
    );
final _malloc = _libc
    .lookupFunction<
      Pointer<Uint8> Function(IntPtr),
      Pointer<Uint8> Function(int)
    >('malloc');
final _free = _libc
    .lookupFunction<
      Void Function(Pointer<Uint8>),
      void Function(Pointer<Uint8>)
    >('free');
final _errnoLocation = _libc
    .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
      '__errno_location',
    );

/// Opens a connected RFCOMM socket. Blocks, so it runs in a helper isolate.
int _openSocket((Uint8List, String) args) {
  final (sockaddr, address) = args;
  final fd = _socket(_afBluetooth, _sockStream, _btprotoRfcomm);
  if (fd < 0) {
    throw OSError(
      'Bluetooth sockets are not available',
      _errnoLocation().value,
    );
  }
  final addr = _malloc(sockaddr.length);
  addr.asTypedList(sockaddr.length).setAll(0, sockaddr);
  final result = _connect(fd, addr, sockaddr.length);
  final errno = _errnoLocation().value;
  _free(addr);
  if (result != 0) {
    _close(fd);
    throw OSError('Cannot connect to $address', errno);
  }
  return fd;
}

/// Reads from the socket until it closes, forwarding chunks to the owner.
void _readLoop((int, SendPort) args) {
  final (fd, port) = args;
  const size = 512;
  final buffer = _malloc(size);
  while (true) {
    final n = _read(fd, buffer, size);
    if (n <= 0) break; // closed by either side, or an error
    port.send(Uint8List.fromList(buffer.asTypedList(n)));
  }
  _free(buffer);
  port.send(null);
}

/// Bluetooth Classic serial link (SPP) to an ELM327 adapter over a plain
/// RFCOMM socket, the way every desktop OBD tool talks to these adapters.
///
/// The device must already be paired with the system.
class RfcommObdTransport implements ObdTransport {
  RfcommObdTransport._(this._fd, this._input);

  final int _fd;
  final StreamController<List<int>> _input;
  bool _closed = false;

  /// [channel] is the adapter's serial port channel; ELM327 clones use 1.
  static Future<RfcommObdTransport> connect(
    String address, {
    int channel = 1,
  }) async {
    if (!Platform.isLinux) {
      throw UnsupportedError('RFCOMM sockets are implemented for Linux only');
    }
    final sockaddr = rfcommSockaddr(address, channel);
    // connect() blocks for seconds while the radio pages the adapter.
    final fd = await Isolate.run(() => _openSocket((sockaddr, address)));
    final port = ReceivePort();
    final input = StreamController<List<int>>();
    final transport = RfcommObdTransport._(fd, input);
    port.listen((message) {
      if (message is Uint8List) {
        input.add(message);
      } else {
        // The read loop ended: the link is gone.
        port.close();
        input.close();
      }
    });
    await Isolate.spawn(_readLoop, (fd, port.sendPort));
    return transport;
  }

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  void write(List<int> bytes) {
    if (_closed || bytes.isEmpty) return;
    // Commands are a few bytes: a blocking write returns at once.
    final buffer = _malloc(bytes.length);
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    _write(_fd, buffer, bytes.length);
    _free(buffer);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // shutdown() wakes the reader blocked in read(); it then reports the end.
    _shutdown(_fd, _shutRdwr);
    await _input.done.timeout(const Duration(seconds: 2), onTimeout: () {});
    _close(_fd);
  }
}
