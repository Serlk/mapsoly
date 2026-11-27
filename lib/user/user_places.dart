/// Places the driver saved: home, work and favourites.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import 'json_store.dart';

enum SavedPlaceKind { home, work, favorite }

/// Name used when the user gave none.
String defaultPlaceName(SavedPlaceKind kind) => switch (kind) {
  SavedPlaceKind.home => 'Дом',
  SavedPlaceKind.work => 'Работа',
  SavedPlaceKind.favorite => 'Место',
};

/// A fixed point the driver jumps to.
@immutable
class SavedPlace {
  /// Without [id] a new one is generated.
  SavedPlace({
    String? id,
    required this.name,
    this.kind = SavedPlaceKind.favorite,
    required this.point,
    this.address,
  }) : id = id ?? newUserId();

  final String id;
  final String name;
  final SavedPlaceKind kind;
  final LatLng point;

  /// Postal address or another one-line description, if known.
  final String? address;

  /// Copy with some fields replaced. The address cannot be cleared this
  /// way; construct a new place for that.
  SavedPlace copyWith({
    String? name,
    SavedPlaceKind? kind,
    LatLng? point,
    String? address,
  }) => SavedPlace(
    id: id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    point: point ?? this.point,
    address: address ?? this.address,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'point': pointToJson(point),
    'address': ?address,
  };

  /// Null when [json] lacks an id or a valid point.
  static SavedPlace? fromJson(Map<String, dynamic> json) {
    final id = json['id'], name = json['name'], address = json['address'];
    final point = pointFromJson(json['point']);
    if (id is! String || id.isEmpty || point == null) return null;
    final kind = SavedPlaceKind.values.firstWhere(
      (k) => k.name == json['kind'],
      orElse: () => SavedPlaceKind.favorite,
    );
    return SavedPlace(
      id: id,
      name: name is String && name.trim().isNotEmpty
          ? name
          : defaultPlaceName(kind),
      kind: kind,
      point: point,
      address: address is String && address.isNotEmpty ? address : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SavedPlace &&
      other.id == id &&
      other.name == name &&
      other.kind == kind &&
      other.point == point &&
      other.address == address;

  @override
  int get hashCode => Object.hash(id, name, kind, point, address);

  @override
  String toString() => 'SavedPlace($id, ${kind.name}, "$name", $point)';
}

/// The saved places, kept in `places.json`.
class UserPlaces extends JsonListStore<SavedPlace> {
  UserPlaces._(File? file) : super(file, 'places');

  /// Loads `<dir>/places.json`. Never throws; see [loadError].
  factory UserPlaces.load(Directory dir) =>
      UserPlaces._(File('${dir.path}/places.json'))
        ..load()
        .._enforceSingles();

  /// A store that is not persisted.
  factory UserPlaces.inMemory() => UserPlaces._(null);

  @override
  SavedPlace? decodeItem(Map<String, dynamic> json) =>
      SavedPlace.fromJson(json);

  @override
  Map<String, dynamic> encodeItem(SavedPlace item) => item.toJson();

  /// Home first, then work, then favourites by name.
  List<SavedPlace> get places => List.unmodifiable(
    [...items]..sort((a, b) {
      final k = a.kind.index.compareTo(b.kind.index);
      if (k != 0) return k;
      final n = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return n != 0 ? n : a.id.compareTo(b.id);
    }),
  );

  SavedPlace? get home => _single(SavedPlaceKind.home);
  SavedPlace? get work => _single(SavedPlaceKind.work);

  /// Favourites only, by name.
  List<SavedPlace> get favorites => [
    for (final p in places)
      if (p.kind == SavedPlaceKind.favorite) p,
  ];

  SavedPlace? byId(String id) {
    for (final p in items) {
      if (p.id == id) return p;
    }
    return null;
  }

  SavedPlace? _single(SavedPlaceKind kind) {
    for (final p in items) {
      if (p.kind == kind) return p;
    }
    return null;
  }

  /// A hand-edited file may hold two homes: keep the first.
  void _enforceSingles() {
    for (final kind in const [SavedPlaceKind.home, SavedPlaceKind.work]) {
      var seen = false;
      items.removeWhere((p) {
        if (p.kind != kind) return false;
        if (!seen) {
          seen = true;
          return false;
        }
        return true;
      });
    }
    final ids = <String>{};
    items.removeWhere((p) => !ids.add(p.id));
  }

  static SavedPlace _clean(SavedPlace p) {
    final name = p.name.trim();
    final address = p.address?.trim();
    return SavedPlace(
      id: p.id,
      name: name.isEmpty ? defaultPlaceName(p.kind) : name,
      kind: p.kind,
      point: p.point,
      address: address == null || address.isEmpty ? null : address,
    );
  }

  bool _put(SavedPlace place) {
    if (!validLatLon(place.point.latitude, place.point.longitude)) {
      return false;
    }
    final p = _clean(place);
    items.removeWhere(
      (o) =>
          o.id == p.id ||
          (p.kind != SavedPlaceKind.favorite && o.kind == p.kind),
    );
    items.add(p);
    return true;
  }

  /// Adds [place], or replaces the one with the same id. A new home (work)
  /// replaces the previous home (work). The name is trimmed; an empty name
  /// becomes [defaultPlaceName]. Returns the place as stored.
  ///
  /// Throws [ArgumentError] for coordinates outside the globe.
  SavedPlace save(SavedPlace place) {
    if (!_put(place)) {
      throw ArgumentError.value(place.point, 'place.point', 'not on Earth');
    }
    changed();
    return byId(place.id)!;
  }

  /// Adds places from an import in one write. A home (work) from the file
  /// does not displace an existing one: it is added as a favourite instead.
  /// Places whose id is already present replace the stored ones. Returns
  /// the number of places taken.
  int addAll(Iterable<SavedPlace> imported) {
    var n = 0;
    for (final p in imported) {
      final existing = p.kind == SavedPlaceKind.favorite
          ? null
          : _single(p.kind);
      final demote = existing != null && existing.id != p.id;
      if (_put(demote ? p.copyWith(kind: SavedPlaceKind.favorite) : p)) n++;
    }
    if (n > 0) changed();
    return n;
  }

  /// Returns false when there is no such place.
  bool remove(String id) {
    final before = items.length;
    items.removeWhere((p) => p.id == id);
    if (items.length == before) return false;
    changed();
    return true;
  }

  /// Returns false when there is no such place. An empty name becomes
  /// [defaultPlaceName].
  bool rename(String id, String name) {
    final p = byId(id);
    if (p == null) return false;
    _put(
      p.copyWith(name: name.trim().isEmpty ? defaultPlaceName(p.kind) : name),
    );
    changed();
    return true;
  }
}
