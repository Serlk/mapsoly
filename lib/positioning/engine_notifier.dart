/// Flutter adapter: exposes a [PositioningEngine] as a [ChangeNotifier] for
/// `ListenableBuilder` / `AnimatedBuilder`. The engine itself is pure Dart.
library;

import 'dart:async';
import 'dart:math' as math;

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
      // The engine reports after every satellite epoch, scan and tick,
      // several times a second, mostly with nothing new to show. Whoever
      // listens here redraws the screen, so they are told only of changes
      // one could see.
      final all = visibleState(status);
      if (all == _shownDetails) return;
      _shownDetails = all;
      details.notifyListeners();
      final shown = mapState(status);
      if (shown == _shown) return;
      _shown = shown;
      notifyListeners();
    });
  }

  Object? _shown, _shownDetails;

  /// Fires on every visible change, counters included: for a screen that
  /// shows them (the location sheet). The notifier itself fires only for
  /// what the map shows, see [mapState].
  final details = _Details();

  /// The part of [status] the map screen draws: the position and the few
  /// flags on it. How many access points are in the air changes with every
  /// scan and is nothing to redraw a map for.
  @visibleForTesting
  static Object mapState(PositioningStatus status) {
    final h = status.gnssHealth;
    return (
      _estimateState(status.estimate),
      status.running,
      status.gnssConnected,
      (h.verdict, h.unconfirmed),
      status.privateArea,
      status.spoofingCheck,
    );
  }

  static Object? _estimateState(PositionEstimate? e) {
    if (e == null) return null;
    int? step(double? v, double size) => v == null ? null : (v / size).round();
    return (
      step(e.lat, 5e-6),
      step(e.lon, 5e-6),
      // Steps of 5 %: log scale.
      (math.log(math.max(e.accuracyM, 1)) * 20).round(),
      e.source,
      step(e.speedMps, 0.2),
      step(e.courseDeg, 2),
    );
  }

  /// What of [status] reaches the screen, coarsened to what the eye can
  /// tell: the position to about half a metre, the speed to 0.2 m/s, the
  /// course to two degrees, the accuracy to a twentieth of itself.
  @visibleForTesting
  static Object visibleState(PositioningStatus status) {
    final h = status.gnssHealth;
    return (
      _estimateState(status.estimate),
      (status.running, status.wifiVisible, status.wifiKnown, status.wifiUsed),
      (status.cellsVisible, status.cellsKnown, status.bleVisible),
      (status.gnssConnected, status.satellitesInView, status.satellitesUsed),
      (h.verdict, h.unconfirmed, h.anomalies.map((a) => a.index).join(',')),
      (status.wardriving, status.wardrivingSamples, status.onlineLookups),
      (status.onlineError, status.wifiCellConflict, status.privateArea),
      status.spoofingCheck,
    );
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
    details.dispose();
    super.dispose();
  }
}

class _Details extends ChangeNotifier {
  @override
  void notifyListeners() => super.notifyListeners();
}
