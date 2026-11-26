import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/routing/polyline.dart';

void main() {
  test('decodes the reference polyline5 example', () {
    final points = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@', precision: 5);
    expect(points, const [
      LatLng(38.5, -120.2),
      LatLng(40.7, -120.95),
      LatLng(43.252, -126.453),
    ]);
  });

  test('decodes polyline6 as sent by Valhalla', () {
    // First points of the captured Kaliningrad route fixture.
    final points = decodePolyline('qpgjgB{rh_f@pCjq@');
    expect(points.length, 2);
    expect(points[0].latitude, closeTo(54.710553, 1e-9));
    expect(points[0].longitude, closeTo(20.452158, 1e-9));
    expect(points[1].latitude, closeTo(54.71048, 1e-9));
    expect(points[1].longitude, closeTo(20.451352, 1e-9));
  });

  test('encode and decode round-trip, including negative coordinates', () {
    const points = [
      LatLng(55.755826, 37.6173),
      LatLng(55.7558, 37.617301),
      LatLng(-33.868820, 151.209296),
      LatLng(0, 0),
      LatLng(-0.000001, -179.999999),
    ];
    final decoded = decodePolyline(encodePolyline(points));
    expect(decoded.length, points.length);
    for (var i = 0; i < points.length; i++) {
      expect(decoded[i].latitude, closeTo(points[i].latitude, 1e-9));
      expect(decoded[i].longitude, closeTo(points[i].longitude, 1e-9));
    }
  });

  test('empty string is an empty line', () {
    expect(decodePolyline(''), isEmpty);
  });

  test('truncated input throws FormatException', () {
    final encoded = encodePolyline(const [LatLng(55.75, 37.61)]);
    expect(
      () => decodePolyline(encoded.substring(0, encoded.length - 1)),
      throwsFormatException,
    );
    // A latitude without its longitude.
    expect(() => decodePolyline('_p~iF'), throwsFormatException);
  });
}
