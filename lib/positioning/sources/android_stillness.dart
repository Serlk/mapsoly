/// "The device lies still", from StillnessBridge.kt on Android or the IIO
/// accelerometer on Linux, fed to the engine so that the position does not
/// drift between Wi-Fi scans and as evidence against a lying receiver.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../engine.dart';

/// While the device's accelerometer shows no movement at all, tells the
/// engine so once a second.
///
/// Android lets an app scan Wi-Fi about twice a minute. Between two scans
/// the filter knows nothing about movement and widens the accuracy circle as
/// if the device might be driving; lying on a table it would swing from
/// tens of metres to kilometres and back with every scan.
///
/// Satellites know better: while they give a usable fix nothing is fed, so
/// a phone in a very smooth car is not told to stand still against the
/// measured speed.
class StationaryFeeder {
  StationaryFeeder(
    this.engine, {
    EventChannel events = const EventChannel('mapsoly/android/still'),
    Stream<bool> Function()? states,
    this.period = const Duration(seconds: 1),
    this.gnssFresh = const Duration(seconds: 3),
    DateTime Function()? now,
  }) : _events = events,
       _states = states,
       _now = now ?? DateTime.now;

  final PositioningEngine engine;
  final Duration period;

  /// A fix this recent speaks for itself.
  final Duration gnssFresh;
  final EventChannel _events;

  /// Where "still" comes from when not from the Android channel.
  final Stream<bool> Function()? _states;
  final DateTime Function() _now;
  StreamSubscription<Object?>? _sub;
  Timer? _timer;

  bool? _logged;

  /// What the sensor said last.
  bool still = false;

  /// How many times the engine was told (diagnostics).
  int samplesFed = 0;

  /// Starts listening to the sensor (it runs only while listened to).
  void start() {
    _sub ??= (_states?.call() ?? _events.receiveBroadcastStream()).listen(
      (value) {
        final now = value == true;
        if (now != _logged) {
          _logged = now;
          debugPrint('stillness: ${now ? 'still' : 'moving'}');
        }
        still = now;
        _timer?.cancel();
        _timer = still ? Timer.periodic(period, (_) => _feed()) : null;
        if (still) _feed();
      },
      onError: (Object _) {}, // no such sensor: never still
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    still = false;
    unawaited(_sub?.cancel());
    _sub = null;
  }

  void _feed() {
    if (!engine.isRunning) return;
    final fix = engine.lastGnssFix;
    final now = _now();
    // Evidence for the spoofing check, whatever the satellites say.
    engine.noteDeviceStill(time: now);
    if (fix != null &&
        fix.hasPosition &&
        engine.status.gnssHealth.usable &&
        now.difference(fix.receivedAt) <= gnssFresh) {
      return;
    }
    samplesFed++;
    engine.addStationarySample(time: now);
  }
}
