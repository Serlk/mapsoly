import 'dart:async';

import 'package:flutter/services.dart';

import '../../platform/android_bridge.dart';
import 'linux_compass.dart';

/// The Android compass: the system's fused rotation vector, turned into an
/// azimuth by CompassBridge.kt. The sensor runs only while [start]ed.
class AndroidCompass implements LocalCompass {
  AndroidCompass({
    MethodChannel channel = androidChannel,
    EventChannel events = const EventChannel('mapsoly/android/compass'),
  }) : _channel = channel,
       _events = events;

  final MethodChannel _channel;
  final EventChannel _events;
  final _headings = StreamController<double>.broadcast();
  StreamSubscription<Object?>? _sub;

  @override
  Stream<double> get headings => _headings.stream;

  @override
  Future<bool> available() async {
    try {
      return await _channel.invokeMethod<bool>('hasCompass') ?? false;
    } on Exception {
      return false;
    }
  }

  @override
  Future<void> start() async {
    _sub ??= _events.receiveBroadcastStream().listen(
      (value) {
        if (value is num && !_headings.isClosed) {
          _headings.add(value.toDouble());
        }
      },
      onError: (Object _) {}, // no sensor: the stream stays empty
    );
  }

  @override
  Future<void> stop() async {
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _headings.close();
  }
}
