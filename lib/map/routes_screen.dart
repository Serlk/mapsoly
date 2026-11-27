import 'package:flutter/material.dart' hide Route;

import '../routing/route_models.dart' show RouteCosting, RouteSummary;
import '../user/file_exchange.dart';
import '../user/saved_routes.dart';
import '../user/user_data.dart';
import 'point_picker.dart';
import 'route_controller.dart';
import 'route_panel.dart';
import 'ui_kit.dart';

/// Routes section: the trip planner and the saved routes, as two tabs.
///
/// [tab] (0: the trip, 1: saved) belongs to the owner so that other parts
/// of the app can open the planner directly.
class RoutesScreen extends StatefulWidget {
  const RoutesScreen({
    super.key,
    required this.route,
    required this.user,
    required this.services,
    required this.files,
    required this.tab,
    required this.onGo,
  });

  final RouteController route;
  final UserData user;
  final MapServices services;
  final FileExchange files;
  final ValueNotifier<int> tab;

  /// Guidance was started: show the map.
  final VoidCallback onGo;

  @override
  State<RoutesScreen> createState() => _RoutesScreenState();
}

class _RoutesScreenState extends State<RoutesScreen> {
  // The saved route the planner was filled from: saving again updates it.
  SavedRoute? _opened;

  RouteController get _route => widget.route;

  Future<void> _addStop() async {
    final picked = await choosePoint(
      context,
      services: widget.services,
      places: widget.user.places,
      title: _route.stops.isEmpty ? 'Куда поедем?' : 'Новая остановка',
      // The trip already starts from the current position.
      offerMyPosition: false,
    );
    if (picked != null) _route.addStop(picked.point, label: picked.label);
  }

  Future<void> _chooseStart() async {
    final picked = await choosePoint(
      context,
      services: widget.services,
      places: widget.user.places,
      title: 'Откуда поедем?',
    );
    if (picked == null) return;
    final here = widget.services.myPosition;
    if (picked.label == null && here != null && picked.point == here) {
      _route.setFromMyPosition();
    } else {
      _route.setFrom(picked.point, label: picked.label);
    }
  }

  Future<void> _replaceStop(int index) async {
    final picked = await choosePoint(
      context,
      services: widget.services,
      places: widget.user.places,
      title: 'Остановка ${index + 1}',
      offerMyPosition: index == 0,
    );
    if (picked == null) return;
    final here = widget.services.myPosition;
    if (index == 0 && picked.label == null && picked.point == here) {
      _route.setFromMyPosition();
    } else {
      _route.setStop(index, picked.point, label: picked.label);
    }
  }

  void _removeStop(int index) {
    final removed = _route.removeStop(index);
    if (removed == null) return;
    showNote(
      context,
      'Остановка «${stopTitle(removed)}» убрана',
      action: 'Вернуть',
      onAction: () => _route.insertStop(index, removed),
    );
  }

  void _clear() {
    final stops = _route.stops;
    final costing = _route.costing;
    final opened = _opened;
    _route.clear();
    setState(() => _opened = null);
    showNote(
      context,
      'Поездка очищена',
      action: 'Вернуть',
      onAction: () {
        _route.setStops(stops, costing: costing);
        setState(() => _opened = opened);
      },
    );
  }

  String _defaultName() {
    final opened = _opened;
    if (opened != null) return opened.name;
    final stops = _route.stops;
    if (stops.isEmpty) return '';
    final first = stops.first, last = stops.last;
    return first.myPosition || stops.length == 1
        ? stopTitle(last)
        : '${stopTitle(first)} — ${stopTitle(last)}';
  }

  /// The trip as it stands, as a route that can be stored or written out.
  SavedRoute? _snapshot(String name) {
    final stops = _route.stops;
    if (_route.needStart || stops.length < 2) return null;
    final points = <RoutePoint>[];
    for (var i = 0; i < stops.length; i++) {
      final p = _route.pointOf(i);
      if (p == null) return null;
      points.add(
        RoutePoint(p, label: stops[i].myPosition ? null : stops[i].label),
      );
    }
    final selected = _route.selected;
    return SavedRoute(
      id: _opened?.id,
      created: _opened?.created,
      name: name,
      points: points,
      costing: _route.costing,
      geometry: selected?.shape,
      lengthMeters: selected?.lengthMeters,
    );
  }

  Future<void> _save() async {
    final name = await promptText(
      context,
      title: 'Сохранить маршрут',
      label: 'Название',
      initial: _defaultName(),
    );
    if (name == null || !mounted) return;
    final route = _snapshot(name);
    if (route == null) return;
    final stored = widget.user.routes.save(route);
    setState(() => _opened = stored);
    showNote(
      context,
      widget.user.routes.saveError ?? 'Маршрут «${stored.name}» сохранён',
    );
  }

  Future<void> _share([SavedRoute? saved]) async {
    final route = saved ?? _snapshot(_defaultName());
    if (route == null) return;
    await exportGpxFile(
      context,
      widget.files,
      routes: [route],
      baseName: 'mapsoly-route',
    );
  }

  void _open(SavedRoute saved) {
    _route.setStops([
      for (final p in saved.points) RouteStop(p.point, label: p.label),
    ], costing: saved.costing);
    setState(() => _opened = saved);
    widget.tab.value = 0;
  }

  void _delete(SavedRoute saved) {
    widget.user.routes.remove(saved.id);
    if (_opened?.id == saved.id) setState(() => _opened = null);
    showNote(
      context,
      'Маршрут «${saved.name}» удалён',
      action: 'Вернуть',
      onAction: () => widget.user.routes.save(saved),
    );
  }

  Future<void> _rename(SavedRoute saved) async {
    final name = await promptText(
      context,
      title: 'Переименовать маршрут',
      label: 'Название',
      initial: saved.name,
    );
    if (name == null) return;
    widget.user.routes.rename(saved.id, name);
    if (_opened?.id == saved.id) {
      setState(() => _opened = widget.user.routes.byId(saved.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([
            widget.tab,
            _route,
            widget.user.routes,
          ]),
          builder: (context, _) {
            final saved = widget.user.routes.routes;
            final tab = widget.tab.value;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Ui.pad, 12, Ui.pad, 4),
                  child: SegmentedButton<int>(
                    showSelectedIcon: false,
                    style: Ui.segmented(height: 52),
                    segments: [
                      const ButtonSegment(value: 0, label: Text('Поездка')),
                      ButtonSegment(
                        value: 1,
                        label: Text(
                          saved.isEmpty
                              ? 'Сохранённые'
                              : 'Сохранённые · ${saved.length}',
                        ),
                      ),
                    ],
                    selected: {tab},
                    onSelectionChanged: (s) => widget.tab.value = s.first,
                  ),
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: KeyedSubtree(
                      key: ValueKey(tab),
                      child: tab == 0 ? _planner(context) : _saved(saved),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- planner

  Widget _planner(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final stops = _route.stops;
    if (stops.isEmpty) {
      return EmptyState(
        icon: Icons.alt_route,
        text:
            'Соберите поездку: добавьте место, куда едете, '
            'а потом остановки по пути.',
        action: 'Добавить остановку',
        onAction: _addStop,
      );
    }
    final route = _route.selected;
    final selected = _route.selectedIndex;
    final error = _route.loading ? null : _route.error;

    // Totals: the travel time is the one large figure.
    final String figure;
    String? detail;
    if (route != null) {
      figure = formatDuration(_route.timeOf(selected));
      detail = [
        formatDistance(route.lengthMeters),
        if (_route.trafficTime(selected) != null)
          'без пробок ${formatDuration(route.duration)}',
      ].join(' · ');
    } else if (_route.loading) {
      figure = 'Строю маршрут…';
    } else if (error != null) {
      figure = error;
    } else if (_route.needStart) {
      figure = 'Выберите, откуда ехать';
    } else {
      figure = 'Добавьте, куда ехать';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ReorderableListView(
            buildDefaultDragHandles: false,
            padding: const EdgeInsets.only(top: 4, bottom: Ui.gap),
            onReorder: (from, to) =>
                _route.moveStop(from, to > from ? to - 1 : to),
            header: _route.needStart
                ? _StartPlaceholder(onTap: _chooseStart)
                : null,
            footer: Padding(
              padding: const EdgeInsets.fromLTRB(Ui.pad, 4, Ui.pad, 0),
              child: OutlinedButton.icon(
                style: Ui.outlined,
                onPressed: _addStop,
                icon: const Icon(Icons.add),
                label: const Text('Добавить остановку'),
              ),
            ),
            children: [
              for (var i = 0; i < stops.length; i++)
                _StopRow(
                  key: ValueKey((i, stops[i])),
                  index: i,
                  count: stops.length,
                  stop: stops[i],
                  isStart: i == 0 && !_route.needStart,
                  leg: _route.legTo(i),
                  failed: _route.errorStop == i,
                  onTap: () => _replaceStop(i),
                  onUp: i > 0 ? () => _route.moveStop(i, i - 1) : null,
                  onDown: i < stops.length - 1
                      ? () => _route.moveStop(i, i + 1)
                      : null,
                  onRemove: () => _removeStop(i),
                ),
            ],
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.outlineVariant)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Ui.pad, 10, Ui.pad, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            figure,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: route != null
                                ? theme.textTheme.headlineSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  )
                                : theme.textTheme.titleMedium?.copyWith(
                                    color: error != null ? colors.error : null,
                                  ),
                          ),
                          if (detail != null)
                            Text(
                              detail,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: Ui.gap),
                    CostingSwitch(
                      compact: true,
                      value: _route.costing,
                      onChanged: _route.setCosting,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _PlannerActions(
                  onGo: route == null
                      ? null
                      : () {
                          _route.startGuidance();
                          widget.onGo();
                        },
                  onSave: route == null ? null : _save,
                  onShare: _snapshot('') == null ? null : _share,
                  onClear: _clear,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ saved

  Widget _saved(List<SavedRoute> saved) {
    final error = widget.user.routes.loadError;
    Future<void> import() => importGpxInto(context, widget.files, widget.user);
    if (saved.isEmpty) {
      return Column(
        children: [
          if (error != null) InfoPanel(text: error, error: true),
          Expanded(
            child: EmptyState(
              icon: Icons.bookmark_border,
              text:
                  'Здесь будут поездки, которые вы сохраните. '
                  'Маршрут можно взять и из файла GPX.',
              action: 'Импорт из файла',
              actionIcon: Icons.file_open_outlined,
              onAction: import,
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(top: 4, bottom: Ui.gap),
            children: [
              if (error != null) InfoPanel(text: error, error: true),
              for (final r in saved)
                Dismissible(
                  key: ValueKey(r.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    child: const Icon(Icons.delete_outline),
                  ),
                  onDismissed: (_) => _delete(r),
                  child: _SavedRow(
                    route: r,
                    current: _opened?.id == r.id,
                    onTap: () => _open(r),
                    onRename: () => _rename(r),
                    onShare: () => _share(r),
                    onDelete: () => _delete(r),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Ui.pad, 0, Ui.pad, 12),
          child: OutlinedButton.icon(
            style: Ui.outlined,
            onPressed: import,
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Импорт из файла'),
          ),
        ),
      ],
    );
  }
}

/// "Поехали" and the quieter things one can do with a planned trip.
class _PlannerActions extends StatelessWidget {
  const _PlannerActions({
    required this.onGo,
    required this.onSave,
    required this.onShare,
    required this.onClear,
  });

  final VoidCallback? onGo, onSave, onShare;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final go = FilledButton.icon(
      style: Ui.filled,
      onPressed: onGo,
      icon: const Icon(Icons.navigation),
      label: const Text('Поехали'),
    );
    final save = OutlinedButton.icon(
      style: Ui.outlined,
      onPressed: onSave,
      icon: const Icon(Icons.bookmark_border),
      label: const Text('Сохранить'),
    );
    final share = TextButton.icon(
      style: Ui.text,
      onPressed: onShare,
      icon: const Icon(Icons.ios_share),
      label: const Text('Поделиться файлом'),
    );
    final clear = TextButton.icon(
      style: Ui.text,
      onPressed: onClear,
      icon: const Icon(Icons.delete_outline),
      label: const Text('Очистить'),
    );
    return LayoutBuilder(
      builder: (context, box) {
        // Everything in one row when it fits (a wide window, a normal font
        // size); otherwise the two rare actions get a line of their own, so
        // that "Поехали" is never squeezed.
        final style = Theme.of(context).textTheme.labelLarge;
        final scaler = MediaQuery.textScalerOf(context);
        var needed = 0.0;
        for (final label in const [
          'Поехали',
          'Сохранить',
          'Поделиться файлом',
          'Очистить',
        ]) {
          final painter = TextPainter(
            text: TextSpan(text: label, style: style),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
          )..layout();
          // The label, its icon and the button's padding.
          needed += painter.width + 26 + 40;
          painter.dispose();
        }
        if (needed + 2 * Ui.gap <= box.maxWidth) {
          return Row(
            children: [
              Expanded(child: go),
              const SizedBox(width: Ui.gap),
              save,
              const SizedBox(width: 4),
              share,
              clear,
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: go),
                const SizedBox(width: Ui.gap),
                save,
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(child: share),
                clear,
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Shown above the stops while the trip has no start.
class _StartPlaceholder extends StatelessWidget {
  const _StartPlaceholder({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Ui.pad, 4, Ui.pad, 4),
      child: Material(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(Ui.radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Ui.row),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Ui.pad),
              child: Row(
                children: [
                  Icon(Icons.trip_origin, color: colors.onPrimaryContainer),
                  const SizedBox(width: Ui.pad),
                  Expanded(
                    child: Text(
                      'Выберите, откуда ехать',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: colors.onPrimaryContainer,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right, color: colors.onPrimaryContainer),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One stop of the trip: its number, its name, the way to it from the stop
/// before, and the controls that move or remove it.
class _StopRow extends StatelessWidget {
  const _StopRow({
    super.key,
    required this.index,
    required this.count,
    required this.stop,
    required this.isStart,
    required this.leg,
    required this.failed,
    required this.onTap,
    required this.onUp,
    required this.onDown,
    required this.onRemove,
  });

  final int index, count;
  final RouteStop stop;
  final bool isStart, failed;
  final RouteSummary? leg;
  final VoidCallback onTap, onRemove;
  final VoidCallback? onUp, onDown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final last = index == count - 1 && !isStart;
    final badgeColor = failed
        ? colors.error
        : last
        ? colors.primary
        : colors.secondaryContainer;
    final badgeText = failed
        ? colors.onError
        : last
        ? colors.onPrimary
        : colors.onSecondaryContainer;
    final leg = this.leg;
    final legLine = leg == null
        ? (isStart ? 'Начало' : null)
        : '${formatDistance(leg.lengthMeters)} · '
              '${formatDuration(leg.duration)} от предыдущей';

    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Ui.iconButton(
          icon: Icons.arrow_upward,
          label: 'Выше',
          size: 48,
          onPressed: onUp,
        ),
        Ui.iconButton(
          icon: Icons.arrow_downward,
          label: 'Ниже',
          size: 48,
          onPressed: onDown,
        ),
        Ui.iconButton(
          icon: Icons.close,
          label: 'Убрать остановку',
          size: 48,
          onPressed: onRemove,
        ),
        ReorderableDragStartListener(
          index: index,
          child: const SizedBox(
            width: 40,
            height: 48,
            child: Icon(Icons.drag_indicator, semanticLabel: 'Перетащить'),
          ),
        ),
      ],
    );

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          stopTitle(stop),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium,
        ),
        if (legLine != null)
          Text(
            legLine,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        if (failed)
          Text(
            'Сюда не получается проехать',
            style: theme.textTheme.bodyMedium?.copyWith(color: colors.error),
          ),
      ],
    );

    final badge = Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: badgeColor, shape: BoxShape.circle),
      child: Text(
        '${index + 1}',
        style: theme.textTheme.titleMedium?.copyWith(color: badgeText),
      ),
    );

    return Material(
      color: colors.surface,
      child: InkWell(
        onTap: onTap,
        child: LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth >= 560;
            return ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 72),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Ui.pad, 6, 4, 6),
                child: wide
                    ? Row(
                        children: [
                          badge,
                          const SizedBox(width: Ui.pad),
                          Expanded(child: text),
                          controls,
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              badge,
                              const SizedBox(width: Ui.pad),
                              Expanded(child: text),
                            ],
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: controls,
                          ),
                        ],
                      ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SavedRow extends StatelessWidget {
  const _SavedRow({
    required this.route,
    required this.current,
    required this.onTap,
    required this.onRename,
    required this.onShare,
    required this.onDelete,
  });

  final SavedRoute route;
  final bool current;
  final VoidCallback onTap, onRename, onShare, onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final length = route.lengthMeters;
    return Material(
      color: colors.surface,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 72),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Ui.pad, 6, 4, 6),
            child: Row(
              children: [
                Icon(
                  costingIcons[route.costing] ??
                      costingIcons[RouteCosting.auto],
                  color: current ? colors.primary : colors.onSurfaceVariant,
                ),
                const SizedBox(width: Ui.pad),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        route.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        [
                          plural(
                            route.points.length,
                            'остановка',
                            'остановки',
                            'остановок',
                          ),
                          if (length != null) formatDistance(length),
                          if (current) 'открыт в поездке',
                        ].join(' · '),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Ui.iconButton(
                  icon: Icons.edit_outlined,
                  label: 'Переименовать',
                  size: 48,
                  onPressed: onRename,
                ),
                Ui.iconButton(
                  icon: Icons.ios_share,
                  label: 'Поделиться файлом',
                  size: 48,
                  onPressed: onShare,
                ),
                Ui.iconButton(
                  icon: Icons.delete_outline,
                  label: 'Удалить',
                  size: 48,
                  onPressed: onDelete,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
