import 'package:flutter/material.dart';

import '../settings.dart';
import 'obd_service.dart';
import 'obd_session.dart';
import 'rfcomm_transport.dart';

String _num(double? v, [int digits = 1]) =>
    v == null ? '—' : v.toStringAsFixed(digits).replaceAll('.', ',');

const _fuelNames = {
  FuelType.petrol: 'бензин',
  FuelType.diesel: 'дизель',
  FuelType.lpg: 'газ (пропан)',
  FuelType.cng: 'газ (метан)',
  FuelType.electric: 'электричество',
  FuelType.hybrid: 'гибрид',
  FuelType.other: 'другое',
};

/// The ELM327 block of the settings screen.
class ObdSettingsSection extends StatelessWidget {
  const ObdSettingsSection({
    super.key,
    required this.settings,
    required this.service,
  });

  final AppSettings settings;
  final ObdService service;

  static const _linkNames = {
    ObdLink.bluetooth: 'Bluetooth',
    ObdLink.wifi: 'Wi-Fi',
    ObdLink.serial: 'Провод',
  };
  static const _addressHints = {
    ObdLink.bluetooth: 'Выберите адаптер',
    ObdLink.wifi: 'Адрес адаптера, например 192.168.0.10:35000',
    ObdLink.serial: 'Порт, например /dev/ttyUSB0',
  };

  String _status() {
    final config = settings.obd;
    if (!config.usable) return 'Адаптер не выбран';
    switch (service.state) {
      case ObdState.connected:
        return 'Подключено${service.adapter == null ? '' : ': ${service.adapter}'}';
      case ObdState.connecting:
        return 'Подключение…';
      case ObdState.disconnected:
        return service.lastError == null
            ? 'Нет связи с адаптером'
            : 'Нет связи с адаптером. Проверьте, что зажигание включено';
    }
  }

  Future<void> _pickBluetooth(BuildContext context) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => FutureBuilder<List<BluetoothDevice>>(
        future: listBluetoothDevices(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const ListTile(
              minTileHeight: 72,
              leading: Icon(Icons.bluetooth_disabled),
              title: Text('Bluetooth недоступен'),
              subtitle: Text('Включите его в настройках системы'),
            );
          }
          final devices = snapshot.data;
          if (devices == null) {
            return const SizedBox(
              height: 96,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (devices.isEmpty) {
            return const ListTile(
              minTileHeight: 72,
              leading: Icon(Icons.bluetooth_searching),
              title: Text('Нет сопряжённых устройств'),
              subtitle: Text(
                'Сопрягите адаптер в настройках Bluetooth системы '
                '(код обычно 1234 или 0000)',
              ),
            );
          }
          return ListView(
            shrinkWrap: true,
            children: [
              for (final d in devices)
                ListTile(
                  minTileHeight: 64,
                  leading: Icon(
                    d.looksLikeObd ? Icons.directions_car : Icons.bluetooth,
                  ),
                  title: Text(d.name),
                  subtitle: Text(
                    d.paired ? d.address : '${d.address} · не сопряжено',
                  ),
                  onTap: () => Navigator.pop(context, d.address),
                ),
            ],
          );
        },
      ),
    );
    if (picked != null) settings.obd = settings.obd.copyWith(address: picked);
  }

  Future<void> _typeAddress(BuildContext context) async {
    final config = settings.obd;
    final controller = TextEditingController(text: config.address);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_linkNames[config.link]!),
        content: TextField(
          controller: controller,
          autofocus: true,
          autocorrect: false,
          decoration: InputDecoration(labelText: _addressHints[config.link]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null) settings.obd = config.copyWith(address: value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([settings, service]),
      builder: (context, _) {
        final config = settings.obd;
        void set(ObdConfig c) => settings.obd = c;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
              child: Text(
                'Автомобиль',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            SwitchListTile(
              title: const Text('Адаптер ELM327'),
              subtitle: Text(
                config.enabled
                    ? _status()
                    : 'Скорость с автомобиля, когда нет GPS',
              ),
              value: config.enabled,
              onChanged: (v) => set(config.copyWith(enabled: v)),
            ),
            if (config.enabled) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ObdLink>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      minimumSize: WidgetStatePropertyAll(Size(0, 56)),
                    ),
                    segments: [
                      for (final e in _linkNames.entries)
                        ButtonSegment(value: e.key, label: Text(e.value)),
                    ],
                    selected: {config.link},
                    // Another kind of link needs another kind of address.
                    onSelectionChanged: (s) =>
                        set(config.copyWith(link: s.first, address: '')),
                  ),
                ),
              ),
              ListTile(
                minTileHeight: 64,
                leading: const Icon(Icons.settings_input_antenna),
                title: Text(
                  config.address.isEmpty
                      ? _addressHints[config.link]!
                      : config.address,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => config.link == ObdLink.bluetooth
                    ? _pickBluetooth(context)
                    : _typeAddress(context),
              ),
              SwitchListTile(
                title: const Text('Расход топлива'),
                subtitle: const Text('Мгновенный и средний за поездку'),
                value: config.fuel,
                onChanged: (v) => set(config.copyWith(fuel: v)),
              ),
              SwitchListTile(
                title: const Text('Сведения о машине'),
                subtitle: const Text(
                  'Обороты, температура, напряжение, ошибки двигателя',
                ),
                value: config.vehicleInfo,
                onChanged: (v) => set(config.copyWith(vehicleInfo: v)),
              ),
              SwitchListTile(
                title: const Text('Журнал поездок'),
                subtitle: const Text('Запись показаний в файл раз в секунду'),
                value: config.tripLog,
                onChanged: (v) => set(config.copyWith(tripLog: v)),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// Small pill on the map with the one or two numbers worth a glance while
/// driving; a tap opens the full sheet. Hidden while no adapter is
/// connected, so it never takes space for nothing.
class VehicleChip extends StatelessWidget {
  const VehicleChip({super.key, required this.service});

  final ObdService service;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        if (!service.connected) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        final t = service.telemetry;
        final v = service.vehicle;
        final hot = (t.coolantC ?? 0) >= 108;
        final warn = hot || v.milOn == true;
        final parts = <String>[
          if (t.consumptionLPer100km != null)
            '${_num(t.consumptionLPer100km)} л/100'
          else if (t.fuelRateLph != null)
            '${_num(t.fuelRateLph)} л/ч',
          if (hot) '${t.coolantC}°',
        ];
        return Card(
          color: warn ? colors.errorContainer : null,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => showModalBottomSheet<void>(
              context: context,
              showDragHandle: true,
              isScrollControlled: true,
              builder: (context) => VehicleSheet(service: service),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      warn
                          ? Icons.warning_amber_rounded
                          : Icons.directions_car_outlined,
                      size: 22,
                      color: warn ? colors.onErrorContainer : null,
                    ),
                    if (parts.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Text(
                        parts.join(' · '),
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: warn ? colors.onErrorContainer : null,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Everything the car reports, opened from [VehicleChip].
class VehicleSheet extends StatelessWidget {
  const VehicleSheet({super.key, required this.service});

  final ObdService service;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final t = service.telemetry;
        final v = service.vehicle;
        final speed = service.speedMps;
        final rows = <(String, String)>[
          ('Скорость', speed == null ? '—' : '${(speed * 3.6).round()} км/ч'),
          if (t.rpm != null) ('Обороты', '${t.rpm!.round()} об/мин'),
          if (t.coolantC != null) ('Температура двигателя', '${t.coolantC} °C'),
          if (t.fuelRateLph != null)
            (
              t.fuelRateEstimated ? 'Расход (оценка по воздуху)' : 'Расход',
              t.consumptionLPer100km != null
                  ? '${_num(t.consumptionLPer100km)} л/100 км'
                  : '${_num(t.fuelRateLph)} л/ч',
            ),
          if (t.tripConsumptionLPer100km != null)
            (
              'Средний за поездку',
              '${_num(t.tripConsumptionLPer100km)} л/100 км',
            ),
          if (t.tripDistanceKm >= 0.1)
            (
              'Поездка',
              '${_num(t.tripDistanceKm)} км'
                  '${t.tripFuelL > 0 ? ' · ${_num(t.tripFuelL, 2)} л' : ''}',
            ),
          if (t.fuelLevelPercent != null)
            ('Топливо в баке', '${t.fuelLevelPercent!.round()} %'),
          if (t.batteryVolts != null)
            ('Бортовая сеть', '${_num(t.batteryVolts)} В'),
          if (v.fuelType != FuelType.unknown)
            ('Топливо', _fuelNames[v.fuelType] ?? '—'),
          if (v.vin != null) ('VIN', v.vin!),
          if (service.adapter != null) ('Адаптер', service.adapter!),
        ];
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Автомобиль', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              if (!service.connected)
                const Text('Адаптер не подключён')
              else ...[
                if (v.milOn == true || v.troubleCodes.isNotEmpty)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      v.troubleCodes.isEmpty
                          ? 'Горит индикатор неисправности двигателя'
                          : 'Ошибки двигателя: ${v.troubleCodes.join(', ')}',
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                for (final (label, value) in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            label,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Text(value, style: theme.textTheme.titleMedium),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}
