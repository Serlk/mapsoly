import 'package:flutter/material.dart' hide Route;
import 'package:latlong2/latlong.dart';

import '../places/camera_alert.dart';
import '../routing/valhalla_client.dart';
import 'route_controller.dart';

String _pointLabel(LatLng p) =>
    '${p.latitude.toStringAsFixed(4)}, ${p.longitude.toStringAsFixed(4)}';

/// Route planner: explicit "from" and "to", travel mode, alternatives and
/// the button that starts guidance.
class RoutePanel extends StatelessWidget {
  const RoutePanel({super.key, required this.controller});

  final RouteController controller;

  static const _costingIcons = {
    RouteCosting.auto: Icons.directions_car_outlined,
    RouteCosting.pedestrian: Icons.directions_walk,
    RouteCosting.bicycle: Icons.directions_bike,
  };
  static const _costingNames = {
    RouteCosting.auto: 'На машине',
    RouteCosting.pedestrian: 'Пешком',
    RouteCosting.bicycle: 'На велосипеде',
  };

  String? _hint() {
    if (controller.loading) return 'Строю маршрут…';
    if (controller.error != null) return controller.error;
    if (controller.from == null || controller.to == null) {
      return 'Долгое нажатие на карте — выбрать точку';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final route = controller.selected;
    final routes = controller.routes;
    final hint = _hint();
    final from = controller.from, to = controller.to;
    final selected = controller.selectedIndex;
    final withTraffic =
        route != null && controller.trafficTime(selected) != null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      _EndpointRow(
                        icon: Icons.trip_origin,
                        color: colors.primary,
                        caption: 'Откуда',
                        value: controller.fromIsMyPosition
                            ? 'Моё местоположение'
                            : from == null
                            ? null
                            : controller.fromLabel ?? _pointLabel(from),
                        onClear: controller.clearFrom,
                        trailing:
                            controller.myPosition != null &&
                                !controller.fromIsMyPosition
                            ? IconButton(
                                tooltip: 'От моего местоположения',
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.my_location, size: 20),
                                onPressed: controller.setFromMyPosition,
                              )
                            : null,
                      ),
                      _EndpointRow(
                        icon: Icons.place,
                        color: colors.error,
                        caption: 'Куда',
                        value: to == null
                            ? null
                            : controller.toLabel ?? _pointLabel(to),
                        onClear: controller.clearTo,
                      ),
                    ],
                  ),
                ),
                Column(
                  children: [
                    IconButton(
                      tooltip: 'Закрыть маршрут',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close),
                      onPressed: controller.clear,
                    ),
                    IconButton(
                      tooltip: 'Поменять местами',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.swap_vert),
                      onPressed: from != null && to != null
                          ? controller.swap
                          : null,
                    ),
                  ],
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 4),
              child: Row(
                children: [
                  for (final c in RouteCosting.values)
                    IconButton(
                      tooltip: _costingNames[c],
                      visualDensity: VisualDensity.compact,
                      icon: Icon(_costingIcons[c]),
                      color: controller.costing == c
                          ? colors.primary
                          : colors.onSurfaceVariant,
                      onPressed: () => controller.setCosting(c),
                    ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: route != null
                        ? const SizedBox.shrink()
                        : Text(
                            hint ?? '',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: controller.error != null
                                  ? colors.error
                                  : colors.onSurfaceVariant,
                            ),
                          ),
                  ),
                  if (route != null)
                    FilledButton.icon(
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: controller.startGuidance,
                      icon: const Icon(Icons.navigation, size: 18),
                      label: const Text('Поехали'),
                    ),
                ],
              ),
            ),
            // Alternatives never wrap: the row scrolls sideways.
            if (routes.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 8, 0),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < routes.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            visualDensity: VisualDensity.compact,
                            showCheckmark: false,
                            label: Text(formatDuration(controller.timeOf(i))),
                            selected: i == selected,
                            onSelected: (_) => controller.select(i),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            if (route != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 8, 0),
                child: Text(
                  [
                    if (routes.length == 1)
                      formatDuration(controller.timeOf(selected)),
                    formatDistance(route.lengthMeters),
                    if (withTraffic)
                      'без пробок ${formatDuration(route.duration)}',
                  ].join(' · '),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EndpointRow extends StatelessWidget {
  const _EndpointRow({
    required this.icon,
    required this.color,
    required this.caption,
    required this.value,
    required this.onClear,
    this.trailing,
  });

  final IconData icon;
  final Color color;
  final String caption;
  final String? value;
  final VoidCallback onClear;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          const SizedBox(width: 8),
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value ?? '$caption: не выбрано',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: value == null
                  ? theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    )
                  : theme.textTheme.bodyMedium,
            ),
          ),
          ?trailing,
          if (value != null)
            IconButton(
              tooltip: '$caption: очистить',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.backspace_outlined, size: 18),
              onPressed: onClear,
            ),
        ],
      ),
    );
  }
}

/// Card shown after a long press: what to do with the picked point.
class PickedPointCard extends StatelessWidget {
  const PickedPointCard({
    super.key,
    required this.point,
    this.label,
    required this.onFrom,
    required this.onTo,
    required this.onClose,
  });

  final LatLng point;

  /// Name of the place when it came from search.
  final String? label;
  final VoidCallback onFrom, onTo, onClose;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label ?? 'Точка ${_pointLabel(point)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Закрыть',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close),
                  onPressed: onClose,
                ),
              ],
            ),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: onTo,
                  icon: const Icon(Icons.place),
                  label: const Text('Сюда'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: onFrom,
                  icon: const Icon(Icons.trip_origin),
                  label: const Text('Отсюда'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Guidance banner. With a position fix it shows the upcoming maneuver,
/// the distance to it, what is left of the trip and the next camera; without
/// one the maneuvers are stepped through by hand.
class GuidanceBanner extends StatelessWidget {
  const GuidanceBanner({super.key, required this.controller});

  final RouteController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final route = controller.selected!;
    final steps = route.maneuvers.toList();
    final i = controller.step.clamp(0, steps.length - 1);
    final progress = controller.progress;
    final onColor = colors.onPrimaryContainer;

    String title, detail;
    if (progress != null) {
      // Driving: announce the next maneuver and how far it is.
      final next = i + 1 < steps.length ? steps[i + 1] : null;
      final toNext = next == null
          ? 0.0
          : controller.alongOf(next.beginShapeIndex) - progress.alongM;
      title = next == null
          ? steps[i].instruction
          : 'Через ${formatDistance(toNext < 0 ? 0 : toNext)}: '
                '${next.instruction}';
      final left = controller.remainingM ?? 0;
      final total = route.lengthMeters;
      final time = controller.timeOf(controller.selectedIndex);
      final timeLeft = total <= 0
          ? Duration.zero
          : Duration(seconds: (time.inSeconds * left / total).round());
      final speed = controller.speedKmh;
      detail =
          'Осталось ${formatDistance(left)} · ${formatDuration(timeLeft)}'
          '${speed == null ? '' : ' · ${speed.round()} км/ч'}';
    } else {
      final m = steps[i];
      var remaining = 0.0;
      for (var k = i; k < steps.length; k++) {
        remaining += steps[k].lengthMeters;
      }
      title = m.instruction;
      detail =
          '${m.lengthMeters > 0 ? 'Затем ${formatDistance(m.lengthMeters)} · ' : ''}'
          'осталось ${formatDistance(remaining)} · '
          'шаг ${i + 1} из ${steps.length}';
    }

    final camera = controller.nextCamera;
    final cameraDistance = controller.nextCameraDistanceM;
    final showCamera =
        progress != null &&
        camera != null &&
        cameraDistance != null &&
        cameraDistance < 1500;
    final limit = camera?.camera.maxSpeedKmh;

    return Card(
      color: colors.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (progress == null)
                  IconButton(
                    tooltip: 'Предыдущий манёвр',
                    icon: const Icon(Icons.chevron_left),
                    onPressed: i > 0 ? () => controller.goToStep(i - 1) : null,
                  )
                else
                  const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: onColor,
                        ),
                      ),
                      Text(
                        detail,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: onColor,
                        ),
                      ),
                    ],
                  ),
                ),
                if (progress == null)
                  IconButton(
                    tooltip: 'Следующий манёвр',
                    icon: const Icon(Icons.chevron_right),
                    onPressed: i < steps.length - 1
                        ? () => controller.goToStep(i + 1)
                        : null,
                  ),
                IconButton(
                  tooltip: 'Завершить ведение',
                  icon: const Icon(Icons.close),
                  onPressed: controller.stopGuidance,
                ),
              ],
            ),
            if (showCamera)
              Container(
                margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: controller.speeding
                      ? colors.errorContainer
                      : colors.surface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.speed,
                      size: 18,
                      color: controller.speeding
                          ? colors.onErrorContainer
                          : colors.onSurface,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '${controller.speeding ? '${CameraAlertTexts.slowDown}. ' : ''}'
                        '${CameraAlertTexts.typeLabel(camera.camera.type)} '
                        'через ${formatDistance(cameraDistance)}'
                        '${limit == null ? '' : ' · $limit км/ч'}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: controller.speeding
                              ? colors.onErrorContainer
                              : colors.onSurface,
                        ),
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
