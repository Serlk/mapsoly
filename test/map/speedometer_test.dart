import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/map/speed_limit.dart';
import 'package:mapsoly/map/speedometer.dart';
import 'package:mapsoly/routing/route_models.dart';

NearbyEdge edge(double distance, double heading, int? limit) => NearbyEdge(
  distanceM: distance,
  headingDeg: heading,
  speedLimitKmh: limit,
  roadClass: 'primary',
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

  test('the driven road is the nearest one going our way', () {
    final edges = [
      edge(4, 270, 40), // the side street crossing here
      edge(9, 92, 60), // our carriageway
      edge(9, 272, 80), // the opposite one
    ];
    expect(pickDrivenEdge(edges, headingDeg: 90)!.speedLimitKmh, 60);
    expect(pickDrivenEdge(edges, headingDeg: 355), isNull);
    expect(pickDrivenEdge(edges)!.speedLimitKmh, 40);
    expect(headingDifference(350, 10), 20);
  });

  test('verbose locate edges: 0 and 255 are not limits', () {
    Map<String, dynamic> json(Object? limit) => {
      'distance': 3.5,
      'heading': 181,
      'edge_info': {'speed_limit': limit},
      'edge': {
        'classification': {'classification': 'trunk'},
      },
    };
    expect(NearbyEdge.tryParse(json(100))!.speedLimitKmh, 100);
    expect(NearbyEdge.tryParse(json(100))!.roadClass, 'trunk');
    expect(NearbyEdge.tryParse(json(0))!.speedLimitKmh, isNull);
    expect(NearbyEdge.tryParse(json(255))!.speedLimitKmh, isNull);
    expect(NearbyEdge.tryParse({'edge_info': <String, dynamic>{}}), isNull);
  });

  group('SpeedLimitTracker', () {
    // About 11 m per step northwards.
    LatLng p(int step) => LatLng(55.75 + step * 0.0001, 37.6);

    test('asks every few dozen metres and keeps a limit over gaps', () async {
      var answer = <NearbyEdge>[edge(2, 0, 60)];
      var asked = 0;
      final tracker = SpeedLimitTracker((_) async {
        asked++;
        return answer;
      });
      addTearDown(tracker.dispose);
      tracker.update(p(0), 0);
      await pumpEventQueue();
      expect(tracker.limitKmh, 60);
      // Too close to ask again.
      tracker.update(p(1), 0);
      await pumpEventQueue();
      expect(asked, 1);
      // A stretch without a mapped limit: the last one stays for a while.
      answer = [edge(2, 0, null)];
      tracker.update(p(4), 0);
      await pumpEventQueue();
      expect(asked, 2);
      expect(tracker.limitKmh, 60);
      tracker.update(p(14), 0);
      await pumpEventQueue();
      expect(tracker.limitKmh, isNull);
      // A turn asks again at once.
      answer = [edge(2, 90, 40)];
      tracker.update(p(14), 90);
      await pumpEventQueue();
      expect(tracker.limitKmh, 40);
    });

    test('no routing data or a failing lookup: no limit, no crash', () async {
      final none = SpeedLimitTracker((_) async => null);
      addTearDown(none.dispose);
      none.update(p(0), 0);
      await pumpEventQueue();
      expect(none.limitKmh, isNull);
      final broken = SpeedLimitTracker((_) async => throw Exception('down'));
      addTearDown(broken.dispose);
      broken.update(p(0), 0);
      await pumpEventQueue();
      expect(broken.limitKmh, isNull);
      // It asks again later.
      broken.update(p(5), 0);
      await pumpEventQueue();
    });
  });
}
