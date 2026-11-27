import 'dart:math' as math;

import 'package:flutter/material.dart';

/// How the position is drawn when its direction is known. Without a
/// direction it is always a dot.
enum PositionArrow {
  /// A navigation arrowhead with a notch at the back.
  chevron('Стрелка'),

  /// A dot with a beam of light in the direction faced.
  beam('Точка с лучом'),

  /// A drop: a round body with a pointed tip.
  drop('Капля'),

  /// A narrow, sharp arrow.
  dart('Острая стрелка');

  const PositionArrow(this.label);

  /// Name in the settings.
  final String label;
}

/// Draws [style] pointing up, filling a [size] square: [color] with an
/// [outline] edge so it shows on any map.
void paintPositionArrow(
  Canvas canvas,
  double size,
  PositionArrow style, {
  required Color color,
  required Color outline,
}) {
  final c = size / 2;
  final fill = Paint()
    ..color = color
    ..isAntiAlias = true;
  final edge = Paint()
    ..color = outline
    ..style = PaintingStyle.stroke
    ..strokeJoin = StrokeJoin.round
    ..strokeWidth = size * 0.075
    ..isAntiAlias = true;
  final shadow = Paint()
    ..color = const Color(0x40000000)
    ..maskFilter = MaskFilter.blur(BlurStyle.normal, size * 0.05);

  void shape(Path path) {
    canvas.drawPath(path.shift(Offset(0, size * 0.02)), shadow);
    canvas.drawPath(path, edge);
    canvas.drawPath(path, fill);
  }

  switch (style) {
    case PositionArrow.chevron:
      shape(
        Path()
          ..moveTo(c, size * 0.08)
          ..lineTo(size * 0.84, size * 0.88)
          ..lineTo(c, size * 0.68)
          ..lineTo(size * 0.16, size * 0.88)
          ..close(),
      );
    case PositionArrow.dart:
      shape(
        Path()
          ..moveTo(c, size * 0.04)
          ..lineTo(size * 0.72, size * 0.92)
          ..lineTo(c, size * 0.78)
          ..lineTo(size * 0.28, size * 0.92)
          ..close(),
      );
    case PositionArrow.drop:
      final r = size * 0.25;
      final centre = Offset(c, size * 0.62);
      // Tangents from the tip to the circle, then round the back.
      const tipY = 0.06;
      final d = centre.dy - size * tipY;
      final a = math.acos(r / d);
      shape(
        Path()
          ..moveTo(c, size * tipY)
          ..lineTo(centre.dx + r * math.sin(a), centre.dy - r * math.cos(a))
          ..arcToPoint(
            Offset(centre.dx - r * math.sin(a), centre.dy - r * math.cos(a)),
            radius: Radius.circular(r),
            largeArc: true,
          )
          ..close(),
      );
      canvas.drawCircle(centre, r * 0.36, Paint()..color = outline);
    case PositionArrow.beam:
      final centre = Offset(c, size * 0.62);
      final r = size * 0.18;
      // The beam: a sector fading away from the dot.
      final reach = size * 0.58;
      final beam = Path()
        ..moveTo(centre.dx, centre.dy)
        ..arcTo(
          Rect.fromCircle(center: centre, radius: reach),
          -math.pi / 2 - 0.5,
          1.0,
          false,
        )
        ..close();
      canvas.drawPath(
        beam,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: 0.75),
              color.withValues(alpha: 0.0),
            ],
          ).createShader(Rect.fromCircle(center: centre, radius: reach)),
      );
      canvas.drawCircle(centre.translate(0, size * 0.02), r, shadow);
      canvas.drawCircle(centre, r, fill);
      canvas.drawCircle(centre, r, edge);
  }
}

/// [paintPositionArrow] as a widget, turned to [headingDeg].
class PositionArrowIcon extends StatelessWidget {
  const PositionArrowIcon({
    super.key,
    required this.style,
    this.size = 44,
    this.headingDeg = 0,
    this.color,
  });

  final PositionArrow style;
  final double size;
  final double headingDeg;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Transform.rotate(
      angle: headingDeg * math.pi / 180,
      child: CustomPaint(
        size: Size.square(size),
        painter: _ArrowPainter(style, color ?? colors.primary, colors.surface),
      ),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  const _ArrowPainter(this.style, this.color, this.outline);

  final PositionArrow style;
  final Color color, outline;

  @override
  void paint(Canvas canvas, Size size) => paintPositionArrow(
    canvas,
    size.shortestSide,
    style,
    color: color,
    outline: outline,
  );

  @override
  bool shouldRepaint(_ArrowPainter old) =>
      old.style != style || old.color != color || old.outline != outline;
}
