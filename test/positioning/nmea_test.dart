import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/positioning/models.dart';
import 'package:mapsoly/positioning/nmea.dart';

/// Wraps a sentence body with `$` and a computed checksum.
String s(String body) => '\$$body*${nmeaChecksum(body)}';

void main() {
  group('NmeaSentence', () {
    test('accepts classic reference sentences with their checksums', () {
      // Well-known examples from the NMEA 0183 literature.
      const gga =
          r'$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47';
      const rmc =
          r'$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A';
      final a = NmeaSentence.parse(gga)!;
      expect(a.talker, 'GP');
      expect(a.type, 'GGA');
      expect(a.fields.length, 14);
      expect(NmeaSentence.parse(rmc)!.type, 'RMC');
    });

    test('rejects bad checksum, garbage and missing checksum', () {
      expect(
        NmeaSentence.parse(
          r'$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*48',
        ),
        isNull,
      );
      expect(NmeaSentence.parse('hello'), isNull);
      expect(NmeaSentence.parse(r'$GPGGA,123519'), isNull);
      expect(NmeaSentence.parse(r'$GPGGA,1*'), isNull);
      expect(
        NmeaSentence.parse(r'$GPGGA,123519', requireChecksum: false),
        isNotNull,
      );
    });

    test('tolerates leading noise and CRLF', () {
      final line = '\x00\x00${s('GNVTG,84.4,T,,M,22.4,N,41.5,K,A')}\r\n';
      expect(NmeaSentence.parse(line)!.type, 'VTG');
    });
  });

  test('coordinates', () {
    expect(parseNmeaCoordinate('4807.038', 'N'), closeTo(48.1173, 1e-6));
    expect(parseNmeaCoordinate('01131.000', 'E'), closeTo(11.516667, 1e-6));
    expect(parseNmeaCoordinate('3351.000', 'S'), closeTo(-33.85, 1e-9));
    expect(parseNmeaCoordinate('15112.500', 'W'), closeTo(-151.208333, 1e-6));
    expect(parseNmeaCoordinate('', 'N'), isNull);
    expect(parseNmeaCoordinate('4861.000', 'N'), isNull); // 61 minutes
    expect(parseNmeaCoordinate('4807.038', 'X'), isNull);
  });

  group('NmeaParser', () {
    test('single-constellation GGA + RMC epoch', () {
      final p = NmeaParser(now: () => DateTime.utc(2026, 11, 26, 12));
      expect(
        p.addLine(
          r'$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47',
        ),
        isNull,
      );
      final fix = p.addLine(
        r'$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A',
      )!;
      expect(fix.valid, isTrue);
      expect(fix.lat, closeTo(48.1173, 1e-6));
      expect(fix.lon, closeTo(11.516667, 1e-6));
      expect(fix.altitudeM, 545.4);
      expect(fix.speedMps, closeTo(22.4 * 0.514444, 1e-6));
      expect(fix.courseDeg, 84.4);
      expect(fix.hdop, 0.9);
      expect(fix.accuracyM, closeTo(4.5, 1e-9)); // HDOP * 5 m
      expect(fix.satellitesUsed, 8);
      // Two-digit year 94 is mapped into 20xx (GPS receivers post-2000).
      expect(fix.time, DateTime.utc(2094, 3, 23, 12, 35, 19));
      expect(fix.receivedAt, DateTime.utc(2026, 11, 26, 12));
    });

    test('multi-constellation epoch as sent by a MediaTek chip', () {
      // Realistic AG35xx-style output for St. Petersburg: GN position, per
      // constellation GSA (NMEA 4.10 system id) and GSV with signal ids.
      final lines = [
        s(
          'GNGGA,101530.000,5955.2040,N,03039.1560,E,1,14,0.72,23.4,M,16.9,M,,',
        ),
        s('GNGSA,A,3,05,13,15,18,23,29,,,,,,,1.21,0.72,0.97,1'),
        s('GNGSA,A,3,66,67,81,82,,,,,,,,,1.21,0.72,0.97,2'),
        s('GNGSA,A,3,02,11,25,36,,,,,,,,,1.21,0.72,0.97,3'),
        s('GPGSV,3,1,09,05,62,251,44,13,48,075,41,15,25,051,35,18,71,152,46,1'),
        s('GPGSV,3,2,09,23,33,199,39,29,17,298,31,20,09,115,24,26,05,331,,1'),
        s('GPGSV,3,3,09,16,02,020,,1'),
        s('GLGSV,2,1,05,66,45,089,40,67,72,315,43,81,30,220,37,82,55,290,42,1'),
        s('GLGSV,2,2,05,75,08,010,22,1'),
        s('GAGSV,1,1,04,02,41,170,38,11,60,080,42,25,22,310,33,36,35,240,37,7'),
        s(
          'GNRMC,101530.000,A,5955.2040,N,03039.1560,E,31.25,271.40,261126,,,A,V',
        ),
        s('GNVTG,271.40,T,,M,31.25,N,57.88,K,A'),
      ];
      final p = NmeaParser();
      GnssFix? fix;
      for (final l in lines) {
        fix = p.addLine(l) ?? fix;
      }
      expect(p.rejected, 0);
      expect(fix, isNotNull);
      expect(fix!.valid, isTrue);
      expect(fix.lat, closeTo(59.9200667, 1e-6));
      expect(fix.lon, closeTo(30.6526, 1e-6));
      expect(fix.time, DateTime.utc(2026, 11, 26, 10, 15, 30));
      expect(fix.speedMps, closeTo(31.25 * 0.514444, 1e-6));
      expect(fix.courseDeg, 271.4);
      expect(fix.accuracyM, closeTo(3.6, 1e-9));
      expect(fix.satellites.length, 9 + 5 + 4);
      final bySys = <GnssSystem, int>{};
      for (final sat in fix.satellites) {
        bySys[sat.system] = (bySys[sat.system] ?? 0) + 1;
      }
      expect(bySys, {
        GnssSystem.gps: 9,
        GnssSystem.glonass: 5,
        GnssSystem.galileo: 4,
      });
      // GPS PRN 2 is not in view; Galileo E02 is used: systems must not mix.
      final used = fix.satellites.where((x) => x.used).toList();
      expect(used.length, 14);
      expect(
        used.where((x) => x.system == GnssSystem.galileo).map((x) => x.prn),
        containsAll([2, 11, 25, 36]),
      );
      // Untracked satellites keep a null C/N0 (never 0).
      final untracked = fix.satellites.firstWhere(
        (x) => x.system == GnssSystem.gps && x.prn == 26,
      );
      expect(untracked.cn0, isNull);
      expect(untracked.used, isFalse);
      expect(fix.satellites.firstWhere((x) => x.prn == 18).cn0, 46);
      expect(fix.satellites.first.signalId, 1);
    });

    test('VTG after the epoch updates speed of the next emitted fix only', () {
      final p = NmeaParser();
      p.addLine(s('GNRMC,101530.000,A,5955.2040,N,03039.1560,E,,,261126,,,A'));
      p.addLine(s('GNVTG,90.0,T,,M,,N,36.0,K,A'));
      // RMC-only receiver: the epoch is emitted when the next one starts.
      final fix = p.addLine(
        s('GNRMC,101531.000,A,5955.2040,N,03039.1570,E,,,261126,,,A'),
      )!;
      expect(fix.time, DateTime.utc(2026, 11, 26, 10, 15, 30));
      expect(fix.speedMps, closeTo(10.0, 1e-9));
      expect(fix.courseDeg, 90.0);
      expect(p.flush()!.time, DateTime.utc(2026, 11, 26, 10, 15, 31));
    });

    test('no fix: void RMC and quality 0 give an invalid epoch', () {
      final p = NmeaParser();
      p.addLine(s('GNGGA,101530.000,,,,,0,00,99.99,,,,,,'));
      final fix = p.addLine(s('GNRMC,101530.000,V,,,,,,,261126,,,N'))!;
      expect(fix.valid, isFalse);
      expect(fix.hasPosition, isFalse);
      expect(fix.lat, isNull);
      expect(fix.accuracyM, isNull);
      expect(fix.speedMps, isNull);
    });

    test('GST sigma overrides the HDOP guess', () {
      final p = NmeaParser();
      p.addLine(s('GNGST,101530.000,1.2,3.0,2.0,45.0,3.0,4.0,6.0'));
      p.addLine(
        s(
          'GNGGA,101530.000,5955.2040,N,03039.1560,E,1,14,0.72,23.4,M,16.9,M,,',
        ),
      );
      final fix = p.addLine(
        s('GNRMC,101530.000,A,5955.2040,N,03039.1560,E,0.0,,261126,,,A'),
      )!;
      expect(fix.accuracyM, closeTo(5.0, 1e-9));
    });

    test('legacy GN GSA without system id maps PRNs by number', () {
      final p = NmeaParser();
      p.addLine(s('GNGSA,A,3,05,13,,,,,,,,,,,1.2,0.7,0.9'));
      p.addLine(s('GNGSA,A,3,66,67,,,,,,,,,,,1.2,0.7,0.9'));
      p.addLine(s('GPGSV,1,1,02,05,62,251,44,13,48,075,41'));
      p.addLine(s('GLGSV,1,1,02,66,45,089,40,67,72,315,43'));
      p.addLine(
        s(
          'GNGGA,101530.000,5955.2040,N,03039.1560,E,1,04,0.72,23.4,M,16.9,M,,',
        ),
      );
      final fix = p.addLine(
        s('GNRMC,101530.000,A,5955.2040,N,03039.1560,E,0.0,,261126,,,A'),
      )!;
      expect(fix.satellites.length, 4);
      expect(fix.satellites.every((x) => x.used), isTrue);
      expect(fix.satellites.first.signalId, isNull);
    });

    test('corrupted lines are counted and do not break the stream', () {
      final p = NmeaParser();
      p.addLine(r'$GNGGA,101530.000,5955.2040,N,03039.1560,E,1,14*00');
      p.addLine('\$GNRMC,1015');
      expect(p.rejected, 2);
      expect(p.accepted, 0);
      expect(p.flush(), isNull);
    });
  });
}
