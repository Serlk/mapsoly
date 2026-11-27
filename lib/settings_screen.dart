import 'map/position_arrow.dart';
import 'sensors_screen.dart';
import 'package:flutter/material.dart';

import 'map/location_sheet.dart';
import 'map/point_picker.dart';
import 'map/ui_kit.dart';
import 'obd/obd_service.dart';
import 'obd/obd_widgets.dart';
import 'positioning/positioning.dart';
import 'settings.dart';
import 'traffic/traffic.dart';
import 'user/data_screen.dart';
import 'user/file_exchange.dart';
import 'user/places_screen.dart';
import 'user/user_data.dart';
import 'user/user_places.dart';
import 'user/zones_screen.dart';

/// Settings, first screen: a short list of titled blocks. The two choices
/// made most often (theme, traffic) are right here; everything bigger —
/// places, location, privacy zones, the car, data — opens as its own screen.
///
/// Shown as a section of the main screen, above the bottom bar. Rows are
/// tall and controls large enough to hit without aiming.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.traffic,
    required this.positioning,
    required this.obd,
    required this.onOpenPacks,
    this.showSensors = false,
    this.locationAccess,
    required this.user,
    required this.services,
    required this.files,
    this.canTilt = false,
    this.onGoToPlace,
  });

  final AppSettings settings;
  final TrafficController traffic;
  final PositioningNotifier? positioning;

  /// Null until the adapter service has started.
  final ObdService? obd;
  final VoidCallback onOpenPacks;

  /// Offers the choice of sensors (Linux; Android needs none).
  final bool showSensors;

  /// See [LocationSheet.access].
  final LocationAccess? locationAccess;
  final UserData user;
  final MapServices services;
  final FileExchange files;

  /// Whether the map engine can tilt: shows the 3D option.
  final bool canTilt;

  /// "Go there" from the list of saved places.
  final void Function(SavedPlace place)? onGoToPlace;

  static const _themeNames = {
    ThemeMode.system: 'Как в системе',
    ThemeMode.light: 'Светлая',
    ThemeMode.dark: 'Тёмная',
  };
  static const _trafficNames = {
    TrafficSource.off: 'Выключены',
    TrafficSource.yandex: 'Яндекс',
    TrafficSource.google: 'Google',
  };

  /// Asks for the address of a map server. Anyone can host the packs (a
  /// folder with catalog.json behind any web server), so it is editable.
  Future<void> _editServer(BuildContext context) async {
    final controller = TextEditingController(
      text: settings.hasCustomCatalog ? settings.catalogUrl : '',
    );
    String? error;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Сервер карт'),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Адрес',
              hintText: Uri.parse(defaultCatalogUrl).host,
              helperText: 'Пусто — сервер по умолчанию',
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                final text = controller.text.trim();
                if (text.isEmpty) {
                  settings.catalogUrl = null;
                  Navigator.pop(context);
                  return;
                }
                final url = normalizeCatalogUrl(text);
                if (url == null) {
                  setState(() => error = 'Это не похоже на адрес сервера');
                  return;
                }
                settings.catalogUrl = url;
                Navigator.pop(context);
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
  }

  void _push(BuildContext context, WidgetBuilder page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: page));

  String _placesSummary() {
    final places = user.places;
    final parts = [
      if (places.home != null) 'дом',
      if (places.work != null) 'работа',
      if (places.favorites.isNotEmpty)
        plural(places.favorites.length, 'место', 'места', 'мест'),
    ];
    if (parts.isEmpty) return 'Дом, работа и любимые места';
    final text = parts.join(', ');
    return text[0].toUpperCase() + text.substring(1);
  }

  String _locationSummary() {
    final status = positioning?.status;
    if (status == null) return 'На этом устройстве не запустилось';
    final fix = status.estimate;
    if (fix == null) return 'Пока не определено';
    final zone = status.privateArea ? ' · безопасная зона' : '';
    return 'Точность около ${fix.accuracyM.round()} м$zone';
  }

  String _obdSummary() {
    final service = obd;
    if (service == null || !settings.obd.usable) return 'Адаптер ELM327';
    return service.connected ? 'Адаптер подключён' : 'Адаптер не на связи';
  }

  @override
  Widget build(BuildContext context) {
    // Big segmented controls: one tap, no menus.
    Widget choice<T>(
      Map<T, String> names,
      T selected,
      ValueChanged<T> onChanged,
    ) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: Ui.pad),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<T>(
          showSelectedIcon: false,
          style: Ui.segmented(),
          segments: [
            for (final e in names.entries)
              ButtonSegment(value: e.key, label: Text(e.value)),
          ],
          selected: {selected},
          onSelectionChanged: (s) => onChanged(s.first),
        ),
      ),
    );

    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([
            settings,
            traffic,
            positioning,
            obd,
            user.places,
            user.zones,
          ]),
          builder: (context, _) {
            final zones = user.zones;
            return ListView(
              padding: const EdgeInsets.only(bottom: Ui.pad),
              children: [
                const SectionHeader('Оформление'),
                choice(
                  _themeNames,
                  settings.themeMode,
                  (v) => settings.themeMode = v,
                ),
                const SectionHeader('Пробки'),
                choice(_trafficNames, traffic.source, traffic.select),
                // A layer of its own: shown with any traffic choice.
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: Ui.pad,
                  ),
                  secondary: const Icon(Icons.blur_on),
                  title: const Text('Карта сигналов'),
                  subtitle: const Text(
                    'Тепловая карта собранных точек Wi-Fi, сот и Bluetooth '
                    'поверх карты',
                  ),
                  value: settings.signalHeat,
                  onChanged: (v) => settings.signalHeat = v,
                ),
                const SectionHeader('Карты'),
                BigRow(
                  icon: Icons.download_for_offline_outlined,
                  title: 'Карты для работы без сети',
                  subtitle: 'Скачать, обновить или удалить регионы',
                  onTap: onOpenPacks,
                ),
                BigRow(
                  icon: Icons.dns_outlined,
                  title: 'Сервер карт',
                  subtitle: settings.hasCustomCatalog
                      ? Uri.parse(settings.catalogUrl).host
                      : '${Uri.parse(settings.catalogUrl).host} '
                            '(по умолчанию)',
                  onTap: () => _editServer(context),
                ),
                if (canTilt)
                  SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: Ui.pad,
                    ),
                    secondary: const Icon(Icons.view_in_ar_outlined),
                    title: const Text('Объёмная карта в движении'),
                    subtitle: const Text(
                      'Когда машина едет, карта наклоняется и '
                      'поворачивается по ходу — с маршрутом и без него',
                    ),
                    value: settings.drive3d,
                    onChanged: (v) => settings.drive3d = v,
                  ),
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: Ui.pad,
                  ),
                  title: const Text('Плавная карта в движении'),
                  subtitle: const Text(
                    'Рисовать карту с полной частотой экрана, пока она едет '
                    'за машиной. Если выключить — 30 кадров в секунду: '
                    'меньше нагрузка и расход батареи, но движение грубее',
                  ),
                  value: settings.smoothDrive,
                  onChanged: (v) => settings.smoothDrive = v,
                ),
                // The marker of the position, when its direction is known.
                Padding(
                  padding: const EdgeInsets.fromLTRB(Ui.pad, Ui.gap, Ui.pad, 4),
                  child: Text(
                    'Значок моего положения',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Ui.pad),
                  child: Wrap(
                    spacing: Ui.gap,
                    runSpacing: Ui.gap,
                    children: [
                      for (final arrow in PositionArrow.values)
                        _ArrowChoice(
                          arrow: arrow,
                          selected: settings.positionArrow == arrow,
                          onTap: () => settings.positionArrow = arrow,
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Ui.pad, 4, Ui.pad, Ui.gap),
                  child: Text(
                    'Показывает, куда вы едете или куда смотрит телефон. '
                    'Без компаса и без движения остаётся точка.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: Ui.pad,
                  ),
                  secondary: const Icon(Icons.speed),
                  title: const Text('Сигнал о превышении скорости'),
                  subtitle: const Text(
                    'Звук, когда скорость выше ограничения на 20 км/ч — '
                    'с этого начинаются штрафы',
                  ),
                  value: settings.speedSound,
                  onChanged: (v) => settings.speedSound = v,
                ),
                const SectionHeader('Мои места'),
                BigRow(
                  icon: Icons.star_outline,
                  title: 'Дом, работа, места',
                  subtitle: _placesSummary(),
                  onTap: () => _push(
                    context,
                    (_) => PlacesScreen(
                      user: user,
                      services: services,
                      onGo: onGoToPlace,
                    ),
                  ),
                ),
                const SectionHeader('Местоположение'),
                BigRow(
                  icon: Icons.my_location,
                  title: 'Как определяется',
                  subtitle: _locationSummary(),
                  onTap: () => _push(
                    context,
                    (_) => SubPage(
                      title: 'Местоположение',
                      child: LocationSheet(
                        positioning: positioning,
                        settings: settings,
                        showTitle: false,
                        access: locationAccess,
                      ),
                    ),
                  ),
                ),
                // Only where sensors may need picking by hand.
                if (showSensors)
                  BigRow(
                    icon: Icons.explore_outlined,
                    title: 'Датчики',
                    subtitle: 'Компас: откуда брать показания',
                    onTap: () => _push(
                      context,
                      (_) => SensorsScreen(settings: settings),
                    ),
                  ),
                const SectionHeader('Безопасные зоны'),
                BigRow(
                  icon: Icons.shield_outlined,
                  title: 'Где ничего не записывать',
                  subtitle: zones.unconfirmed
                      ? 'Список повреждён — проверьте его'
                      : zones.isEmpty
                      ? 'Зон нет'
                      : plural(zones.zones.length, 'зона', 'зоны', 'зон'),
                  warning: zones.unconfirmed,
                  onTap: () => _push(
                    context,
                    (_) => ZonesScreen(
                      user: user,
                      services: services,
                      engine: positioning?.engine,
                    ),
                  ),
                ),
                const SectionHeader('Автомобиль'),
                BigRow(
                  icon: Icons.directions_car_outlined,
                  title: 'Связь с автомобилем',
                  subtitle: _obdSummary(),
                  onTap: obd == null
                      ? null
                      : () => _push(
                          context,
                          (_) => SubPage(
                            title: 'Автомобиль',
                            child: SingleChildScrollView(
                              child: ObdSettingsSection(
                                settings: settings,
                                service: obd!,
                                showHeader: false,
                              ),
                            ),
                          ),
                        ),
                ),
                const SectionHeader('Данные'),
                BigRow(
                  icon: Icons.folder_outlined,
                  title: 'Файлы и собранные данные',
                  subtitle: 'Маршруты и места, журналы поездок, своя база',
                  onTap: () => _push(
                    context,
                    (_) => DataScreen(
                      user: user,
                      files: files,
                      engine: positioning?.engine,
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
}

/// One of the position markers to choose from: its picture and name.
class _ArrowChoice extends StatelessWidget {
  const _ArrowChoice({
    required this.arrow,
    required this.selected,
    required this.onTap,
  });

  final PositionArrow arrow;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: arrow.label,
      child: InkWell(
        borderRadius: BorderRadius.circular(Ui.radiusSmall),
        onTap: onTap,
        child: Container(
          width: 104,
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          decoration: BoxDecoration(
            color: selected ? colors.primary.withValues(alpha: 0.12) : null,
            borderRadius: BorderRadius.circular(Ui.radiusSmall),
            border: Border.all(
              color: selected ? colors.primary : colors.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PositionArrowIcon(style: arrow, size: 44),
              const SizedBox(height: 6),
              ExcludeSemantics(
                child: Text(
                  arrow.label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
