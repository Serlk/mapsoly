import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'traffic_sampler.dart';

enum TrafficSource { off, yandex, google }

/// Browser-like UA: both traffic endpoints are unofficial and reject
/// obviously non-browser clients.
const Map<String, String> trafficHeaders = {
  'User-Agent':
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/130.0 Safari/537.36',
};

/// Holds the selected traffic source and the data version used to refresh
/// tiles. Yandex publishes an explicit version stamp; Google has none, so a
/// time bucket is used instead.
class TrafficController extends ChangeNotifier {
  TrafficController({http.Client? client}) : client = client ?? http.Client();

  static const _refresh = Duration(seconds: 90);
  static final _stampsUri = Uri.parse(
    'https://api-maps.yandex.ru/services/coverage/v2/layers_stamps'
    '?lang=ru_RU&l=trf',
  );

  final http.Client client;
  TrafficSource _source = TrafficSource.off;
  String? _version;
  DateTime? _updatedAt;
  String? _error;
  Timer? _timer;

  TrafficSource get source => _source;

  /// Null until the first successful refresh for the current source.
  String? get version => _version;
  DateTime? get updatedAt => _updatedAt;
  String? get error => _error;

  void select(TrafficSource source) {
    if (source == _source) return;
    _source = source;
    _version = null;
    _error = null;
    _timer?.cancel();
    notifyListeners();
    if (source == TrafficSource.off) return;
    _tick();
    _timer = Timer.periodic(_refresh, (_) => _tick());
  }

  Future<void> _tick() async {
    final requested = _source;
    try {
      final String version;
      if (requested == TrafficSource.yandex) {
        final r = await client
            .get(_stampsUri, headers: trafficHeaders)
            .timeout(const Duration(seconds: 10));
        if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
        version = (jsonDecode(r.body) as Map)['trf']['version'] as String;
      } else {
        version =
            '${DateTime.now().millisecondsSinceEpoch ~/ _refresh.inMilliseconds}';
      }
      if (requested != _source) return;
      _error = null;
      _updatedAt = DateTime.now();
      if (version != _version) _version = version;
    } catch (e) {
      if (requested != _source) return;
      _error = '$e';
    }
    notifyListeners();
  }

  /// A sampler reading the current Yandex traffic picture, or null when
  /// that layer is not the selected, loaded source.
  TrafficSampler? sampler() {
    final version = _version;
    if (_source != TrafficSource.yandex || version == null) return null;
    return TrafficSampler((x, y, z) async {
      try {
        final r = await client
            .get(
              Uri.parse(
                'https://core-jams-rdr-cache.maps.yandex.net/1.1/tiles'
                '?trf&l=trf&lang=ru_RU&x=$x&y=$y&z=$z&scale=1&tm=$version',
              ),
              headers: trafficHeaders,
            )
            .timeout(const Duration(seconds: 10));
        if (r.statusCode != 200 || r.bodyBytes.isEmpty) return null;
        final codec = await ui.instantiateImageCodec(r.bodyBytes);
        final image = (await codec.getNextFrame()).image;
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final size = image.width;
        image.dispose();
        return data == null ? null : TrafficTile(size, data);
      } on Exception {
        return null;
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    client.close();
    super.dispose();
  }
}

/// Google's traffic tiles come with its own road network drawn in grey
/// and beige under the traffic colours; where Google has no traffic data
/// (most of Russia) that is all there is, and the map turns grey. This
/// clears every pixel that is not a traffic colour, in place.
///
/// [rgba] is straight (not premultiplied) RGBA. Traffic colours are
/// saturated (green, yellow, red, dark red); the road network is not.
void keepTrafficColours(Uint8List rgba, {bool premultiply = false}) {
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    final a = rgba[i + 3];
    if (a == 0) continue;
    final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
    final max = r > g ? (r > b ? r : b) : (g > b ? g : b);
    final min = r < g ? (r < b ? r : b) : (g < b ? g : b);
    if (max < 60 || (max - min) * 5 < max * 3) {
      rgba[i] = rgba[i + 1] = rgba[i + 2] = rgba[i + 3] = 0;
    } else if (premultiply && a < 255) {
      rgba[i] = r * a ~/ 255;
      rgba[i + 1] = g * a ~/ 255;
      rgba[i + 2] = b * a ~/ 255;
    }
  }
}

/// [keepTrafficColours] for an encoded tile: PNG in, PNG out. Returns the
/// tile as it was when it cannot be decoded.
Future<Uint8List> stripGoogleRoads(Uint8List png) async {
  try {
    final codec = await ui.instantiateImageCodec(png);
    final frame = await codec.getNextFrame();
    final source = frame.image;
    final width = source.width, height = source.height;
    final data = await source.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    source.dispose();
    codec.dispose();
    if (data == null) return png;
    final rgba = data.buffer.asUint8List();
    keepTrafficColours(rgba, premultiply: true);
    final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final out = await descriptor.instantiateCodec();
    final image = (await out.getNextFrame()).image;
    final encoded = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    out.dispose();
    descriptor.dispose();
    buffer.dispose();
    return encoded?.buffer.asUint8List() ?? png;
  } on Object catch (e) {
    debugPrint('Google traffic tile not filtered: $e');
    return png;
  }
}
