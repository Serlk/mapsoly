/// Platform-independent interfaces of the observation sources. Linux
/// implementations live next to this file; Android ones can be added later
/// without touching the estimator or the engine.
library;

import '../models.dart';

/// Wi-Fi scanner.
abstract class WifiScanner {
  /// Human-readable backend name for diagnostics ("wpa_supplicant", ...).
  String get backend;

  /// True when signal levels are real dBm measurements (not percent).
  bool get reportsDbm;

  /// Asks the platform to start a new scan. Must not throw when the platform
  /// refuses (rate limit, permission); returns false in that case.
  Future<bool> requestScan();

  /// Returns the access points heard within [maxAge].
  Future<List<WifiObservation>> getObservations({
    Duration maxAge = const Duration(seconds: 30),
  });

  Future<void> close();
}

/// Cellular measurement source.
abstract class CellSource {
  String get backend;

  /// Current serving (and, when available, neighbour) cells of all modems.
  Future<List<CellObservation>> getCells();

  Future<void> close();
}

/// GNSS receiver.
abstract class GnssSource {
  /// Broadcast stream of epochs, valid or not.
  Stream<GnssFix> get fixes;

  /// True while a receiver connection is established.
  bool get connected;

  Future<void> start();
  Future<void> stop();
}

/// Bluetooth LE scanner (not implemented on Linux yet).
abstract class BleScanner {
  Future<List<BleObservation>> getObservations({
    Duration maxAge = const Duration(seconds: 15),
  });

  Future<void> close();
}
