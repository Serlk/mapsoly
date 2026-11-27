import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/positioning/positioning.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mapsoly-journal'));
  tearDown(() => dir.deleteSync(recursive: true));

  final at = DateTime.utc(2026, 11, 27, 12);
  GnssFix fix(int t) => GnssFix(
    valid: true,
    receivedAt: at.add(Duration(seconds: t)),
    lat: 55.75,
    lon: 37.62,
    accuracyM: 3,
    speedMps: 12,
    courseDeg: 90,
  );

  test('kept only when asked for', () {
    final db = '${dir.path}/positioning.sqlite';
    expect(PositionJournal.requested(db), isNull);
    File('${dir.path}/positioning-journal.on').createSync();
    expect(
      PositionJournal.requested(db)!.path,
      '${dir.path}/positioning-journal.csv',
    );
  });

  test('one line per epoch, no coordinates from a private area', () async {
    final journal = PositionJournal('${dir.path}/j.csv');
    final checker = GnssSanityChecker();
    journal.gnss(fix(0), checker.check(fix(0)));
    journal.gnss(fix(1), checker.check(fix(1)), private: true);
    await journal.close();
    final lines = File('${dir.path}/j.csv').readAsLinesSync();
    expect(lines, hasLength(3));
    expect(lines[0], PositionJournal.header);
    expect(lines[1], contains('55.750000,37.620000,3.0,12.0,90'));
    expect(lines[1], contains(',ok,1,'));
    expect(lines[2], isNot(contains('55.75')));
    expect(lines[2], isNot(contains('37.62')));
    expect(lines[2].split(','), hasLength(lines[0].split(',').length));
  });

  test('a full file is put aside and a new one started', () async {
    final journal = PositionJournal('${dir.path}/j.csv', maxBytes: 400);
    final checker = GnssSanityChecker();
    for (var t = 0; t < 20; t++) {
      journal.gnss(fix(t), checker.check(fix(t)));
    }
    await journal.close();
    expect(File('${dir.path}/j.csv.1').existsSync(), isTrue);
    expect(File('${dir.path}/j.csv').lengthSync(), lessThan(1200));
  });
}
