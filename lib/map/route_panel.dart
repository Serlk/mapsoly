import 'package:flutter/material.dart' hide Route;
import 'package:latlong2/latlong.dart';

import '../places/camera_alert.dart';
import '../routing/valhalla_client.dart';
import 'route_controller.dart';
import 'ui_kit.dart';

String _pointLabel(LatLng p) =>
    '${p.latitude.toStringAsFixed(4)}, ${p.longitude.toStringAsFixed(4)}';

const costingIcons = {
  RouteCosting.auto: Icons.directions_car_outlined,
  RouteCosting.pedestrian: Icons.directions_walk,
  RouteCosting.bicycle: Icons.directions_bike,
};
const costingNames = {
  RouteCosting.auto: 'На машине',
  RouteCosting.pedestrian: 'Пешком',
  RouteCosting.bicycle: 'На велосипеде',
};

/// Car / walk / bike as one segmented control. [compact] shows icons only
/// (on the map card); otherwise icons with names.
class CostingSwitch extends StatelessWidget {
  const CostingSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.compact = false,
  });

  final RouteCosting value;
  final ValueChanged<RouteCosting> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<RouteCosting>(
      showSelectedIcon: false,
      style: Ui.segmented(height: 52, side: compact ? 10 : 12),
      segments: [
        for (final c in RouteCosting.values)
          ButtonSegment(
            value: c,
            icon: Icon(costingIcons[c], semanticLabel: costingNames[c]),
            label: compact ? null : Text(costingNames[c]!),
            tooltip: compact ? costingNames[c] : null,
          ),
      ],
      selected: {value},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

/// "Дом — Казань", "Моё местоположение — 2 остановки — Казань".
String tripLine(List<RouteStop> stops) {
  if (stops.isEmpty) return '';
  if (stops.length == 1) return stopTitle(stops.first);
  final between = stops.length - 2;
  return [
    stopTitle(stops.first),
    if (between > 0) plural(between, 'остановка', 'остановки', 'остановок'),
    stopTitle(stops.last),
  ].join(' — ');
}

/// The route on the map, in short: the travel time as the one large figure,
/// where it goes, the alternatives and the button that starts guidance.
/// Editing the stops happens in the planner ([onPlan]).
class RoutePanel extends StatelessWidget {
  const RoutePanel({
    super.key,
    required this.controller,
    this.onPlan,
    this.now,
  });

  final RouteController controller;

  /// Opens the trip planner (stops, order, saving).
  final VoidCallback? onPlan;

  /// Clock for the arrival time (tests pin it).
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final route = controller.selected;
    final routes = controller.routes;
    final selected = controller.selectedIndex;
    final quiet = theme.textTheme.bodyMedium?.copyWith(
      color: colors.onSurfaceVariant,
    );

    // The headline: the time, or what is going on instead of it.
    final Widget headline;
    if (route != null) {
      final time = controller.timeOf(selected);
      final arrive = (now?.call() ?? DateTime.now()).add(time);
      final free = controller.trafficTime(selected) != null
          ? ' · без пробок ${formatDuration(route.duration)}'
          : '';
      headline = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            formatDuration(time),
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            '${formatDistance(route.lengthMeters)} · '
            'прибытие в ${formatClock(arrive)}$free',
            maxLines: 2,
            style: quiet,
          ),
        ],
      );
    } else {
      final error = controller.error;
      final text = controller.loading
          ? 'Строю маршрут…'
          : error ??
                (controller.needStart
                    ? 'Откуда поедем?'
                    : controller.to == null
                    ? 'Куда поедем?'
                    : '');
      headline = Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          text,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(
            color: error != null && !controller.loading ? colors.error : null,
          ),
        ),
      );
    }

    return Glass(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Ui.pad, 6, 6, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: headline,
                  ),
                ),
                Ui.iconButton(
                  icon: Icons.close,
                  label: 'Убрать маршрут',
                  size: 48,
                  onPressed: controller.clear,
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Where the trip goes; a tap opens the planner.
            InkWell(
              borderRadius: BorderRadius.circular(Ui.radiusSmall),
              onTap: onPlan,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        controller.needStart
                            ? 'Начало не выбрано — '
                                  '${tripLine(controller.stops)}'
                            : tripLine(controller.stops),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                    if (onPlan != null) ...[
                      const SizedBox(width: Ui.gap),
                      Text(
                        controller.needStart ? 'Выбрать' : 'Изменить',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: colors.primary,
                        ),
                      ),
                      Icon(Icons.chevron_right, color: colors.primary),
                    ],
                  ],
                ),
              ),
            ),
            // Alternatives never wrap: the row scrolls sideways.
            if (routes.length > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < routes.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: Ui.gap),
                          child: ChoiceChip(
                            showCheckmark: false,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 10,
                            ),
                            label: Text(
                              '${formatDuration(controller.timeOf(i))} · '
                              '${formatDistance(routes[i].lengthMeters)}',
                            ),
                            selected: i == selected,
                            onSelected: (_) => controller.select(i),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Row(
                children: [
                  CostingSwitch(
                    compact: true,
                    value: controller.costing,
                    onChanged: controller.setCosting,
                  ),
                  const SizedBox(width: Ui.gap),
                  Expanded(
                    child: FilledButton.icon(
                      // Narrow cards (tall phones) leave it little room.
                      style: Ui.filled.copyWith(
                        padding: const WidgetStatePropertyAll(
                          EdgeInsets.symmetric(horizontal: 12),
                        ),
                      ),
                      onPressed: route == null
                          ? null
                          : controller.startGuidance,
                      icon: const Icon(Icons.navigation),
                      label: const Text('Поехали'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Card shown for a point picked on the map or found by search: go there
/// (the primary action), or use it another way.
class PickedPointCard extends StatelessWidget {
  const PickedPointCard({
    super.key,
    required this.point,
    this.label,
    required this.onFrom,
    required this.onTo,
    required this.onClose,
    this.onAddStop,
    this.onSave,
  });

  final LatLng point;

  /// Name of the place when it came from search.
  final String? label;
  final VoidCallback onFrom, onTo, onClose;

  /// Adds the point to the trip being planned; null when there is none.
  final VoidCallback? onAddStop;

  /// Keeps the point among the saved places.
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Glass(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Ui.pad, 6, 6, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 6),
                    child: Text(
                      label ?? 'Точка ${_pointLabel(point)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ),
                Ui.iconButton(
                  icon: Icons.close,
                  label: 'Закрыть',
                  size: 48,
                  onPressed: onClose,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: Ui.filled,
                      onPressed: onTo,
                      icon: const Icon(Icons.navigation),
                      label: const Text('Сюда'),
                    ),
                  ),
                  const SizedBox(width: Ui.gap),
                  OutlinedButton(
                    style: Ui.outlined,
                    onPressed: onFrom,
                    child: const Text('Отсюда'),
                  ),
                ],
              ),
            ),
            // Used less often: quiet, but with words, not bare icons.
            if (onAddStop != null || onSave != null)
              Wrap(
                children: [
                  if (onAddStop != null)
                    TextButton.icon(
                      style: Ui.text,
                      onPressed: onAddStop,
                      icon: const Icon(Icons.add_location_alt_outlined),
                      label: const Text('Заехать'),
                    ),
                  if (onSave != null)
                    TextButton.icon(
                      style: Ui.text,
                      onPressed: onSave,
                      icon: const Icon(Icons.star_outline),
                      label: const Text('Сохранить место'),
                    ),
                ],
              )
            else
              const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}

/// The arrow for a maneuver.
IconData maneuverIcon(ManeuverType type) => switch (type) {
  ManeuverType.start ||
  ManeuverType.startRight ||
  ManeuverType.startLeft => Icons.navigation,
  ManeuverType.destination ||
  ManeuverType.destinationRight ||
  ManeuverType.destinationLeft => Icons.flag,
  ManeuverType.slightRight => Icons.turn_slight_right,
  ManeuverType.right => Icons.turn_right,
  ManeuverType.sharpRight => Icons.turn_sharp_right,
  ManeuverType.uturnRight => Icons.u_turn_right,
  ManeuverType.uturnLeft => Icons.u_turn_left,
  ManeuverType.sharpLeft => Icons.turn_sharp_left,
  ManeuverType.left => Icons.turn_left,
  ManeuverType.slightLeft => Icons.turn_slight_left,
  ManeuverType.rampRight || ManeuverType.exitRight => Icons.ramp_right,
  ManeuverType.rampLeft || ManeuverType.exitLeft => Icons.ramp_left,
  ManeuverType.stayRight => Icons.fork_right,
  ManeuverType.stayLeft => Icons.fork_left,
  ManeuverType.merge ||
  ManeuverType.mergeRight ||
  ManeuverType.mergeLeft => Icons.merge,
  ManeuverType.roundaboutEnter => Icons.roundabout_left,
  ManeuverType.roundaboutExit => Icons.roundabout_right,
  ManeuverType.ferryEnter ||
  ManeuverType.ferryExit => Icons.directions_boat_outlined,
  _ => Icons.straight,
};

bool _isArrival(ManeuverType t) =>
    t == ManeuverType.destination ||
    t == ManeuverType.destinationRight ||
    t == ManeuverType.destinationLeft;

/// Guidance banner: the most important thing on the screen while driving.
///
/// With a position fix: the arrow of the next maneuver, the distance to it
/// as the one large figure and the street, then a quiet line with what is
/// left of the trip, the arrival time and the speed; the next camera when
/// it is close. Without a fix the maneuvers are stepped through by hand.
///
/// Ending the route takes two taps: the small cross, then "Завершить".
class GuidanceBanner extends StatelessWidget {
  const GuidanceBanner({
    super.key,
    required this.controller,
    this.confirmingEnd = false,
    this.onAskEnd,
    this.onCancelEnd,
    this.onEnd,
    this.now,
  });

  final RouteController controller;

  /// True while the "end the route?" question is shown.
  final bool confirmingEnd;
  final VoidCallback? onAskEnd, onCancelEnd;

  /// Ends guidance; defaults to [RouteController.stopGuidance].
  final VoidCallback? onEnd;

  /// Clock for the arrival time (tests pin it).
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final route = controller.selected!;
    final steps = route.maneuvers.toList();
    final i = controller.step.clamp(0, steps.length - 1);
    final progress = controller.progress;
    final notice = controller.stopNotice;
    final quiet = theme.textTheme.bodyMedium?.copyWith(
      color: colors.onSurfaceVariant,
    );

    // What the arrow tile and the two main lines say.
    Maneuver shown;
    IconData? icon;
    var stopInTile = false;
    String? figure;
    String title;
    String detail;
    if (progress != null) {
      final next = i + 1 < steps.length ? steps[i + 1] : null;
      shown = next ?? steps[i];
      final toNext = next == null
          ? (controller.remainingM ?? 0)
          : controller.alongOf(next.beginShapeIndex) - progress.alongM;
      figure = formatDistance(toNext < 0 ? 0 : toNext);
      title = shown.streetNames.isNotEmpty && !_isArrival(shown.type)
          ? shown.streetNames.first
          : shown.instruction;
      // An arrival in the middle of the trip is a stop, not the end.
      if (notice != null &&
          !notice.reached &&
          (_isArrival(shown.type) || notice.distanceM <= 60)) {
        icon = Icons.flag;
        stopInTile = true;
        figure = formatDistance(notice.distanceM);
        title = 'Остановка: ${stopTitle(notice.stop)}';
      }
      final left = controller.remainingM ?? 0;
      final total = route.lengthMeters;
      final time = controller.timeOf(controller.selectedIndex);
      final timeLeft = total <= 0
          ? Duration.zero
          : Duration(seconds: (time.inSeconds * left / total).round());
      final arrive = (now?.call() ?? DateTime.now()).add(timeLeft);
      final speed = controller.speedKmh;
      detail = [
        formatDistance(left),
        'прибытие в ${formatClock(arrive)}',
        if (speed != null) '${speed.round()} км/ч',
      ].join(' · ');
    } else {
      shown = steps[i];
      var remaining = 0.0;
      for (var k = i; k < steps.length; k++) {
        remaining += steps[k].lengthMeters;
      }
      title = shown.instruction;
      detail =
          'Шаг ${i + 1} из ${steps.length} · '
          'осталось ${formatDistance(remaining)}';
    }

    final camera = controller.nextCamera;
    final cameraDistance = controller.nextCameraDistanceM;
    final showCamera =
        progress != null &&
        camera != null &&
        cameraDistance != null &&
        cameraDistance < 1500;
    final limit = camera?.camera.maxSpeedKmh;
    final speeding = controller.speeding;

    Widget pill({
      required IconData icon,
      required String text,
      Color? background,
      Color? foreground,
      bool strong = false,
    }) => Container(
      margin: const EdgeInsets.only(top: Ui.gap),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: background ?? colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Ui.radiusSmall),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 22, color: foreground ?? colors.onSurface),
          const SizedBox(width: Ui.gap),
          Flexible(
            child: Text(
              text,
              style: theme.textTheme.titleSmall?.copyWith(
                color: foreground ?? colors.onSurface,
                fontWeight: strong ? FontWeight.w700 : null,
              ),
            ),
          ),
        ],
      ),
    );

    return Glass(
      opacity: 0.92,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 4, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: colors.primary,
                    borderRadius: BorderRadius.circular(Ui.radius),
                  ),
                  child: Icon(
                    icon ?? maneuverIcon(shown.type),
                    size: 42,
                    color: colors.onPrimary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 64),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (figure != null)
                          Text(
                            figure,
                            style: theme.textTheme.headlineMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              height: 1.1,
                            ),
                          ),
                        Text(
                          title,
                          maxLines: figure == null ? 3 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ),
                ),
                // Small and in the far corner: not where the thumb rests.
                if (!confirmingEnd)
                  IconButton(
                    tooltip: 'Завершить маршрут',
                    iconSize: 22,
                    color: colors.onSurfaceVariant,
                    constraints: const BoxConstraints.tightFor(
                      width: 48,
                      height: 48,
                    ),
                    icon: const Icon(Icons.close),
                    onPressed: onAskEnd ?? onEnd ?? controller.stopGuidance,
                  )
                else
                  const SizedBox(width: 8),
              ],
            ),
            if (confirmingEnd)
              Padding(
                padding: const EdgeInsets.only(top: Ui.gap, right: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Завершить маршрут?',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    TextButton(
                      style: Ui.text,
                      onPressed: onCancelEnd,
                      child: const Text('Нет, едем'),
                    ),
                    const SizedBox(width: Ui.gap),
                    FilledButton.tonal(
                      style: Ui.filled,
                      onPressed: onEnd ?? controller.stopGuidance,
                      child: const Text('Завершить'),
                    ),
                  ],
                ),
              )
            else if (progress == null)
              // No position: the driver turns the pages.
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 8),
                child: Row(
                  children: [
                    Expanded(child: Text(detail, style: quiet)),
                    Ui.iconButton(
                      icon: Icons.chevron_left,
                      label: 'Предыдущий манёвр',
                      size: 52,
                      onPressed: i > 0
                          ? () => controller.goToStep(i - 1)
                          : null,
                    ),
                    Ui.iconButton(
                      icon: Icons.chevron_right,
                      label: 'Следующий манёвр',
                      size: 52,
                      onPressed: i < steps.length - 1
                          ? () => controller.goToStep(i + 1)
                          : null,
                    ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: Ui.gap, right: 8),
                child: Text(detail, style: quiet),
              ),
            if (notice != null && !stopInTile && !confirmingEnd)
              pill(
                icon: Icons.flag_outlined,
                text: notice.reached
                    ? 'Остановка ${notice.number}: ${stopTitle(notice.stop)}'
                    : 'Через ${formatDistance(notice.distanceM)} остановка: '
                          '${stopTitle(notice.stop)}',
              ),
            if (showCamera)
              pill(
                icon: speeding ? Icons.warning_amber_rounded : Icons.speed,
                background: speeding ? colors.error : null,
                foreground: speeding ? colors.onError : null,
                strong: speeding,
                // Short enough for one line at a glance.
                text: speeding
                    ? '${CameraAlertTexts.slowDown} · камера через '
                          '${formatDistance(cameraDistance)}'
                          '${limit == null ? '' : ' · лимит $limit'}'
                    : '${CameraAlertTexts.typeLabel(camera.camera.type)} '
                          'через ${formatDistance(cameraDistance)}'
                          '${limit == null ? '' : ' · лимит $limit'}',
              ),
          ],
        ),
      ),
    );
  }
}

/// Shown on arrival: the trip in two numbers and one button.
class ArrivalCard extends StatelessWidget {
  const ArrivalCard({super.key, required this.summary, required this.onDone});

  final TripSummary summary;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final label = summary.label;
    return Glass(
      opacity: 0.92,
      child: Padding(
        padding: const EdgeInsets.all(Ui.pad),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.flag, size: 32, color: colors.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Вы приехали',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (label != null && label.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
            const SizedBox(height: Ui.gap),
            Text(
              'В пути ${formatDuration(summary.duration)} · '
              '${formatDistance(summary.distanceM)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Ui.pad),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: Ui.filled,
                onPressed: onDone,
                child: const Text('Готово'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
