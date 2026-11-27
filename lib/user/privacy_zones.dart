/// "Safe zones": areas (home, for one) inside which nothing the app
/// collects may be recorded or leave the device.
///
/// This file only knows the zones and their geometry (great-circle
/// distances on the same spherical Earth as the positioning code). What
/// enforces them is in `privacy_guard.dart` (positioning, trip log) and
/// `data_export.dart`.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../positioning/geo.dart' show haversineM;
import 'json_store.dart';

const double _earthRadiusM = 6371008.8;
const double _rad = math.pi / 180.0;

/// A circular safe zone.
@immutable
class PrivacyZone {
  /// Without [id] a new one is generated.
  PrivacyZone({
    String? id,
    required this.name,
    required this.center,
    required this.radiusM,
  }) : id = id ?? newUserId();

  /// A zone that hides [point] without having it in the middle: the centre
  /// is moved in a random direction by up to 40 % of the radius (the point
  /// stays at least 60 % of the radius away from the edge).
  ///
  /// Why: recorded tracks stop at the edge of a zone. With the protected
  /// point exactly in the centre, three such track ends are enough to
  /// compute it. Prefer this over the plain constructor when the user picks
  /// "around my home".
  factory PrivacyZone.around(
    LatLng point, {
    required String name,
    double radiusM = defaultRadiusM,
    math.Random? random,
  }) {
    final rnd = random ?? math.Random.secure();
    // sqrt: uniform over the disc rather than crowded near the middle.
    final shift = radiusM * 0.4 * math.sqrt(rnd.nextDouble());
    final bearing = rnd.nextDouble() * 2 * math.pi;
    final lat =
        point.latitude + shift * math.cos(bearing) / _earthRadiusM / _rad;
    final cosLat = math.cos(point.latitude * _rad).abs().clamp(0.01, 1.0);
    var lon =
        point.longitude +
        shift * math.sin(bearing) / _earthRadiusM / _rad / cosLat;
    if (lon > 180) lon -= 360;
    if (lon < -180) lon += 360;
    return PrivacyZone(
      name: name,
      center: LatLng(lat.clamp(-90.0, 90.0), lon),
      radiusM: radiusM,
    );
  }

  /// Suggested radius for a new zone. Wi-Fi is heard 100 m and further from
  /// an access point, so a zone much smaller than this does not keep the
  /// home network out of the wardriving data (see `docs/user-data.md`).
  static const double defaultRadiusM = 300;
  static const double minRadiusM = 50;
  static const double maxRadiusM = 50000;

  final String id;
  final String name;
  final LatLng center;
  final double radiusM;

  /// Whether the circle of [marginM] metres around [p] touches the zone
  /// (with a margin of 0: whether [p] is inside).
  bool touches(LatLng p, [double marginM = 0]) =>
      haversineM(center.latitude, center.longitude, p.latitude, p.longitude) <=
      radiusM + marginM;

  PrivacyZone copyWith({String? name, LatLng? center, double? radiusM}) =>
      PrivacyZone(
        id: id,
        name: name ?? this.name,
        center: center ?? this.center,
        radiusM: radiusM ?? this.radiusM,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'center': pointToJson(center),
    'radiusM': radiusM,
  };

  static PrivacyZone? fromJson(Map<String, dynamic> json) {
    final id = json['id'], name = json['name'], radius = json['radiusM'];
    final center = pointFromJson(json['center']);
    if (id is! String || id.isEmpty || center == null) return null;
    if (radius is! num || !radius.isFinite || radius <= 0) return null;
    return PrivacyZone(
      id: id,
      name: name is String && name.trim().isNotEmpty ? name : defaultZoneName,
      center: center,
      radiusM: radius.toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PrivacyZone &&
      other.id == id &&
      other.name == name &&
      other.center == center &&
      other.radiusM == radiusM;

  @override
  int get hashCode => Object.hash(id, name, center, radiusM);

  @override
  String toString() => 'PrivacyZone($id, "$name", $center, $radiusM m)';
}

/// Name used when the user gave none.
const String defaultZoneName = 'Зона';

/// The safe zones, kept in `privacy_zones.json`.
///
/// **Fails closed.** If the file exists but cannot be read (or some of its
/// zones cannot), the zones that protected the user are unknown, so
/// [contains] and [intersects] answer true for every position until the
/// user has looked at the list and [confirmZones] is called: no wardriving,
/// no online lookups, no coordinates in trip logs or exports. [unconfirmed]
/// tells the UI to ask. A missing file is the normal first start and means
/// "no zones".
class PrivacyZones extends JsonListStore<PrivacyZone> {
  PrivacyZones._(File? file) : super(file, 'zones');

  /// Loads `<dir>/privacy_zones.json`. Never throws; see [loadError] and
  /// [unconfirmed].
  factory PrivacyZones.load(Directory dir) {
    final store = PrivacyZones._(File('${dir.path}/privacy_zones.json'))
      ..load();
    final ids = <String>{};
    store.items.removeWhere((z) => !ids.add(z.id));
    if (store.damaged || store.skippedOnLoad > 0) store._unconfirmed = true;
    return store;
  }

  /// A store that is not persisted.
  factory PrivacyZones.inMemory() => PrivacyZones._(null);

  bool _unconfirmed = false;

  // Kept in the file: editing the list while it is unconfirmed rewrites the
  // file, and the next start must still ask.
  @override
  Map<String, dynamic> get extraJson => {if (_unconfirmed) 'unconfirmed': true};

  @override
  void decodeExtra(Map<dynamic, dynamic> json) {
    if (json['unconfirmed'] == true) {
      _unconfirmed = true;
      loadError ??= 'Список зон мог быть прочитан не полностью';
    }
  }

  @override
  PrivacyZone? decodeItem(Map<String, dynamic> json) =>
      PrivacyZone.fromJson(json);

  @override
  Map<String, dynamic> encodeItem(PrivacyZone item) => item.toJson();

  /// True after a damaged file was found: every position is treated as
  /// private until [confirmZones]. The UI should show the zone list, say
  /// that it may be incomplete ([loadError]) and let the user fix it.
  bool get unconfirmed => _unconfirmed;

  /// The user has reviewed [zones] after a damaged file: they are the truth
  /// from now on. Writes the file, which ends the fail-closed state for
  /// later starts too.
  void confirmZones() {
    if (!_unconfirmed) return;
    _unconfirmed = false;
    damaged = false;
    skippedOnLoad = 0;
    loadError = null;
    changed();
  }

  /// By name.
  List<PrivacyZone> get zones => List.unmodifiable(
    [...items]..sort((a, b) {
      final n = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return n != 0 ? n : a.id.compareTo(b.id);
    }),
  );

  bool get isEmpty => items.isEmpty;

  PrivacyZone? byId(String id) {
    for (final z in items) {
      if (z.id == id) return z;
    }
    return null;
  }

  /// Whether [p] is inside a zone.
  bool contains(LatLng p) => intersects(p, 0);

  /// Whether the circle of [radiusM] metres around [center] touches a zone:
  /// the test for a position that is only known to that accuracy. A
  /// non-finite or negative radius counts as "anywhere", i.e. true whenever
  /// there is a zone at all; so does a non-finite position.
  bool intersects(LatLng center, double radiusM) {
    if (_unconfirmed) return true;
    if (items.isEmpty) return false;
    final lat = center.latitude, lon = center.longitude;
    if (!(radiusM >= 0) ||
        !radiusM.isFinite ||
        !lat.isFinite ||
        !lon.isFinite) {
      return true;
    }
    for (final z in items) {
      final reach = z.radiusM + radiusM;
      // Cheap rejection by latitude before the trigonometry.
      if ((z.center.latitude - lat).abs() * _rad * _earthRadiusM > reach) {
        continue;
      }
      if (haversineM(z.center.latitude, z.center.longitude, lat, lon) <=
          reach) {
        return true;
      }
    }
    return false;
  }

  /// The zone containing [p], if any (the first by name).
  PrivacyZone? zoneAt(LatLng p) {
    for (final z in zones) {
      if (z.touches(p)) return z;
    }
    return null;
  }

  static PrivacyZone _checked(PrivacyZone z) {
    final c = z.center;
    if (!validLatLon(c.latitude, c.longitude)) {
      throw ArgumentError.value(c, 'zone.center', 'not on Earth');
    }
    if (!z.radiusM.isFinite || z.radiusM <= 0) {
      throw ArgumentError.value(z.radiusM, 'zone.radiusM', 'must be positive');
    }
    final name = z.name.trim();
    return z.copyWith(
      name: name.isEmpty ? defaultZoneName : name,
      radiusM: z.radiusM.clamp(PrivacyZone.minRadiusM, PrivacyZone.maxRadiusM),
    );
  }

  /// Adds a zone; it applies to everything collected from now on. The
  /// radius is clamped to [PrivacyZone.minRadiusM]..[PrivacyZone.maxRadiusM].
  /// Returns the zone as stored.
  ///
  /// Data stored earlier is not touched: exports filter it out, and
  /// `purgeWardrivingInside` deletes it when the user asks for that.
  ///
  /// Throws [ArgumentError] for an invalid centre or radius, and
  /// [StateError] when a zone with this id exists (use [update]).
  PrivacyZone add(PrivacyZone zone) {
    if (byId(zone.id) != null) throw StateError('zone ${zone.id} exists');
    final z = _checked(zone);
    items.add(z);
    changed();
    return z;
  }

  /// Replaces the zone with the same id. Returns false when there is none.
  bool update(PrivacyZone zone) {
    final i = items.indexWhere((z) => z.id == zone.id);
    if (i < 0) return false;
    items[i] = _checked(zone);
    changed();
    return true;
  }

  /// Returns false when there is no such zone.
  bool remove(String id) {
    final before = items.length;
    items.removeWhere((z) => z.id == id);
    if (items.length == before) return false;
    changed();
    return true;
  }
}
