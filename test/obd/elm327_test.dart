import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/obd/elm327.dart';
import 'dart:io';

import 'package:mapsoly/obd/obd_session.dart';

import 'fake_elm.dart';

void main() {
  group('reply parsing', () {
    List<int>? speed(List<String> lines) =>
        Elm327.parseReply(lines, mode: 0x01, pid: 0x0D);

    test('compact and spaced replies', () {
      expect(speed(['410D3C']), [0x3C]);
      expect(speed(['41 0D 3C']), [0x3C]);
      expect(speed(['41 0d 00']), [0]);
    });

    test('skips status lines and other ECUs', () {
      expect(speed(['SEARCHING...', '410D5A']), [0x5A]);
      expect(speed(['410C1AF8', '410D21']), [0x21]);
    });

    test('headers left on still parse', () {
      expect(speed(['7E8 03 41 0D 3C']), [0x3C]);
    });

    test('errors and noise give null', () {
      expect(speed(['NO DATA']), isNull);
      expect(speed(['UNABLE TO CONNECT']), isNull);
      expect(speed(['CAN ERROR']), isNull);
      expect(speed(['?']), isNull);
      expect(speed(['410D3']), isNull);
      expect(speed([]), isNull);
    });
  });

  group('adapter session', () {
    test('initialises and reads speed', () async {
      final fake = FakeElm(speedKmh: 87);
      final elm = Elm327(fake);
      await elm.initialize();
      expect(elm.version, 'ELM327 v1.5');
      expect(fake.received.take(6), [
        'ATZ',
        'ATE0',
        'ATL0',
        'ATS0',
        'ATH0',
        'ATSP0',
      ]);
      expect(await elm.readSpeedKmh(), 87);
      expect(fake.received.last, '010D1');
      await elm.close();
    });

    test('a clone that rejects the count suffix falls back once', () async {
      final fake = FakeElm(
        version: 'ELM327 v2.1',
        speedKmh: 40,
        supportsCountSuffix: false,
      );
      final elm = Elm327(fake);
      await elm.initialize();
      expect(await elm.readSpeedKmh(), 40);
      fake.received.clear();
      expect(await elm.readSpeedKmh(), 40);
      expect(fake.received, ['010D']);
      await elm.close();
    });

    test('slow protocol search on the first request', () async {
      final fake = FakeElm(searchingFirst: true);
      final elm = Elm327(fake);
      await elm.initialize();
      expect(await elm.readSpeedKmh(), 60);
      await elm.close();
    });

    test('ignition off: no data is null, not zero', () async {
      final fake = FakeElm();
      final elm = Elm327(fake);
      await elm.initialize();
      fake.speedKmh = null;
      expect(await elm.readSpeedKmh(), isNull);
      await elm.close();
    });

    test('a car that does not answer fails initialisation', () async {
      final elm = Elm327(FakeElm(vehicleAnswers: false));
      await expectLater(elm.initialize(), throwsA(isA<ElmException>()));
      await elm.close();
    });

    test('a dropped link fails the command in flight', () async {
      final fake = FakeElm();
      final elm = Elm327(fake);
      await elm.initialize();
      fake.drop();
      await expectLater(elm.readSpeedKmh(), throwsA(isA<ElmException>()));
    });
  });

  group('speed source', () {
    test('streams speed in m/s and reports its state', () async {
      final fake = FakeElm(speedKmh: 72);
      final source = ObdSession(
        () async => fake,
        pollInterval: const Duration(milliseconds: 5),
      );
      final states = <ObdState>[];
      source.states.listen(states.add);
      source.start();
      final first = await source.samples.first;
      expect(first.speedMps, closeTo(20, 1e-9));
      expect(states, [ObdState.connecting, ObdState.connected]);
      expect(source.adapter, 'ELM327 v1.5');
      await source.dispose();
    });

    test('reconnects after the link drops', () async {
      final adapters = [FakeElm(speedKmh: 30), FakeElm(speedKmh: 50)];
      var connects = 0;
      final source = ObdSession(
        () async => adapters[connects++],
        pollInterval: const Duration(milliseconds: 5),
      );
      final seen = <double>[];
      final got50 = Completer<void>();
      source.samples.listen((s) {
        seen.add(s.speedMps * 3.6);
        if ((s.speedMps * 3.6 - 50).abs() < 0.01 && !got50.isCompleted) {
          got50.complete();
        }
      });
      source.start();
      await source.samples.first;
      adapters[0].drop();
      await got50.future.timeout(const Duration(seconds: 5));
      expect(connects, 2);
      expect(seen.first, closeTo(30, 0.01));
      await source.dispose();
    });

    test('an unreachable adapter is reported, not thrown', () async {
      final source = ObdSession(
        () async => throw const FormatException('no route to adapter'),
      );
      source.start();
      await source.states.firstWhere((s) => s == ObdState.disconnected);
      expect(source.lastError, contains('no route to adapter'));
      await source.dispose();
    });
  });

  group('decoders', () {
    test('supported PID bitmask', () {
      // BE 3E A8 13: the mask a typical petrol car returns for 0100.
      final pids = supportedPids(0, [0xBE, 0x3E, 0xA8, 0x13]);
      expect(pids, containsAll([0x01, 0x04, 0x05, 0x0C, 0x0D, 0x20]));
      expect(pids, isNot(contains(0x02)));
      expect(pids, isNot(contains(0x10)));
    });

    test('engine and fuel values', () {
      expect(rpmFrom([0x1A, 0xF8]), 1726);
      expect(coolantFrom([0x7B]), 83);
      expect(fuelRateFrom([0x00, 0x78]), 6);
      expect(fuelLevelFrom([0x80]), closeTo(50.2, 0.1));
      // 10 g/s of air on petrol is about 3.3 L/h.
      expect(fuelRateFromMaf(10, FuelType.petrol), closeTo(3.29, 0.01));
      expect(fuelRateFromMaf(10, FuelType.diesel), isNull);
    });

    test('trouble codes on CAN and on older protocols', () {
      expect(troubleCodesFrom(['43020133D016'], can: true), ['P0133', 'U1016']);
      expect(troubleCodesFrom(['43013300000000'], can: false), ['P0133']);
      expect(troubleCodesFrom(['4300'], can: true), isEmpty);
      expect(troubleCodesFrom(['NO DATA'], can: true), isEmpty);
    });

    test('VIN in both reply layouts', () {
      expect(
        vinFrom([
          '014',
          '0:490201575657',
          '1:5A5A5A314A5A58',
          '2:57303030303031',
        ]),
        'WVWZZZ1JZXW000001',
      );
      expect(
        vinFrom([
          '49020100000057',
          '49020256575A5A',
          '4902035A314A5A',
          '49020458573030',
          '49020530303031',
        ]),
        'WVWZZZ1JZXW000001',
      );
      expect(vinFrom(['NO DATA']), isNull);
    });
  });

  group('optional data', () {
    Future<ObdSession> connected(FakeElm fake, ObdOptions options) async {
      final session = ObdSession(
        () async => fake,
        options: options,
        pollInterval: const Duration(milliseconds: 2),
      );
      session.start();
      await session.states.firstWhere((s) => s == ObdState.connected);
      return session;
    }

    test('nothing extra is requested by default', () async {
      final fake = FakeElm(pids: {0x0C, 0x05, 0x5E, 0x2F, 0x51, 0x01});
      final session = ObdSession(
        () async => fake,
        pollInterval: const Duration(milliseconds: 2),
      );
      session.start();
      await session.samples.take(5).last;
      await session.dispose();
      final extra = fake.received.where(
        (c) => !c.startsWith('AT') && c != '0100' && !c.startsWith('010D'),
      );
      expect(extra, isEmpty);
      expect(session.telemetry.fuelRateLph, isNull);
      expect(session.vehicle.vin, isNull);
    });

    test('fuel rate from the ECU, consumption and trip totals', () async {
      final fake = FakeElm(speedKmh: 90, pids: {0x5E, 0x2F, 0x51})
        ..fuelRateLph = 5.4;
      final session = await connected(fake, const ObdOptions(fuel: true));
      final t = await session.telemetryUpdates.firstWhere(
        (t) => t.fuelRateLph != null && t.fuelLevelPercent != null,
      );
      expect(t.fuelRateLph, closeTo(5.4, 0.05));
      expect(t.fuelRateEstimated, isFalse);
      expect(t.consumptionLPer100km, closeTo(6.0, 0.1));
      expect(t.fuelLevelPercent, closeTo(50, 0.5));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(session.telemetry.tripDistanceKm, greaterThan(0));
      expect(session.telemetry.tripFuelL, greaterThan(0));
      await session.dispose();
    });

    test('fuel rate estimated from air flow on a petrol car', () async {
      final fake = FakeElm(speedKmh: 60, pids: {0x10, 0x51})..mafGps = 10;
      final session = await connected(fake, const ObdOptions(fuel: true));
      final t = await session.telemetryUpdates.firstWhere(
        (t) => t.fuelRateLph != null,
      );
      expect(t.fuelRateLph, closeTo(3.29, 0.02));
      expect(t.fuelRateEstimated, isTrue);
      await session.dispose();
    });

    test('no air-flow estimate for a diesel', () async {
      final fake = FakeElm(pids: {0x10, 0x51}, fuelTypeCode: 4);
      final session = await connected(fake, const ObdOptions(fuel: true));
      await session.samples.take(6).last;
      expect(session.telemetry.fuelRateLph, isNull);
      expect(fake.received, isNot(contains('0110')));
      await session.dispose();
    });

    test('standing still gives no per-distance consumption', () async {
      final fake = FakeElm(speedKmh: 0, pids: {0x5E});
      final session = await connected(fake, const ObdOptions(fuel: true));
      final t = await session.telemetryUpdates.firstWhere(
        (t) => t.fuelRateLph != null,
      );
      expect(t.consumptionLPer100km, isNull);
      await session.dispose();
    });

    for (final can in [true, false]) {
      test('vehicle info on ${can ? 'CAN' : 'an older protocol'}', () async {
        final fake = FakeElm(
          can: can,
          pids: {0x01, 0x05, 0x0C, 0x51},
          troubleCodes: const ['0133'],
        );
        final session = await connected(
          fake,
          const ObdOptions(vehicleInfo: true),
        );
        expect(session.vehicle.vin, 'WVWZZZ1JZXW000001');
        expect(session.vehicle.fuelType, FuelType.petrol);
        expect(session.vehicle.milOn, isTrue);
        expect(session.vehicle.troubleCodes, ['P0133']);
        expect(session.vehicle.protocol, contains(can ? 'CAN' : '9141'));
        final t = await session.telemetryUpdates.firstWhere(
          (t) => t.rpm != null && t.coolantC != null && t.batteryVolts != null,
        );
        expect(t.rpm, 2000);
        expect(t.coolantC, 90);
        expect(t.batteryVolts, 12.6);
        await session.dispose();
      });
    }

    test('trip log has a header and one row per second', () async {
      final dir = Directory.systemTemp.createTempSync('mapsoly-obd-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final fake = FakeElm(speedKmh: 50, pids: {0x5E});
      final session = await connected(
        fake,
        ObdOptions(
          fuel: true,
          logDirectory: dir,
          position: () => (lat: 55.75, lon: 37.62),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await session.dispose();
      final files = dir.listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      final lines = files.single.readAsLinesSync();
      expect(lines.first, startsWith('time,speed_kmh,rpm'));
      expect(lines.length, inInclusiveRange(2, 3));
      final row = lines[1].split(',');
      expect(row[1], '50');
      expect(row.sublist(row.length - 2), ['55.750000', '37.620000']);
    });
  });
}
