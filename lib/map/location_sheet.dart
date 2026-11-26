import 'package:flutter/material.dart';

import '../positioning/positioning.dart';
import '../settings.dart';

const _sourceNames = {
  PositionSource.gnss: 'спутники',
  PositionSource.wifi: 'Wi-Fi',
  PositionSource.cell: 'сотовые вышки',
  PositionSource.fused: 'спутники и радио',
  PositionSource.deadReckoning: 'счисление пути',
};

/// Where the position comes from right now, plus the privacy-relevant
/// switches: online lookups and wardriving.
class LocationSheet extends StatelessWidget {
  const LocationSheet({
    super.key,
    required this.positioning,
    required this.settings,
  });

  /// Null when positioning could not start on this device.
  final PositioningNotifier? positioning;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([positioning, settings]),
      builder: (context, _) {
        final status = positioning?.status;
        final fix = status?.estimate;
        final lines = <String>[
          if (status == null)
            'Определение местоположения на этом устройстве не запустилось'
          else ...[
            fix == null
                ? 'Местоположение пока не определено'
                : 'Источник: ${_sourceNames[fix.source]}, '
                      'точность около ${fix.accuracyM.round()} м',
            'Wi-Fi: видно ${status.wifiVisible}, известно ${status.wifiKnown}',
            'Соты: видно ${status.cellsVisible}, известно ${status.cellsKnown}',
            status.gnssConnected
                ? 'Спутники: в решении ${status.satellitesUsed} '
                      'из ${status.satellitesInView}'
                : 'Спутниковый приёмник недоступен',
            if (status.spoofingSuspected)
              'Похоже на подмену GPS — спутники не используются',
            if (status.jammingSuspected) 'Похоже на глушение GPS',
            if (status.onlineError != null) 'Онлайн-уточнение не отвечает',
          ],
        ];
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Местоположение',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
                  child: Text(line, style: theme.textTheme.bodyMedium),
                ),
              const SizedBox(height: 8),
              SwitchListTile(
                dense: true,
                title: const Text('Уточнять онлайн'),
                subtitle: const Text(
                  'Неизвестные Wi-Fi и соты отправляются в beaconDB и Apple',
                ),
                value: settings.onlineLocation,
                onChanged: (v) => settings.onlineLocation = v,
              ),
              SwitchListTile(
                dense: true,
                title: const Text('Собирать свою базу'),
                subtitle: const Text(
                  'Запоминать Wi-Fi и соты, пока спутники дают точную позицию',
                ),
                value: settings.wardriving,
                onChanged: (v) => settings.wardriving = v,
              ),
            ],
          ),
        );
      },
    );
  }
}
