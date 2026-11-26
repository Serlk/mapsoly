import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/traffic/yandex_tile_provider.dart';

void main() {
  test('equator maps to the same row in both projections', () {
    expect(ellipticalRow(2048, 12), closeTo(2048, 1e-6));
  });

  test('Moscow rows are shifted south by about three tiles at z12', () {
    // The tile fetched by hand for central Moscow: 3857 row 1280 -> 3395 row 1283.
    expect(ellipticalRow(1280, 12).floor(), 1283);
  });
}
