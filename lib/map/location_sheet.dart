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

/// What stands between the app and the position, and the button that
/// deals with it; null when nothing does.
(String, String)? _accessProblem(LocationAccessState? state) => switch (state) {
  LocationAccessState.denied => (
    'Приложению не разрешён доступ к местоположению. Без него карта '
        'работает, но не знает, где вы.',
    'Разрешить',
  ),
  LocationAccessState.blocked => (
    'Приложению не разрешён доступ к местоположению. Включите «Точное '
        'местоположение» в разрешениях приложения.',
    'Открыть настройки',
  ),
  LocationAccessState.switchedOff => (
    'Определение местоположения выключено в системе.',
    'Открыть настройки',
  ),
  _ => null,
};

/// Where the position comes from right now, plus the privacy-relevant
/// switches: online lookups and wardriving.
class LocationSheet extends StatelessWidget {
  const LocationSheet({
    super.key,
    required this.positioning,
    required this.settings,
    this.showTitle = true,
    this.access,
  });

  /// Where the system asks the user before giving out the position: what
  /// was answered. Null when there is nothing to ask.
  final LocationAccess? access;

  /// False when the surrounding page already carries the title.
  final bool showTitle;

  /// Null when positioning could not start on this device.
  final PositioningNotifier? positioning;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([positioning, settings, access?.state]),
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
                // The app has no link to the receiver at all (its system
                // service is not running or not open to us): not the same
                // as a receiver that sees no satellites, which is the line
                // above with zeros.
                : 'Нет связи со спутниковым приёмником: системная служба '
                      'GNSS не запущена или недоступна',
            if (!status.spoofingCheck)
              status.spoofingSuspected
                  ? 'Проверка подмены выключена. Она бы спутникам не '
                        'поверила${spoofingReason(status.gnssHealth.anomalies)}'
                  : 'Проверка подмены GPS выключена'
            else if (status.spoofingSuspected)
              'Похоже на подмену GPS — спутники не используются'
                  '${spoofingReason(status.gnssHealth.anomalies)}',
            if (status.jammingSuspected) 'Похоже на глушение GPS',
            if (status.onlineError != null) 'Онлайн-уточнение не отвечает',
            if (status.privateArea)
              'Вы в безопасной зоне: сбор базы и онлайн-уточнение '
                  'приостановлены',
          ],
        ];
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showTitle)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Местоположение',
                    style: theme.textTheme.titleMedium,
                  ),
                )
              else
                const SizedBox(height: 8),
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
                  child: Text(line, style: theme.textTheme.bodyMedium),
                ),
              if (_accessProblem(access?.state.value) case final problem?)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(problem.$1, style: theme.textTheme.bodyMedium),
                      const SizedBox(height: 8),
                      FilledButton.tonal(
                        onPressed: access!.request,
                        child: Text(problem.$2),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: const Text('Уточнять онлайн'),
                subtitle: const Text(
                  'Неизвестные Wi-Fi и соты отправляются в beaconDB и Apple',
                ),
                value: settings.onlineLocation,
                onChanged: (v) => settings.onlineLocation = v,
              ),
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: const Text('Собирать свою базу'),
                subtitle: const Text(
                  'Запоминать Wi-Fi и соты, пока спутники дают точную позицию',
                ),
                value: settings.wardriving,
                onChanged: (v) => settings.wardriving = v,
              ),
              SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                title: const Text('Проверять подмену GPS'),
                subtitle: const Text(
                  'Если выключить, спутникам верят всегда, а своя база '
                  'не пополняется',
                ),
                value: settings.spoofingCheck,
                onChanged: (v) => settings.spoofingCheck = v,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Why the satellites are not believed, in a few words for the sheet: the
/// most telling reason only.
String spoofingReason(Set<GnssAnomaly> anomalies) {
  const reasons = {
    GnssAnomaly.motionMismatch: 'приёмник показывает движение, которого нет',
    GnssAnomaly.impossibleMotion: 'манёвры, невозможные для машины',
    GnssAnomaly.positionJump: 'позиция перескочила в другое место',
    GnssAnomaly.radioMismatch: 'не сходится с Wi-Fi и сотами',
    GnssAnomaly.uniformCn0: 'все спутники слышны одинаково',
  };
  for (final e in reasons.entries) {
    if (anomalies.contains(e.key)) return ': ${e.value}';
  }
  return '';
}
