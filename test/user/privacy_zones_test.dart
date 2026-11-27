import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/positioning/geo.dart';
import 'package:mapsoly/user/privacy_zones.dart';

const palaceSquare = LatLng(59.9390, 30.3158);
const redSquare = LatLng(55.7539, 37.6208);

/// [distanceM] metres from [from] on course [courseDeg].
LatLng offset(LatLng from, double courseDeg, double distanceM) {
  final (lat, lon) = destination(
    from.latitude,
    from.longitude,
    courseDeg,
    distanceM,
  );
  return LatLng(lat, lon);
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('mapsoly-user-'));
  tearDown(() => dir.deleteSync(recursive: true));

  File file() => File('${dir.path}/privacy_zones.json');

  test('contains: great-circle distance against the radius', () {
    final zones = PrivacyZones.inMemory();
    expect(zones.contains(palaceSquare), isFalse);
    zones.add(PrivacyZone(name: 'A', center: palaceSquare, radiusM: 300));
    for (final course in [0.0, 90.0, 180.0, 270.0, 45.0]) {
      expect(zones.contains(offset(palaceSquare, course, 295)), isTrue);
      expect(zones.contains(offset(palaceSquare, course, 305)), isFalse);
    }
    expect(zones.contains(palaceSquare), isTrue);
    expect(zones.contains(redSquare), isFalse);
    expect(zones.zoneAt(palaceSquare)!.name, 'A');
    expect(zones.zoneAt(redSquare), isNull);
  });

  test('intersects: the accuracy circle only has to touch the zone', () {
    final zones = PrivacyZones.inMemory()
      ..add(PrivacyZone(name: 'A', center: palaceSquare, radiusM: 300))
      ..add(PrivacyZone(name: 'B', center: redSquare, radiusM: 100));
    final near = offset(palaceSquare, 90, 500);
    expect(zones.contains(near), isFalse);
    expect(zones.intersects(near, 150), isFalse);
    expect(zones.intersects(near, 210), isTrue);
    expect(zones.intersects(offset(redSquare, 10, 1000), 950), isTrue);
    expect(zones.intersects(offset(redSquare, 10, 1000), 850), isFalse);
    // An unknown accuracy is "could be anywhere".
    expect(zones.intersects(const LatLng(0, 0), double.infinity), isTrue);
    expect(zones.intersects(const LatLng(0, 0), double.nan), isTrue);
    expect(zones.intersects(const LatLng(0, 0), -1), isTrue);
    expect(zones.intersects(const LatLng(double.nan, 0), 0), isTrue);
    expect(PrivacyZones.inMemory().intersects(near, double.infinity), isFalse);
  });

  test('zones across the antimeridian and at a pole', () {
    final zones = PrivacyZones.inMemory()
      ..add(
        PrivacyZone(
          name: 'Date line',
          center: const LatLng(0, 179.999),
          radiusM: 500,
        ),
      )
      ..add(
        PrivacyZone(name: 'Pole', center: const LatLng(90, 0), radiusM: 1000),
      );
    expect(zones.contains(const LatLng(0, -179.999)), isTrue); // 222 m away
    expect(zones.contains(const LatLng(0, -179.99)), isFalse);
    expect(zones.contains(const LatLng(89.995, 135)), isTrue); // 556 m
    expect(zones.contains(const LatLng(89.98, -60)), isFalse);
  });

  test('a handful of zones is checked fast', () {
    final zones = PrivacyZones.inMemory();
    for (var i = 0; i < 8; i++) {
      zones.add(
        PrivacyZone(
          name: 'Z$i',
          center: offset(palaceSquare, i * 45, 2000.0 * (i + 1)),
          radiusM: 300,
        ),
      );
    }
    final watch = Stopwatch()..start();
    var hits = 0;
    for (var i = 0; i < 100000; i++) {
      if (zones.contains(offset(palaceSquare, i % 360, i % 20000))) hits++;
    }
    watch.stop();
    expect(hits, greaterThan(0));
    // 100 000 checks: far below a second even on a slow phone.
    expect(watch.elapsedMilliseconds, lessThan(2000));
  });

  test('add, update, remove persist and notify', () {
    final zones = PrivacyZones.load(dir);
    var notified = 0;
    zones.addListener(() => notified++);
    final home = zones.add(
      PrivacyZone(name: ' Дом ', center: palaceSquare, radiusM: 250),
    );
    expect(home.name, 'Дом');
    expect(() => zones.add(home), throwsStateError);
    expect(zones.update(home.copyWith(radiusM: 400, name: '')), isTrue);
    expect(zones.zones.single.radiusM, 400);
    expect(zones.zones.single.name, 'Зона');
    expect(
      zones.update(PrivacyZone(name: 'x', center: redSquare, radiusM: 9)),
      isFalse,
    );
    expect(notified, 2);

    final again = PrivacyZones.load(dir);
    expect(again.zones, zones.zones);
    expect(again.unconfirmed, isFalse);
    expect(again.contains(offset(palaceSquare, 0, 390)), isTrue);

    expect(zones.remove(home.id), isTrue);
    expect(zones.remove(home.id), isFalse);
    expect(zones.contains(palaceSquare), isFalse);
    expect(PrivacyZones.load(dir).zones, isEmpty);
  });

  test('radius is clamped, nonsense refused', () {
    final zones = PrivacyZones.inMemory();
    expect(
      zones
          .add(PrivacyZone(name: 'tiny', center: redSquare, radiusM: 1))
          .radiusM,
      PrivacyZone.minRadiusM,
    );
    expect(
      zones
          .add(PrivacyZone(name: 'huge', center: redSquare, radiusM: 1e9))
          .radiusM,
      PrivacyZone.maxRadiusM,
    );
    for (final bad in [0.0, -5.0, double.nan, double.infinity]) {
      expect(
        () =>
            zones.add(PrivacyZone(name: 'x', center: redSquare, radiusM: bad)),
        throwsArgumentError,
      );
    }
    expect(
      () => zones.add(
        PrivacyZone(name: 'x', center: const LatLng(95, 0), radiusM: 100),
      ),
      throwsArgumentError,
    );
    expect(zones.zones, hasLength(2));
  });

  test('PrivacyZone.around hides the point off-centre', () {
    final rnd = math.Random(1);
    for (var i = 0; i < 200; i++) {
      final z = PrivacyZone.around(
        palaceSquare,
        name: 'Дом',
        radiusM: 300,
        random: rnd,
      );
      final d = haversineM(
        z.center.latitude,
        z.center.longitude,
        palaceSquare.latitude,
        palaceSquare.longitude,
      );
      expect(d, lessThanOrEqualTo(0.4 * 300 + 0.5));
      expect(z.touches(palaceSquare), isTrue);
    }
    final a = PrivacyZone.around(palaceSquare, name: 'a');
    final b = PrivacyZone.around(palaceSquare, name: 'b');
    expect(a.center, isNot(b.center));
    expect(a.radiusM, PrivacyZone.defaultRadiusM);
  });

  group('damaged file fails closed', () {
    test('missing file is simply "no zones"', () {
      final zones = PrivacyZones.load(dir);
      expect(zones.unconfirmed, isFalse);
      expect(zones.contains(palaceSquare), isFalse);
      expect(file().existsSync(), isFalse);
    });

    test('unreadable file: everything is private until confirmed', () {
      file().writeAsStringSync('{"zones": [{"id": "a", "cen');
      var zones = PrivacyZones.load(dir);
      expect(zones.zones, isEmpty);
      expect(zones.unconfirmed, isTrue);
      expect(zones.loadError, isNotNull);
      expect(zones.contains(redSquare), isTrue);
      expect(zones.intersects(const LatLng(-33.8568, 151.2153), 0), isTrue);
      expect(File('${file().path}.bak').existsSync(), isTrue);

      // Still so after a restart...
      zones = PrivacyZones.load(dir);
      expect(zones.unconfirmed, isTrue);
      // ...and after the list was edited without confirming it.
      zones.add(PrivacyZone(name: 'Дом', center: palaceSquare, radiusM: 300));
      zones = PrivacyZones.load(dir);
      expect(zones.zones, hasLength(1));
      expect(zones.unconfirmed, isTrue);
      expect(zones.loadError, isNotNull);
      expect(zones.contains(redSquare), isTrue);

      var notified = 0;
      zones.addListener(() => notified++);
      zones.confirmZones();
      expect(notified, 1);
      expect(zones.unconfirmed, isFalse);
      expect(zones.loadError, isNull);
      expect(zones.contains(redSquare), isFalse);
      expect(zones.contains(palaceSquare), isTrue);
      zones = PrivacyZones.load(dir);
      expect(zones.unconfirmed, isFalse);
      expect(zones.contains(redSquare), isFalse);
      expect(zones.contains(palaceSquare), isTrue);
    });

    test('a zone that cannot be read counts as damage too', () {
      file().writeAsStringSync(
        '{"version":1,"zones":['
        '{"id":"a","name":"Дом","center":[59.939,30.3158],"radiusM":300},'
        '{"id":"b","name":"Дача","center":[59.9,30.3],"radiusM":"big"}]}',
      );
      final zones = PrivacyZones.load(dir);
      expect(zones.zones.single.id, 'a');
      expect(zones.skippedOnLoad, 1);
      expect(zones.unconfirmed, isTrue);
      expect(zones.contains(redSquare), isTrue);
    });
  });
}
