import 'package:flutter/material.dart';

import 'route_controller.dart';

/// Routes section: the route being planned and the ways to start a new one.
class RoutesScreen extends StatelessWidget {
  const RoutesScreen({
    super.key,
    required this.route,
    required this.onShowOnMap,
    required this.onSearch,
  });

  final RouteController route;

  /// Switch to the map (to look at the route, or to pick a point on it).
  final VoidCallback onShowOnMap;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
    String point(String? label, bool mine, bool chosen) => mine
        ? 'Моё местоположение'
        : label ?? (chosen ? 'Точка на карте' : 'не выбрано');

    return ListenableBuilder(
      listenable: route,
      builder: (context, _) {
        final selected = route.selected;
        return ListView(
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            header('Текущий маршрут'),
            if (!route.active)
              const ListTile(
                minTileHeight: 64,
                title: Text('Маршрут не задан'),
                subtitle: Text('Найдите место или выберите точку на карте'),
              )
            else ...[
              ListTile(
                minTileHeight: 64,
                leading: const Icon(Icons.trip_origin),
                title: Text(
                  point(
                    route.fromLabel,
                    route.fromIsMyPosition,
                    route.from != null,
                  ),
                ),
                subtitle: const Text('Откуда'),
              ),
              ListTile(
                minTileHeight: 64,
                leading: const Icon(Icons.place),
                title: Text(point(route.toLabel, false, route.to != null)),
                subtitle: const Text('Куда'),
              ),
              if (selected != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text(
                    '${formatDuration(route.timeOf(route.selectedIndex))} · '
                    '${formatDistance(selected.lengthMeters)}',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 56),
                        ),
                        onPressed: onShowOnMap,
                        icon: const Icon(Icons.map_outlined),
                        label: const Text('На карте'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 56),
                        ),
                        onPressed: route.clear,
                        icon: const Icon(Icons.close),
                        label: const Text('Сбросить'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            header('Новый маршрут'),
            ListTile(
              minTileHeight: 64,
              leading: const Icon(Icons.search),
              title: const Text('Найти место'),
              subtitle: const Text('Адрес, улица, заведение'),
              trailing: const Icon(Icons.chevron_right),
              onTap: onSearch,
            ),
            ListTile(
              minTileHeight: 64,
              leading: const Icon(Icons.touch_app_outlined),
              title: const Text('Выбрать на карте'),
              subtitle: const Text('Долгое нажатие на нужном месте'),
              trailing: const Icon(Icons.chevron_right),
              onTap: onShowOnMap,
            ),
          ],
        );
      },
    );
  }
}
