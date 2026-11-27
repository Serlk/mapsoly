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
                      ),
                    ),
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
