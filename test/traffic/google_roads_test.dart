import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/traffic/traffic.dart';

void main() {
  test('only traffic colours survive in a Google tile', () {
    const pixels = [
      [0, 216, 144, 255], // free
      [240, 192, 48, 255], // slow
      [240, 72, 48, 255], // heavy
      [128, 31, 31, 255], // jam
      [150, 150, 150, 255], // a road without data
      [240, 216, 168, 255], // a motorway of the base map
      [255, 255, 255, 255], // a label halo
      [20, 20, 20, 255], // label text
      [0, 0, 0, 0], // nothing
    ];
    final rgba = Uint8List.fromList([for (final p in pixels) ...p]);
    keepTrafficColours(rgba);
    List<int> at(int i) => rgba.sublist(i * 4, i * 4 + 4);
    for (var i = 0; i < 4; i++) {
      expect(at(i), pixels[i], reason: 'traffic colour $i');
    }
    for (var i = 4; i < pixels.length; i++) {
      expect(at(i), [0, 0, 0, 0], reason: 'pixel $i');
    }
  });

  test('kept pixels are premultiplied on request', () {
    final rgba = Uint8List.fromList([240, 72, 48, 128]);
    keepTrafficColours(rgba, premultiply: true);
    expect(rgba, [120, 36, 24, 128]);
  });
}
