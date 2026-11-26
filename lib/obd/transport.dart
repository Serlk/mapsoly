import 'dart:async';
import 'dart:io';

/// A byte pipe to an ELM327 adapter, whatever carries it.
abstract class ObdTransport {
  /// Bytes received from the adapter. Closes when the link drops.
  Stream<List<int>> get input;

  void write(List<int> bytes);

  Future<void> close();
}

/// Opens a transport; throws when the adapter cannot be reached.
typedef ObdConnector = Future<ObdTransport> Function();

/// Wi-Fi adapters: a plain TCP socket (commonly 192.168.0.10:35000).
class TcpObdTransport implements ObdTransport {
  TcpObdTransport._(this._socket);

  final Socket _socket;

  static Future<TcpObdTransport> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    return TcpObdTransport._(socket);
  }

  @override
  Stream<List<int>> get input => _socket;

  @override
  void write(List<int> bytes) => _socket.add(bytes);

  @override
  Future<void> close() async => _socket.destroy();
}

/// USB adapters (`/dev/ttyUSB0`) and Bluetooth serial ports bound by the
/// system (`/dev/rfcomm0`): a character device configured for raw I/O.
class SerialObdTransport implements ObdTransport {
  SerialObdTransport._(this._file, this._input);

  final RandomAccessFile _file;
  final StreamController<List<int>> _input;
  bool _closed = false;

  /// [baud] matters for USB adapters (38400 is the usual default, some use
  /// 9600 or 115200); Bluetooth serial ports ignore it.
  static Future<SerialObdTransport> open(
    String path, {
    int baud = 38400,
  }) async {
    // Raw mode: no echo, no line editing, no CR/LF translation.
    final stty = await Process.run('stty', [
      '-F',
      path,
      '$baud',
      'raw',
      '-echo',
      'min',
      '1',
      'time',
      '0',
    ]);
    if (stty.exitCode != 0) {
      throw FileSystemException('stty failed: ${stty.stderr}'.trim(), path);
    }
    final file = await File(path).open(mode: FileMode.append);
    final reader = await File(path).open();
    final input = StreamController<List<int>>();
    final transport = SerialObdTransport._(file, input);
    unawaited(transport._pump(reader));
    return transport;
  }

  Future<void> _pump(RandomAccessFile reader) async {
    try {
      while (!_closed) {
        final chunk = await reader.read(256);
        if (chunk.isEmpty) break; // device went away
        _input.add(chunk);
      }
    } on FileSystemException catch (e) {
      if (!_closed) _input.addError(e);
    } finally {
      await reader.close().catchError((Object _) => reader);
      await _input.close();
    }
  }

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  void write(List<int> bytes) {
    if (!_closed) _file.writeFromSync(bytes);
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _file.close();
  }
}
