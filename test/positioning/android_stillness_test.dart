import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/positioning/positioning.dart';

import '../user/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  PositionEstimate wifiFix(DateTime t) => PositionEstimate(
    lat: lat0,
    lon: lon0,
    accuracyM: 25,
    source: PositionSource.wifi,
    timestamp: t,
    transmittersUsed: 4,
  );

  group('filter', () {
    final t0 = DateTime.utc(2026, 11, 27, 12);
    final later = t0.add(const Duration(seconds: 40));

    test('between scans the accuracy circle runs away', () {
      final filter = FusionFilter(config: androidPositioningConfig.fusion)
        ..addPosition(wifiFix(t0));
      // Forty seconds without evidence: it may have driven off.
      expect(filter.estimateAt(later)!.accuracyM, greaterThan(250));
    });

    test('a device known to lie still stays where the scan put it', () {
      final filter = FusionFilter(config: androidPositioningConfig.fusion)
        ..addPosition(wifiFix(t0));
      for (var s = 1; s <= 40; s++) {
        filter.addStationary(t0.add(Duration(seconds: s)));
      }
      final e = filter.estimateAt(later)!;
      expect(e.accuracyM, lessThan(40));
      expect(haversineM(e.lat, e.lon, lat0, lon0), lessThan(1));
      // Still a Wi-Fi position: stillness is not a source of its own.
      expect(e.source, PositionSource.wifi);
      expect(e.speedMps, 0);
    });

    test('before the first fix there is nothing to hold', () {
      final filter = FusionFilter()..addStationary(t0);
      expect(filter.estimateAt(t0), isNull);
    });
  });

  group('feeder', () {
    const events = EventChannel('test/android/still');
    late MockStreamHandlerEventSink? sink;
    late DateTime clock;
    late FakeGnss gnss;
    late PositioningEngine engine;
    late StationaryFeeder feeder;

    setUp(() async {
      sink = null;
      clock = DateTime.utc(2026, 11, 27, 12);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
            events,
            MockStreamHandler.inline(
              onListen: (_, s) => sink = s,
              onCancel: (_) => sink = null,
            ),
          );
      gnss = FakeGnss();
      engine = PositioningEngine(
        db: LocationDb.inMemory(),
        gnss: gnss,
        now: () => clock,
        config: const PositioningConfig(
          wifiScanInterval: Duration(hours: 1),
          cellPollInterval: Duration(hours: 1),
          outputInterval: Duration(hours: 1),
        ),
      );
      feeder = StationaryFeeder(
        engine,
        events: events,
        period: const Duration(milliseconds: 5),
        now: () => clock,
      );
      await engine.start();
    });

    tearDown(() async {
      feeder.stop();
      await engine.dispose();
      await gnss.controller.close();
    });

    Future<void> wait() =>
        Future<void>.delayed(const Duration(milliseconds: 30));

    test('feeds while still, stops when moved or stopped', () async {
      feeder.start();
      await wait();
      expect(feeder.samplesFed, 0); // the sensor has not spoken yet

      sink!.success(true);
      await wait();
      expect(feeder.still, isTrue);
      final fed = feeder.samplesFed;
      expect(fed, greaterThan(2));

      sink!.success(false);
      await wait();
      final afterMove = feeder.samplesFed;
      await wait();
      expect(feeder.samplesFed, afterMove);

      sink!.success(true);
      await wait();
      expect(feeder.samplesFed, greaterThan(afterMove));
      feeder.stop();
      await wait();
      expect(sink, isNull); // the sensor is released
      final afterStop = feeder.samplesFed;
      await wait();
      expect(feeder.samplesFed, afterStop);
    });

    test('satellites with a fix are not argued with', () async {
      feeder.start();
      await wait();
      // Driving at 20 m/s on a road smooth enough to look like a table.
      for (var s = 0; s < 5; s++) {
        gnss.controller.add(fixAt(clock, 20.0 * s, 0, speed: 20));
        clock = clock.add(const Duration(seconds: 1));
      }
      sink!.success(true);
      await wait();
      expect(feeder.samplesFed, 0);

      // The fix is lost (a tunnel): now stillness is the only evidence.
      clock = clock.add(const Duration(seconds: 10));
      await wait();
      expect(feeder.samplesFed, greaterThan(0));
    });

    test('a stopped engine is left alone', () async {
      feeder.start();
      await wait();
      await engine.stop();
      sink!.success(true);
      await wait();
      expect(feeder.samplesFed, 0);
    });
  });
}
