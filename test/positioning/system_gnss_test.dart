import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/positioning/positioning.dart';

void main() {
  test('the reason is put in words; unknown ones are left out', () {
    expect(
      const SystemGnssVerdict('suspect', 'still: 33 m/s').reasonText,
      contains('телефон лежит'),
    );
    expect(
      const SystemGnssVerdict('suspect', 'network: 55 km').reasonText,
      contains('Wi-Fi'),
    );
    expect(const SystemGnssVerdict('suspect', 'turn').reasonText, isNotEmpty);
    expect(const SystemGnssVerdict('suspect', 'novelty').reasonText, isEmpty);
    expect(const SystemGnssVerdict('ok', '').suspect, isFalse);
    expect(const SystemGnssVerdict('off', '').suspect, isFalse);
  });

  test('the notifier passes the system verdict on to the details', () async {
    final db = LocationDb.inMemory();
    final engine = PositioningEngine(db: db);
    final system = StreamController<SystemGnssVerdict>();
    final notifier = PositioningNotifier(engine, system: system.stream);
    var details = 0, map = 0;
    notifier.details.addListener(() => details++);
    notifier.addListener(() => map++);
    expect(notifier.systemGnss, isNull);

    system.add(const SystemGnssVerdict('suspect', 'still: 33 m/s'));
    await Future<void>.delayed(Duration.zero);
    expect(notifier.systemGnss!.suspect, isTrue);
    expect(details, 1);
    // The same again changes nothing; the map is not redrawn for it at all.
    system.add(const SystemGnssVerdict('suspect', 'still: 33 m/s'));
    await Future<void>.delayed(Duration.zero);
    expect(details, 1);
    expect(map, 0);

    system.add(const SystemGnssVerdict('ok', ''));
    await Future<void>.delayed(Duration.zero);
    expect(notifier.systemGnss!.suspect, isFalse);
    expect(details, 2);

    notifier.dispose();
    await system.close();
    await engine.dispose();
  });
}
