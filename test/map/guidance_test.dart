import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/map/guidance.dart';

void main() {
  // North 1.11 km, then east about 0.63 km.
  const shape = [
    LatLng(55.75, 37.60),
    LatLng(55.76, 37.60),
    LatLng(55.76, 37.61),
  ];

  test('measures distance along the route', () {
    final t = RouteTracker(shape);
    expect(t.alongOf(1), closeTo(1113, 5));
    expect(t.lengthM, closeTo(1113 + 627, 10));
  });

  test('matches a position beside the first leg', () {
    final t = RouteTracker(shape);
    final p = t.match(const LatLng(55.755, 37.6003)); // ~19 m east of it
    expect(p.segment, 0);
    expect(p.alongM, closeTo(556, 5));
    expect(p.lateralM, closeTo(19, 3));
    expect(p.point.longitude, closeTo(37.60, 1e-5));
  });

  test('progress moves onto the second leg after the turn', () {
    final t = RouteTracker(shape);
    t.match(const LatLng(55.7599, 37.60));
    final p = t.match(const LatLng(55.76, 37.605));
    expect(p.segment, 1);
    expect(p.alongM, closeTo(1113 + 313, 10));
  });

  test('pointAt inverts alongOf', () {
    final t = RouteTracker(shape);
    final p = t.pointAt(t.alongOf(1));
    expect(p.latitude, closeTo(55.76, 1e-6));
    expect(p.longitude, closeTo(37.60, 1e-6));
  });

  test('a route passing the same road twice keeps the current pass', () {
    // Out and back along the same street.
    const loop = [
      LatLng(55.75, 37.60),
      LatLng(55.76, 37.60),
      LatLng(55.75, 37.60),
    ];
    final t = RouteTracker(loop);
    t.match(const LatLng(55.7595, 37.60));
    t.match(const LatLng(55.7599, 37.60));
    final back = t.match(const LatLng(55.7550, 37.60));
    expect(back.alongM, greaterThan(1113));
  });

  test('off-route fires once after several far fixes', () {
    final d = OffRouteDetector();
    expect(d.update(120, 20), isFalse);
    expect(d.update(120, 20), isFalse);
    expect(d.update(120, 20), isTrue);
    expect(d.update(120, 20), isFalse);
  });

  test('poor accuracy does not trigger off-route', () {
    final d = OffRouteDetector();
    for (var i = 0; i < 10; i++) {
      expect(d.update(300, 900), isFalse);
    }
  });

  test('returning to the route resets the count', () {
    final d = OffRouteDetector();
    d.update(120, 10);
    d.update(120, 10);
    d.update(5, 10);
    expect(d.update(120, 10), isFalse);
  });
}
