import 'package:flutter/material.dart';

import 'map/location_sheet.dart';
import 'obd/obd_service.dart';
import 'obd/obd_widgets.dart';
import 'positioning/positioning.dart';
import 'settings.dart';
import 'traffic/traffic.dart';

/// Settings: appearance, traffic source, offline maps and location.
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
  });

  final AppSettings settings;
  final TrafficController traffic;
  final PositioningNotifier? positioning;

  /// Null until the adapter service has started.
  final ObdService? obd;
  final VoidCallback onOpenPacks;

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
    // Big segmented controls: one tap, no menus.
    Widget choice<T>(
      Map<T, String> names,
      T selected,
      ValueChanged<T> onChanged,
    ) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<T>(
          showSelectedIcon: false,
          style: const ButtonStyle(
            minimumSize: WidgetStatePropertyAll(Size(0, 56)),
          ),
          segments: [
            for (final e in names.entries)
              ButtonSegment(value: e.key, label: Text(e.value)),
          ],
          selected: {selected},
          onSelectionChanged: (s) => onChanged(s.first),
        ),
      ),
    );

    return ListenableBuilder(
      listenable: Listenable.merge([settings, traffic]),
      builder: (context, _) => ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          header('Оформление'),
          choice(
            _themeNames,
            settings.themeMode,
            (v) => settings.themeMode = v,
          ),
          header('Пробки'),
          choice(_trafficNames, traffic.source, traffic.select),
          header('Карты'),
          ListTile(
            minTileHeight: 64,
            leading: const Icon(Icons.download_for_offline_outlined),
            title: const Text('Карты для работы без сети'),
            subtitle: const Text('Скачать, обновить или удалить регионы'),
            trailing: const Icon(Icons.chevron_right),
            onTap: onOpenPacks,
          ),
          ListTile(
            minTileHeight: 64,
            leading: const Icon(Icons.dns_outlined),
            title: const Text('Сервер карт'),
            subtitle: Text(
              settings.hasCustomCatalog
                  ? Uri.parse(settings.catalogUrl).host
                  : '${Uri.parse(settings.catalogUrl).host} (по умолчанию)',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _editServer(context),
          ),
          const Divider(height: 24),
          LocationSheet(positioning: positioning, settings: settings),
          if (obd != null)
            ObdSettingsSection(settings: settings, service: obd!),
        ],
      ),
    );
  }
}
