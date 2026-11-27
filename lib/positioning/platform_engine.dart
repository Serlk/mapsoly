/// The positioning engine with this platform's sources.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'engine.dart';
import 'estimator.dart';
import 'fusion.dart';
import 'location_access.dart';
import 'location_db.dart';
import 'online/resolver.dart';
import 'sources/android_gnss.dart';
import 'sources/android_radio.dart';
import 'sources/android_stillness.dart';

/// An engine and, where reading the position takes the user's consent, the
/// handle to ask for it.
class PlatformPositioning {
  PlatformPositioning(
    this.engine, {
    this.access,
    this.stationary,
    bool pauseWhenHidden = false,
  }) {
    stationary?.start();
    if (pauseWhenHidden) {
      _lifecycle = AppLifecycleListener(
        onHide: () {
          stationary?.stop();
          unawaited(engine.stop());
        },
        onShow: () {
          unawaited(engine.start());
          stationary?.start();
        },
      );
    }
  }

  final PositioningEngine engine;
  final LocationAccess? access;

  /// Tells the engine when the device lies still (Android).
  final StationaryFeeder? stationary;
  AppLifecycleListener? _lifecycle;

  /// Stops watching the app's visibility and the motion sensor. The engine
  /// itself belongs to the caller.
  void release() {
    _lifecycle?.dispose();
    _lifecycle = null;
    stationary?.stop();
  }
}

/// The engine settings for Android.
///
/// A scan the app asks for is rationed to one per ~30 s and takes a few
/// seconds, so the freshest list is routinely a little over 30 s old just
/// before the next one arrives (measured: a new list every 33–35 s). With
/// the default limits of 30 s and 35 s the Wi-Fi estimate, and then its
/// label, would drop out for those seconds of every cycle.
const androidPositioningConfig = PositioningConfig(
  estimator: EstimatorConfig(maxWifiAge: Duration(seconds: 45)),
  fusion: FusionConfig(radioFresh: Duration(seconds: 60)),
);

/// Opens (creates) the database at [dbPath] and builds the engine; null on
/// a platform without position sources.
///
/// Linux: NetworkManager / wpa_supplicant, ModemManager and the NMEA
/// socket. Android: the platform LocationManager (satellites), WifiManager
/// scan results and TelephonyManager cells, plus the accelerometer to know
/// when the device lies still. There everything is stopped while the app is
/// not on screen and started again when it returns: no scanning in the
/// background.
PlatformPositioning? createPlatformPositioning({
  required String dbPath,
  PositioningConfig? config,
}) {
  if (Platform.isLinux) {
    return PlatformPositioning(
      PositioningEngine.linux(
        dbPath: dbPath,
        config: config ?? const PositioningConfig(),
      ),
    );
  }
  if (Platform.isAndroid) {
    final gnss = AndroidGnssSource();
    final db = LocationDb.open(dbPath);
    final engine = PositioningEngine(
      db: db,
      wifi: AndroidWifiScanner(),
      cells: AndroidCellSource(),
      gnss: gnss,
      resolver: OnlineResolver(db),
      config: config ?? androidPositioningConfig,
    );
    return PlatformPositioning(
      engine,
      access: gnss,
      stationary: StationaryFeeder(engine),
      pauseWhenHidden: true,
    );
  }
  return null;
}
