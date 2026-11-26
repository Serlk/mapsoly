import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/positioning/models.dart';
import 'package:mapsoly/positioning/sources/dbus_decode.dart';

DBusValue v(DBusValue x) => DBusVariant(x);

void main() {
  group('NetworkManager AccessPoint', () {
    // Captured on the Titan 2 (2026-11-26, as user serlk):
    // gdbus ... GetAll org.freedesktop.NetworkManager.AccessPoint
    // {'Flags': <uint32 1>, 'WpaFlags': <uint32 0>, 'RsnFlags': <uint32 392>,
    //  'Ssid': <[byte 0x53, ...]>, 'Frequency': <uint32 5180>,
    //  'HwAddress': <'AA:BB:CC:6B:1F:94'>, 'Mode': <uint32 2>,
    //  'MaxBitrate': <uint32 405000>, 'Bandwidth': <uint32 40>,
    //  'Strength': <byte 0x55>, 'LastSeen': <10>}
    // getAllProperties() already unwraps the variants.
    Map<String, DBusValue> captured({int lastSeen = 10}) => {
      'Flags': const DBusUint32(1),
      'WpaFlags': const DBusUint32(0),
      'RsnFlags': const DBusUint32(392),
      'Ssid': DBusArray.byte('ExampleNet'.codeUnits),
      'Frequency': const DBusUint32(5180),
      'HwAddress': const DBusString('AA:BB:CC:6B:1F:94'),
      'Mode': const DBusUint32(2),
      'MaxBitrate': const DBusUint32(405000),
      'Bandwidth': const DBusUint32(40),
      'Strength': const DBusByte(0x55),
      'LastSeen': DBusInt32(lastSeen),
    };

    test('decodes the captured dictionary', () {
      final o = decodeNmAccessPoint(captured(), boottimeSeconds: 1039.1)!;
      expect(o.bssid, 'aa:bb:cc:6b:1f:94');
      expect(o.frequencyMhz, 5180);
      expect(o.signalPercent, 85);
      expect(o.signalDbm, isNull);
      expect(o.effectiveDbm, closeTo(-49, 1e-9));
      expect(o.ssid, 'ExampleNet');
      // LastSeen is CLOCK_BOOTTIME seconds: 1039.1 - 10.
      expect(o.age.inMilliseconds, 1029100);
    });

    test('LastSeen -1 (never) and missing fields are dropped', () {
      expect(
        decodeNmAccessPoint(captured(lastSeen: -1), boottimeSeconds: 100),
        isNull,
      );
      expect(
        decodeNmAccessPoint({
          'Strength': const DBusByte(50),
        }, boottimeSeconds: 100),
        isNull,
      );
      // Clock skew must not produce a negative age.
      final o = decodeNmAccessPoint(
        captured(lastSeen: 1062),
        boottimeSeconds: 1061.9,
      )!;
      expect(o.age, Duration.zero);
    });

    test('variant-wrapped values are accepted too', () {
      final wrapped = captured().map((k, x) => MapEntry(k, v(x)));
      final o = decodeNmAccessPoint(wrapped, boottimeSeconds: 12)!;
      expect(o.bssid, 'aa:bb:cc:6b:1f:94');
      expect(o.age.inSeconds, 2);
    });
  });

  group('wpa_supplicant BSS', () {
    // Captured on the Titan 2 as root (serlk is denied by the bus policy):
    // {'SSID': <[byte 0x53, ...]>, 'BSSID': <[byte 0xaa, 0xbb, 0xcc, 0x6b,
    //  0x1f, 0x94]>, 'Privacy': <true>, 'Mode': <'infrastructure'>,
    //  'Signal': <int16 -35>, 'Frequency': <uint16 5180>, 'Rates': <[uint32
    //  54000000, ...]>, ..., 'Age': <uint32 1035>, 'ANQP': <@a{sv} {}>}
    final captured = <String, DBusValue>{
      'SSID': DBusArray.byte('ExampleNet'.codeUnits),
      'BSSID': DBusArray.byte([0xaa, 0xbb, 0xcc, 0x6b, 0x1f, 0x94]),
      'Privacy': const DBusBoolean(true),
      'Mode': const DBusString('infrastructure'),
      'Signal': const DBusInt16(-35),
      'Frequency': const DBusUint16(5180),
      'Rates': DBusArray.uint32([54000000, 48000000]),
      'Age': const DBusUint32(1035),
      'ANQP': DBusDict.stringVariant(const {}),
    };

    test('decodes the captured dictionary', () {
      final o = decodeWpaBss(captured)!;
      expect(o.bssid, 'aa:bb:cc:6b:1f:94');
      expect(o.signalDbm, -35);
      expect(o.signalPercent, isNull);
      expect(o.effectiveDbm, -35);
      expect(o.frequencyMhz, 5180);
      expect(o.age, const Duration(seconds: 1035));
    });

    test('a level of 0 is "unknown", not a measurement', () {
      final o = decodeWpaBss({...captured, 'Signal': const DBusInt16(0)})!;
      expect(o.signalDbm, isNull);
      expect(o.effectiveDbm, isNull);
    });

    test('malformed BSSID is rejected', () {
      expect(
        decodeWpaBss({
          ...captured,
          'BSSID': DBusArray.byte([1, 2, 3]),
        }),
        isNull,
      );
      expect(decodeWpaBss({'Signal': const DBusInt16(-40)}), isNull);
    });
  });

  group('ModemManager Location', () {
    // Captured on the Titan 2 as root:
    // GetLocation -> ({uint32 1: <'250,20,0,1A2B3C4,1F40'>},)   modem 0
    //                ({uint32 1: <'250,02,0,2B3C4D5,2A2B'>},)   modem 1
    // Modem.AccessTechnologies = uint32 16384 (LTE).
    test('decodes both captured modems', () {
      final a = decodeMmLocation(
        {1: const DBusString('250,20,0,1A2B3C4,1F40')},
        accessTechnologies: 16384,
        modem: 0,
      )!;
      expect(a.radio, RadioType.lte);
      expect(a.mcc, 250);
      expect(a.mnc, 20);
      expect(a.area, 0x1F40);
      expect(a.cellId, 0x1A2B3C4);
      expect(a.serving, isTrue);
      expect(a.modem, 0);
      expect(a.key, 'lte:250:20:8000:27440068');
      // Nothing measured: stays null, never 0.
      expect(a.signalDbm, isNull);
      expect(a.timingAdvance, isNull);
      expect(a.pci, isNull);

      final b = decodeMmLocation({
        1: v(const DBusString('250,02,0,2B3C4D5,2A2B')),
      }, accessTechnologies: 16384)!;
      expect(b.mnc, 2);
      expect(b.key, 'lte:250:2:10795:45335765');
    });

    test('radio type falls back to the id layout when unknown', () {
      final lte = decodeMmLocation({
        1: const DBusString('250,20,0,1A2B3C4,1F40'),
      })!;
      expect(lte.radio, RadioType.lte);
      final gsm = decodeMmLocation({
        1: const DBusString('250,01,1F40,2B67,0'),
      })!;
      expect(gsm.radio, RadioType.gsm);
      expect(gsm.area, 0x1F40);
      expect(gsm.cellId, 0x2B67);
      final umts = decodeMmLocation({
        1: const DBusString('250,01,1F40,A2B67C1,0'),
      }, accessTechnologies: 1 << 5)!;
      expect(umts.radio, RadioType.umts);
    });

    test('empty / unregistered / unrelated sources give null', () {
      // What serlk gets today: the property is an empty dictionary.
      expect(decodeMmLocation({}), isNull);
      expect(decodeMmLocation({1: const DBusString('250,20,0,0,0')}), isNull);
      expect(decodeMmLocation({1: const DBusString(',,,,')}), isNull);
      expect(decodeMmLocation({2: const DBusString('nmea')}), isNull);
    });

    test('access technology bitmask', () {
      expect(radioFromAccessTechnologies(16384), RadioType.lte);
      expect(radioFromAccessTechnologies(1 << 15), RadioType.nr);
      // NSA: registered on the LTE anchor.
      expect(radioFromAccessTechnologies((1 << 14) | (1 << 15)), RadioType.lte);
      expect(radioFromAccessTechnologies(1 << 9), RadioType.umts);
      expect(radioFromAccessTechnologies(1 << 4), RadioType.gsm);
      expect(radioFromAccessTechnologies(0), RadioType.unknown);
      expect(radioFromAccessTechnologies(null), RadioType.unknown);
    });
  });

  group('ModemManager GetCellInfo (documented API, not yet on the phone)', () {
    test('LTE serving cell with levels and timing advance', () {
      final c = decodeMmCellInfo({
        'cell-type': const DBusUint32(5),
        'serving': const DBusBoolean(true),
        'operator-id': const DBusString('25020'),
        'tac': const DBusString('1F40'),
        'ci': const DBusString('1A2B3C4'),
        'physical-ci': const DBusString('12D'),
        'earfcn': const DBusUint32(1300),
        'rsrp': const DBusDouble(-97.0),
        'rsrq': const DBusDouble(-11.5),
        'timing-advance': const DBusUint32(7),
        'bandwidth': const DBusUint32(20),
      }, modem: 0)!;
      expect(c.radio, RadioType.lte);
      expect(c.serving, isTrue);
      expect(c.key, 'lte:250:20:8000:27440068');
      expect(c.pci, 0x12D);
      expect(c.arfcn, 1300);
      expect(c.signalDbm, -97.0);
      expect(c.rsrq, -11.5);
      expect(c.timingAdvance, 7);
      expect(
        timingAdvanceMeters(c.radio, c.timingAdvance),
        closeTo(546.84, 0.01),
      );
    });

    test('LTE neighbour: only PCI, EARFCN and level; the rest stays null', () {
      final c = decodeMmCellInfo({
        'cell-type': const DBusUint32(5),
        'serving': const DBusBoolean(false),
        'physical-ci': const DBusString('1A'),
        'earfcn': const DBusUint32(3048),
        'rsrp': const DBusDouble(-108.0),
      })!;
      expect(c.serving, isFalse);
      expect(c.pci, 26);
      expect(c.arfcn, 3048);
      expect(c.mcc, isNull);
      expect(c.mnc, isNull);
      expect(c.area, isNull);
      expect(c.cellId, isNull);
      expect(c.timingAdvance, isNull);
      expect(c.rsrq, isNull);
      expect(c.hasFullId, isFalse);
      expect(c.key, isNull);
    });

    test('NR, UMTS and GSM field names', () {
      final nr = decodeMmCellInfo({
        'cell-type': const DBusUint32(6),
        'serving': const DBusBoolean(true),
        'operator-id': const DBusString('25001'),
        'tac': const DBusString('1F40'),
        'ci': const DBusString('1A2B3C4D5'),
        'physical-ci': const DBusString('2F'),
        'nrarfcn': const DBusUint32(431070),
        'rsrp': const DBusDouble(-88.0),
        'sinr': const DBusDouble(14.0),
      })!;
      expect(nr.radio, RadioType.nr);
      expect(nr.cellId, 0x1A2B3C4D5); // 36-bit NCI
      expect(nr.arfcn, 431070);

      final umts = decodeMmCellInfo({
        'cell-type': const DBusUint32(3),
        'operator-id': const DBusString('25002'),
        'lac': const DBusString('2A2B'),
        'ci': const DBusString('A2B67C1'),
        'psc': const DBusString('1F'),
        'uarfcn': const DBusUint32(10713),
        'rscp': const DBusDouble(-85.0),
        'ecio': const DBusDouble(-7.0),
      })!;
      expect(umts.radio, RadioType.umts);
      expect(umts.area, 0x2A2B);
      expect(umts.pci, 31);
      expect(umts.signalDbm, -85.0);
      expect(umts.rsrq, -7.0);
      expect(umts.serving, isFalse); // key absent -> not serving

      final gsm = decodeMmCellInfo({
        'cell-type': const DBusUint32(2),
        'serving': const DBusBoolean(true),
        'operator-id': const DBusString('310260'),
        'lac': const DBusString('1F40'),
        'ci': const DBusString('2B67'),
        'base-station-id': const DBusString('2A'),
        'arfcn': const DBusUint32(62),
        'rx-level': const DBusUint32(30),
        'timing-advance': const DBusUint32(3),
      })!;
      expect(gsm.mcc, 310);
      expect(gsm.mnc, 260);
      expect(gsm.signalDbm, -80.0); // RXLEV 30 -> -110 + 30
      expect(gsm.pci, 0x2A);
      expect(
        timingAdvanceMeters(gsm.radio, gsm.timingAdvance),
        closeTo(1660.38, 0.01),
      );
    });

    test('integer-typed identifiers are accepted; unknown types skipped', () {
      final c = decodeMmCellInfo({
        'cell-type': const DBusUint32(5),
        'operator-id': const DBusString('25020'),
        'tac': const DBusUint32(8000),
        'ci': const DBusUint32(27440068),
      })!;
      expect(c.key, 'lte:250:20:8000:27440068');
      expect(decodeMmCellInfo({'cell-type': const DBusUint32(0)}), isNull);
      expect(decodeMmCellInfo({'cell-type': const DBusUint32(1)}), isNull);
      expect(decodeMmCellInfo({}), isNull);
    });

    test('operator id parsing', () {
      expect(parseOperatorId('25020'), (250, 20));
      expect(parseOperatorId('310260'), (310, 260));
      expect(parseOperatorId('2502'), isNull);
      expect(parseOperatorId(null), isNull);
    });
  });

  test('normalizeMac', () {
    expect(normalizeMac('AA:BB:CC:6B:1F:94'), 'aa:bb:cc:6b:1f:94');
    expect(normalizeMac('0:21:52:cd:25:56'), '00:21:52:cd:25:56');
    expect(normalizeMac('AA-BB-CC-6B-1F-94'), 'aa:bb:cc:6b:1f:94');
    expect(normalizeMac('aabbcc6b1f94'), 'aa:bb:cc:6b:1f:94');
    expect(normalizeMac('aa:bb:cc:6b:1f'), isNull);
    expect(normalizeMac('zz:d7:f6:6b:1f:94'), isNull);
    expect(normalizeMac('310260_1234_5678'), isNull);
    expect(
      macFromBytes([0xaa, 0xbb, 0xcc, 0x6b, 0x1f, 0x94]),
      'aa:bb:cc:6b:1f:94',
    );
  });
}
