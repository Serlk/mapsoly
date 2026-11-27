import 'package:flutter/material.dart';

/// Decides when the bottom bar and the map buttons get out of the way:
/// while the car is moving they are hidden, and a touch brings them back
/// for a few seconds.
class DriveChrome {
  DriveChrome({
    this.startKmh = 10,
    this.stopKmh = 3,
    this.stopAfter = const Duration(seconds: 4),
  });

  /// Faster than this the car is moving; slower than [stopKmh] for
  /// [stopAfter] it has stopped. The gap keeps a traffic jam from flashing
  /// the controls on and off.
  final double startKmh, stopKmh;
  final Duration stopAfter;

  /// How long a touch keeps the controls on screen.
  static const revealFor = Duration(seconds: 6);

  bool _moving = false;
  DateTime? _slowSince;
  bool _revealed = false;

  bool get moving => _moving;

  /// Feeds the current speed; null means it is not known.
  void update(double? speedKmh, DateTime now) {
    final speed = speedKmh ?? 0;
    if (speed >= startKmh) {
      _moving = true;
      _slowSince = null;
    } else if (_moving && speed < stopKmh) {
      final since = _slowSince ??= now;
      if (now.difference(since) >= stopAfter) {
        _moving = false;
        _slowSince = null;
        _revealed = false;
      }
    } else {
      _slowSince = null;
    }
  }

  /// The screen was touched: the controls are back until [conceal].
  void reveal() => _revealed = true;

  /// The touch was [revealFor] ago.
  void conceal() => _revealed = false;

  /// Driving ended: everything is shown again.
  void reset() {
    _moving = false;
    _slowSince = null;
    _revealed = false;
  }

  bool get hidden => _moving && !_revealed;
}

/// How far over the limit the driver is.
enum Speeding { none, over, far }

/// [margin] is where "far" begins: fines in Russia start at +20 km/h.
Speeding speedingOf(double speedKmh, int? limitKmh, {int margin = 20}) {
  if (limitKmh == null) return Speeding.none;
  final shown = speedKmh.round();
  if (shown > limitKmh + margin) return Speeding.far;
  if (shown > limitKmh) return Speeding.over;
  return Speeding.none;
}

/// The current speed in a round badge, with the road's limit as a road
/// sign next to it. Over the limit the figure turns red; far over it the
/// whole badge does.
class Speedometer extends StatelessWidget {
  const Speedometer({
    super.key,
    required this.speedKmh,
    this.limitKmh,
    this.limitPosted = true,
    this.signFirst = false,
  });

  final double speedKmh;
  final int? limitKmh;

  /// False when the limit is the general rule for this kind of road and
  /// not a mapped sign: the sign is then drawn paler.
  final bool limitPosted;

  /// The sign to the left of the speed: for the right edge of the screen,
  /// where the speed itself keeps the corner.
  final bool signFirst;

  static const double size = 76;
  static const double signSize = 54;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final speeding = speedingOf(speedKmh, limitKmh);
    final far = speeding == Speeding.far;
    // The same strong red in both themes: it has to be noticed.
    const alarm = Color(0xFFD32F2F);
    final background = far ? alarm : colors.surface.withValues(alpha: 0.94);
    final figure = switch (speeding) {
      Speeding.far => Colors.white,
      Speeding.over => colors.error,
      Speeding.none => colors.onSurface,
    };
    final limit = limitKmh;
    return Semantics(
      label: limit == null
          ? 'Скорость ${speedKmh.round()} километров в час'
          : 'Скорость ${speedKmh.round()}, ограничение $limit',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (limit != null && signFirst)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: SpeedLimitSign(limitKmh: limit, posted: limitPosted),
              ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: background,
                shape: BoxShape.circle,
                border: Border.all(
                  color: speeding == Speeding.none
                      ? colors.outlineVariant
                      : colors.error,
                  width: speeding == Speeding.none ? 1 : 2,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              alignment: Alignment.center,
              padding: const EdgeInsets.all(6),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${speedKmh.round()}',
                      style: TextStyle(
                        fontSize: 30,
                        height: 1,
                        fontWeight: FontWeight.w700,
                        color: figure,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'км/ч',
                      style: TextStyle(
                        fontSize: 11,
                        height: 1,
                        color: far ? Colors.white : colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (limit != null && !signFirst)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: SpeedLimitSign(limitKmh: limit, posted: limitPosted),
              ),
          ],
        ),
      ),
    );
  }
}

/// A speed limit drawn as the road sign: the same in both themes, because
/// that is how it looks on the road.
class SpeedLimitSign extends StatelessWidget {
  const SpeedLimitSign({
    super.key,
    required this.limitKmh,
    this.posted = true,
    this.size = Speedometer.signSize,
  });

  final int limitKmh;

  /// A mapped limit has the full red ring; one that follows from the
  /// general rule (no sign in the map data) a paler one.
  final bool posted;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(
          color: posted ? const Color(0xFFD32F2F) : const Color(0xFFE39A9A),
          width: size * 0.11,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        '$limitKmh',
        style: TextStyle(
          fontSize: limitKmh >= 100 ? size * 0.34 : size * 0.4,
          height: 1,
          fontWeight: FontWeight.w700,
          color: Colors.black,
        ),
      ),
    );
  }
}
