import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/positioning/positioning.dart';

/// The platform side of the location channels, scripted.
class _FakePlatform {
  _FakePlatform({this.granted = false, this.answer = 'granted'}) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'hasPermission':
          return granted;
        case 'requestPermission':
          if (answer == 'granted') granted = true;
          return answer;
        case 'locationEnabled':
          return enabled;
      }
      return null;
    });
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (_, sink) => this.sink = sink,
        onCancel: (_) => sink = null,
      ),
    );
  }

  static const channel = MethodChannel('test/android');
  static const events = EventChannel('test/android/location');

  bool granted;
  bool enabled = true;
  String answer;
  final calls = <String>[];
  MockStreamHandlerEventSink? sink;

  AndroidGnssSource source() =>
      AndroidGnssSource(channel: channel, events: events);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Red Square, Moscow.
  const fixEvent = {
    'lat': 55.7539,
    'lon': 37.6208,
    'alt': 150.0,
    'acc': 4.0,
    'speed': 12.5,
    'course': 90.0,
    'time': 1795780000000,
    'sats': [
      [1, 5, 38.0, 60.0, 120.0, true],
      [3, 12, 31.5, 25.0, 300.0, true],
      [6, 7, 0.0, 5.0, 10.0, false],
    ],
  };

  test('a platform fix becomes a GNSS epoch', () {
    final at = DateTime(2026, 11, 27, 12);
    final fix = fixFromAndroid(fixEvent, at);
    expect(fix.hasPosition, isTrue);
    expect(fix.lat, 55.7539);
    expect(fix.lon, 37.6208);
    expect(fix.altitudeM, 150);
    expect(fix.accuracyM, 4);
    expect(fix.speedMps, 12.5);
    expect(fix.courseDeg, 90);
    expect(fix.receivedAt, at);
    expect(fix.time!.isUtc, isTrue);
    expect(fix.satellites, hasLength(3));
    expect(fix.satellitesUsed, 2);
    expect(fix.satellites[1].system, GnssSystem.glonass);
    expect(fix.satellites[1].cn0, 31.5);
    // Not tracked: no signal level rather than a zero one.
    expect(fix.satellites[2].cn0, isNull);
  });

  test('a fix is dated by when it was taken, not when it arrived', () {
    final now = DateTime(2026, 11, 27, 12, 0, 10);
    int ms(DateTime t) => t.millisecondsSinceEpoch;
    // Held up for four seconds behind a busy app.
    final late = fixFromAndroid({...fixEvent, 'at': ms(now) - 4000}, now);
    expect(late.receivedAt, now.subtract(const Duration(seconds: 4)));
    // Nonsense is not believed: the future, or half a minute ago and more.
    expect(
      fixFromAndroid({...fixEvent, 'at': ms(now) + 5000}, now).receivedAt,
      now,
    );
    expect(
      fixFromAndroid({...fixEvent, 'at': ms(now) - 60000}, now).receivedAt,
      now,
    );
    expect(fixFromAndroid(fixEvent, now).receivedAt, now);
  });

  test('fixes delivered in a bunch are not a position jump', () {
    // 33 m/s east along the Moskva embankment, a fix every second; the
    // app was busy and got five of them at once.
    final now = DateTime(2026, 11, 27, 12, 0, 10);
    final checker = GnssSanityChecker();
    for (var i = 0; i < 5; i++) {
      final fix = fixFromAndroid({
        'lat': 55.7539,
        'lon': 37.6208 + i * 33 / 62700, // ~62.7 km per degree here
        'acc': 3.0,
        'speed': 33.0,
        'course': 90.0,
        'time': now.millisecondsSinceEpoch - (4 - i) * 1000,
        'at': now.millisecondsSinceEpoch - (4 - i) * 1000,
        'sats': <Object>[],
      }, now);
      expect(checker.check(fix).anomalies, isEmpty, reason: 'fix $i');
    }
    // The same five dated by arrival would be 132 m in no time at all.
    final naive = GnssSanityChecker();
    Set<GnssAnomaly> last = {};
    for (var i = 0; i < 5; i++) {
      last = naive
          .check(
            GnssFix(
              valid: true,
              receivedAt: now.add(Duration(milliseconds: i)),
              lat: 55.7539,
              lon: 37.6208 + i * 3 * 33 / 62700,
              accuracyM: 3,
              speedMps: 33,
            ),
          )
          .anomalies;
    }
    expect(last, contains(GnssAnomaly.positionJump));
  });

  test('an event without coordinates is an epoch without a position', () {
    final fix = fixFromAndroid({'sats': []}, DateTime(2026));
    expect(fix.valid, isFalse);
    expect(fix.hasPosition, isFalse);
  });

  test('the course of a standing device is dropped', () {
    final fix = fixFromAndroid({...fixEvent, 'speed': 0.1}, DateTime(2026));
    expect(fix.courseDeg, isNull);
  });

  test('with the permission held, fixes flow at once', () async {
    final platform = _FakePlatform(granted: true);
    final source = platform.source();
    final fixes = <GnssFix>[];
    source.fixes.listen(fixes.add);
    await source.start();
    await pumpEventQueue();
    expect(source.connected, isTrue);
    expect(platform.calls, isNot(contains('requestPermission')));
    platform.sink!.success(fixEvent);
    await pumpEventQueue();
    expect(fixes.single.lat, 55.7539);
    expect(source.state.value, LocationAccessState.granted);
    await source.stop();
    expect(source.connected, isFalse);
    expect(platform.sink, isNull);
    await source.dispose();
  });

  test('a refusal is remembered, and asking again can fix it', () async {
    final platform = _FakePlatform(answer: 'denied');
    final source = platform.source();
    await source.start();
    await pumpEventQueue();
    expect(source.connected, isFalse);
    expect(source.state.value, LocationAccessState.denied);
    expect(platform.sink, isNull);

    platform.answer = 'granted';
    await source.request();
    await pumpEventQueue();
    expect(source.connected, isTrue);
    expect(source.state.value, LocationAccessState.granted);
    await source.dispose();
  });

  test('a restart does not bring the dialog up again', () async {
    final platform = _FakePlatform(answer: 'denied');
    final source = platform.source();
    await source.start();
    await pumpEventQueue();
    // The app left the screen and came back.
    await source.stop();
    await source.start();
    await pumpEventQueue();
    expect(platform.calls.where((c) => c == 'requestPermission'), hasLength(1));
    expect(source.state.value, LocationAccessState.denied);
    // Granted in the system settings meanwhile: picked up without asking.
    platform.granted = true;
    await source.stop();
    await source.start();
    await pumpEventQueue();
    expect(source.connected, isTrue);
    expect(platform.calls.where((c) => c == 'requestPermission'), hasLength(1));
    await source.dispose();
  });

  test('a blocked permission sends the user to the settings', () async {
    final platform = _FakePlatform(answer: 'blocked');
    final source = platform.source();
    await source.start();
    await pumpEventQueue();
    expect(source.state.value, LocationAccessState.blocked);
    platform.calls.clear();
    await source.request();
    expect(platform.calls, ['openAppSettings']);

    // Back from the settings with the permission given.
    platform.granted = true;
    await source.refresh();
    await pumpEventQueue();
    expect(source.connected, isTrue);
    expect(source.state.value, LocationAccessState.granted);
    await source.dispose();
  });

  test('location switched off in the system is told apart', () async {
    final platform = _FakePlatform(granted: true)..enabled = false;
    final source = platform.source();
    await source.start();
    await pumpEventQueue();
    expect(source.state.value, LocationAccessState.switchedOff);
    platform.enabled = true;
    await source.refresh();
    expect(source.state.value, LocationAccessState.granted);
    // The provider goes away while the system switch is still on (a test
    // provider, an old phone's separate GPS toggle): not "switched off".
    platform.sink!.success({'off': true, 'sats': <Object>[]});
    await pumpEventQueue();
    expect(source.state.value, LocationAccessState.granted);
    platform.enabled = false;
    platform.sink!.success({'off': true, 'sats': <Object>[]});
    await pumpEventQueue();
    expect(source.state.value, LocationAccessState.switchedOff);
    await source.dispose();
  });

  test('the permission taken away while running stops the stream', () async {
    final platform = _FakePlatform(granted: true);
    final source = platform.source();
    await source.start();
    await pumpEventQueue();
    platform.granted = false;
    await source.refresh();
    expect(source.connected, isFalse);
    expect(source.state.value, LocationAccessState.denied);
    await source.dispose();
  });

  test('feeds the engine like any GNSS source', () async {
    final platform = _FakePlatform(granted: true);
    final source = platform.source();
    final engine = PositioningEngine(
      db: LocationDb.open(':memory:'),
      gnss: source,
    );
    await engine.start();
    await pumpEventQueue();
    platform.sink!.success(fixEvent);
    await pumpEventQueue();
    await engine.pollNow();
    expect(engine.status.gnssConnected, isTrue);
    expect(engine.current!.lat, closeTo(55.7539, 1e-4));
    expect(engine.current!.source, PositionSource.gnss);
    expect(engine.status.satellitesUsed, 2);
    await engine.dispose();
    await source.dispose();
  });
}
