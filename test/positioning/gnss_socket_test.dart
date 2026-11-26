import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/positioning/models.dart';
import 'package:mapsoly/positioning/nmea.dart';
import 'package:mapsoly/positioning/sources/nmea_socket_gnss.dart';

String s(String body) => '\$$body*${nmeaChecksum(body)}\r\n';

String epoch(int sec, {double lonMin = 39.1560}) {
  final t = '1015${sec.toString().padLeft(2, '0')}.000';
  final lon = '030${lonMin.toStringAsFixed(4)}';
  return s('GNGGA,$t,5955.2040,N,$lon,E,1,14,0.72,23.4,M,16.9,M,,') +
      s('GPGSV,1,1,03,05,62,251,44,13,48,075,41,15,25,051,35,1') +
      s('GNRMC,$t,A,5955.2040,N,$lon,E,10.00,90.00,261126,,,A,V');
}

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mapsoly_gnss_test');
    path = '${dir.path}/nmea.sock';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<ServerSocket> serve() => ServerSocket.bind(
    InternetAddress(path, type: InternetAddressType.unix),
    0,
  );

  test(
    'waits for the socket, reads fixes, reconnects after a restart',
    () async {
      final source = NmeaSocketGnssSource(
        path: path,
        maxBackoff: const Duration(milliseconds: 200),
      );
      final fixes = <GnssFix>[];
      final sub = source.fixes.listen(fixes.add);

      // Service not running yet: the source must keep quiet and keep trying.
      await source.start();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(source.connected, isFalse);
      expect(source.lastError, contains('does not exist'));

      var server = await serve();
      var client = await server.first.timeout(const Duration(seconds: 5));
      // Split a sentence across two writes to exercise line reassembly.
      final data = epoch(30) + epoch(31, lonMin: 39.1660);
      client.write(data.substring(0, 50));
      await client.flush();
      client.write(data.substring(50));
      await client.flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(source.connected, isTrue);
      expect(source.lastError, isNull);
      expect(fixes.length, 2);
      expect(fixes.first.valid, isTrue);
      expect(fixes.first.lat, closeTo(59.92006667, 1e-6));
      expect(fixes.first.speedMps, closeTo(5.14444, 1e-4));
      expect(fixes.first.satellites.length, 3);
      expect(fixes[1].lon, greaterThan(fixes[0].lon!));

      // Service restarts: old socket file disappears, a new one comes up.
      client.destroy();
      await server.close();
      if (File(path).existsSync()) File(path).deleteSync();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(source.connected, isFalse);

      server = await serve();
      client = await server.first.timeout(const Duration(seconds: 5));
      client.write(epoch(40));
      await client.flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(fixes.length, 3);
      expect(fixes.last.time, DateTime.utc(2026, 11, 26, 10, 15, 40));

      await source.stop();
      expect(source.connected, isFalse);
      client.destroy();
      await server.close();
      await sub.cancel();
      await source.dispose();
    },
  );

  test('a silent connection is dropped and retried', () async {
    final server = await serve();
    var connections = 0;
    final sockets = <Socket>[];
    final sub = server.listen((c) {
      connections++;
      sockets.add(c);
    });
    final source = NmeaSocketGnssSource(
      path: path,
      maxBackoff: const Duration(milliseconds: 100),
      silenceTimeout: const Duration(milliseconds: 150),
    );
    await source.start();
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(connections, greaterThanOrEqualTo(2));
    expect(source.lastError, anyOf(isNull, contains('no data')));
    await source.dispose();
    for (final c in sockets) {
      c.destroy();
    }
    await sub.cancel();
    await server.close();
  });

  test('garbage on the socket does not produce fixes or crash', () async {
    final server = await serve();
    final source = NmeaSocketGnssSource(path: path);
    final fixes = <GnssFix>[];
    final sub = source.fixes.listen(fixes.add);
    await source.start();
    final client = await server.first.timeout(const Duration(seconds: 5));
    client.add([0xff, 0xfe, 0x00, 0x24, 0x47, 0x0a]);
    client.write('\$GNRMC,broken*00\r\nnot nmea at all\r\n');
    client.write(epoch(50));
    await client.flush();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(fixes.length, 1);
    await source.dispose();
    client.destroy();
    await sub.cancel();
    await server.close();
  });
}
