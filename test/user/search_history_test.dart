import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/user/search_history.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 27, 9);
  DateTime at(int minutes) => t0.add(Duration(minutes: minutes));
  const a = LatLng(55.75, 37.60), b = LatLng(55.76, 37.61);
  const c = LatLng(55.77, 37.62);

  test('the most often picked first, the most recent among equals', () {
    final h = SearchHistory.inMemory();
    h.record('Аптека', a, now: at(0));
    h.record('Заправка', b, now: at(1));
    h.record('Вокзал', c, now: at(2));
    expect(h.ranked.map((p) => p.label), ['Вокзал', 'Заправка', 'Аптека']);
    // Picked again (a few metres off): the same place, counted twice.
    h.record('Аптека', const LatLng(55.75005, 37.60005), now: at(3));
    expect(h.ranked.map((p) => p.label), ['Аптека', 'Вокзал', 'Заправка']);
    expect(h.ranked.first.count, 2);
    // The same name somewhere else is another place.
    h.record('Аптека', c, now: at(4));
    expect(h.ranked.length, 4);

    h.remove(h.ranked.first);
    expect(h.ranked.first.label, 'Аптека');
    expect(h.ranked.first.count, 1);
    h.clear();
    expect(h.isEmpty, isTrue);
  });

  test('kept between launches, and capped', () {
    final dir = Directory.systemTemp.createTempSync('mapsoly-history');
    addTearDown(() => dir.deleteSync(recursive: true));
    final h = SearchHistory.load(dir);
    h.record('Дом культуры', a, now: at(0));
    h.record('Дом культуры', a, now: at(5));
    for (var i = 0; i < SearchHistory.capacity + 10; i++) {
      h.record('Место $i', LatLng(56 + i * 0.01, 38), now: at(10 + i));
    }
    final again = SearchHistory.load(dir);
    expect(again.loadError, isNull);
    expect(again.ranked.length, SearchHistory.capacity);
    // The favourite survives; the oldest single picks went.
    expect(again.ranked.first.label, 'Дом культуры');
    expect(again.ranked.first.count, 2);
    expect(again.ranked.any((p) => p.label == 'Место 0'), isFalse);
    expect(
      again.ranked.any((p) => p.label == 'Место ${SearchHistory.capacity + 9}'),
      isTrue,
    );
  });
}
