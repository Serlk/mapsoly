import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/map/engine/maplibre_engine.dart';

void main() {
  ({int ms, bool linear}) plan({
    int? requested,
    int? sinceLast,
    double distance = 100,
    double zoomChange = 0,
  }) => planCameraMove(
    requestedMs: requested,
    sinceLastMoveMs: sinceLast,
    screenDistance: distance,
    zoomChange: zoomChange,
    viewSide: 720,
  );

  test('an explicit duration is taken as it is', () {
    expect(plan(requested: 0, sinceLast: 1000), (ms: 0, linear: false));
    expect(plan(requested: 2000, distance: 99999), (ms: 2000, linear: false));
  });

  test('a single short hop eases, a far target jumps', () {
    expect(plan(), (ms: 350, linear: false));
    expect(plan(sinceLast: 5000), (ms: 350, linear: false));
    expect(plan(distance: 1500), (ms: 0, linear: false));
    expect(plan(zoomChange: 3), (ms: 0, linear: false));
  });

  test('a steady stream of updates blends into constant motion', () {
    // About once a second: each move lasts a little longer than the gap to
    // the next, so the camera never stops in between.
    final p = plan(sinceLast: 1000);
    expect(p.linear, isTrue);
    expect(p.ms, greaterThan(1000));
    expect(p.ms, lessThan(1300));
    expect(plan(sinceLast: 200).ms, 250); // not shorter than this
    // A burst of calls in one frame is not a stream.
    expect(plan(sinceLast: 5), (ms: 350, linear: false));
    // Even in a stream, a far jump stays a jump.
    expect(plan(sinceLast: 1000, distance: 5000), (ms: 0, linear: false));
  });
}
