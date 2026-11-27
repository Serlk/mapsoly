/// The positioning engine with this platform's sources.
library;

import 'dart:io';

import 'engine.dart';
import 'location_access.dart';
import 'location_db.dart';
import 'online/resolver.dart';
import 'sources/android_gnss.dart';

/// An engine and, where reading the position takes the user's consent, the
/// handle to ask for it.
class PlatformPositioning {
  const PlatformPositioning(this.engine, {this.access, this.radio = true});

  final PositioningEngine engine;
  final LocationAccess? access;

  /// Whether Wi-Fi and cell scans take part (and with them online lookups
  /// and the user's own transmitter database).
  final bool radio;
}

/// Opens (creates) the database at [dbPath] and builds the engine; null on
/// a platform without position sources.
///
/// Linux: NetworkManager / wpa_supplicant, ModemManager and the NMEA
/// socket. Android: satellites from the platform LocationManager only;
/// Wi-Fi and cell scans are not read there (the system throttles Wi-Fi
/// scans to a few per two minutes and wants more permissions for both), so
/// the radio estimate, online lookups and wardriving have nothing to work
/// on.
PlatformPositioning? createPlatformPositioning({
  required String dbPath,
  PositioningConfig config = const PositioningConfig(),
}) {
  if (Platform.isLinux) {
    return PlatformPositioning(
      PositioningEngine.linux(dbPath: dbPath, config: config),
    );
  }
  if (Platform.isAndroid) {
    final gnss = AndroidGnssSource();
    final db = LocationDb.open(dbPath);
    return PlatformPositioning(
      PositioningEngine(
        db: db,
        gnss: gnss,
        resolver: OnlineResolver(db),
        config: config,
      ),
      access: gnss,
      radio: false,
    );
  }
  return null;
}
