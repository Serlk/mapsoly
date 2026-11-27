/// "Безопасные зоны": the list of privacy zones and the editor of one.
library;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../map/point_picker.dart';
import '../map/ui_kit.dart';
import '../positioning/positioning.dart';
import 'privacy_guard.dart';
import 'privacy_zones.dart';
import 'user_data.dart';

/// "300 м", "1 км", "1,5 км".
String formatZoneRadius(double meters) {
  if (meters < 1000) return '${meters.round()} м';
  final km = meters / 1000;
  final text = km == km.roundToDouble()
      ? km.round().toString()
      : km.toStringAsFixed(km * 10 == (km * 10).roundToDouble() ? 1 : 2);
  return '${text.replaceAll('.', ',')} км';
}

const _explanation =
    'Внутри зоны ничего из собранного не сохраняется и не уходит с '
    'устройства: не записываются Wi-Fi и сотовые вышки, не отправляются '
    'запросы на уточнение местоположения, в журнал поездок не попадают '
    'координаты, а в выгрузках этих мест нет.';

/// The zones, what they do, and the way to add or change one.
class ZonesScreen extends StatelessWidget {
  const ZonesScreen({
    super.key,
    required this.user,
    required this.services,
    required this.engine,
  });

  final UserData user;
  final MapServices services;

  /// Null when positioning did not start: nothing to clean up then.
  final PositioningEngine? engine;

  PrivacyZones get _zones => user.zones;

  Future<void> _open(BuildContext context, [PrivacyZone? zone]) async {
    final added = await Navigator.of(context).push<PrivacyZone>(
      MaterialPageRoute(
        builder: (context) =>
            _ZoneEditor(user: user, services: services, existing: zone),
      ),
    );
    if (added == null || !context.mounted) return;
    await _offerPurge(context);
  }

  /// A new zone does not touch what was recorded there earlier; say how
  /// much there is and delete it only when asked to.
  Future<void> _offerPurge(BuildContext context) async {
    final db = engine?.db;
    if (db == null) return;
    final int found;
    try {
      found = purgeWardrivingInside(db, _zones, dryRun: true);
    } on Object catch (e) {
      debugPrint('Zone contents not counted: $e');
      return;
    }
    if (found == 0 || !context.mounted) return;
    final points = plural(found, 'точка', 'точки', 'точек');
    final ok = await confirmAction(
      context,
      title: 'Удалить записанное в зонах?',
      text:
          'В безопасных зонах уже записано $points. Удалить их? '
          'Если оставить, они не попадут в выгрузки, но останутся на '
          'устройстве.',
      confirm: 'Удалить',
    );
    if (!ok || !context.mounted) return;
    try {
      final removed = purgeWardrivingInside(db, _zones);
      if (context.mounted) {
        showNote(
          context,
          'Удалено: ${plural(removed, 'точка', 'точки', 'точек')}',
        );
      }
    } on Object catch (e) {
      debugPrint('Zone contents not deleted: $e');
      if (context.mounted) showNote(context, 'Не удалось удалить записи');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _zones,
      builder: (context, _) {
        final zones = _zones.zones;
        final unconfirmed = _zones.unconfirmed;
        // While the list waits to be confirmed, that is the main action.
        final add = unconfirmed
            ? OutlinedButton.icon(
                style: Ui.outlined,
                onPressed: () => _open(context),
                icon: const Icon(Icons.add),
                label: const Text('Добавить зону'),
              )
            : FilledButton.icon(
                style: Ui.filled,
                onPressed: () => _open(context),
                icon: const Icon(Icons.add),
                label: const Text('Добавить зону'),
              );
        final saveError = _zones.saveError;
        return SubPage(
          title: 'Безопасные зоны',
          bottom: add,
          child: ListView(
            padding: const EdgeInsets.only(bottom: Ui.pad),
            children: [
              if (unconfirmed)
                InfoPanel(
                  error: true,
                  icon: Icons.warning_amber_rounded,
                  text:
                      '${_zones.loadError ?? 'Список зон мог быть прочитан не полностью'}. '
                      'Пока вы не подтвердите список, зоной считается '
                      'всё: ничего не собирается и никуда не '
                      'отправляется. Проверьте зоны ниже, добавьте '
                      'недостающие и подтвердите.',
                  action: 'Подтвердить список',
                  onAction: _zones.confirmZones,
                ),
              if (saveError != null) InfoPanel(text: saveError, error: true),
              if (zones.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Ui.pad,
                    Ui.gap,
                    Ui.pad,
                    Ui.gap,
                  ),
                  child: Text(
                    unconfirmed
                        ? 'В списке нет ни одной зоны.'
                        : 'Отметьте места, о которых приложение не '
                              'должно ничего запоминать, — например, '
                              'дом.',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
              for (final zone in zones)
                BigRow(
                  icon: Icons.shield_outlined,
                  title: zone.name,
                  subtitle: 'Радиус ${formatZoneRadius(zone.radiusM)}',
                  onTap: () => _open(context, zone),
                ),
              const SizedBox(height: Ui.gap),
              const InfoPanel(text: _explanation),
            ],
          ),
        );
      },
    );
  }
}

/// Adds a zone (centre, then name and radius) or edits an existing one.
/// Pops with the zone when one was added.
class _ZoneEditor extends StatefulWidget {
  const _ZoneEditor({
    required this.user,
    required this.services,
    this.existing,
  });

  final UserData user;
  final MapServices services;
  final PrivacyZone? existing;

  @override
  State<_ZoneEditor> createState() => _ZoneEditorState();
}

class _ZoneEditorState extends State<_ZoneEditor> {
  static const _presets = [300.0, 500.0, 1000.0, 2000.0];

  LatLng? _center;
  String? _centerLabel;
  late String _name = widget.existing?.name ?? defaultZoneName;
  late double _radius = widget.existing?.radiusM ?? PrivacyZone.defaultRadiusM;

  bool get _isNew => widget.existing == null;

  void _setCenter(LatLng point, String label, {String? name}) => setState(() {
    _center = point;
    _centerLabel = label;
    if (name != null) _name = name;
  });

  void _adjust(int direction) {
    // Finer steps where they matter: around a house.
    final step = direction > 0
        ? (_radius < 1000 ? 50.0 : 100.0)
        : (_radius <= 1000 ? 50.0 : 100.0);
    final next = ((_radius + direction * step) / 50).round() * 50.0;
    setState(
      () =>
          _radius = next.clamp(PrivacyZone.minRadiusM, PrivacyZone.maxRadiusM),
    );
  }

  Future<void> _rename() async {
    final name = await promptText(
      context,
      title: 'Название зоны',
      initial: _name,
      label: 'Название',
      confirm: 'Готово',
    );
    if (name == null || !mounted) return;
    setState(() => _name = name.trim().isEmpty ? defaultZoneName : name.trim());
  }

  void _save() {
    final zones = widget.user.zones;
    final existing = widget.existing;
    if (existing != null) {
      zones.update(existing.copyWith(name: _name, radiusM: _radius));
      Navigator.of(context).pop();
      return;
    }
    // The stored centre is moved off the chosen point on purpose.
    final zone = zones.add(
      PrivacyZone.around(_center!, name: _name, radiusM: _radius),
    );
    Navigator.of(context).pop(zone);
  }

  Future<void> _delete() async {
    final zone = widget.existing!;
    final ok = await confirmAction(
      context,
      title: 'Удалить зону «${zone.name}»?',
      text: 'Здесь снова будут собираться и отправляться данные.',
      confirm: 'Удалить',
    );
    if (!ok || !mounted) return;
    widget.user.zones.remove(zone.id);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_isNew && _center == null) return _centerStep(context);
    // "Back" from a new zone's form returns to the choice of its centre.
    return PopScope(
      canPop: !_isNew,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _center = null);
      },
      child: _form(context),
    );
  }

  Widget _form(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final canShrink = _radius > PrivacyZone.minRadiusM;
    final canGrow = _radius < PrivacyZone.maxRadiusM;

    Widget round(IconData icon, String label, VoidCallback? onPressed) =>
        IconButton.filledTonal(
          tooltip: label,
          iconSize: 28,
          constraints: const BoxConstraints.tightFor(width: 64, height: 64),
          icon: Icon(icon),
          onPressed: onPressed,
        );

    return SubPage(
      title: _isNew ? 'Новая зона' : 'Зона',
      bottom: FilledButton.icon(
        style: Ui.filled,
        onPressed: _save,
        icon: const Icon(Icons.check),
        label: Text(_isNew ? 'Сохранить зону' : 'Сохранить'),
      ),
      child: ListView(
        padding: const EdgeInsets.only(bottom: Ui.pad),
        children: [
          BigRow(
            icon: Icons.label_outline,
            title: _name,
            subtitle: 'Название',
            trailing: const Icon(Icons.edit_outlined),
            onTap: _rename,
          ),
          if (_isNew)
            BigRow(
              icon: Icons.place_outlined,
              title: _centerLabel ?? 'Точка на карте',
              subtitle: 'Место, которое нужно скрыть',
              trailing: const Icon(Icons.edit_outlined),
              onTap: () => setState(() => _center = null),
            ),
          const SectionHeader('Радиус'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Ui.pad),
            child: Row(
              children: [
                round(
                  Icons.remove,
                  'Уменьшить радиус',
                  canShrink ? () => _adjust(-1) : null,
                ),
                Expanded(
                  child: Text(
                    formatZoneRadius(_radius),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                round(
                  Icons.add,
                  'Увеличить радиус',
                  canGrow ? () => _adjust(1) : null,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Ui.pad, Ui.pad, Ui.pad, 0),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<double>(
                showSelectedIcon: false,
                emptySelectionAllowed: true,
                style: Ui.segmented(),
                segments: [
                  for (final r in _presets)
                    ButtonSegment(value: r, label: Text(formatZoneRadius(r))),
                ],
                selected: {if (_presets.contains(_radius)) _radius},
                onSelectionChanged: (s) {
                  if (s.isNotEmpty) setState(() => _radius = s.first);
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Ui.pad, Ui.pad, Ui.pad, 0),
            child: Text(
              _isNew
                  ? 'Круг нарочно сдвинут в сторону от выбранной точки: '
                        'иначе по местам, где обрываются записи, можно '
                        'вычислить точный адрес.'
                  : 'Центр зоны не меняется. Чтобы перенести зону, удалите '
                        'её и добавьте заново.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          if (!_isNew)
            Padding(
              padding: const EdgeInsets.fromLTRB(Ui.pad, 24, Ui.pad, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: Ui.text.copyWith(
                    foregroundColor: WidgetStatePropertyAll(colors.error),
                  ),
                  onPressed: _delete,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Удалить зону'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// First step of a new zone: what to hide.
  Widget _centerStep(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final home = widget.user.places.home;
    final here = widget.services.myPosition;

    Widget choice(
      IconData icon,
      String title,
      String detail,
      VoidCallback onTap, {
      bool primary = false,
    }) => Padding(
      padding: const EdgeInsets.fromLTRB(Ui.pad, 0, Ui.pad, Ui.gap),
      child: Material(
        color: colors.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Ui.radius),
          // The suggested choice is outlined, not shouted.
          side: primary
              ? BorderSide(color: colors.primary, width: 1.5)
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Ui.pad,
                vertical: 12,
              ),
              child: Row(
                children: [
                  Icon(icon, size: 28, color: colors.primary),
                  const SizedBox(width: Ui.pad),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(title, style: theme.textTheme.titleMedium),
                        Text(
                          detail,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    return SubPage(
      title: 'Что скрыть',
      child: ListView(
        padding: const EdgeInsets.only(top: Ui.gap, bottom: Ui.pad),
        children: [
          if (home != null)
            choice(
              Icons.home_outlined,
              'Вокруг дома',
              home.address ?? 'Сохранённое место «${home.name}»',
              () => _setCenter(home.point, 'Вокруг дома', name: 'Дом'),
              primary: true,
            ),
          if (here != null)
            choice(
              Icons.my_location,
              'Моё местоположение',
              'Там, где вы сейчас',
              () => _setCenter(here, 'Моё местоположение'),
            ),
          choice(
            Icons.map_outlined,
            'На карте',
            'Подвиньте карту под прицел и подтвердите',
            () async {
              final p = await widget.services.pickOnMap(title: 'Центр зоны');
              if (p != null && mounted) {
                _setCenter(p.point, p.label ?? 'Точка на карте');
              }
            },
          ),
          choice(Icons.search, 'Найти', 'Адрес, улица, заведение', () async {
            final p = await searchPoint(context, widget.services);
            if (p != null && mounted) {
              _setCenter(p.point, p.label ?? 'Найденное место');
            }
          }),
        ],
      ),
    );
  }
}
