import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/map/engine/maplibre/camera.dart';

void main() {
  const moscow = LatLng(55.752, 37.616);
  const distance = Distance();

  test('project and unproject are inverse', () {
    for (final z in [3.0, 11.5, 19.0]) {
      final back = MapCamera.unproject(MapCamera.project(moscow, z), z);
      expect(back.latitude, closeTo(moscow.latitude, 1e-9));
      expect(back.longitude, closeTo(moscow.longitude, 1e-9));
    }
  });

  test('zoom is counted in 256 px tiles, MapLibre zoom is one less', () {
    expect(MapCamera.worldSize(0), 256);
    expect(const MapCamera(moscow, 14).mapLibreZoom, 13);
  });

  test('screen positions follow the bearing', () {
    const north = MapCamera(moscow, 15);
    const eastUp = MapCamera(moscow, 15, 90);
    final east = distance.offset(moscow, 500, 90);
    // North-up: a place to the east is to the right.
    expect(north.screenOf(east).dx, greaterThan(50));
    expect(north.screenOf(east).dy.abs(), lessThan(1));
    // East-up: the same place is straight above the centre.
    expect(eastUp.screenOf(east).dy, lessThan(-50));
    expect(eastUp.screenOf(east).dx.abs(), lessThan(1));
    for (final cam in [north, eastUp, const MapCamera(moscow, 12.3, -37)]) {
      const p = Offset(123, -77);
      expect((cam.screenOf(cam.latLngAt(p)) - p).distance, lessThan(1e-6));
    }
  });

  test('panning moves the content with the finger', () {
    const cam = MapCamera(moscow, 15, 30);
    final target = cam.latLngAt(const Offset(40, 10));
    final moved = cam.panned(const Offset(-40, -10));
    expect(moved.screenOf(target).distance, lessThan(1e-6));
    expect(moved.zoom, 15);
    expect(moved.bearing, 30);
  });

  test('zooming and rotating keep the focal point in place', () {
    const cam = MapCamera(moscow, 14, 20);
    const focal = Offset(150, -90);
    final under = cam.latLngAt(focal);
    final zoomed = cam.zoomedAround(focal, 16.4);
    expect(zoomed.zoom, 16.4);
    expect((zoomed.screenOf(under) - focal).distance, lessThan(1e-6));
    final turned = cam.rotatedAround(focal, 35);
    expect(turned.bearing, closeTo(-15, 1e-9));
    expect((turned.screenOf(under) - focal).distance, lessThan(1e-6));
  });

  test('zoom is clamped and bearing normalised', () {
    const cam = MapCamera(moscow, 18.5);
    expect(cam.zoomedAround(Offset.zero, 25).zoom, MapCamera.maxZoom);
    expect(cam.zoomedAround(Offset.zero, 0).zoom, MapCamera.minZoom);
    expect(MapCamera.normalizeBearing(270), -90);
    expect(MapCamera.normalizeBearing(-190), 170);
    expect(cam.rotatedAround(Offset.zero, 200).bearing, 160);
  });

  test('fit shows all points inside the padded area', () {
    final points = [
      const LatLng(55.70, 37.50),
      const LatLng(55.80, 37.75),
      const LatLng(55.76, 37.40),
    ];
    const size = Size(720, 686);
    const padding = EdgeInsetsLike(40, 90, 70, 200);
    final cam = MapCamera.fit(points, size, padding)!;
    expect(cam.bearing, 0);
    final free = Rect.fromLTRB(
      -size.width / 2 + padding.left,
      -size.height / 2 + padding.top,
      size.width / 2 - padding.right,
      size.height / 2 - padding.bottom,
    ).inflate(0.5);
    for (final p in points) {
      expect(free.contains(cam.screenOf(p)), isTrue, reason: '$p');
    }
    // As tight as possible: one more zoom level would not fit.
    final closer = MapCamera(cam.center, cam.zoom + 1);
    expect(points.every((p) => free.contains(closer.screenOf(p))), isFalse);
  });

  test('fit of a single point stops at the maximum zoom', () {
    final cam = MapCamera.fit(
      [moscow],
      const Size(400, 400),
      const EdgeInsetsLike(0, 0, 0, 0),
    )!;
    expect(cam.zoom, 17);
    expect(cam.center.latitude, closeTo(moscow.latitude, 1e-6));
    expect(
      MapCamera.fit([], const Size(400, 400), const EdgeInsetsLike(0, 0, 0, 0)),
      isNull,
    );
  });

  test('accuracy ring has the radius in metres on the ground', () {
    final ring = circleRing(moscow, 250);
    expect(ring.first, ring.last);
    for (final c in ring) {
      expect(distance(moscow, LatLng(c[1], c[0])), closeTo(250, 2));
    }
  });
}
