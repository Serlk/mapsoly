import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/map/speed_limit.dart';
import 'package:mapsoly/map/speedometer.dart';
import 'package:mapsoly/routing/route_models.dart';

DrivenEdge edge({int? limit, int? density = 15, String cls = 'primary'}) =>
    DrivenEdge(
      speedLimitKmh: limit,
      density: density,
      roadClass: cls,
      use: 'road',
    );

void main() {
  final t0 = DateTime.utc(2026, 11, 27, 9);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  group('DriveChrome', () {
    test('hides on the move, a touch reveals for a while', () {
      final c = DriveChrome();
      expect(c.hidden, isFalse);
      c.update(8, at(0));
      expect(c.hidden, isFalse);
      c.update(30, at(1));
      expect(c.hidden, isTrue);
      c.reveal();
      expect(c.hidden, isFalse);
      c.conceal();
      expect(c.hidden, isTrue);
    });

    test('a short stop keeps things hidden, a long one shows them', () {
      final c = DriveChrome()..update(40, at(0));
      c.update(0, at(1));
      expect(c.hidden, isTrue);
      // Crawling in a jam is still driving.
      c.update(6, at(3));
      c.update(0, at(4));
      c.update(0, at(7));
      expect(c.hidden, isTrue);
      c.update(0, at(8));
      expect(c.hidden, isFalse);
      // Rolling off slowly does not hide them yet.
      c.update(7, at(9));
      expect(c.hidden, isFalse);
    });
  });

  test('speeding: over the limit, and far over it', () {
    expect(speedingOf(100, null), Speeding.none);
    expect(speedingOf(60.4, 60), Speeding.none);
    expect(speedingOf(63, 60), Speeding.over);
    expect(speedingOf(80, 60), Speeding.over);
    expect(speedingOf(81, 60), Speeding.far);
  });

  test('the limit of a road: mapped, or the general rule', () {
    expect(limitOf(edge(limit: 40)), const RoadLimit(40));
    // A city street without a mapped limit: 60 by rule.
    expect(limitOf(edge()), const RoadLimit(60, posted: false));
    expect(limitOf(edge(density: 3)), const RoadLimit(90, posted: false));
    expect(
      limitOf(edge(density: 3, cls: 'motorway')),
      const RoadLimit(110, posted: false),
    );
    expect(
      limitOf(
        const DrivenEdge(
          speedLimitKmh: null,
          density: 15,
          roadClass: 'residential',
          use: 'living_street',
        ),
      ),
      const RoadLimit(20, posted: false),
    );
    // Yards and car parks: nothing to show.
    expect(limitOf(edge(cls: 'service_other')), isNull);
    expect(limitOf(edge(density: null)), isNull);
    expect(headingDifference(350, 10), 20);
  });

  test('trace attributes: absent, 0 and 255 are not limits', () {
    DrivenEdge parse(Object? limit) => DrivenEdge.fromJson({
      'speed_limit': ?limit,
      'density': 15,
      'road_class': 'trunk',
      'use': 'road',
    });
    expect(parse(100).speedLimitKmh, 100);
    expect(parse(100).roadClass, 'trunk');
    expect(parse(null).speedLimitKmh, isNull);
    expect(parse(0).speedLimitKmh, isNull);
    expect(parse(255).speedLimitKmh, isNull);
  });

  test('the matched stretch lies behind the car', () {
    final p = pointBehind(const LatLng(55.75, 37.6), 90, 30);
    expect(p.latitude, closeTo(55.75, 1e-6));
    expect(p.longitude, lessThan(37.6));
    expect(
      const Distance().as(LengthUnit.Meter, p, const LatLng(55.75, 37.6)),
      closeTo(30, 1),
    );
  });

  group('SpeedLimitTracker', () {
    // About 11 m per step northwards.
    LatLng p(int step) => LatLng(55.75 + step * 0.0001, 37.6);

    test('asks every few dozen metres and keeps a limit over gaps', () async {
      DrivenEdge? answer = edge(limit: 60);
      var asked = 0;
      final tracker = SpeedLimitTracker((from, to) async {
        asked++;
        expect(from.latitude, lessThan(to.latitude));
        return answer;
      });
      addTearDown(tracker.dispose);
      // Without a direction there is nothing to match.
      tracker.update(p(0), null);
      await pumpEventQueue();
      expect(asked, 0);
      tracker.update(p(0), 0);
      await pumpEventQueue();
      expect(tracker.limit, const RoadLimit(60));
      // Too close to ask again.
      tracker.update(p(1), 0);
      await pumpEventQueue();
      expect(asked, 1);
      // No road matched for a moment: the last limit stays for a while.
      answer = null;
      tracker.update(p(4), 0);
      await pumpEventQueue();
      expect(asked, 2);
      expect(tracker.limit, const RoadLimit(60));
      tracker.update(p(16), 0);
      await pumpEventQueue();
      expect(tracker.limit, isNull);
      // A street without a mapped limit: the rule, marked as such.
      answer = edge();
      tracker.update(p(20), 0);
      await pumpEventQueue();
      expect(tracker.limit, const RoadLimit(60, posted: false));
    });

    test('a failing lookup: no limit, no crash, asks again', () async {
      var asked = 0;
      final broken = SpeedLimitTracker((_, _) async {
        asked++;
        throw Exception('down');
      });
      addTearDown(broken.dispose);
      broken.update(p(0), 0);
      await pumpEventQueue();
      expect(broken.limit, isNull);
      broken.update(p(5), 0);
      await pumpEventQueue();
      expect(asked, 2);
    });
  });
}
