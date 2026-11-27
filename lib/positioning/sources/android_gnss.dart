/// GNSS source for Android: fixes from the platform LocationManager (GPS
/// provider), delivered by LocationBridge.kt.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../platform/android_bridge.dart';
import '../location_access.dart';
import '../models.dart';
import 'sources.dart';

/// Android `GnssStatus.CONSTELLATION_*`.
const _systems = {
  1: GnssSystem.gps,
  2: GnssSystem.sbas,
  3: GnssSystem.glonass,
  4: GnssSystem.qzss,
  5: GnssSystem.beidou,
  6: GnssSystem.galileo,
  7: GnssSystem.navic,
};

/// Turns one event of the `mapsoly/android/location` stream into a fix.
/// An event without coordinates is an epoch without a position.
///
/// [now] is the local clock at arrival. The fix is dated by `at`, the
/// platform's own record of when it was taken (system clock, not the
/// receiver's time): events can sit in the queue while the app is busy, and
/// two fixes handed over together would otherwise look like a jump of
/// their whole distance in no time, which is what the spoofing check
/// looks for. An `at` from the future or implausibly old is not believed.
@visibleForTesting
GnssFix fixFromAndroid(Map<Object?, Object?> event, DateTime now) {
  double? number(String key) => (event[key] as num?)?.toDouble();
  var receivedAt = now;
  final at = event['at'];
  if (at is num) {
    final taken = DateTime.fromMillisecondsSinceEpoch(
      at.toInt(),
      isUtc: now.isUtc,
    );
    final age = now.difference(taken);
    if (!age.isNegative && age <= const Duration(seconds: 30)) {
      receivedAt = taken;
    }
  }
  final satellites = <GnssSatellite>[
    for (final s in (event['sats'] as List<Object?>? ?? const []))
      if (s is List && s.length >= 6)
        GnssSatellite(
          system: _systems[s[0]] ?? GnssSystem.unknown,
          prn: (s[1] as num).toInt(),
          // Android reports 0 for a satellite it does not track.
          cn0: (s[2] as num) > 0 ? (s[2] as num).toDouble() : null,
          elevationDeg: (s[3] as num).toDouble(),
          azimuthDeg: (s[4] as num).toDouble(),
          used: s[5] == true,
        ),
  ];
  final lat = number('lat'), lon = number('lon');
  final time = (event['time'] as num?)?.toInt();
  final speed = number('speed');
  return GnssFix(
    valid: lat != null && lon != null,
    receivedAt: receivedAt,
    lat: lat,
    lon: lon,
    altitudeM: number('alt'),
    // Android's accuracy is already a 68 % radius, like the engine's.
    accuracyM: number('acc'),
    speedMps: speed,
    // A course reported while standing is noise.
    courseDeg: speed != null && speed > 0.5 ? number('course') : null,
    time: time == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(time, isUtc: true),
    satellitesUsed: satellites.isEmpty
        ? null
        : satellites.where((s) => s.used).length,
    satellites: satellites,
  );
}

/// Satellite fixes on Android, with the location permission that guards
/// them.
///
/// [start] asks for the permission once (the system dialog); a refusal is
/// not asked about again until the user chooses to through [request]. The
/// state is looked at again whenever the app comes back to the front, since
/// both the permission and the system's location switch change outside it.
class AndroidGnssSource implements GnssSource, LocationAccess {
  AndroidGnssSource({
    MethodChannel channel = androidChannel,
    EventChannel events = const EventChannel('mapsoly/android/location'),
    DateTime Function()? now,
  }) : _channel = channel,
       _events = events,
       _permissions = AndroidPermissions(channel),
       _now = now ?? DateTime.now;

  final MethodChannel _channel;
  final EventChannel _events;
  final AndroidPermissions _permissions;
  final DateTime Function() _now;
  final _fixes = StreamController<GnssFix>.broadcast();
  final _state = ValueNotifier(LocationAccessState.unknown);
  StreamSubscription<Object?>? _sub;
  AppLifecycleListener? _lifecycle;
  bool _running = false;
  bool _asked = false;

  @override
  Stream<GnssFix> get fixes => _fixes.stream;

  @override
  bool get connected => _sub != null;

  @override
  ValueListenable<LocationAccessState> get state => _state;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _lifecycle ??= AppLifecycleListener(onResume: () => unawaited(refresh()));
    try {
      if (await _permissions.has(AndroidPermissions.location)) {
        await _listen();
      } else if (!_asked) {
        // Once per run: the source is restarted every time the app comes
        // back to the screen, and a refusal must not bring the dialog up
        // again each time. Not awaited by the engine's start: the dialog
        // may stay open.
        _asked = true;
        unawaited(_ask());
      }
    } on Object catch (e) {
      debugPrint('Android location not started: $e');
    }
  }

  @override
  Future<void> stop() async {
    _running = false;
    _lifecycle?.dispose();
    _lifecycle = null;
    await _unlisten();
  }

  @override
  Future<void> request() async {
    try {
      switch (_state.value) {
        case LocationAccessState.blocked || LocationAccessState.switchedOff:
          // Nothing the app can show: the answer is in the system settings.
          // The state is read again when the user comes back.
          await _permissions.openAppSettings();
        case _:
          await _ask();
      }
    } on Object catch (e) {
      debugPrint('Location permission request failed: $e');
    }
  }

  Future<void> _ask() async {
    final answer = await _permissions.request(AndroidPermissions.location);
    switch (answer) {
      case PermissionAnswer.granted:
        if (_running) await _listen();
      case PermissionAnswer.denied:
        _state.value = LocationAccessState.denied;
      case PermissionAnswer.blocked:
        _state.value = LocationAccessState.blocked;
    }
  }

  /// Looks at the permission and the system switch again.
  Future<void> refresh() async {
    if (!_running) return;
    try {
      if (!await _permissions.has(AndroidPermissions.location)) {
        // Taken away in the system settings while the app was running.
        if (_sub != null) await _unlisten();
        if (_state.value == LocationAccessState.granted ||
            _state.value == LocationAccessState.switchedOff) {
          _state.value = LocationAccessState.denied;
        }
        return;
      }
      if (_sub == null) {
        await _listen();
      } else {
        await _readSwitch();
      }
    } on Object catch (e) {
      debugPrint('Location state not read: $e');
    }
  }

  Future<void> _readSwitch() async {
    final on = await _channel.invokeMethod<bool>('locationEnabled') ?? false;
    _state.value = on
        ? LocationAccessState.granted
        : LocationAccessState.switchedOff;
  }

  Future<void> _listen() async {
    if (_sub != null) return;
    _sub = _events.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map || _fixes.isClosed) return;
        if (event['off'] == true) {
          // The satellite provider went away; whether that is the whole
          // system's location switch is a separate question.
          unawaited(_readSwitch().catchError((Object _) {}));
        } else if (event['lat'] != null) {
          _state.value = LocationAccessState.granted;
        }
        _fixes.add(fixFromAndroid(event, _now()));
      },
      onError: (Object e) {
        debugPrint('Android location: $e');
        _sub = null;
        if (e is PlatformException && e.code == 'permission') {
          _state.value = LocationAccessState.denied;
        }
      },
    );
    await _readSwitch();
  }

  Future<void> _unlisten() async {
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
  }

  /// Stops and releases the stream. The source cannot be restarted afterwards.
  Future<void> dispose() async {
    await stop();
    await _fixes.close();
    _state.dispose();
  }
}
