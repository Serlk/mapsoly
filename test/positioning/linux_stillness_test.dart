import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/positioning/positioning.dart';

void main() {
  test('a resting sensor is still, a shaken one is not', () {
    final d = StillnessDetector();
    final rnd = math.Random(1);
    double noise(double s) => (rnd.nextDouble() * 2 - 1) * s;
    // Sensor noise of a phone on a table: a few hundredths of a m/s^2.
    bool? state;
    for (var i = 0; i < 16; i++) {
      state = d.add(0.3 + noise(0.03), 1.2 + noise(0.03), 9.31 + noise(0.04));
    }
    expect(state, isTrue);
    expect(d.still, isTrue);
    // In a car: engine and road, tenths of a m/s^2.
    bool? changed;
    for (var i = 0; i < 16; i++) {
      changed =
          d.add(0.3 + noise(0.5), 1.2 + noise(0.5), 9.31 + noise(0.6)) ??
          changed;
    }
    expect(changed, isFalse);
    expect(d.still, isFalse);
  });

  test('nothing is said before the window has filled', () {
    final d = StillnessDetector();
    for (var i = 0; i < 15; i++) {
      expect(d.add(0, 0, 9.81), isNull);
    }
    expect(d.still, isNull);
  });

  group('sysfs', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('mapsoly-iio'));
    tearDown(() => root.deleteSync(recursive: true));

    void device(String id, String name, {bool accel = true, String? scale}) {
      final d = Directory('${root.path}/$id')..createSync();
      File('${d.path}/name').writeAsStringSync('$name\n');
      if (accel) {
        File('${d.path}/in_accel_x_raw').writeAsStringSync('301\n');
        File('${d.path}/in_accel_y_raw').writeAsStringSync('1220\n');
        File('${d.path}/in_accel_z_raw').writeAsStringSync('9315\n');
      }
      if (scale != null) {
        File('${d.path}/in_accel_scale').writeAsStringSync('$scale\n');
      }
    }

    test('the plain accelerometer is preferred to the linear one', () {
      device('iio:device0', 'hub-linear-accel');
      device('iio:device1', 'hub-accel');
      device('iio:device2', 'hub-gyro', accel: false);
      expect(IioStillness.find(root.path)!.path, endsWith('iio:device1'));
      expect(IioStillness.find('${root.path}/none'), isNull);
    });

    test('scale: from the driver, else guessed from gravity', () {
      device('iio:device0', 'a', scale: '0.0048');
      device('iio:device1', 'b');
      final withScale = Directory('${root.path}/iio:device0');
      final without = Directory('${root.path}/iio:device1');
      expect(IioStillness.scaleOf(withScale, 2040), 0.0048);
      expect(IioStillness.scaleOf(without, 9400), 0.001); // mm/s^2
      expect(IioStillness.scaleOf(without, 9.8), 1);
    });

    test('the stream reports a resting device as still', () async {
      device('iio:device1', 'hub-accel');
      final states = IioStillness(
        root: root.path,
        period: const Duration(milliseconds: 2),
      ).states;
      expect(await states.first.timeout(const Duration(seconds: 5)), isTrue);
    });
  });
}
