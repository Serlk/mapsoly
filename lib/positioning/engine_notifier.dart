/// Flutter adapter: exposes a [PositioningEngine] as a [ChangeNotifier] for
/// `ListenableBuilder` / `AnimatedBuilder`. The engine itself is pure Dart.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'engine.dart';
import 'models.dart';

/// Notifies listeners whenever the engine status or estimate changes.
class PositioningNotifier extends ChangeNotifier {
  PositioningNotifier(this.engine) {
    _sub = engine.statusStream.listen((_) => notifyListeners());
  }

  final PositioningEngine engine;
  late final StreamSubscription<PositioningStatus> _sub;

  PositioningStatus get status => engine.status;
  PositionEstimate? get estimate => engine.current;

  Future<void> start() => engine.start();
  Future<void> stop() => engine.stop();

  /// Cancels the subscription. Does not dispose the engine.
  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}
