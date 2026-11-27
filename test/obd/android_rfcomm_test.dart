import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/obd/android_rfcomm_transport.dart';
import 'package:mapsoly/obd/elm327.dart';

/// BluetoothBridge.kt, scripted.
class _FakeBridge {
  _FakeBridge() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'hasPermission':
          return granted;
        case 'requestPermission':
          requests++;
          if (answer == 'granted') granted = true;
          return answer;
        case 'btBonded':
          if (off) throw PlatformException(code: 'off');
          return [
            {'address': '00:1D:A5:68:98:8B', 'name': 'OBDII'},
            {'address': '11:22:33:44:55:66', 'name': 'Headphones'},
          ];
        case 'btConnect':
          if (unreachable) throw PlatformException(code: 'connect');
          connected.add(call.arguments as String);
          return nextId++;
        case 'btWrite':
          final args = call.arguments as Map;
          written.add((args['id'] as int, args['data'] as Uint8List));
          onWrite?.call(args['id'] as int, args['data'] as Uint8List);
          return null;
        case 'btClose':
          closed.add(call.arguments as int);
          sink?.success({'id': call.arguments, 'closed': true});
          return null;
      }
      return null;
    });
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (_, s) => sink = s,
        onCancel: (_) => sink = null,
      ),
    );
  }

  static const channel = MethodChannel('test/android');
  static const events = EventChannel('test/android/bluetooth');

  bool granted = true;
  String answer = 'granted';
  int requests = 0;
  bool off = false;
  bool unreachable = false;
  int nextId = 1;
  final calls = <String>[];
  final connected = <String>[];
  final written = <(int, Uint8List)>[];
  final closed = <int>[];
  void Function(int id, Uint8List data)? onWrite;
  MockStreamHandlerEventSink? sink;

  AndroidBluetooth bluetooth() =>
      AndroidBluetooth(channel: channel, events: events);

  void receive(int id, String text) =>
      sink!.success({'id': id, 'data': Uint8List.fromList(text.codeUnits)});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('paired devices are listed by name', () async {
    final bridge = _FakeBridge();
    final devices = await bridge.bluetooth().devices();
    expect(devices.map((d) => d.name), ['Headphones', 'OBDII']);
    expect(devices.every((d) => d.paired), isTrue);
    expect(devices.last.address, '00:1D:A5:68:98:8B');
    expect(devices.last.looksLikeObd, isTrue);
  });

  test('the picker asks for the permission; a refusal is an error', () async {
    final bridge = _FakeBridge()
      ..granted = false
      ..answer = 'denied';
    final bluetooth = bridge.bluetooth();
    await expectLater(
      bluetooth.devices(),
      throwsA(isA<BluetoothPermissionDenied>()),
    );
    expect(bridge.requests, 1);
    expect(bridge.calls, isNot(contains('btBonded')));
    // The user opens the picker again: asked again.
    bridge.answer = 'granted';
    expect(await bluetooth.devices(), hasLength(2));
    expect(bridge.requests, 2);
  });

  test('reconnecting in the background asks only once', () async {
    final bridge = _FakeBridge()
      ..granted = false
      ..answer = 'denied';
    final bluetooth = bridge.bluetooth();
    for (var i = 0; i < 3; i++) {
      await expectLater(
        bluetooth.connect('00:1D:A5:68:98:8B'),
        throwsA(isA<BluetoothPermissionDenied>()),
      );
    }
    expect(bridge.requests, 1);
    expect(bridge.connected, isEmpty);
  });

  test('Bluetooth switched off surfaces as a platform error', () async {
    final bridge = _FakeBridge()..off = true;
    await expectLater(
      bridge.bluetooth().devices(),
      throwsA(isA<PlatformException>()),
    );
  });

  test('an adapter out of reach fails the connection', () async {
    final bridge = _FakeBridge()..unreachable = true;
    await expectLater(
      bridge.bluetooth().connect('00:1D:A5:68:98:8B'),
      throwsA(isA<PlatformException>()),
    );
  });

  test('bytes go both ways and each link sees only its own', () async {
    final bridge = _FakeBridge();
    final bluetooth = bridge.bluetooth();
    final a = await bluetooth.connect('00:1D:A5:68:98:8B');
    final b = await bluetooth.connect('11:22:33:44:55:66');
    expect(bridge.connected, ['00:1D:A5:68:98:8B', '11:22:33:44:55:66']);
    final fromA = <int>[], fromB = <int>[];
    a.input.listen(fromA.addAll);
    b.input.listen(fromB.addAll);

    a.write('ATZ\r'.codeUnits);
    a.write(const []); // nothing to send: no call
    await pumpEventQueue();
    expect(bridge.written, hasLength(1));
    expect(bridge.written.single.$1, 1);
    expect(String.fromCharCodes(bridge.written.single.$2), 'ATZ\r');

    bridge.receive(1, 'ELM327 v1.5\r>');
    bridge.receive(2, 'x');
    bridge.receive(99, 'stray'); // a link long gone
    await pumpEventQueue();
    expect(String.fromCharCodes(fromA), 'ELM327 v1.5\r>');
    expect(String.fromCharCodes(fromB), 'x');
    await a.close();
    await b.close();
  });

  test('closing ends the input and stops writes', () async {
    final bridge = _FakeBridge();
    final link = await bridge.bluetooth().connect('00:1D:A5:68:98:8B');
    var done = false;
    link.input.listen((_) {}, onDone: () => done = true);
    await link.close();
    await pumpEventQueue();
    expect(bridge.closed, [1]);
    expect(done, isTrue);
    link.write('ATZ\r'.codeUnits);
    await pumpEventQueue();
    expect(bridge.written, isEmpty);
    await link.close(); // twice is fine
    expect(bridge.closed, [1]);
  });

  test('a link dropped by the adapter closes the input', () async {
    final bridge = _FakeBridge();
    final link = await bridge.bluetooth().connect('00:1D:A5:68:98:8B');
    var done = false;
    link.input.listen((_) {}, onDone: () => done = true);
    bridge.sink!.success({'id': 1, 'closed': true});
    await pumpEventQueue();
    expect(done, isTrue);
  });

  test('carries an ELM327 conversation', () async {
    final bridge = _FakeBridge();
    // An adapter that answers the speed request with 60 km/h.
    bridge.onWrite = (id, data) {
      final command = String.fromCharCodes(data).trim();
      bridge.receive(id, command.startsWith('010D') ? '41 0D 3C\r\r>' : 'OK\r\r>');
    };
    final link = await bridge.bluetooth().connect('00:1D:A5:68:98:8B');
    final elm = Elm327(link);
    expect(await elm.readSpeedKmh(), 60);
    await elm.close();
    expect(bridge.closed, [1]);
  });
}
