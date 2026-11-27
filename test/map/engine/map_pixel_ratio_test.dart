import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/map/engine/maplibre/surface_android.dart';

void main() {
  test('a phone-sized map is drawn at every pixel', () {
    // 1080x2400 at 2.75 is under the budget once the bars are off.
    expect(mapPixelRatio(2.75, const Size(392, 700)), 2.75);
    expect(mapPixelRatio(2.0, const Size(480, 480)), 2.0);
  });

  test('a large dense screen gets a smaller picture, in quarter steps', () {
    // A 2560x1600 tablet at density 2: four million pixels asked for.
    final r = mapPixelRatio(2.0, const Size(1280, 800));
    expect(r, 1.25);
    expect(1280 * 800 * r * r, lessThanOrEqualTo(2.2e6));
    // 1920x1200 at 1.5 is a little over: one step down.
    expect(mapPixelRatio(1.5, const Size(1280, 800)), 1.25);
    // A few pixels more or less do not change it.
    expect(
      mapPixelRatio(2.0, const Size(1280, 752)),
      mapPixelRatio(2.0, const Size(1280, 760)),
    );
  });

  test('never coarser than 1.25, and never finer than the screen', () {
    expect(mapPixelRatio(3.0, const Size(3000, 2000)), 1.25);
    expect(mapPixelRatio(1.0, const Size(3000, 2000)), 1.0);
    expect(mapPixelRatio(2.0, Size.zero), 2.0);
  });
}
