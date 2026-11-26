import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/traffic/traffic_sampler.dart';

TrafficTile solid(int r, int g, int b, [int a = 255]) {
  final data = ByteData(256 * 256 * 4);
  for (var i = 0; i < 256 * 256; i++) {
    data
      ..setUint8(i * 4, r)
      ..setUint8(i * 4 + 1, g)
      ..setUint8(i * 4 + 2, b)
      ..setUint8(i * 4 + 3, a);
  }
  return TrafficTile(256, data);
}

void main() {
  test('the palette of a real Yandex tile classifies as expected', () {
    // Dominant colours of a tile fetched for central Moscow on 2026-11-26.
    expect(classifyTrafficColor(94, 205, 76, 255), Congestion.free);
    expect(classifyTrafficColor(255, 187, 51, 255), Congestion.slow);
    expect(classifyTrafficColor(230, 90, 70, 255), Congestion.heavy);
    // Dark red was not present in that tile: this value is an assumption.
    expect(classifyTrafficColor(130, 25, 25, 255), Congestion.jam);
    expect(classifyTrafficColor(255, 255, 255, 255), Congestion.unknown);
    expect(classifyTrafficColor(60, 60, 60, 255), Congestion.unknown);
    expect(classifyTrafficColor(93, 204, 68, 0), Congestion.unknown);
  });

  // A straight 1.1 km stretch in Moscow split into two equal segments.
  const shape = [
    LatLng(55.7500, 37.6000),
    LatLng(55.7550, 37.6000),
    LatLng(55.7600, 37.6000),
  ];
  const segments = [TrafficSegment(0, 1, 60), TrafficSegment(1, 2, 60)];

  test('free roads keep the free-flow time', () async {
    final sampler = TrafficSampler((x, y, z) async => solid(93, 204, 68));
    final e = await sampler.estimate(shape, segments);
    expect(e.seconds, closeTo(120, 1e-6));
    expect(e.coverage, 1);
  });

  test('red roads slow the route by the heavy factor', () async {
    final sampler = TrafficSampler((x, y, z) async => solid(230, 60, 50));
    final e = await sampler.estimate(shape, segments);
    expect(e.seconds, closeTo(120 / 0.3, 1e-6));
  });

  test('missing tiles count as no traffic data', () async {
    final sampler = TrafficSampler((x, y, z) async => null);
    final e = await sampler.estimate(shape, segments);
    expect(e.seconds, closeTo(120, 1e-6));
    expect(e.coverage, 0);
  });

  test('each tile is loaded once', () async {
    var loads = 0;
    final sampler = TrafficSampler((x, y, z) async {
      loads++;
      return solid(250, 180, 40);
    });
    await sampler.estimate(shape, segments);
    expect(loads, lessThanOrEqualTo(4));
  });
}
