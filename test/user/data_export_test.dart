import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/positioning/positioning.dart';
import 'package:mapsoly/user/data_export.dart';
import 'package:mapsoly/user/privacy_guard.dart';
import 'package:mapsoly/user/privacy_zones.dart';

import 'fakes.dart';

const wifi = TransmitterKind.wifi;
const ble = TransmitterKind.ble;
const cellKind = TransmitterKind.cell;

void main() {
  late Directory dir;
  late LocationDb db;
  late PrivacyZones zones;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mapsoly-export-');
    db = LocationDb.inMemory();
    zones = PrivacyZones.inMemory();
  });
  tearDown(() {
    db.close();
    dir.deleteSync(recursive: true);
  });

  File out([String name = 'wardriving.csv']) => File('${dir.path}/out/$name');

  Future<LocationDb> reimport(File file) async {
    final fresh = LocationDb.inMemory();
    addTearDown(fresh.close);
    await importWigleCsv(fresh, csvLines(file));
    return fresh;
  }

  group('exportWardriving', () {
    final lteKey = cellKey(RadioType.lte, 999, 7, 4242, 1234567);
    final nrKey = cellKey(RadioType.nr, 999, 123, 77, 9876543210);
    final gsmKey = cellKey(RadioType.gsm, 999, 7, 4242, 4001);

    /// Home is the origin. Own data in and around it, plus foreign data.
    void fill() {
      db.addSamples([
        // Learnt at home, before any zone existed.
        sample(wifi, mac(1), at(10, 10), signalDbm: -45),
        sample(ble, mac(0x51), at(-20, 5)),
        sample(cellKind, gsmKey, at(30, -30)),
        // Learnt on the road.
        sample(wifi, mac(2), at(1500, 0), signalDbm: -62.4),
        sample(wifi, mac(2), at(1510, 4), signalDbm: -71),
        sample(wifi, mac(3), at(2500, 300)),
        sample(ble, mac(0x52), at(1800, -40), signalDbm: -80),
        sample(cellKind, lteKey, at(3000, 1000), signalDbm: -95),
        sample(cellKind, nrKey, at(-4000, 2500)),
      ]);
      db.upsertExternal([
        // Cached answers of the online services.
        record(wifi, mac(0x10), at(1600, 50)),
        record(wifi, mac(0x11), at(15, -15)),
        record(
          cellKind,
          cellKey(RadioType.lte, 999, 7, 4242, 555),
          at(2000, 2000),
          source: TransmitterSource.beacondb,
          accuracyM: 1500,
        ),
        // Imported files.
        record(wifi, mac(0x20), at(1700, 0), source: TransmitterSource.wigle),
        record(wifi, mac(0x21), at(1750, 0), source: TransmitterSource.csv),
        // Will be refined by own wardriving below.
        record(wifi, mac(0x30), at(2200, 0)),
        record(wifi, mac(0x31), at(2300, 0), source: TransmitterSource.wigle),
      ]);
      db.addSamples([
        sample(wifi, mac(0x30), at(2210, 0)), // started from an Apple answer
        sample(wifi, mac(0x31), at(2310, 0)), // started from the user's import
      ]);
    }

    test(
      'own data only, outside the zones; reads back through the importer',
      () async {
        fill();
        zones.add(PrivacyZone(name: 'Дом', center: origin, radiusM: 300));
        final result = await exportWardriving(db, zones, out());

        expect(result.file!.path, out().path);
        expect(result.exported, 6);
        expect(result.wifi, 3); // mac 2, 3 and the one seeded from an import
        expect(result.ble, 1);
        expect(result.cells, 2);
        expect(result.withheldByZones, 3);
        // 2 Apple + 1 beaconDB + 1 WiGLE + 1 CSV, and the Apple-seeded record.
        expect(result.notOwn, 6);
        expect(File('${out().path}.tmp').existsSync(), isFalse);

        final lines = out().readAsLinesSync();
        expect(lines[0], startsWith('WigleWifi-1.6,appRelease=mapsoly,'));
        expect(
          lines[1],
          'MAC,SSID,AuthMode,FirstSeen,Channel,Frequency,RSSI,CurrentLatitude,'
          'CurrentLongitude,AltitudeMeters,AccuracyMeters,RCOIs,MfgrId,Type',
        );
        expect(lines, hasLength(2 + 6));
        final rows = {
          for (final l in lines.skip(2)) l.split(',').first: l.split(','),
        };
        expect(rows.keys.toSet(), {
          mac(2), mac(3), mac(0x31), mac(0x52), '99907_4242_1234567', //
          '999123_77_9876543210',
        });
        expect(rows[mac(2)]!.last, 'WIFI');
        expect(rows[mac(2)]![3], '2026-11-26 12:00:00');
        expect(rows[mac(2)]![6], '-62');
        expect(rows[mac(0x52)]!.last, 'BLE');
        expect(rows['99907_4242_1234567']!.last, 'LTE');
        expect(rows['999123_77_9876543210']!.last, 'NR');
        // Nothing of the home, nothing foreign, in any form.
        final text = out().readAsStringSync();
        for (final absent in [
          mac(1),
          mac(0x51),
          '4001',
          mac(0x10),
          mac(0x11),
          mac(0x20),
          mac(0x21),
          mac(0x30),
          '_555',
        ]) {
          expect(text, isNot(contains(absent)), reason: absent);
        }

        final fresh = await reimport(out());
        expect(fresh.stats().total, 6);
        for (final original in db.records()) {
          final copy = fresh.get(original.kind, original.id);
          final shouldBeThere =
              original.isOwn &&
              !zones.contains(LatLng(original.lat, original.lon));
          expect(copy != null, shouldBeThere, reason: original.id);
          if (copy == null) continue;
          expect(copy.lat, original.lat);
          expect(copy.lon, original.lon);
          expect(copy.accuracyM, closeTo(original.accuracyM, 0.06));
          expect(copy.bestSignalDbm, original.bestSignalDbm?.roundToDouble());
          expect(copy.source, TransmitterSource.wigle);
        }
        // Cells keep their 300 m+ uncertainty instead of being dropped by the
        // importer's 50 m limit for observation rows.
        expect(
          fresh.get(cellKind, lteKey)!.accuracyM,
          greaterThanOrEqualTo(300),
        );
      },
    );

    test('onlyOwn: false exports every source, still not the zones', () async {
      fill();
      zones.add(PrivacyZone(name: 'Дом', center: origin, radiusM: 300));
      final result = await exportWardriving(db, zones, out(), onlyOwn: false);
      expect(result.notOwn, 0);
      expect(result.withheldByZones, 4); // the three own + Apple's mac 0x11
      expect(result.exported, db.stats().total - 4);
      final fresh = await reimport(out());
      expect(fresh.stats().total, result.exported);
      expect(fresh.get(wifi, mac(0x10)), isNotNull);
      expect(fresh.get(wifi, mac(0x11)), isNull);
      expect(fresh.get(wifi, mac(1)), isNull);
      for (final r in fresh.records()) {
        expect(zones.contains(LatLng(r.lat, r.lon)), isFalse);
      }
    });

    test(
      'd. data recorded before a zone existed is withheld afterwards',
      () async {
        fill();
        var result = await exportWardriving(db, zones, out('before.csv'));
        expect(result.withheldByZones, 0);
        expect(result.exported, 9);
        expect(out('before.csv').readAsStringSync(), contains(mac(1)));

        zones.add(PrivacyZone(name: 'Дом', center: origin, radiusM: 300));
        result = await exportWardriving(db, zones, out('after.csv'));
        expect(result.withheldByZones, 3);
        expect(result.exported, 6);
        expect(out('after.csv').readAsStringSync(), isNot(contains(mac(1))));
        // The database itself was not touched by the export...
        expect(db.get(wifi, mac(1)), isNotNull);
        // ...until the user asks: own records only, counted first.
        expect(purgeWardrivingInside(db, zones, dryRun: true), 3);
        expect(db.get(wifi, mac(1)), isNotNull);
        expect(purgeWardrivingInside(db, zones), 3);
        expect(db.get(wifi, mac(1)), isNull);
        expect(db.get(ble, mac(0x51)), isNull);
        expect(db.get(cellKind, gsmKey), isNull);
        expect(db.get(wifi, mac(0x11)), isNotNull); // Apple's, kept
        expect(db.get(wifi, mac(2)), isNotNull);
        expect(purgeWardrivingInside(db, zones), 0);
        expect(purgeWardrivingInside(db, zones, allSources: true), 1);
        expect(db.get(wifi, mac(0x11)), isNull);
      },
    );

    test('overlapping zones count a record once', () {
      fill();
      zones
        ..add(PrivacyZone(name: 'A', center: origin, radiusM: 300))
        ..add(PrivacyZone(name: 'B', center: at(50, 0), radiusM: 300));
      expect(purgeWardrivingInside(db, zones, dryRun: true), 3);
    });

    test('nothing to export: no file', () async {
      db.upsertExternal([record(wifi, mac(0x10), at(1600, 50))]);
      db.addSamples([sample(wifi, mac(1), at(10, 10))]);
      zones.add(PrivacyZone(name: 'Дом', center: origin, radiusM: 300));
      final result = await exportWardriving(db, zones, out());
      expect(result.file, isNull);
      expect(result.exported, 0);
      expect(result.withheldByZones, 1);
      expect(result.notOwn, 1);
      expect(out().existsSync(), isFalse);
      expect(out().parent.listSync(), isEmpty);
    });

    test('an unconfirmed zone list withholds everything', () async {
      File('${dir.path}/privacy_zones.json').writeAsStringSync('oops');
      zones = PrivacyZones.load(dir);
      fill();
      final result = await exportWardriving(db, zones, out());
      expect(result.exported, 0);
      expect(result.withheldByZones, 9);
      expect(out().existsSync(), isFalse);
    });

    test('many records: paged reading, every row survives', () async {
      db.addSamples([
        for (var i = 0; i < 5000; i++)
          sample(
            wifi,
            'aa:bb:cc:${(i >> 16).toRadixString(16).padLeft(2, '0')}:'
            '${((i >> 8) & 255).toRadixString(16).padLeft(2, '0')}:'
            '${(i & 255).toRadixString(16).padLeft(2, '0')}',
            at(1000.0 + i, (i % 50) * 10.0),
          ),
      ]);
      zones.add(PrivacyZone(name: 'Дом', center: at(3000, 250), radiusM: 100));
      final result = await exportWardriving(db, zones, out());
      expect(result.exported + result.withheldByZones, 5000);
      expect(result.withheldByZones, inInclusiveRange(1, 500));
      final lines = out().readAsLinesSync();
      expect(lines, hasLength(2 + result.exported));
      expect(lines.where((l) => l.isEmpty), isEmpty);
      final fresh = await reimport(out());
      expect(fresh.stats().wifi, result.exported);
    });

    test(
      'an unwritable target fails loudly and leaves nothing behind',
      () async {
        fill();
        final blocker = File('${dir.path}/blocker')..writeAsStringSync('x');
        await expectLater(
          exportWardriving(db, zones, File('${blocker.path}/x.csv')),
          throwsA(isA<FileSystemException>()),
        );
        expect(blocker.readAsStringSync(), 'x');
      },
    );
  });

  group('trip logs', () {
    const header =
        'time,speed_kmh,rpm,coolant_c,fuel_lph,fuel_level_pct,'
        'battery_v,trip_km,trip_fuel_l,lat,lon';

    Directory logs() => Directory('${dir.path}/trips');

    /// A log like `ObdSession` writes: one row a second, driving east from
    /// [startEast] metres at 20 m/s.
    File writeLog(
      String name,
      DateTime start,
      int seconds, {
      double startEast = 0,
      bool coordinates = true,
    }) {
      final b = StringBuffer()..writeln(header);
      for (var s = 0; s < seconds; s++) {
        final p = at(startEast + 20.0 * s, 0);
        b.writeln(
          [
            start.add(Duration(seconds: s)).toIso8601String(),
            '72',
            '2100',
            '90',
            '6.40',
            '55.0',
            '14.1',
            (0.02 * s).toStringAsFixed(3),
            (0.0018 * s).toStringAsFixed(3),
            if (coordinates) ...[
              p.latitude.toStringAsFixed(6),
              p.longitude.toStringAsFixed(6),
            ] else ...[
              '',
              '',
            ],
          ].join(','),
        );
      }
      logs().createSync(recursive: true);
      return File('${logs().path}/$name')..writeAsStringSync('$b');
    }

    test('listing: start, duration, distance, size; newest first', () {
      expect(listTripLogs(logs()), isEmpty); // no directory yet
      final short = writeLog(
        'trip-20261120T081500.csv',
        DateTime(2026, 11, 20, 8, 15),
        61,
      );
      // Long enough that only its two ends are read.
      final long = writeLog(
        'trip-20261125T180000.csv',
        DateTime(2026, 11, 25, 18),
        3600,
      );
      final headerOnly = File('${logs().path}/trip-20261126T070000.csv')
        ..writeAsStringSync('$header\n');
      final empty = File('${logs().path}/trip-20261101T000000.csv')
        ..writeAsStringSync('');
      File('${logs().path}/notes.txt').writeAsStringSync('x');
      File('${logs().path}/other.csv').writeAsStringSync('a,b\n1,2\n');
      Directory('${logs().path}/trip-dir.csv').createSync();

      final list = listTripLogs(logs());
      expect(list.map((t) => t.name), [
        'trip-20261126T070000.csv',
        'trip-20261125T180000.csv',
        'trip-20261120T081500.csv',
        'trip-20261101T000000.csv',
      ]);
      final a = list[2];
      expect(a.file.path, short.path);
      expect(a.start, DateTime(2026, 11, 20, 8, 15));
      expect(a.duration, const Duration(seconds: 60));
      expect(a.distanceKm, closeTo(1.2, 1e-9));
      expect(a.sizeBytes, short.lengthSync());

      final b = list[1];
      expect(long.lengthSync(), greaterThan(100000));
      expect(b.start, DateTime(2026, 11, 25, 18));
      expect(b.duration, const Duration(seconds: 3599));
      expect(b.distanceKm, closeTo(71.98, 1e-9));

      // No rows: the start comes from the file name.
      expect(list[0].file.path, headerOnly.path);
      expect(list[0].start, DateTime(2026, 11, 26, 7));
      expect(list[0].duration, isNull);
      expect(list[0].distanceKm, isNull);
      expect(list[3].file.path, empty.path);
      expect(list[3].sizeBytes, 0);
      expect(list[3].start, DateTime(2026, 11, 1));
    });

    test('listing a log that is still being written (torn last line)', () {
      final log = writeLog(
        'trip-20261120T081500.csv',
        DateTime(2026, 11, 20, 8, 15),
        30,
      );
      log.writeAsStringSync(
        '2026-11-20T08:15:30.000,72,21',
        mode: FileMode.append,
      );
      final info = listTripLogs(logs()).single;
      expect(info.duration, const Duration(seconds: 29));
      expect(info.distanceKm, closeTo(0.58, 1e-9));
    });

    test('export blanks the rows inside zones and keeps the rest', () async {
      // 0..1980 m east of the origin; the zone covers the first 310 m.
      final log = writeLog(
        'trip-20261120T081500.csv',
        DateTime(2026, 11, 20, 8, 15),
        100,
      );
      final noGps = writeLog(
        'trip-20261121T081500.csv',
        DateTime(2026, 11, 21, 8, 15),
        10,
        coordinates: false,
      );
      zones.add(PrivacyZone(name: 'Дом', center: origin, radiusM: 310));
      final target = Directory('${dir.path}/share/trips');
      final result = await exportTripLogs([log, noGps], zones, target);

      expect(result.failed, isEmpty);
      expect(result.files.map((f) => f.path), [
        '${target.path}/trip-20261120T081500.csv',
        '${target.path}/trip-20261121T081500.csv',
      ]);
      expect(result.rows, 110);
      expect(result.rowsBlanked, 16); // 0, 20, ... 300 m
      expect(target.listSync(), hasLength(2)); // no temporary files

      final source = log.readAsLinesSync();
      final copy = result.files.first.readAsLinesSync();
      expect(copy, hasLength(source.length));
      expect(copy.first, header);
      for (var i = 1; i < copy.length; i++) {
        final was = source[i].split(','), now = copy[i].split(',');
        expect(now.sublist(0, 9), was.sublist(0, 9)); // vehicle data intact
        if (i <= 16) {
          expect(now.sublist(9), ['', '']);
        } else {
          expect(now.sublist(9), was.sublist(9));
          expect(
            zones.contains(LatLng(double.parse(now[9]), double.parse(now[10]))),
            isFalse,
          );
        }
      }
      expect(result.files.last.readAsLinesSync(), noGps.readAsLinesSync());
      expect(log.readAsLinesSync(), source); // the original is not modified
    });

    test('export does not trust odd rows', () async {
      logs().createSync(recursive: true);
      final home = at(0, 0), away = at(5000, 3000);
      String row(String lat, String lon) =>
          '2026-11-20T08:15:00.000,50,,,,,,0.100,,$lat,$lon';
      final log = File('${logs().path}/trip-20261120T081500.csv')
        ..writeAsStringSync(
          [
            header,
            row('${away.latitude}', '${away.longitude}'),
            row('${home.latitude}', '${home.longitude}'),
            row(
              '59,939',
              '30,3158',
            ), // decimal commas shift the columns: dropped
            row('${home.latitude}', ''), // half a position: blanked
            row('', ''),
            row('north', 'east'), // not numbers: blanked
            // Shifted columns: coordinates could be anywhere, row dropped.
            '2026-11-20T08:15:05.000,50,${home.latitude},${home.longitude}',
            '${row('${home.latitude}', '${home.longitude}')},extra',
            '',
          ].join('\n'),
        );
      zones.add(PrivacyZone(name: 'Дом', center: origin, radiusM: 300));
      final result = await exportTripLogs(
        [log],
        zones,
        Directory('${dir.path}/share'),
      );
      expect(result.rows, 5);
      expect(result.rowsBlanked, 3);
      final copy = result.files.single.readAsStringSync();
      expect(copy, isNot(contains('${home.latitude}')));
      expect(copy, isNot(contains('59,939')));
      expect(copy, isNot(contains('north')));
      expect(copy, contains('${away.latitude},${away.longitude}'));
    });

    test('export refuses what it cannot check', () async {
      logs().createSync(recursive: true);
      final other = File('${logs().path}/other.csv')
        ..writeAsStringSync('when,where\nnow,59.9390 30.3158\n');
      final empty = File('${logs().path}/trip-empty.csv')
        ..writeAsStringSync('');
      final gone = File('${logs().path}/trip-gone.csv');
      final good = writeLog('trip-20261120T081500.csv', DateTime(2026), 3);
      final target = Directory('${dir.path}/share');
      var result = await exportTripLogs(
        [other, empty, gone, good],
        zones,
        target,
      );
      expect(result.failed.keys, [
        'other.csv',
        'trip-empty.csv',
        'trip-gone.csv',
      ]);
      expect(result.failed['other.csv'], 'Это не журнал поездки');
      expect(result.failed['trip-gone.csv'], 'Файл не удалось скопировать');
      expect(
        result.files.single.path,
        '${target.path}/trip-20261120T081500.csv',
      );
      expect(target.listSync(), hasLength(1));

      // Exporting into the log directory itself would overwrite the log.
      final before = good.readAsStringSync();
      result = await exportTripLogs([good], zones, logs());
      expect(result.files, isEmpty);
      expect(result.failed.values.single, contains('совпадает'));
      expect(good.readAsStringSync(), before);
    });

    test('an unconfirmed zone list blanks every coordinate', () async {
      File('${dir.path}/privacy_zones.json').writeAsStringSync('oops');
      zones = PrivacyZones.load(dir);
      final log = writeLog('trip-20261120T081500.csv', DateTime(2026), 20);
      final result = await exportTripLogs(
        [log],
        zones,
        Directory('${dir.path}/share'),
      );
      expect(result.rows, 20);
      expect(result.rowsBlanked, 20);
    });

    test('delete', () {
      final log = writeLog('trip-20261120T081500.csv', DateTime(2026), 3);
      expect(deleteTripLog(log), isTrue);
      expect(log.existsSync(), isFalse);
      expect(deleteTripLog(log), isFalse);
      expect(listTripLogs(logs()), isEmpty);
    });
  });
}
