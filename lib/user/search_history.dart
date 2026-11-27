import 'dart:io';

import 'package:latlong2/latlong.dart';

import 'json_store.dart';

/// A place the user picked from the search results.
class SearchedPlace {
  const SearchedPlace({
    required this.label,
    required this.point,
    required this.count,
    required this.lastUsed,
  });

  /// What the result was called: "улица Ленина, 5 — Тверь".
  final String label;
  final LatLng point;

  /// How many times it was picked.
  final int count;
  final DateTime lastUsed;
}

/// Places picked from the search results, so that they are one tap away
/// next time: the most often picked first, the most recent first among
/// equals. Kept on the device only.
class SearchHistory extends JsonListStore<SearchedPlace> {
  SearchHistory._(File? file) : super(file, 'searches');

  /// Loads `<dir>/search_history.json`. Never throws; see [loadError].
  factory SearchHistory.load(Directory dir) =>
      SearchHistory._(File('${dir.path}/search_history.json'))..load();

  /// A store that is not persisted.
  factory SearchHistory.inMemory() => SearchHistory._(null);

  /// More than this many places are not kept; the least used go first.
  static const capacity = 100;

  static const _distance = Distance();

  @override
  SearchedPlace? decodeItem(Map<String, dynamic> json) {
    final label = json['label'], lat = json['lat'], lon = json['lon'];
    if (label is! String || lat is! num || lon is! num) return null;
    final last = DateTime.tryParse('${json['last']}');
    return SearchedPlace(
      label: label,
      point: LatLng(lat.toDouble(), lon.toDouble()),
      count: (json['count'] as num?)?.toInt() ?? 1,
      lastUsed: last ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  @override
  Map<String, dynamic> encodeItem(SearchedPlace item) => {
    'label': item.label,
    'lat': item.point.latitude,
    'lon': item.point.longitude,
    'count': item.count,
    'last': item.lastUsed.toUtc().toIso8601String(),
  };

  bool get isEmpty => items.isEmpty;

  /// The most often picked first; among equals, the most recent.
  List<SearchedPlace> get ranked => [...items]
    ..sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      return byCount != 0 ? byCount : b.lastUsed.compareTo(a.lastUsed);
    });

  bool _same(SearchedPlace p, String label, LatLng point) =>
      p.label == label && _distance.as(LengthUnit.Meter, p.point, point) < 30;

  /// The user picked this place from the search results.
  void record(String label, LatLng point, {DateTime? now}) {
    final time = now ?? DateTime.now();
    final i = items.indexWhere((p) => _same(p, label, point));
    if (i >= 0) {
      final old = items[i];
      items[i] = SearchedPlace(
        label: label,
        point: old.point,
        count: old.count + 1,
        lastUsed: time,
      );
    } else {
      items.add(
        SearchedPlace(label: label, point: point, count: 1, lastUsed: time),
      );
      if (items.length > capacity) {
        // The last of the ranking is the one least worth keeping, but never
        // the place that was just added.
        final drop = ranked.lastWhere((p) => !_same(p, label, point));
        items.remove(drop);
      }
    }
    changed();
  }

  void remove(SearchedPlace place) {
    if (items.remove(place)) changed();
  }

  void clear() {
    if (items.isEmpty) return;
    items.clear();
    changed();
  }
}
