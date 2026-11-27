import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/positioning/sources/linux_compass.dart';

typedef V = ({double x, double y, double z});

void main() {
  // A field like the one in St Petersburg: weak towards north, strong down.
  // In a frame with x east, y north, z up it is (0, 0.15, -0.5).
  const up = (x: 0.0, y: 0.0, z: 9.8);

  test('lying flat: the direction of the top edge', () {
    // Top edge to the north: the device frame is the world frame.
    expect(compassHeading((x: 0, y: 0.15, z: -0.5), up), closeTo(0, 1e-6));
    // Top edge to the east: north is to the left of the screen (-x).
    expect(compassHeading((x: -0.15, y: 0, z: -0.5), up), closeTo(90, 1e-6));
    // To the south, to the west.
    expect(compassHeading((x: 0, y: -0.15, z: -0.5), up), closeTo(180, 1e-6));
    expect(compassHeading((x: 0.15, y: 0, z: -0.5), up), closeTo(270, 1e-6));
  });

  test('upright in a mount: where the back of the device faces', () {
    // Screen towards the driver, top edge up. Gravity reaction along +y;
    // the back (-z) faces north, so north is -z and the sky is +y.
    const upright = (x: 0.0, y: 9.8, z: 0.0);
    expect(
      compassHeading((x: 0, y: -0.5, z: -0.15), upright),
      closeTo(0, 1e-6),
    );
    // The back faces east: screen right (+x) then points south.
    expect(
      compassHeading((x: -0.15, y: -0.5, z: 0), upright),
      closeTo(90, 1e-6),
    );
  });

  test('no direction in free fall or with the field along gravity', () {
    expect(
      compassHeading((x: 0, y: 0.15, z: -0.5), (x: 0, y: 0, z: 0)),
      isNull,
    );
    expect(compassHeading((x: 0, y: 0, z: -0.5), up), isNull);
  });

  test('reads the IIO sensors from sysfs', () async {
    final root = Directory.systemTemp.createTempSync('mapsoly-iio');
    addTearDown(() => root.deleteSync(recursive: true));
    void device(String name, String axis, List<num> v) {
      final d = Directory('${root.path}/$name')..createSync();
      for (final (i, a) in ['x', 'y', 'z'].indexed) {
        File('${d.path}/in_${axis}_${a}_raw').writeAsStringSync('${v[i]}\n');
      }
    }

    void name(String device, String value) =>
        File('${root.path}/$device/name').writeAsStringSync('$value\n');

    final none = IioCompass(root: root.path);
    expect(none.available(), isFalse);
    expect(IioCompass.sensors('magn', root: root.path), isEmpty);
    device('iio:device1', 'accel', [0, 0, 9052]);
    device('iio:device3', 'magn', [-15000, 0, -48000]);
    // A second magnetometer, pointing elsewhere, to choose between.
    device('iio:device7', 'magn', [0, 15000, -48000]);
    name('iio:device3', 'hub-magn');
    name('iio:device7', 'spare-magn');
    expect(IioCompass.sensors('magn', root: root.path), [
      'hub-magn',
      'spare-magn',
    ]);
    // Without a name file the directory name is shown.
    expect(IioCompass.sensors('accel', root: root.path), ['iio:device1']);
    final spare = IioCompass(root: root.path, magnetName: 'spare-magn');
    final spareFirst = spare.headings.first;
    await spare.start();
    expect(await spareFirst, closeTo(0, 1e-6));
    await spare.stop();
    expect(
      IioCompass(root: root.path, magnetName: 'gone').available(),
      isFalse,
    );
    final compass = IioCompass(root: root.path);
    expect(compass.available(), isTrue);
    final first = compass.headings.first;
    await compass.start();
    expect(await first, closeTo(90, 1e-6));
    await compass.stop();
  });
}
