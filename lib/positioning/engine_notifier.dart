/// Flutter adapter: exposes a [PositioningEngine] as a [ChangeNotifier] for
/// `ListenableBuilder` / `AnimatedBuilder`. The engine itself is pure Dart.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'engine.dart';
import 'gnss_sanity.dart';
import 'models.dart';

/// Notifies listeners whenever the engine status or estimate changes.
class PositioningNotifier extends ChangeNotifier {
  PositioningNotifier(this.engine) {
    _sub = engine.statusStream.listen((status) {
      _logGnssHealth(status.gnssHealth);
      _logRadio(status);
      notifyListeners();
    });
  }

  String? _loggedHealth;

  /// One log line whenever the verdict on the satellites changes, with the
  /// reasons: "why are my satellites not used" is otherwise unanswerable
  /// on a device in the field. No positions are logged.
  void _logGnssHealth(GnssHealth health) {
    final text =
        '${health.verdict.name}'
        '${health.unconfirmed ? ' (unconfirmed)' : ''} '
        '${health.anomalies.map((a) => a.name).toList()}';
    if (text == _loggedHealth) return;
    _loggedHealth = text;
    debugPrint('gnss health: $text');
  }

  final PositioningEngine engine;
  late final StreamSubscription<PositioningStatus> _sub;

  PositioningStatus get status => engine.status;
  PositionEstimate? get estimate => engine.current;

  Future<void> start() => engine.start();
  Future<void> stop() => engine.stop();

  String? _loggedRadio;
  ({int asked, int returned, int matched})? _loggedLookup;

  /// Counts only, and only when they change: what is heard, how much of it
  /// the database knows, and whether the online services answer.
  void _logRadio(PositioningStatus status) {
    final text =
        'wifi ${status.wifiVisible} seen ${status.wifiKnown} known '
        '${status.wifiUsed} used, cells ${status.cellsVisible} seen '
        '${status.cellsKnown} known, source ${status.source?.name}'
        '${status.onlineError == null ? '' : ', online: ${status.onlineError}'}';
    final lookup = engine.lastWifiLookup;
    if (lookup != _loggedLookup && lookup != null) {
      _loggedLookup = lookup;
      debugPrint(
        'online wifi lookup: asked ${lookup.asked}, '
        '${lookup.returned} records back, ${lookup.matched} of the asked',
      );
    }
    if (text == _loggedRadio) return;
    _loggedRadio = text;
    debugPrint('radio: $text');
  }

  /// Cancels the subscription. Does not dispose the engine.
  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}
