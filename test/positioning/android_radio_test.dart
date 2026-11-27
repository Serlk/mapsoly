import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/positioning/positioning.dart';

const _channel = MethodChannel('test/android/radio');
const _intMax = 0x7fffffff;
const _longMax = 0x7fffffffffffffff;

/// RadioBridge.kt, scripted.
class _FakeRadio {
  _FakeRadio() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'wifiScan':
              return wifi;
            case 'wifiRequestScan':
              return scanAccepted;
            case 'cells':
              return cells;
          }
          return null;
        });
  }

  List<Object?> wifi = [];
  List<Object?> cells = [];
  bool scanAccepted = true;
  final calls = <String>[];

  int count(String method) => calls.where((c) => c == method).length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Wi-Fi rows', () {
    test('an access point with everything known', () {
      final o = wifiFromAndroid(['AA:BB:CC:00:00:01', -61, 2437, 1500, 'Cafe']);
      expect(o!.bssid, 'aa:bb:cc:00:00:01');
      expect(o.signalDbm, -61);
      expect(o.signalPercent, isNull);
      expect(o.frequencyMhz, 2437);
      expect(o.age, const Duration(milliseconds: 1500));
      expect(o.ssid, 'Cafe');
      expect(o.optedOut, isFalse);
    });

    test('hidden networks have no name, in any of its spellings', () {
      for (final ssid in [null, '', '<unknown ssid>']) {
        final o = wifiFromAndroid(['aa:bb:cc:00:00:02', -70, 5180, 0, ssid]);
        expect(o!.ssid, isNull, reason: '$ssid');
        expect(o.optedOut, isFalse);
      }
      // Older bridges send four columns.
      expect(
        wifiFromAndroid(['aa:bb:cc:00:00:02', -70, 5180, 0])!.ssid,
        isNull,
      );
    });

    test('the opt-out suffix is honoured', () {
      final o = wifiFromAndroid(['aa:bb:cc:00:00:03', -70, 2412, 0, 'x_nomap']);
      expect(o!.optedOut, isTrue);
    });

    test('6 GHz channels keep their frequency', () {
      final o = wifiFromAndroid(['aa:bb:cc:00:00:04', -72, 6115, 0, 'six']);
      expect(o!.frequencyMhz, 6115);
      // The model puts a 6 GHz AP nearer than a 2.4 GHz one at equal level.
      const model = PathLossModel();
      expect(
        model.wifiDistanceM(-72, frequencyMhz: 6115),
        lessThan(model.wifiDistanceM(-72, frequencyMhz: 2437)),
      );
    });

    test('placeholders and garbage are not access points', () {
      // What Android shows instead of the BSSID to an app without access.
      expect(wifiFromAndroid(['02:00:00:00:00:00', -50, 2437, 0, 'a']), isNull);
      expect(wifiFromAndroid(['00:00:00:00:00:00', -50, 2437, 0, 'a']), isNull);
      expect(wifiFromAndroid(['not a mac', -50, 2437, 0, 'a']), isNull);
      expect(wifiFromAndroid([null, -50, 2437, 0, 'a']), isNull);
      expect(wifiFromAndroid(['aa:bb:cc:00:00:05']), isNull);
      expect(wifiFromAndroid('aa:bb:cc:00:00:05'), isNull);
    });

    test('impossible levels, frequencies and ages are dropped, not kept', () {
      final o = wifiFromAndroid(['aa:bb:cc:00:00:06', 0, 0, -400, 'a']);
      expect(o!.signalDbm, isNull);
      expect(o.frequencyMhz, isNull);
      expect(o.age, Duration.zero);
      expect(
        wifiFromAndroid(['aa:bb:cc:00:00:06', -200, 2437, 0])!.signalDbm,
        isNull,
      );
    });
  });

  group('Wi-Fi scanner', () {
    test('stale entries of the cache are left out', () async {
      final radio = _FakeRadio()
        ..wifi = [
          ['aa:bb:cc:00:00:01', -60, 2437, 2000, 'fresh'],
          ['aa:bb:cc:00:00:02', -60, 2437, 44000, 'ageing'],
          ['aa:bb:cc:00:00:03', -60, 2437, 600000, 'ten minutes old'],
        ];
      final scanner = AndroidWifiScanner(channel: _channel);
      expect(scanner.reportsDbm, isTrue);
      final thirty = await scanner.getObservations();
      expect(thirty.map((o) => o.bssid), ['aa:bb:cc:00:00:01']);
      final fortyFive = await scanner.getObservations(
        maxAge: androidPositioningConfig.estimator.maxWifiAge,
      );
      expect(fortyFive, hasLength(2));
      expect(radio.count('wifiScan'), 2);
    });

    test('an access point listed twice counts once, at its best', () async {
      _FakeRadio().wifi = [
        ['aa:bb:cc:00:00:01', -80, 2437, 0, 'a'],
        ['AA:BB:CC:00:00:01', -55, 2437, 0, 'a'],
        ['02:00:00:00:00:00', -40, 2437, 0, 'a'],
      ];
      final scan = await AndroidWifiScanner(
        channel: _channel,
      ).getObservations();
      expect(scan.single.signalDbm, -55);
    });

    test('scan requests keep to four in two minutes', () async {
      final radio = _FakeRadio();
      var clock = DateTime.utc(2026, 11, 27, 12);
      final scanner = AndroidWifiScanner(channel: _channel, now: () => clock);
      var accepted = 0;
      // The engine asks every five seconds.
      for (var s = 0; s < 120; s += 5) {
        if (await scanner.requestScan()) accepted++;
        clock = clock.add(const Duration(seconds: 5));
      }
      expect(accepted, 4);
      expect(radio.count('wifiRequestScan'), 4);
    });

    test('a refusal is not argued with for a minute', () async {
      final radio = _FakeRadio()..scanAccepted = false;
      var clock = DateTime.utc(2026, 11, 27, 12);
      final scanner = AndroidWifiScanner(channel: _channel, now: () => clock);
      expect(await scanner.requestScan(), isFalse);
      clock = clock.add(const Duration(seconds: 45));
      expect(await scanner.requestScan(), isFalse);
      expect(radio.count('wifiRequestScan'), 1);
      radio.scanAccepted = true;
      clock = clock.add(const Duration(seconds: 20));
      expect(await scanner.requestScan(), isTrue);
      expect(radio.count('wifiRequestScan'), 2);
    });

    test('no platform side: no access points, no errors', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
      final scanner = AndroidWifiScanner(channel: _channel);
      expect(await scanner.getObservations(), isEmpty);
      expect(await scanner.requestScan(), isFalse);
    });
  });

  group('cells', () {
    // Made-up network 999-07, as in the other tests.
    Map<String, Object?> lte({bool serving = true}) => {
      'radio': 'lte',
      'serving': serving,
      'mcc': 999,
      'mnc': 7,
      'area': 4242,
      'cid': 26543105,
      'pci': 301,
      'arfcn': 1850,
      'dbm': -97,
      'rsrq': -11,
      'ta': 3,
    };

    test('a serving LTE cell', () {
      final c = cellFromAndroid(lte())!;
      expect(c.radio, RadioType.lte);
      expect(c.key, 'lte:999:7:4242:26543105');
      expect(c.pci, 301);
      expect(c.arfcn, 1850);
      expect(c.signalDbm, -97);
      expect(c.rsrq, -11);
      expect(c.timingAdvance, 3);
      expect(c.serving, isTrue);
      expect(timingAdvanceMeters(c.radio, c.timingAdvance), closeTo(234, 1));
    });

    test('a neighbour known only by its physical id has no identity', () {
      final c = cellFromAndroid({
        'radio': 'lte',
        'serving': false,
        'mcc': null,
        'mnc': null,
        'area': _intMax,
        'cid': _intMax,
        'pci': 77,
        'arfcn': 1850,
        'dbm': -110,
        'rsrq': _intMax,
        'ta': _intMax,
      })!;
      expect(c.hasFullId, isFalse);
      expect(c.key, isNull);
      expect(c.mcc, isNull);
      expect(c.area, isNull);
      expect(c.cellId, isNull);
      expect(c.rsrq, isNull);
      expect(c.timingAdvance, isNull);
      expect(c.pci, 77);
      expect(c.signalDbm, -110);
      expect(c.serving, isFalse);
    });

    test('"unavailable" never becomes a number', () {
      final c = cellFromAndroid({
        ...lte(),
        'mcc': _intMax,
        'mnc': _intMax,
        'pci': _intMax,
        'arfcn': _intMax,
        'dbm': _intMax,
      })!;
      expect(c.mcc, isNull);
      expect(c.mnc, isNull);
      expect(c.pci, isNull);
      expect(c.arfcn, isNull);
      expect(c.signalDbm, isNull);
      expect(c.hasFullId, isFalse);
    });

    test('reserved identities are not identities', () {
      expect(cellFromAndroid({...lte(), 'cid': 0xfffffff})!.cellId, isNull);
      expect(cellFromAndroid({...lte(), 'cid': 0})!.cellId, isNull);
      expect(cellFromAndroid({...lte(), 'cid': -1})!.cellId, isNull);
      expect(cellFromAndroid({...lte(), 'area': 0})!.area, isNull);
      expect(cellFromAndroid({...lte(), 'area': 0xfffe})!.area, isNull);
      expect(cellFromAndroid({...lte(), 'mcc': 0})!.mcc, isNull);
      // MNC 00 exists.
      expect(cellFromAndroid({...lte(), 'mnc': 0})!.mnc, 0);
      final gsm = {...lte(), 'radio': 'gsm', 'cid': 0xffff};
      expect(cellFromAndroid(gsm)!.cellId, isNull);
    });

    test('GSM and UMTS', () {
      final gsm = cellFromAndroid({
        'radio': 'gsm',
        'serving': true,
        'mcc': 999,
        'mnc': 7,
        'area': 1201,
        'cid': 40321,
        'pci': 23,
        'arfcn': 62,
        'dbm': -83,
        'ta': 1,
      })!;
      expect(gsm.key, 'gsm:999:7:1201:40321');
      expect(gsm.timingAdvance, 1);
      final umts = cellFromAndroid({
        'radio': 'umts',
        'serving': true,
        'mcc': 999,
        'mnc': 7,
        'area': 1201,
        'cid': 123456789,
        'pci': 211,
        'arfcn': 10713,
        'dbm': -91,
      })!;
      expect(umts.key, 'umts:999:7:1201:123456789');
      expect(umts.timingAdvance, isNull);
    });

    test('NR: a 36-bit identity, and its own "unavailable"', () {
      final nr = {
        'radio': 'nr',
        'serving': true,
        'mcc': 999,
        'mnc': 7,
        'area': 70000,
        'cid': 0x812345678,
        'pci': 900,
        'arfcn': 630000,
        'dbm': -101,
        'rsrq': -12,
      };
      final c = cellFromAndroid(nr)!;
      expect(c.cellId, 0x812345678);
      expect(c.area, 70000);
      expect(c.hasFullId, isTrue);
      expect(cellFromAndroid({...nr, 'cid': _longMax})!.cellId, isNull);
      expect(cellFromAndroid({...nr, 'cid': _intMax})!.cellId, _intMax);
    });

    test('kinds without a model are skipped', () {
      expect(cellFromAndroid({...lte(), 'radio': 'cdma'}), isNull);
      expect(cellFromAndroid({'serving': true}), isNull);
      expect(cellFromAndroid('lte'), isNull);
    });

    test('the source: one entry per cell, neighbours kept', () async {
      _FakeRadio().cells = [
        lte(),
        lte(), // the second SIM on the same network
        {...lte(serving: false), 'cid': _intMax, 'pci': 12},
        {...lte(serving: false), 'cid': _intMax, 'pci': 13},
        {'radio': 'cdma', 'serving': false},
      ];
      final cells = await AndroidCellSource(channel: _channel).getCells();
      expect(cells, hasLength(3));
      expect(cells.where((c) => c.hasFullId), hasLength(1));
      expect(cells.first.serving, isTrue);
    });

    test('a tablet without a modem reports no cells', () async {
      _FakeRadio(); // the bridge answers with an empty list
      expect(await AndroidCellSource(channel: _channel).getCells(), isEmpty);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
      expect(await AndroidCellSource(channel: _channel).getCells(), isEmpty);
    });
  });

  test(
    'position from Android scans alone, once the database knows them',
    () async {
      final radio = _FakeRadio();
      final db = LocationDb.inMemory();
      var clock = DateTime.utc(2026, 11, 27, 12);
      // Red Square, Moscow.
      db.upsertExternal([
        TransmitterRecord(
          kind: TransmitterKind.wifi,
          id: 'aa:bb:cc:00:00:01',
          lat: 55.7539,
          lon: 37.6208,
          accuracyM: 30,
          source: TransmitterSource.csv,
          updated: clock,
        ),
      ]);
      final engine = PositioningEngine(
        db: db,
        wifi: AndroidWifiScanner(channel: _channel, now: () => clock),
        cells: AndroidCellSource(channel: _channel),
        now: () => clock,
        config: androidPositioningConfig,
      );
      radio.wifi = [
        ['AA:BB:CC:00:00:01', -58, 5180, 38000, 'known'],
        ['aa:bb:cc:00:00:02', -70, 2437, 38000, null],
      ];
      await engine.pollNow();
      // 38 s old: the list between two rationed scans still counts.
      expect(engine.status.wifiVisible, 2);
      expect(engine.status.wifiKnown, 1);
      expect(engine.lastRadioEstimate.best!.source, PositionSource.wifi);
      expect(engine.current!.lat, closeTo(55.7539, 1e-3));
      expect(engine.current!.lon, closeTo(37.6208, 1e-3));

      // Left behind: the old list ages out and is not used any more.
      radio.wifi = [
        ['AA:BB:CC:00:00:01', -58, 5180, 70000, 'known'],
      ];
      clock = clock.add(const Duration(seconds: 32));
      await engine.pollNow();
      expect(engine.status.wifiVisible, 0);
      expect(engine.lastRadioEstimate.best, isNull);
      await engine.dispose();
    },
  );
}
