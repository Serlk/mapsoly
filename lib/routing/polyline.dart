import 'package:latlong2/latlong.dart';

/// Decodes a Google-style encoded polyline.
///
/// Valhalla uses precision 6 ("polyline6", 1e-6 degrees) for every shape it
/// returns; pass `precision: 5` for the classic Google format.
///
/// Throws [FormatException] if the string is truncated.
List<LatLng> decodePolyline(String encoded, {int precision = 6}) {
  final factor = _pow10(precision);
  final points = <LatLng>[];
  final units = encoded.codeUnits;
  var index = 0;
  var lat = 0;
  var lon = 0;

  int next() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (index >= units.length) {
        throw FormatException('Truncated polyline', encoded, index);
      }
      final byte = units[index++] - 63;
      if (byte < 0 || byte > 63) {
        throw FormatException('Bad polyline character', encoded, index - 1);
      }
      result |= (byte & 0x1f) << shift;
      shift += 5;
      if (byte < 0x20) break;
    }
    return (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
  }

  while (index < units.length) {
    lat += next();
    lon += next();
    points.add(LatLng(lat / factor, lon / factor));
  }
  return points;
}

/// Encodes points as a polyline; the inverse of [decodePolyline].
String encodePolyline(Iterable<LatLng> points, {int precision = 6}) {
  final factor = _pow10(precision);
  final out = StringBuffer();
  var prevLat = 0;
  var prevLon = 0;

  void write(int delta) {
    var value = delta < 0 ? ~(delta << 1) : (delta << 1);
    while (value >= 0x20) {
      out.writeCharCode((0x20 | (value & 0x1f)) + 63);
      value >>= 5;
    }
    out.writeCharCode(value + 63);
  }

  for (final p in points) {
    final lat = (p.latitude * factor).round();
    final lon = (p.longitude * factor).round();
    write(lat - prevLat);
    write(lon - prevLon);
    prevLat = lat;
    prevLon = lon;
  }
  return out.toString();
}

double _pow10(int n) {
  var v = 1.0;
  for (var i = 0; i < n; i++) {
    v *= 10;
  }
  return v;
}
