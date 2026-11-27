import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/positioning/positioning.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/android');
  const events = EventChannel('test/android/compass');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('headings arrive only while started', () async {
    MockStreamHandlerEventSink? sink;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'hasCompass',
    );
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (_, s) => sink = s,
        onCancel: (_) => sink = null,
      ),
    );
    final compass = AndroidCompass(channel: channel, events: events);
    expect(await compass.available(), isTrue);
    final seen = <double>[];
    compass.headings.listen(seen.add);
    expect(sink, isNull); // the sensor is not running yet

    await compass.start();
    await pumpEventQueue();
    sink!.success(271.5);
    sink!.success(3);
    await pumpEventQueue();
    expect(seen, [271.5, 3.0]);

    await compass.stop();
    await pumpEventQueue();
    expect(sink, isNull);
    await compass.dispose();
  });

  test('no platform side means no compass', () async {
    messenger.setMockMethodCallHandler(channel, null);
    final compass = AndroidCompass(channel: channel, events: events);
    expect(await compass.available(), isFalse);
    await compass.dispose();
  });
}
