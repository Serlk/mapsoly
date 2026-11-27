/// What the Titan 2 system GNSS service thinks of the satellites.
library;

import 'dart:async';

import 'package:dbus/dbus.dart';

/// The system's own verdict on spoofing. On the Titan 2 `t2-gnssd` filters
/// the receiver before anyone sees it: while it suspects spoofing the NMEA
/// stream carries no position at all, so to the app it looks exactly like
/// "no fix". This says which of the two it is.
class SystemGnssVerdict {
  const SystemGnssVerdict(this.state, this.reason);

  /// `ok`, `suspect` (fixes are withheld from applications) or `off`.
  final String state;

  /// Why, as the service puts it: `network: …`, `still: …`, `turn`,
  /// `speed`, `accel`, `time`, `jump`, `agc`; empty when not suspected.
  final String reason;

  bool get suspect => state == 'suspect';

  /// The reason in a few words for the screen; empty when there is none or
  /// it is one this app does not know.
  String get reasonText {
    final key = reason.split(':').first.trim();
    return const {
          'network': 'не сходится с позицией по Wi-Fi и сотам',
          'still': 'телефон лежит, а приёмник показывает движение',
          'turn': 'движение, невозможное физически',
          'speed': 'движение, невозможное физически',
          'accel': 'движение, невозможное физически',
          'time': 'время спутников расходится с сетевым',
          'jump': 'позиция перескочила в другое место',
          'agc': 'вход приёмника забит сильным сигналом',
        }[key] ??
        '';
  }

  @override
  bool operator ==(Object other) =>
      other is SystemGnssVerdict &&
      other.state == state &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(state, reason);
}

/// Follows `Spoofing` / `SpoofingReason` of `org.titan2.Gnss1` on the system
/// bus. No polling: one read when listened to, then the service's own
/// change signals (at most one a second). Silent where there is no such
/// service. Reading these properties does not switch the receiver on.
class Titan2GnssService {
  Titan2GnssService({DBusClient? client})
    : _client = client ?? DBusClient.system(),
      _ownsClient = client == null;

  final DBusClient _client;
  final bool _ownsClient;

  static const _name = 'org.titan2.Gnss1';

  Stream<SystemGnssVerdict> get verdicts {
    late StreamController<SystemGnssVerdict> out;
    StreamSubscription<DBusPropertiesChangedSignal>? sub;
    var state = 'ok', reason = '';
    void put(Map<String, DBusValue> props) {
      final s = props['Spoofing'], r = props['SpoofingReason'];
      if (s is DBusString) state = s.value;
      if (r is DBusString) reason = r.value;
      if (!out.isClosed) out.add(SystemGnssVerdict(state, reason));
    }

    out = StreamController<SystemGnssVerdict>(
      onListen: () async {
        final object = DBusRemoteObject(
          _client,
          name: _name,
          path: DBusObjectPath('/org/titan2/Gnss1'),
        );
        try {
          sub = object.propertiesChanged.listen((signal) {
            if (signal.propertiesInterface != _name) return;
            final changed = signal.changedProperties;
            if (changed.containsKey('Spoofing') ||
                changed.containsKey('SpoofingReason')) {
              put(changed);
            }
          });
          put({
            'Spoofing': await object.getProperty(_name, 'Spoofing'),
            'SpoofingReason': await object.getProperty(_name, 'SpoofingReason'),
          });
        } on Object {
          // No such service on this system: nothing to say.
        }
      },
      onCancel: () async {
        await sub?.cancel();
        if (_ownsClient) await _client.close();
      },
    );
    return out.stream;
  }
}
