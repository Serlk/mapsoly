import 'dart:async';

import 'package:flutter/material.dart';

import 'map/ui_kit.dart';
import 'positioning/sources/linux_compass.dart';
import 'settings.dart';

/// Builds the compass the settings ask for.
DeviceCompass compassFor(AppSettings settings) => DeviceCompass(
  choice: settings.compass,
  iio: IioCompass(
    magnetName: settings.magnetSensor,
    accelName: settings.accelSensor,
  ),
);

/// "Sensors" (Linux): which compass to use, chosen by hand when the
/// automatic pick is wrong, with the live reading to check it against a
/// real compass or a known street.
class SensorsScreen extends StatefulWidget {
  const SensorsScreen({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<SensorsScreen> createState() => _SensorsScreenState();
}

class _SensorsScreenState extends State<SensorsScreen> {
  late final List<String> _magnets = IioCompass.sensors('magn');
  late final List<String> _accels = IioCompass.sensors('accel');
  DeviceCompass? _compass;
  StreamSubscription<double>? _sub;
  double? _heading;
  String? _kind;
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    _restart();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _compass?.dispose();
    super.dispose();
  }

  /// Starts the compass as it is set up now, to show what it reads.
  Future<void> _restart() async {
    await _sub?.cancel();
    final old = _compass;
    final compass = _compass = compassFor(widget.settings);
    setState(() {
      _heading = null;
      _kind = null;
      _checked = false;
    });
    unawaited(old?.dispose());
    try {
      final kind = await compass.describe();
      if (!mounted || compass != _compass) return;
      setState(() {
        _kind = kind;
        _checked = true;
      });
      _sub = compass.headings.listen((h) {
        if (mounted) setState(() => _heading = h);
      });
      await compass.start();
    } on Object catch (e) {
      debugPrint('Compass not started: $e');
      if (mounted) setState(() => _checked = true);
    }
  }

  void _set({CompassChoice? choice, String? magnet, String? accel}) {
    final s = widget.settings;
    s.setCompass(
      choice: choice ?? s.compass,
      // An empty name is "automatic".
      magnet: magnet == null
          ? s.magnetSensor
          : (magnet.isEmpty ? null : magnet),
      accel: accel == null ? s.accelSensor : (accel.isEmpty ? null : accel),
    );
    _restart();
  }

  static const _points = ['С', 'СВ', 'В', 'ЮВ', 'Ю', 'ЮЗ', 'З', 'СЗ'];

  String get _reading {
    if (!_checked) return 'Проверяю…';
    final kind = _kind;
    if (kind == null) {
      return switch (widget.settings.compass) {
        CompassChoice.system => 'Системная служба не сообщает о компасе',
        CompassChoice.raw => 'Магнитометр или акселерометр не найден',
        CompassChoice.auto => 'Компас не найден',
      };
    }
    final from = kind == 'system' ? 'системная служба' : 'датчики напрямую';
    final h = _heading;
    if (h == null) return 'Жду показаний ($from)';
    final point = _points[((h + 22.5) % 360 ~/ 45)];
    return '${h.round()}° $point · $from';
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final theme = Theme.of(context);

    Widget choice(CompassChoice value, String title, String subtitle) =>
        RadioListTile<CompassChoice>(
          contentPadding: const EdgeInsets.symmetric(horizontal: Ui.pad),
          value: value,
          // ignore: deprecated_member_use
          groupValue: s.compass,
          // ignore: deprecated_member_use
          onChanged: (v) => _set(choice: v),
          title: Text(title),
          subtitle: Text(subtitle),
        );

    Widget sensor(
      String title,
      List<String> found,
      String? current,
      void Function(String name) onChanged,
    ) => Padding(
      padding: const EdgeInsets.fromLTRB(Ui.pad, 4, Ui.pad, 4),
      child: DropdownButtonFormField<String>(
        key: ValueKey('$title-$current'),
        initialValue: current != null && found.contains(current) ? current : '',
        decoration: InputDecoration(labelText: title),
        items: [
          const DropdownMenuItem(value: '', child: Text('Автоматически')),
          for (final name in found)
            DropdownMenuItem(value: name, child: Text(name)),
        ],
        onChanged: (v) => onChanged(v ?? ''),
      ),
    );

    return SubPage(
      title: 'Датчики',
      child: ListView(
        children: [
          const SectionHeader('Компас сейчас'),
          Padding(
            padding: const EdgeInsets.fromLTRB(Ui.pad, 0, Ui.pad, Ui.gap),
            child: Text(_reading, style: theme.textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Ui.pad),
            child: Text(
              'Направление верхнего края телефона; в держателе стоя — куда '
              'смотрит задняя стенка. Сверьте с известной улицей.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SectionHeader('Откуда брать'),
          choice(
            CompassChoice.auto,
            'Автоматически',
            'Системная служба, а если у неё нет компаса — датчики напрямую',
          ),
          choice(
            CompassChoice.system,
            'Системная служба',
            'iio-sensor-proxy: показания уже обработаны системой',
          ),
          choice(
            CompassChoice.raw,
            'Датчики напрямую',
            'Магнитометр и акселерометр ядра, расчёт в приложении',
          ),
          if (s.compass != CompassChoice.system) ...[
            const SectionHeader('Датчики для расчёта'),
            if (_magnets.isEmpty || _accels.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Ui.pad),
                child: Text(
                  _magnets.isEmpty
                      ? 'Ядро не показывает магнитометр'
                      : 'Ядро не показывает акселерометр',
                ),
              ),
            sensor(
              'Магнитометр',
              _magnets,
              s.magnetSensor,
              (v) => _set(magnet: v),
            ),
            sensor(
              'Акселерометр',
              _accels,
              s.accelSensor,
              (v) => _set(accel: v),
            ),
          ],
          const SizedBox(height: Ui.pad),
        ],
      ),
    );
  }
}
