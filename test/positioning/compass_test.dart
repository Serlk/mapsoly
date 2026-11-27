import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/positioning/sources/linux_compass.dart';

void main() {
  test('small wobble is ignored', () {
    final s = HeadingSmoother();
    expect(s.add(100), 100);
    expect(s.add(101.5), 100);
    expect(s.add(98.2), 100);
  });

  test('a real turn is followed gradually', () {
    final s = HeadingSmoother();
    s.add(0);
    var v = 0.0;
    for (var i = 0; i < 30; i++) {
      v = s.add(90);
    }
    expect(v, closeTo(90, 3.1));
    expect(s.add(90), lessThanOrEqualTo(90));
  });

  test('crosses north the short way', () {
    final s = HeadingSmoother();
    s.add(350);
    final v = s.add(10);
    // Towards 360, not back through 180.
    expect(v, greaterThan(350));
    for (var i = 0; i < 40; i++) {
      s.add(10);
    }
    expect((s.value! - 10).abs(), lessThan(3.1));
  });

  test('reset forgets the last value', () {
    final s = HeadingSmoother()..add(200);
    s.reset();
    expect(s.value, isNull);
    expect(s.add(20), 20);
  });
}
