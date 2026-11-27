import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/map/steady_accuracy.dart';

void main() {
  final t0 = DateTime(2026, 11, 27, 12);
  DateTime at(int s) => t0.add(Duration(seconds: s));

  test('the circle does not breathe between scans', () {
    final steady = SteadyAccuracy();
    // A scan every 15 s gives 40 m; in between the estimate widens to 400.
    final drawn = <double>[];
    for (var s = 0; s < 120; s++) {
      final raw = 40.0 + (s % 15) * 25;
      drawn.add(steady.of(raw, at(s))!);
    }
    expect(drawn.toSet(), {40.0});
  });

  test('it grows once nothing has confirmed the position for a while', () {
    final steady = SteadyAccuracy();
    expect(steady.of(30, at(0)), 30);
    // No more fixes: the estimate only widens.
    expect(steady.of(200, at(20)), 30);
    expect(steady.of(600, at(44)), 30);
    expect(steady.of(700, at(50)), 200);
    expect(steady.of(900, at(70)), 600);
    expect(steady.of(2000, at(200)), 2000);
  });

  test('a better fix shows at once; no position forgets everything', () {
    final steady = SteadyAccuracy();
    expect(steady.of(300, at(0)), 300);
    expect(steady.of(8, at(1)), 8);
    expect(steady.of(null, at(2)), isNull);
    expect(steady.of(500, at(3)), 500);
  });
}
