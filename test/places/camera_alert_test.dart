import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/places/camera_alert.dart';
import 'package:mapsoly/places/cameras.dart';

RouteCamera _cam(
  int id,
  double alongM, {
  int? limit,
  CameraType type = CameraType.speed,
  double? zoneEnd,
}) => RouteCamera(
  camera: SpeedCamera(
    id: id,
    source: CameraSource.pack,
    type: type,
    rawType: type.code,
    point: const LatLng(0, 0),
    maxSpeedKmh: limit,
  ),
  alongM: alongM,
  lateralM: 5,
  zoneEndAlongM: zoneEnd,
);

/// Drives from [from] to [to] metres at a constant speed, one update per
/// second, and collects all alerts with the position they fired at.
List<(double, CameraAlert)> _drive(
  CameraAlerter a,
  double from,
  double to,
  double speedKmh, {
  Duration start = Duration.zero,
}) {
  final out = <(double, CameraAlert)>[];
  final v = speedKmh / 3.6;
  var t = 0;
  for (var pos = from; pos <= to; pos += v, t++) {
    for (final al in a.update(
      alongM: pos,
      speedKmh: speedKmh,
      time: start + Duration(seconds: t),
    )) {
      out.add((pos, al));
    }
  }
  return out;
}

void main() {
  const cfg = CameraAlertConfig();

  test('warning distance grows with speed within its bounds', () {
    expect(cfg.warnDistanceM(0), 300);
    expect(cfg.warnDistanceM(60), 300); // 250 m of travel → minimum
    expect(cfg.warnDistanceM(90), closeTo(375, 0.1));
    expect(cfg.warnDistanceM(130), closeTo(541.7, 0.1));
    expect(cfg.warnDistanceM(300), 1000);
    expect(cfg.urgentDistanceM(60), 150);
    expect(cfg.urgentDistanceM(120), closeTo(200, 0.1));
  });

  test('one approach warning per camera, then passed', () {
    final a = CameraAlerter([_cam(1, 2000, limit: 60)]);
    final ev = _drive(a, 0, 3000, 50);
    expect(ev.map((e) => e.$2.kind), [
      CameraAlertKind.approaching,
      CameraAlertKind.passed,
    ]);
    final (pos, alert) = ev.first;
    expect(2000 - pos, inInclusiveRange(285, 300));
    expect(alert.distanceM, closeTo(2000 - pos, 0.01));
    expect(alert.overLimit, isFalse);
    expect(
      alert.text,
      'Камера контроля скорости через 300 м, ограничение 60 км/ч',
    );
    expect(ev.last.$1, greaterThan(2030));
    expect(a.warnedKeys, {'pack:1'});
    expect(a.next, isNull);
  });

  test('faster means earlier', () {
    final slow = _drive(CameraAlerter([_cam(1, 3000)]), 0, 3200, 60).first.$1;
    final fast = _drive(CameraAlerter([_cam(1, 3000)]), 0, 3200, 130).first.$1;
    expect(3000 - slow, inInclusiveRange(283, 300));
    expect(3000 - fast, inInclusiveRange(505, 542));
  });

  test('speeding gets a second, urgent reminder once', () {
    final a = CameraAlerter([_cam(1, 2000, limit: 60)]);
    final ev = _drive(a, 0, 2500, 90);
    expect(ev.map((e) => e.$2.kind), [
      CameraAlertKind.approaching,
      CameraAlertKind.speeding,
      CameraAlertKind.passed,
    ]);
    expect(ev[0].$2.overLimit, isTrue);
    expect(2000 - ev[1].$1, inInclusiveRange(125, 150));
    expect(ev[1].$2.text, 'Снизьте скорость: ограничение 60 км/ч');
  });

  test('tolerance suppresses the reminder; no limit, no reminder', () {
    final tolerant = CameraAlerter([
      _cam(1, 2000, limit: 60),
    ], config: const CameraAlertConfig(toleranceKmh: 19));
    expect(
      _drive(tolerant, 0, 2500, 75).map((e) => e.$2.kind),
      isNot(contains(CameraAlertKind.speeding)),
    );
    final unknown = CameraAlerter([_cam(1, 2000)]);
    final ev = _drive(unknown, 0, 2500, 150);
    expect(ev.map((e) => e.$2.kind), isNot(contains(CameraAlertKind.speeding)));
    expect(ev.first.$2.text, 'Камера контроля скорости через 600 м');
  });

  test('slowing down in time avoids the reminder', () {
    final a = CameraAlerter([_cam(1, 2000, limit: 60)]);
    final first = _drive(a, 0, 1700, 90);
    expect(first.single.$2.kind, CameraAlertKind.approaching);
    final rest = _drive(a, 1700, 2500, 55, start: const Duration(seconds: 100));
    expect(rest.map((e) => e.$2.kind), [CameraAlertKind.passed]);
  });

  test('several cameras are announced in order, each once', () {
    final a = CameraAlerter([
      _cam(3, 5000, type: CameraType.trafficSignals),
      _cam(1, 1000, limit: 60),
      _cam(2, 1200, limit: 60),
    ]);
    expect(a.next!.camera.id, 1);
    final ev = _drive(a, 0, 6000, 60);
    final approach = ev
        .where((e) => e.$2.kind == CameraAlertKind.approaching)
        .map((e) => e.$2.camera.camera.id);
    expect(approach, [1, 2, 3]);
    expect(
      ev.firstWhere((e) => e.$2.camera.camera.id == 3).$2.text,
      startsWith('Камера на светофоре через '),
    );
    expect(ev.where((e) => e.$2.kind == CameraAlertKind.passed), hasLength(3));
  });

  test('next camera and distance for a persistent indicator', () {
    final a = CameraAlerter([_cam(1, 1000), _cam(2, 4000)]);
    a.update(alongM: 500, speedKmh: 60, time: Duration.zero);
    expect(a.next!.camera.id, 1);
    expect(a.distanceToNextM, 500);
    a.update(alongM: 1100, speedKmh: 60, time: const Duration(seconds: 40));
    expect(a.next!.camera.id, 2);
    expect(a.distanceToNextM, 2900);
  });

  test('a camera already behind at the start is never announced', () {
    final a = CameraAlerter([_cam(1, 100), _cam(2, 5000)]);
    final ev = _drive(a, 1000, 2000, 60);
    expect(ev, isEmpty);
    expect(a.warnedKeys, isEmpty);
  });

  test('warned cameras carry over a re-route', () {
    final first = CameraAlerter([_cam(1, 1000, limit: 60)]);
    _drive(first, 0, 800, 60);
    expect(first.warnedKeys, {'pack:1'});
    // New route: the same camera is now 150 m ahead.
    final second = CameraAlerter([
      _cam(1, 150, limit: 60),
      _cam(2, 3000),
    ], alreadyWarned: first.warnedKeys);
    final ev = _drive(second, 0, 1000, 60);
    expect(ev.map((e) => e.$2.kind), [CameraAlertKind.passed]);
  });

  test('GPS standing still or jumping back does not repeat alerts', () {
    final a = CameraAlerter([_cam(1, 1000, limit: 60)]);
    final kinds = <CameraAlertKind>[];
    var t = 0;
    for (final pos in <double>[
      600,
      720,
      720,
      720,
      700,
      690,
      730,
      800,
      790,
      900,
    ]) {
      kinds.addAll(
        a
            .update(
              alongM: pos,
              speedKmh: 30,
              time: Duration(seconds: t++),
            )
            .map((e) => e.kind),
      );
    }
    expect(kinds, [CameraAlertKind.approaching]);
  });

  group('average-speed section', () {
    RouteCamera zone({int? limit = 90}) => _cam(
      7,
      1000,
      limit: limit,
      type: CameraType.averageSpeed,
      zoneEnd: 6000,
    );

    test('start, end and the measured average', () {
      final a = CameraAlerter([zone()]);
      final ev = _drive(a, 0, 7000, 80);
      expect(ev.map((e) => e.$2.kind), [
        CameraAlertKind.approaching,
        CameraAlertKind.zoneEntered,
        CameraAlertKind.zoneLeft,
      ]);
      expect(ev[0].$2.text, startsWith('Контроль средней скорости через '));
      expect(
        ev[1].$2.text,
        'Начало участка контроля средней скорости, ограничение 90 км/ч',
      );
      expect(ev[1].$1, inInclusiveRange(1000, 1023));
      expect(ev[2].$1, inInclusiveRange(6000, 6023));
      expect(ev[2].$2.averageKmh, closeTo(80, 1));
      expect(ev[2].$2.overLimit, isFalse);
      expect(
        ev[2].$2.text,
        'Конец участка контроля средней скорости. Средняя скорость 80 км/ч',
      );
      expect(a.activeZone, isNull);
    });

    test('average above the limit warns once inside the section', () {
      final a = CameraAlerter([zone()]);
      final ev = _drive(a, 0, 7000, 110);
      expect(ev.map((e) => e.$2.kind), [
        CameraAlertKind.approaching,
        CameraAlertKind.zoneEntered,
        CameraAlertKind.zoneSpeeding,
        CameraAlertKind.zoneLeft,
      ]);
      expect(ev[2].$2.averageKmh, closeTo(110, 2));
      expect(
        ev[2].$2.text,
        'Средняя скорость выше ограничения: 110 км/ч, ограничение 90 км/ч',
      );
      expect(ev[3].$2.overLimit, isTrue);
    });

    test('a short burst does not raise the average above the limit', () {
      final a = CameraAlerter([zone()]);
      final ev = <CameraAlert>[];
      // 4 km at 80 km/h, then 1 km at 110: the average stays under 90.
      ev.addAll(_drive(a, 0, 5000, 80).map((e) => e.$2));
      expect(a.activeZone, isNotNull);
      expect(a.activeZone!.averageKmh, closeTo(80, 1));
      ev.addAll(
        _drive(
          a,
          5000,
          7000,
          110,
          start: const Duration(seconds: 226),
        ).map((e) => e.$2),
      );
      expect(
        ev.map((e) => e.kind),
        isNot(contains(CameraAlertKind.zoneSpeeding)),
      );
      expect(ev.last.kind, CameraAlertKind.zoneLeft);
      expect(ev.last.averageKmh, closeTo(84.6, 1.5));
    });

    test('slowing down re-arms the average warning', () {
      final a = CameraAlerter([zone(limit: 60)]);
      final kinds = <CameraAlertKind>[];
      kinds.addAll(_drive(a, 900, 2000, 90).map((e) => e.$2.kind));
      // Crawl until the average is well below the limit, then speed again.
      kinds.addAll(
        _drive(
          a,
          2000,
          2600,
          20,
          start: const Duration(seconds: 45),
        ).map((e) => e.$2.kind),
      );
      expect(a.activeZone!.averageKmh, lessThan(57));
      kinds.addAll(
        _drive(
          a,
          2600,
          5900,
          120,
          start: const Duration(seconds: 154),
        ).map((e) => e.$2.kind),
      );
      expect(
        kinds.where((k) => k == CameraAlertKind.zoneSpeeding),
        hasLength(2),
      );
    });

    test('a section whose end is not on the route is a plain camera', () {
      final a = CameraAlerter([
        _cam(7, 1000, limit: 90, type: CameraType.averageSpeed),
      ]);
      final ev = _drive(a, 0, 2000, 80);
      expect(ev.map((e) => e.$2.kind), [
        CameraAlertKind.approaching,
        CameraAlertKind.passed,
      ]);
    });

    test('starting inside a section enters it silently measured from now', () {
      final a = CameraAlerter([zone()]);
      final ev = _drive(a, 3000, 7000, 80);
      expect(ev.map((e) => e.$2.kind), [
        CameraAlertKind.zoneEntered,
        CameraAlertKind.zoneLeft,
      ]);
    });
  });

  test('distance wording', () {
    expect(CameraAlertTexts.distance(296), '300 м');
    expect(CameraAlertTexts.distance(149), '150 м');
    expect(CameraAlertTexts.distance(84), '80 м');
    expect(CameraAlertTexts.distance(3), '10 м');
    expect(CameraAlertTexts.distance(1500), '1,5 км');
    expect(CameraAlertTexts.distance(12400), '12 км');
  });
}
