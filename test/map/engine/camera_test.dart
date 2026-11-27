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

  test('a camera can put a place at the centre of the visible part', () {
    // 64 px of the view are under a bar at the bottom: the visible centre is
    // 32 px above the view centre.
    const visibleCentre = Offset(0, -32);
    for (final bearing in [0.0, 75.0]) {
      final cam = MapCamera(moscow, 16, bearing).panned(visibleCentre);
      expect((cam.screenOf(moscow) - visibleCentre).distance, lessThan(1e-6));
      final back = cam.latLngAt(visibleCentre);
      expect(back.latitude, closeTo(moscow.latitude, 1e-9));
      expect(back.longitude, closeTo(moscow.longitude, 1e-9));
    }
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

  group('tilted view', () {
    const cam = MapCamera(moscow, 16, 40, 55, 686);

    test('screen and ground positions are inverse', () {
      for (final p in const [
        Offset(0, 0),
        Offset(200, 150),
        Offset(-300, -120),
      ]) {
        expect((cam.screenOf(cam.latLngAt(p)) - p).distance, lessThan(1e-6));
      }
    });

    test('the far side shows more ground per pixel than the near side', () {
      final near = distance(cam.latLngAt(const Offset(0, 200)), cam.center);
      final far = distance(cam.latLngAt(const Offset(0, -200)), cam.center);
      final flat = distance(
        const MapCamera(moscow, 16, 40).latLngAt(const Offset(0, 200)),
        moscow,
      );
      expect(far, greaterThan(near * 1.5));
      expect(near, greaterThan(flat)); // even near, the ground is foreshortened
      // Sideways at the target nothing changes.
      expect(
        distance(cam.latLngAt(const Offset(100, 0)), cam.center),
        closeTo(
          distance(
            const MapCamera(moscow, 16, 40).latLngAt(const Offset(100, 0)),
            moscow,
          ),
          0.5,
        ),
      );
    });

    test('a dragged place stays under the finger', () {
      const from = Offset(120, 180), to = Offset(-60, 40);
      final under = cam.latLngAt(from);
      final moved = cam.dragged(from, to);
      expect((moved.screenOf(under) - to).distance, lessThan(1e-6));
      expect((moved.pitch, moved.bearing, moved.zoom), (55, 40, 16));
    });

    test('zoom and rotation keep the focal point, tilt is clamped', () {
      const focal = Offset(90, 120);
      final under = cam.latLngAt(focal);
      expect(
        (cam.zoomedAround(focal, 17.2).screenOf(under) - focal).distance,
        lessThan(1e-6),
      );
      expect(
        (cam.rotatedAround(focal, 30).screenOf(under) - focal).distance,
        lessThan(1e-6),
      );
      expect(cam.withPitch(80).pitch, MapCamera.maxPitch);
      expect(cam.withPitch(-5).pitch, 0);
    });
  });

  group('bearing and animation', () {
    test('the short way round', () {
      expect(MapCamera.bearingDelta(350, 10), 20);
      expect(MapCamera.bearingDelta(10, 350), -20);
      expect(MapCamera.bearingDelta(-170, 170), -20);
      expect(MapCamera.bearingDelta(0, 180).abs(), 180);
      expect(MapCamera.bearingDelta(90, 90), 0);
    });

    test('a tween turns through north, not the long way', () {
      const tween = CameraTween(
        MapCamera(moscow, 15, 170),
        MapCamera(moscow, 17, -170, 50),
        linear: true,
      );
      expect(tween.at(0).bearing, 170);
      expect(tween.at(0.25).bearing, 175);
      expect(tween.at(0.5).bearing.abs(), 180);
      expect(tween.at(0.75).bearing, -175);
      expect(tween.at(1).bearing, -170);
      expect(tween.at(0.5).zoom, 16);
      expect(tween.at(0.5).pitch, 25);
    });

    test('linear moves at constant speed, the default eases out', () {
      const a = MapCamera(LatLng(55.75, 37.60), 16),
          b = MapCamera(LatLng(55.75, 37.62), 16);
      final linear = const CameraTween(a, b, linear: true);
      expect(linear.at(0.5).center.longitude, closeTo(37.61, 1e-9));
      expect(linear.at(0.1).center.longitude, closeTo(37.602, 1e-9));
      final eased = const CameraTween(a, b, linear: false);
      // Ease-out: most of the way is covered early, and it never overshoots.
      expect(eased.at(0.5).center.longitude, greaterThan(37.613));
      expect(eased.at(0.9).center.longitude, lessThan(37.62));
      expect(CameraTween.ease(0), 0);
      expect(CameraTween.ease(1), 1);
      var last = 0.0;
      for (var t = 0.05; t < 1; t += 0.05) {
        final e = CameraTween.ease(t);
        expect(e, greaterThan(last));
        last = e;
      }
    });
  });

  group('padding', () {
    test('centre of the padded area and the larger inset', () {
      const bar = EdgeInsetsLike(0, 0, 0, 64);
      expect(bar.centreOffset, const Offset(0, -32));
      const driving = EdgeInsetsLike(0, 300, 0, 0);
      expect(driving.max(bar), const EdgeInsetsLike(0, 300, 0, 64));
      expect(driving.max(bar).centreOffset, const Offset(0, 118));
    });

    test('fit keeps clear of the camera padding and of its own', () {
      final points = [const LatLng(55.70, 37.52), const LatLng(55.80, 37.70)];
      const size = Size(720, 686);
      const bar = EdgeInsetsLike(0, 0, 0, 64),
          own = EdgeInsetsLike(40, 40, 40, 40);
      final cam = MapCamera.fit(points, size, own, cameraPadding: bar)!;
      // Positions are relative to the camera target, which sits at the centre
      // of the area above the bar: 720 x 622, minus 40 on each side.
      final free = const Rect.fromLTRB(-320, -271, 320, 271).inflate(0.5);
      for (final p in points) {
        expect(free.contains(cam.screenOf(p)), isTrue, reason: '$p');
      }
      // Symmetric own padding: the bounds are centred on the target.
      final a = cam.screenOf(points[0]), b = cam.screenOf(points[1]);
      expect(((a + b) / 2).distance, lessThan(1));
      // Without the bar the same route may be drawn larger.
      expect(MapCamera.fit(points, size, own)!.zoom, greaterThan(cam.zoom));
    });
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
