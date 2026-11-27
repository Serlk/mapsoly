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

  test('a large screen of low density goes down to 1', () {
    // 1600x2560 px at 1.27: 4.1 million pixels. Nothing between 1.27 and 1
    // fits the budget, so the map is drawn at its logical size.
    const view = Size(1600 / 1.27, 2560 / 1.27);
    expect(mapPixelRatio(1.27, view), 1.0);
    // ... and stays there whatever the bars take off the view.
    expect(mapPixelRatio(1.27, Size(view.width, view.height - 60)), 1.0);
    expect(mapPixelRatio(1.27, Size(view.width - 80, view.height)), 1.0);
    // The same screen in landscape.
    expect(mapPixelRatio(1.27, Size(view.height, view.width)), 1.0);
  });

  test('between 1 and the screen ratio the quarter grid still applies', () {
    // 1.4 million logical pixels at 1.27 are 2.26 million: just over. 1.25
    // makes 2.19 million, which fits.
    expect(mapPixelRatio(1.27, const Size(1400, 1000)), 1.25);
    // A view the budget covers is left alone.
    expect(mapPixelRatio(1.27, const Size(1200, 1000)), 1.27);
    // Well over: the floor.
    expect(mapPixelRatio(1.27, const Size(1600, 1000)), 1.0);
  });

  test('never coarser than 1, and never finer than the screen', () {
    expect(mapPixelRatio(3.0, const Size(3000, 2000)), 1.0);
    expect(mapPixelRatio(1.0, const Size(3000, 2000)), 1.0);
    expect(mapPixelRatio(0.75, const Size(4000, 3000)), 0.75);
    expect(mapPixelRatio(2.0, Size.zero), 2.0);
    for (final ratio in [1.0, 1.27, 1.5, 2.0, 2.75, 3.5]) {
      for (final side in [300.0, 800.0, 1300.0, 2500.0]) {
        final r = mapPixelRatio(ratio, Size(side, side * 1.6));
        expect(r, inInclusiveRange(1.0, ratio), reason: '$ratio, $side');
      }
    }
  });
}
