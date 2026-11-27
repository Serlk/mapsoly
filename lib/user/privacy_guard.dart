/// Enforcement of the safe zones: connects [PrivacyZones] to the
/// positioning engine and to the trip log, and deletes stored data on
/// request.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../positioning/engine.dart';
import '../positioning/location_db.dart';
import '../positioning/models.dart';
import 'json_store.dart';
import 'privacy_zones.dart';

/// Position for the trip log, as `ObdOptions.position` wants it.
typedef TripPosition = ({double lat, double lon});

/// Applies the zones to a running [PositioningEngine] and remembers across
/// restarts whether the last known position was inside one.
///
/// ```dart
/// final zones = PrivacyZones.load(userDir);
/// final guard = PrivacyGuard.load(userDir, zones);
/// guard.attach(engine);               // before engine.start()
/// ObdOptions(position: guard.enginePosition(engine), ...);
/// ```
class PrivacyGuard {
  PrivacyGuard(this.zones, {File? stateFile}) : _file = stateFile {
    final f = _file;
    if (f == null) return;
    try {
      if (!f.existsSync()) return;
      final json = jsonDecode(f.readAsStringSync());
      _inside = json is! Map || json['inside'] != false;
    } on Exception {
      // Unreadable state: assume the worse case.
      _inside = true;
    }
  }

  /// Keeps its state in `<dir>/privacy_state.json`.
  factory PrivacyGuard.load(Directory dir, PrivacyZones zones) =>
      PrivacyGuard(zones, stateFile: File('${dir.path}/privacy_state.json'));

  final PrivacyZones zones;
  final File? _file;
  bool _inside = false;
  PositioningEngine? _engine;
  StreamSubscription<PositionEstimate>? _sub;

  /// Whether the last position seen by an attached engine was (possibly)
  /// inside a zone. Survives restarts; only this flag is stored, never the
  /// position.
  bool get lastKnownInside => _inside;

  /// The hook for `PositioningEngine.privacyFilter`: true when the circle
  /// touches a zone. Reads the zones at call time, so a changed zone
  /// applies at once.
  bool filter(double lat, double lon, double radiusM) =>
      zones.intersects(LatLng(lat, lon), radiusM);

  /// Installs [filter] on [engine] and starts following its estimates.
  /// Call before `engine.start()`, so that nothing is collected or sent
  /// unfiltered. If the previous session ended inside a zone the engine is
  /// told to treat "position unknown" as private.
  void attach(PositioningEngine engine) {
    detach();
    _engine = engine;
    engine
      ..assumePrivateUntilLocated = _inside
      ..privacyFilter = filter;
    _sub = engine.estimates.listen(
      (e) => _note(zones.intersects(LatLng(e.lat, e.lon), e.accuracyM)),
    );
    zones.addListener(_zonesChanged);
  }

  /// Stops following the engine. The filter stays installed on it: removing
  /// protection must be explicit (`engine.privacyFilter = null`).
  void detach() {
    unawaited(_sub?.cancel());
    _sub = null;
    if (_engine != null) zones.removeListener(_zonesChanged);
    _engine = null;
  }

  /// The user says the device is not in a zone although no position is
  /// known (see [PositioningEngine.assumePrivateUntilLocated]): online
  /// lookups may resume. Has no effect on an estimate that lies in a zone.
  void releaseHold() {
    _engine?.assumePrivateUntilLocated = false;
    _note(false);
  }

  void _zonesChanged() {
    final e = _engine?.current;
    if (e != null) {
      _note(zones.intersects(LatLng(e.lat, e.lon), e.accuracyM));
    } else if (zones.isEmpty && !zones.unconfirmed) {
      _note(false);
    }
  }

  void _note(bool inside) {
    if (inside == _inside) return;
    _inside = inside;
    final f = _file;
    if (f == null) return;
    try {
      writeFileAtomic(f, jsonEncode({'inside': inside}));
    } on FileSystemException catch (e) {
      debugPrint('${f.path} not saved: $e');
    }
  }

  /// Wraps a position source for the trip log: inside a zone the result is
  /// null, so the row is written with empty coordinates and the vehicle
  /// data is kept. [accuracyM], when given, is the uncertainty of the
  /// position at that moment; the row is blanked if its circle touches a
  /// zone.
  TripPosition? Function() tripLogPosition(
    TripPosition? Function() source, {
    double? Function()? accuracyM,
  }) => () {
    final p = source();
    if (p == null) return null;
    final private = zones.intersects(
      LatLng(p.lat, p.lon),
      accuracyM?.call() ?? 0,
    );
    return private ? null : p;
  };

  /// Trip-log position taken from [engine]'s current estimate, blanked in
  /// zones (using the estimate's accuracy circle). Pass the result as
  /// `ObdOptions.position`.
  TripPosition? Function() enginePosition(PositioningEngine engine) =>
      tripLogPosition(() {
        final e = engine.current;
        return e == null ? null : (lat: e.lat, lon: e.lon);
      }, accuracyM: () => engine.current?.accuracyM);
}

/// What [purgeWardrivingInside] found or removed.
typedef PurgeCount = ({int transmitters, int rawSamples});

/// Deletes from [db] what the user's own wardriving recorded inside the
/// zones before they existed: transmitter records learnt by wardriving
/// whose stored position is inside a zone, and raw samples taken there.
/// With [allSources] also records that came from imports and online
/// lookups (this makes positioning inside the zone worse or impossible
/// until the device is online again).
///
/// With [dryRun] nothing is deleted and the result is what would be.
/// Returns the number of rows (transmitters + raw samples); [purgeDetails]
/// gives the two numbers apart.
///
/// Uses the zone list as it is, also while it is unconfirmed (see
/// [PrivacyZones.unconfirmed]): "everything is private" must not turn into
/// "delete everything".
int purgeWardrivingInside(
  LocationDb db,
  PrivacyZones zones, {
  bool dryRun = false,
  bool allSources = false,
}) {
  final c = purgeDetails(db, zones, dryRun: dryRun, allSources: allSources);
  return c.transmitters + c.rawSamples;
}

/// [purgeWardrivingInside] with the counts kept apart.
PurgeCount purgeDetails(
  LocationDb db,
  PrivacyZones zones, {
  bool dryRun = false,
  bool allSources = false,
}) {
  final (t, s) = db.deleteWithin(
    [
      for (final z in zones.zones)
        (z.center.latitude, z.center.longitude, z.radiusM),
    ],
    sources: allSources ? null : const {TransmitterSource.wardriving},
    dryRun: dryRun,
  );
  return (transmitters: t, rawSamples: s);
}
