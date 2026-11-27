import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/map/road_snap.dart';

void main() {
  const d = Distance();
  // A road going north for 200 m, then east for 200 m.
  const lat0 = 55.0, lon0 = 37.0;
  const m = 1 / 111320.0; // degrees of latitude per metre
  final e = m / 0.5735764; // degrees of longitude per metre at 55 N
  final road = [
    const LatLng(lat0, lon0),
    const LatLng(lat0 + 200 * m, lon0),
    LatLng(lat0 + 200 * m, lon0 + 200 * e),
  ];
  LatLng at(double north, double east) =>
      LatLng(lat0 + north * m, lon0 + east * e);

  test('a car beside the road is put onto it, facing along it', () {
    final s = snapToRoad(road, at(120, 9), 4)!;
    expect(d.as(LengthUnit.Meter, s.point, at(120, 0)), lessThan(1));
    expect(s.bearing, closeTo(0, 0.5));
    final t = snapToRoad(road, at(193, 60), 95)!;
    expect(d.as(LengthUnit.Meter, t.point, at(200, 60)), lessThan(1));
    expect(t.bearing, closeTo(90, 0.5));
  });

  test('ahead of the matched stretch the road is continued straight', () {
    final s = snapToRoad(road, at(206, 250), 90)!;
    expect(d.as(LengthUnit.Meter, s.point, at(200, 250)), lessThan(1));
    // But not for ever.
    expect(snapToRoad(road, at(200, 400), 90), isNull);
  });

  test('off the road: too far aside, or turned away', () {
    expect(snapToRoad(road, at(100, 35), 0), isNull);
    expect(snapToRoad(road, at(100, 5), 90), isNull);
    // Without a heading the distance alone decides.
    expect(snapToRoad(road, at(100, 5), null), isNotNull);
    expect(snapToRoad(const [], at(0, 0), 0), isNull);
    expect(snapToRoad([road.first], at(0, 0), 0), isNull);
  });
}
