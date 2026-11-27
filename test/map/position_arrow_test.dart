import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/map/position_arrow.dart';

import '../ui_shots.dart';

void main() {
  testWidgets('every position marker paints, in both themes', (tester) async {
    for (final brightness in Brightness.values) {
      await shoot(
        tester,
        'position_arrows_${brightness.name}',
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final style in PositionArrow.values)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: PositionArrowIcon(style: style, size: 88),
                ),
              const Padding(
                padding: EdgeInsets.all(12),
                child: PositionArrowIcon(
                  style: PositionArrow.chevron,
                  size: 88,
                  headingDeg: 135,
                ),
              ),
            ],
          ),
        ),
        brightness: brightness,
      );
      expect(find.byType(PositionArrowIcon), findsNWidgets(5));
    }
    expect(PositionArrow.values.map((a) => a.label).toSet(), hasLength(4));
  });
}
