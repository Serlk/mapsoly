/// "Данные": what the app has collected and what the user keeps, with the
/// ways to save it to a file and to read it back.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../map/ui_kit.dart';
import '../positioning/positioning.dart';
import 'data_export.dart';
import 'file_exchange.dart';
import 'user_data.dart';

String _number(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
    b.write(s[i]);
  }
  return '$b';
}

String _duration(Duration d) {
  final minutes = (d.inSeconds / 60).round();
  if (minutes < 1) return 'меньше минуты';
  if (minutes < 60) return '$minutes мин';
  final h = minutes ~/ 60, m = minutes % 60;
  return m == 0 ? '$h ч' : '$h ч $m мин';
}

String _km(double km) => km < 10
    ? '${km.toStringAsFixed(1).replaceAll('.', ',')} км'
    : '${km.round()} км';

/// The hub: the collected transmitter database, trip logs, routes and
/// places.
class DataScreen extends StatefulWidget {
  const DataScreen({
    super.key,
    required this.user,
    required this.files,
    required this.engine,
  });

  final UserData user;
  final FileExchange files;

  /// Null when positioning does not run on this device.
  final PositioningEngine? engine;

  @override
  State<DataScreen> createState() => _DataScreenState();
}

class _DataScreenState extends State<DataScreen> {
  DbStats? _stats;
  String? _busy;
  int _trips = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    try {
      _stats = widget.engine?.dbStats();
    } on Exception catch (e) {
      debugPrint('Database statistics not read: $e');
      _stats = null;
    }
    final logs = widget.user.tripLogDirectory;
    _trips = logs == null ? 0 : listTripLogs(logs).length;
  }

  Future<void> _run(String what, Future<void> Function() action) async {
    if (_busy != null) return;
    setState(() => _busy = what);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() {
          _busy = null;
          _refresh();
        });
      }
    }
  }

  Future<void> _exportWardriving() => _run('export', () async {
    final engine = widget.engine!, files = widget.files;
    try {
      final out = await files.newExportFile('mapsoly-wardriving', 'csv');
      final r = await exportWardriving(engine.db, widget.user.zones, out);
      if (!mounted) return;
      final left = [
        if (r.withheldByZones > 0)
          '${_number(r.withheldByZones)} в безопасных зонах',
        if (r.notOwn > 0) '${_number(r.notOwn)} получены не вами',
      ].join(', ');
      if (r.file == null) {
        showNote(
          context,
          'Сохранять нечего: в базе нет точек, собранных вами'
          '${left.isEmpty ? '' : '. Не вошли: $left'}',
        );
        return;
      }
      final kinds = [
        if (r.wifi > 0) 'Wi-Fi ${_number(r.wifi)}',
        if (r.cells > 0) 'соты ${_number(r.cells)}',
        if (r.ble > 0) 'Bluetooth ${_number(r.ble)}',
      ].join(', ');
      showExported(
        context,
        files,
        'Сохранено: ${plural(r.exported, 'точка', 'точки', 'точек')}'
        '${kinds.isEmpty ? '' : ' ($kinds)'}'
        '${left.isEmpty ? '' : '. Не вошли: $left'}',
        file: r.file,
      );
    } on FileSystemException {
      if (!mounted) return;
      showNote(
        context,
        'Не удалось записать файл в папку ${files.exportFolderLabel}',
      );
    }
  });

  Future<void> _importWardriving() async {
    final engine = widget.engine!;
    final file = await widget.files.pickFile(
      context,
      title: 'Импорт базы',
      extensions: const {'csv'},
    );
    if (file == null || !mounted) return;
    await _run('import', () async {
      try {
        Stream<String> lines() => file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter());
        final first = await lines().firstWhere((_) => true, orElse: () => '');
        final r = first.startsWith('WigleWifi')
            ? await importWigleCsv(engine.db, lines())
            : await importGenericCsv(engine.db, lines());
        if (!mounted) return;
        showNote(
          context,
          r.transmitters == 0
              ? 'В файле не нашлось точек с координатами'
                    '${r.skipped > 0 ? ' (пропущено строк: ${_number(r.skipped)})' : ''}'
              : 'Добавлено или обновлено: '
                    '${plural(r.written, 'точка', 'точки', 'точек')} '
                    'из ${_number(r.transmitters)} в файле'
                    '${r.skipped > 0 ? '. Пропущено строк: ${_number(r.skipped)}' : ''}',
          duration: const Duration(seconds: 8),
        );
      } on Exception {
        if (!mounted) return;
        showNote(context, 'Файл не удалось прочитать');
      }
    });
  }

  Future<void> _openTrips() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) =>
            TripLogsScreen(user: widget.user, files: widget.files),
      ),
    );
    if (mounted) setState(_refresh);
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.user, files = widget.files;
    final stats = _stats;
    return SubPage(
      title: 'Данные',
      child: ListenableBuilder(
        listenable: Listenable.merge([user.places, user.routes]),
        builder: (context, _) {
          final places = user.places.places, routes = user.routes.routes;
          final kept = [
            if (places.isNotEmpty)
              plural(places.length, 'место', 'места', 'мест'),
            if (routes.isNotEmpty)
              plural(routes.length, 'маршрут', 'маршрута', 'маршрутов'),
          ].join(' и ');
          return ListView(
            padding: const EdgeInsets.only(bottom: Ui.pad),
            children: [
              const SectionHeader('Собранная база'),
              if (widget.engine == null)
                const _Quiet(
                  'Определение местоположения на этом устройстве не '
                  'запущено, поэтому базы Wi-Fi и сотовых вышек нет.',
                )
              else ...[
                if (stats != null) _StatsCard(stats: stats),
                BigRow(
                  icon: Icons.save_alt,
                  title: _busy == 'export' ? 'Сохраняю…' : 'Сохранить в файл',
                  subtitle:
                      'Только то, что собрали вы сами, без точек из '
                      'безопасных зон',
                  trailing: const SizedBox.shrink(),
                  onTap: _busy == null ? _exportWardriving : null,
                ),
                BigRow(
                  icon: Icons.file_open_outlined,
                  title: _busy == 'import' ? 'Читаю файл…' : 'Импорт из файла',
                  subtitle: 'Таблица WiGLE или обычный CSV',
                  onTap: _busy == null ? _importWardriving : null,
                ),
              ],
              const SectionHeader('Журналы поездок'),
              BigRow(
                icon: Icons.route_outlined,
                title: 'Записанные поездки',
                subtitle: _trips == 0
                    ? 'Пока нет'
                    : plural(_trips, 'поездка', 'поездки', 'поездок'),
                onTap: _openTrips,
              ),
              const SectionHeader('Маршруты и места'),
              BigRow(
                icon: Icons.save_alt,
                title: 'Сохранить всё в один файл',
                subtitle: kept.isEmpty
                    ? 'Пока нечего сохранять: нет ни мест, ни маршрутов'
                    : '$kept, формат GPX',
                trailing: const SizedBox.shrink(),
                onTap: kept.isEmpty
                    ? null
                    : () => exportGpxFile(
                        context,
                        files,
                        places: places,
                        routes: routes,
                        baseName: 'mapsoly',
                      ),
              ),
              BigRow(
                icon: Icons.file_open_outlined,
                title: 'Импорт из файла',
                subtitle: 'Маршруты и места из файла GPX',
                onTap: () => importGpxInto(context, files, user),
              ),
              _Quiet('Файлы сохраняются в папку ${files.exportFolderLabel}'),
            ],
          );
        },
      ),
    );
  }
}

class _Quiet extends StatelessWidget {
  const _Quiet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Ui.pad, Ui.gap, Ui.pad, Ui.gap),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The database in one figure, with the breakdown as a quiet line.
class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.stats});

  final DbStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final own = stats.bySource[TransmitterSource.wardriving] ?? 0;
    final quiet = theme.textTheme.bodyMedium?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return Container(
      margin: const EdgeInsets.fromLTRB(Ui.pad, 0, Ui.pad, Ui.gap),
      padding: const EdgeInsets.all(Ui.pad),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Ui.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                _number(stats.total),
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: Ui.gap),
              Expanded(
                child: Text(
                  stats.total == 0
                      ? 'точек — база пока пуста'
                      : 'точек Wi-Fi и сотовых вышек',
                  style: quiet,
                ),
              ),
            ],
          ),
          if (stats.total > 0) ...[
            const SizedBox(height: 4),
            Text(
              [
                'Wi-Fi ${_number(stats.wifi)}',
                'соты ${_number(stats.cells)}',
                if (stats.ble > 0) 'Bluetooth ${_number(stats.ble)}',
              ].join(' · '),
              style: quiet,
            ),
            Text(
              'Собрано вами ${_number(own)} · на диске '
              '${formatBytes(stats.fileBytes)}',
              style: quiet,
            ),
          ],
        ],
      ),
    );
  }
}

/// Trip logs written by the car adapter: look, save copies, delete.
class TripLogsScreen extends StatefulWidget {
  const TripLogsScreen({super.key, required this.user, required this.files});

  final UserData user;
  final FileExchange files;

  @override
  State<TripLogsScreen> createState() => _TripLogsScreenState();
}

class _TripLogsScreenState extends State<TripLogsScreen> {
  List<TripLogInfo> _logs = const [];
  final _selected = <String>{};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final dir = widget.user.tripLogDirectory;
    _logs = dir == null ? const [] : listTripLogs(dir);
    _selected.retainAll({for (final l in _logs) l.file.path});
  }

  List<TripLogInfo> get _chosen => _selected.isEmpty
      ? _logs
      : [
          for (final l in _logs)
            if (_selected.contains(l.file.path)) l,
        ];

  Future<void> _export() async {
    final files = widget.files, chosen = _chosen;
    setState(() => _busy = true);
    try {
      final out = await files.exportDirectory();
      final r = await exportTripLogs(
        [for (final l in chosen) l.file],
        widget.user.zones,
        out,
      );
      if (!mounted) return;
      final parts = [
        if (r.files.isNotEmpty)
          'Сохранено: ${plural(r.files.length, 'журнал', 'журнала', 'журналов')} '
              'в папку ${files.exportFolderLabel}',
        if (r.rowsBlanked > 0)
          'Из ${plural(r.rowsBlanked, 'строки', 'строк', 'строк')} убраны '
              'координаты: безопасная зона',
        if (r.failed.isNotEmpty)
          'Не сохранены: '
              '${r.failed.entries.map((e) => '${e.key} — ${e.value}').join('; ')}',
      ];
      showExported(context, files, parts.join('. '));
    } on FileSystemException {
      if (!mounted) return;
      showNote(
        context,
        'Не удалось записать файлы в папку ${files.exportFolderLabel}',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final chosen = _chosen;
    final ok = await confirmAction(
      context,
      title:
          'Удалить ${plural(chosen.length, 'журнал', 'журнала', 'журналов')}?',
      text: 'Вернуть их будет нельзя.',
      confirm: 'Удалить',
    );
    if (!ok || !mounted) return;
    var failed = 0;
    for (final l in chosen) {
      if (!deleteTripLog(l.file)) failed++;
    }
    setState(_load);
    if (failed > 0) {
      showNote(
        context,
        'Не удалось удалить: '
        '${plural(failed, 'журнал', 'журнала', 'журналов')}',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final some = _selected.isNotEmpty;
    return SubPage(
      title: 'Журналы поездок',
      bottom: _logs.isEmpty
          ? null
          : Row(
              children: [
                if (some) ...[
                  OutlinedButton.icon(
                    style: Ui.outlined,
                    onPressed: _busy ? null : _delete,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Удалить'),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: FilledButton.icon(
                    style: Ui.filled,
                    onPressed: _busy ? null : _export,
                    icon: const Icon(Icons.save_alt),
                    label: Text(
                      _busy
                          ? 'Сохраняю…'
                          : some
                          ? 'Сохранить выбранные (${_selected.length})'
                          : 'Сохранить все (${_logs.length})',
                    ),
                  ),
                ),
              ],
            ),
      child: _logs.isEmpty
          ? const EmptyState(
              icon: Icons.route_outlined,
              text:
                  'Поездок пока нет. Они записываются, когда в настройках '
                  'в разделе «Автомобиль» включён журнал поездок и подключён '
                  'адаптер.',
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: Ui.pad),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Ui.pad, 4, Ui.pad, Ui.gap),
                  child: Text(
                    'Отметьте поездки, чтобы сохранить или удалить только их. '
                    'В копиях нет координат из безопасных зон.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                for (final log in _logs)
                  _TripRow(
                    log: log,
                    selected: _selected.contains(log.file.path),
                    onTap: () => setState(() {
                      final path = log.file.path;
                      if (!_selected.remove(path)) _selected.add(path);
                    }),
                  ),
              ],
            ),
    );
  }
}

class _TripRow extends StatelessWidget {
  const _TripRow({
    required this.log,
    required this.selected,
    required this.onTap,
  });

  final TripLogInfo log;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final duration = log.duration, km = log.distanceKm;
    return ListTile(
      minTileHeight: Ui.row,
      // Two lines of text would otherwise shrink the row below its minimum.
      minVerticalPadding: 12,
      contentPadding: const EdgeInsets.symmetric(horizontal: Ui.pad),
      selected: selected,
      selectedTileColor: colors.secondaryContainer.withValues(alpha: 0.5),
      selectedColor: colors.onSurface,
      leading: Icon(
        selected ? Icons.check_circle : Icons.radio_button_unchecked,
        color: selected ? colors.primary : colors.outline,
      ),
      title: Text(formatDateTime(log.start)),
      subtitle: Text(
        [
          if (duration != null) _duration(duration),
          if (km != null) _km(km),
          formatBytes(log.sizeBytes),
        ].join(' · '),
      ),
      onTap: onTap,
    );
  }
}
