import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/map/drive_camera.dart';
import 'package:mapsoly/map/guidance.dart';

void main() {
  // A road going north for ~1.1 km, then east.
  final shape = [
    const LatLng(55.7500, 37.6000),
    const LatLng(55.7600, 37.6000),
    const LatLng(55.7600, 37.6200),
  ];

  group('bearing', () {
    test('between points', () {
      expect(bearingBetween(shape[0], shape[1]), closeTo(0, 0.1));
      expect(bearingBetween(shape[1], shape[2]), closeTo(90, 0.2));
      expect(bearingBetween(shape[1], shape[0]), closeTo(180, 0.1));
      expect(bearingBetween(shape[2], shape[1]), closeTo(270, 0.2));
    });

    test('of the route at a point looks a little ahead', () {
      final tracker = RouteTracker(shape);
      expect(routeBearingAt(tracker, 200), closeTo(0, 0.5));
      // Shortly before the corner the view starts to turn.
      final corner = tracker.alongOf(1);
      final before = routeBearingAt(tracker, corner - 20)!;
      expect(before, greaterThan(20));
      expect(before, lessThan(70));
      expect(routeBearingAt(tracker, corner + 100), closeTo(90, 0.5));
      // At the very end it looks back along the last stretch.
      expect(routeBearingAt(tracker, tracker.lengthM), closeTo(90, 0.5));
      expect(routeBearingAt(RouteTracker([shape[0]]), 0), isNull);
    });

    test('angle difference takes the short way round', () {
      expect(angleDelta(350, 10), 20);
      expect(angleDelta(10, 350), -20);
      expect(angleDelta(0, 180).abs(), 180);
    });
  });

  group('zoom', () {
    test('is close in town and wide on the motorway, without jumps', () {
      expect(zoomForSpeed(0), zoomForSpeed(20));
      expect(zoomForSpeed(60), lessThan(zoomForSpeed(20)));
      expect(zoomForSpeed(110), lessThan(zoomForSpeed(60)));
      expect(zoomForSpeed(180), zoomForSpeed(110));
      for (var v = 0.0; v < 150; v += 5) {
        expect((zoomForSpeed(v) - zoomForSpeed(v + 5)).abs(), lessThan(0.2));
      }
    });

    test('tightens before a maneuver', () {
      final cruising = driveZoom(100, null);
      expect(driveZoom(100, 2000), cruising);
      expect(driveZoom(100, 250), greaterThan(cruising));
      expect(driveZoom(100, 50), greaterThan(driveZoom(100, 250)));
      // In town the view is already close.
      expect(driveZoom(20, 50), zoomForSpeed(20));
    });

    test('changes gradually', () {
      final zoom = StepSmoother(0.1);
      expect(zoom.update(17), 17);
      expect(zoom.update(15), closeTo(16.9, 1e-9));
      expect(zoom.update(15), closeTo(16.8, 1e-9));
      expect(zoom.update(16.75), closeTo(16.75, 1e-9));
    });
  });

  group('heading smoothing', () {
    test('ignores jitter and follows real turns part of the way', () {
      final heading = AngleSmoother(deadbandDeg: 3, factor: 0.5);
      expect(heading.update(90), 90);
      expect(heading.update(92), 90);
      expect(heading.update(88.5), 90);
      expect(heading.update(110), 100);
      expect(heading.update(110), 105);
    });

    test('crosses north the short way', () {
      final heading = AngleSmoother(deadbandDeg: 3, factor: 0.5);
      heading.update(350);
      expect(heading.update(10), 0);
      expect(heading.update(10), 5);
      heading.reset();
      expect(heading.update(10), 10);
      expect(heading.update(350), 0);
    });
  });

  group('following', () {
    final t0 = DateTime(2026, 11, 27, 12);

    test('pauses on a touch and resumes by itself while moving', () {
      final follow = FollowState();
      expect(follow.following, isTrue);
      follow.userMoved(t0);
      expect(follow.paused, isTrue);
      expect(
        follow.tick(t0.add(const Duration(seconds: 5)), moving: true),
        isFalse,
      );
      // Standing at a light, however long: the driver is looking around.
      expect(
        follow.tick(t0.add(const Duration(seconds: 60)), moving: false),
        isFalse,
      );
      expect(follow.paused, isTrue);
      expect(
        follow.tick(t0.add(const Duration(seconds: 61)), moving: true),
        isTrue,
      );
      expect(follow.following, isTrue);
    });

    test('another touch restarts the wait; the button resumes at once', () {
      final follow = FollowState();
      follow.userMoved(t0);
      follow.userMoved(t0.add(const Duration(seconds: 8)));
      expect(
        follow.tick(t0.add(const Duration(seconds: 12)), moving: true),
        isFalse,
      );
      follow.resume();
      expect(follow.following, isTrue);
    });

    test('the location button cycles its modes', () {
      expect(nextLocationMode(LocationMode.free), LocationMode.centered);
      expect(nextLocationMode(LocationMode.centered), LocationMode.heading);
      expect(nextLocationMode(LocationMode.heading), LocationMode.centered);
    });
  });

  group('driving camera', () {
    test('sits behind the car: turned along the route and tilted', () {
      final camera = DriveCamera();
      final frame = camera.frame(
        point: shape[1],
        speedKmh: 50,
        tilt: true,
        maxPitch: 60,
        routeBearing: 90,
      );
      expect(frame.center, shape[1]);
      expect(frame.bearing, 90);
      expect(frame.pitch, tiltedPitch);
      expect(frame.zoom, zoomForSpeed(50));
      // The bearing follows a bend over a few updates, not at once.
      final next = camera.frame(
        point: shape[1],
        speedKmh: 50,
        tilt: true,
        maxPitch: 60,
        routeBearing: 140,
      );
      expect(next.bearing, greaterThan(100));
      expect(next.bearing, lessThan(140));
    });

    test('with 3D off stays flat and north-up but still follows', () {
      final frame = DriveCamera().frame(
        point: shape[2],
        speedKmh: 90,
        tilt: false,
        maxPitch: 60,
        routeBearing: 200,
      );
      expect(frame.center, shape[2]);
      expect(frame.bearing, 0);
      expect(frame.pitch, 0);
    });

    test('respects what the engine can tilt; falls back to the course', () {
      final frame = DriveCamera().frame(
        point: shape[0],
        speedKmh: 30,
        tilt: true,
        maxPitch: 40,
        courseDeg: 270,
      );
      expect(frame.pitch, 40);
      expect(frame.bearing, 270);
    });

    test('padding puts the car in the lower third under the banner', () {
      const view = Size(720, 686);
      final padding = drivePadding(view, top: 150, bottom: 64);
      // Centre of what the camera sees as free (the engine keeps the
      // bottom bar clear itself).
      final y = (padding.top + (view.height - 64)) / 2;
      final free = view.height - 150 - 64;
      expect(y, closeTo(150 + free * 2 / 3, 0.01));
      expect(padding.bottom, 0);
      expect(drivePadding(const Size(720, 100), top: 150), EdgeInsets.zero);
    });
  });
}
