import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/map/engine/maplibre/camera.dart';
import 'package:mapsoly/map/engine/maplibre/gestures.dart';

class _Host {
  MapCamera camera = const MapCamera(LatLng(55.752, 37.616), 14);
  final List<bool> animatedFlags = [];
  final List<Offset> longPresses = [];
  final List<bool> animating = [];
  static const size = Size(720, 686);

  late final gestures = MapGestures(
    camera: () => camera,
    setCamera: (c, {animated = false}) {
      camera = c;
      animatedFlags.add(animated);
    },
    onLongPress: longPresses.add,
    origin: () => size.center(Offset.zero),
    onAnimating: animating.add,
  );

  Offset fromCenter(Offset p) => p - size.center(Offset.zero);
}

void main() {
  test('one finger pans; the place under the finger stays under it', () {
    final h = _Host();
    const start = Offset(300, 300);
    final under = h.camera.latLngAt(h.fromCenter(start));
    h.gestures.pointerDown(1, start, 0);
    // Within the slop nothing moves.
    h.gestures.pointerMove(1, start + const Offset(4, 0), 0.01);
    expect(h.animatedFlags, isEmpty);
    h.gestures.pointerMove(1, start + const Offset(30, 0), 0.02);
    h.gestures.pointerMove(1, start + const Offset(80, 40), 0.20);
    h.gestures.pointerUp(1, start + const Offset(80, 40), 0.50);
    final shown = h.camera.screenOf(under) - h.fromCenter(start);
    // The first step (slop) is swallowed, the rest follows the finger.
    expect((shown - const Offset(76, 40)).distance, lessThan(1e-6));
    expect(h.gestures.flinging, isFalse); // the finger rested before lifting
  });

  test('a quick release flings and comes to rest', () {
    final h = _Host();
    h.gestures.pointerDown(1, const Offset(300, 300), 0);
    for (var i = 1; i <= 5; i++) {
      h.gestures.pointerMove(1, Offset(300 + 30.0 * i, 300), 0.016 * i);
    }
    final atRelease = h.camera;
    h.gestures.pointerUp(1, const Offset(450, 300), 0.085);
    expect(h.gestures.flinging, isTrue);
    expect(h.animating, [true]);
    var travelled = 0.0;
    for (var i = 0; i < 400 && h.gestures.flinging; i++) {
      h.gestures.advance(1 / 60);
    }
    travelled = atRelease.screenOf(h.camera.center).distance;
    expect(h.gestures.flinging, isFalse);
    expect(h.animating, [true, false]);
    // v0 = 1875 px/s, decay 0.3 s: about v0 * 0.3 px in total, to the west
    // (the content moved east with the finger).
    expect(travelled, closeTo(1875 * MapGestures.flingDecay, 30));
    expect(h.camera.center.longitude, lessThan(atRelease.center.longitude));
    // A new touch stops a fling at once.
    h.gestures.pointerDown(2, const Offset(10, 10), 5);
    expect(h.gestures.flinging, isFalse);
  });

  test('pinch zooms around the fingers and does not rotate', () {
    final h = _Host();
    const a = Offset(260, 300), b = Offset(460, 300);
    final mid = h.fromCenter((a + b) / 2);
    final under = h.camera.latLngAt(mid);
    h.gestures.pointerDown(1, a, 0);
    h.gestures.pointerDown(2, b, 0.01);
    // Spread to twice the distance, slightly tilted (5 degrees).
    h.gestures.pointerMove(1, const Offset(160, 291), 0.1);
    h.gestures.pointerMove(2, const Offset(560, 309), 0.1);
    expect(h.camera.zoom, closeTo(15, 0.01));
    expect(h.camera.bearing, 0);
    expect((h.camera.screenOf(under) - mid).distance, lessThan(1));
    h.gestures.pointerUp(1, const Offset(160, 291), 0.2);
    h.gestures.pointerUp(2, const Offset(560, 309), 0.2);
    expect(h.gestures.flinging, isFalse);
  });

  test('two fingers rotate once they turned past the threshold', () {
    final h = _Host();
    h.gestures.pointerDown(1, const Offset(260, 300), 0);
    h.gestures.pointerDown(2, const Offset(460, 300), 0.01);
    // Second finger goes around the first: 20, then 45 degrees clockwise
    // (y grows downwards on screen).
    Offset at(double deg) =>
        const Offset(260, 300) +
        Offset.fromDirection(deg * 3.14159265 / 180, 200);
    h.gestures.pointerMove(2, at(20), 0.1);
    expect(h.camera.bearing, 0); // this step only crossed the threshold
    h.gestures.pointerMove(2, at(45), 0.2);
    // The content turns with the fingers (clockwise), so the bearing drops.
    expect(h.camera.bearing, closeTo(-25, 0.01));
    expect(h.camera.zoom, closeTo(14, 0.01));
  });

  test('two fingers moving up together tilt the view', () {
    final h = _Host();
    h.gestures.pointerDown(1, const Offset(260, 400), 0);
    h.gestures.pointerDown(2, const Offset(460, 405), 0.01);
    h.gestures.pointerMove(1, const Offset(261, 380), 0.05);
    h.gestures.pointerMove(2, const Offset(459, 384), 0.05);
    final centre = h.camera.center;
    h.gestures.pointerMove(1, const Offset(261, 300), 0.2);
    h.gestures.pointerMove(2, const Offset(459, 304), 0.2);
    // About 90 px of travel once the tilt was recognised.
    expect(h.camera.pitch, closeTo(90 * MapGestures.pitchPerPixel, 5));
    expect(h.camera.zoom, 14);
    expect(h.camera.bearing, 0);
    expect(h.camera.center, centre);
    // Back down, and further than where it started: clamped at flat.
    h.gestures.pointerMove(1, const Offset(261, 600), 0.4);
    h.gestures.pointerMove(2, const Offset(459, 604), 0.4);
    expect(h.camera.pitch, 0);
  });

  test('a pinch with some vertical movement is not a tilt', () {
    final h = _Host();
    h.gestures.pointerDown(1, const Offset(300, 300), 0);
    h.gestures.pointerDown(2, const Offset(420, 300), 0.01);
    // Fingers move apart diagonally: one up, one down.
    h.gestures.pointerMove(1, const Offset(260, 260), 0.1);
    h.gestures.pointerMove(2, const Offset(460, 340), 0.1);
    expect(h.camera.pitch, 0);
    expect(h.camera.zoom, greaterThan(14.3));
  });

  // testWidgets runs on a fake clock, which the long-press timer needs.
  testWidgets('holding still is a long press; moving cancels it', (
    tester,
  ) async {
    final h = _Host();
    h.gestures.pointerDown(1, const Offset(100, 120), 0);
    await tester.pump(const Duration(milliseconds: 499));
    expect(h.longPresses, isEmpty);
    await tester.pump(const Duration(milliseconds: 2));
    expect(h.longPresses, [const Offset(100, 120)]);
    // The rest of that touch does nothing.
    final before = h.camera;
    h.gestures.pointerUp(1, const Offset(100, 120), 0.8);
    expect(h.camera, before);

    h.gestures.pointerDown(2, const Offset(100, 120), 2);
    h.gestures.pointerMove(2, const Offset(140, 120), 2.1);
    await tester.pump(const Duration(seconds: 1));
    h.gestures.pointerUp(2, const Offset(140, 120), 3.2);
    expect(h.longPresses, hasLength(1));
  });

  test('double tap zooms in one level around the tap, animated', () {
    final h = _Host();
    const tap = Offset(500, 200);
    final under = h.camera.latLngAt(h.fromCenter(tap));
    h.gestures.pointerDown(1, tap, 0);
    h.gestures.pointerUp(1, tap, 0.05);
    expect(h.animatedFlags, isEmpty);
    h.gestures.pointerDown(2, tap + const Offset(3, 2), 0.2);
    h.gestures.pointerUp(2, tap + const Offset(3, 2), 0.25);
    expect(h.camera.zoom, 15);
    expect(h.animatedFlags, [true]);
    expect(
      (h.camera.screenOf(under) - h.fromCenter(tap)).distance,
      lessThan(8),
    );
    // A third tap is a first tap again.
    h.gestures.pointerDown(3, tap, 0.4);
    h.gestures.pointerUp(3, tap, 0.45);
    expect(h.camera.zoom, 15);
  });

  test('two slow taps are not a double tap', () {
    final h = _Host();
    h.gestures.pointerDown(1, const Offset(200, 200), 0);
    h.gestures.pointerUp(1, const Offset(200, 200), 0.05);
    h.gestures.pointerDown(2, const Offset(200, 200), 0.6);
    h.gestures.pointerUp(2, const Offset(200, 200), 0.65);
    expect(h.camera.zoom, 14);
  });

  test('double tap and drag zooms continuously', () {
    final h = _Host();
    const tap = Offset(360, 343);
    h.gestures.pointerDown(1, tap, 0);
    h.gestures.pointerUp(1, tap, 0.05);
    h.gestures.pointerDown(2, tap, 0.2);
    h.gestures.pointerMove(
      2,
      tap + const Offset(0, MapGestures.dragPerZoomLevel * 1.5),
      0.4,
    );
    expect(h.camera.zoom, closeTo(15.5, 1e-9));
    h.gestures.pointerMove(
      2,
      tap + const Offset(0, -MapGestures.dragPerZoomLevel),
      0.6,
    );
    expect(h.camera.zoom, closeTo(13, 1e-9));
    h.gestures.pointerUp(2, tap, 0.7);
    expect(h.camera.zoom, closeTo(13, 1e-9)); // no extra step on release
    expect(h.animatedFlags.every((a) => !a), isTrue);
  });

  test('wheel zooms around the pointer', () {
    final h = _Host();
    const at = Offset(600, 100);
    final under = h.camera.latLngAt(h.fromCenter(at));
    h.gestures.scroll(at, -100);
    expect(h.camera.zoom, 14.5);
    expect(
      (h.camera.screenOf(under) - h.fromCenter(at)).distance,
      lessThan(1e-6),
    );
    h.gestures.scroll(at, 1000); // clamped to one step
    expect(h.camera.zoom, 14);
    expect(h.animatedFlags, [true, true]);
  });
}
