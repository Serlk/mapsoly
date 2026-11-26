// Runs against real packs in data/packs when present (skipped otherwise).
// Prints example results and latency; used for the numbers in docs/places.md.
//
//   flutter test test/places/real_pack_test.dart --dart-define=PACK=moscow
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/places/places_database.dart';

const _pack = String.fromEnvironment('PACK', defaultValue: 'kaliningrad');

const _centres = {
  'kaliningrad': LatLng(54.7104, 20.5101),
  'moscow': LatLng(55.7558, 37.6173),
};

const _queries = {
  'kaliningrad': [
    'ленина 5',
    '5 ленина',
    'ул. Ленина, 5',
    'ленинский пр-т 30',
    'пр мира',
    'светлогорск ленина 10',
    'калинин',
    'зеленоградск',
    'аптека',
    'азс',
    'заправка лукойл',
    'южный вокзал',
    'храброво',
    'музей океана',
    '9 апреля 5',
    'озерная 12',
    'озёрная 12а',
  ],
  'moscow': [
    'тверская 7',
    '7 тверская',
    'ул. Тверская, д. 7',
    'ленинский проспект 30',
    'ленинский пр-т 30 к2',
    'пр мира 100',
    '1-я парковая 5',
    'ленина 5',
    'ленина 5 подольск',
    'химки',
    'тула',
    'шереметьево',
    'красная площадь',
    'метро арбатская',
    'аптека',
    'азс лукойл',
    'мкад',
    'курский вокзал',
    'домодед',
    'б. якиманка 24',
  ],
};

void main() {
  final path = 'data/packs/$_pack/places.sqlite';
  final exists = File(path).existsSync();

  test('search on the $_pack pack', skip: exists ? false : 'no $path', () {
    final db = PlacesDatabase.open(path);
    addTearDown(db.close);
    final near = _centres[_pack] ?? const LatLng(0, 0);
    // ignore: avoid_print
    void out(Object o) => print(o);
    out('meta: ${db.meta}');
    final queries = _queries[_pack] ?? _queries['moscow']!;
    for (final q in queries) {
      final res = db.search(q, near: near, limit: 5);
      out('\n"$q"');
      for (final r in res) {
        out(
          '  ${r.score.toStringAsFixed(2)} [${r.category}] ${r.name}'
          ' — ${r.context ?? ''} (${((r.distanceM ?? 0) / 1000).toStringAsFixed(1)} km)',
        );
      }
    }
    // Latency: every prefix of every query, as when typing.
    final times = <int>[];
    final sw = Stopwatch();
    String worstQ = '';
    var worst = 0;
    for (var round = 0; round < 3; round++) {
      for (final q in queries) {
        for (var i = 1; i <= q.length; i++) {
          final prefix = q.substring(0, i);
          sw
            ..reset()
            ..start();
          db.search(prefix, near: near, limit: 20);
          sw.stop();
          if (round > 0) {
            times.add(sw.elapsedMicroseconds);
            if (sw.elapsedMicroseconds > worst) {
              worst = sw.elapsedMicroseconds;
              worstQ = prefix;
            }
          }
        }
      }
    }
    times.sort();
    String ms(int us) => (us / 1000).toStringAsFixed(2);
    out(
      '\nlatency over ${times.length} as-you-type searches: '
      'p50 ${ms(times[times.length ~/ 2])} ms, '
      'p95 ${ms(times[(times.length * 0.95).floor()])} ms, '
      'p99 ${ms(times[(times.length * 0.99).floor()])} ms, '
      'max ${ms(times.last)} ms ("$worstQ")',
    );
    final cams = db.camerasNear(near, 20000);
    out(
      'cameras within 20 km of centre: ${cams.length}; total ${db.cameras.count}',
    );
  });

  test(
    'camera directions are self-consistent on the $_pack pack',
    skip: exists ? false : 'no $path',
    () {
      final db = PlacesDatabase.open(path);
      addTearDown(db.close);
      final near = _centres[_pack] ?? const LatLng(0, 0);
      const d = Distance();
      var directed = 0, forwardOk = 0, reverseHidden = 0;
      final sw = Stopwatch()..start();
      final all = db.camerasNear(near, 400000);
      for (final n in all) {
        final c = n.camera;
        if (c.bearing == null) continue;
        directed++;
        // A 600 m straight drive through the camera along its bearing.
        final a = d.offset(c.point, 300, (c.bearing! + 180) % 360);
        final b = d.offset(c.point, 300, c.bearing!);
        final fwd = db.camerasAlong([a, b]);
        if (fwd.any(
          (r) => r.camera.id == c.id && (r.alongM - 300).abs() < 15,
        )) {
          forwardOk++;
        }
        final back = db.camerasAlong([b, a]);
        if (c.bidirectional || !back.any((r) => r.camera.id == c.id)) {
          reverseHidden++;
        }
      }
      sw.stop();
      final per = sw.elapsedMicroseconds / 2 / (directed == 0 ? 1 : directed);
      // ignore: avoid_print
      print(
        'cameras: ${all.length}, with direction: $directed, '
        '${per.toStringAsFixed(0)} µs per camerasAlong',
      );
      expect(forwardOk, directed);
      expect(reverseHidden, directed);

      // A long synthetic route (straight line across the pack).
      final box = db.bbox;
      if (box != null) {
        final route = <LatLng>[
          for (var i = 0; i <= 20000; i++)
            LatLng(
              box[1] + (box[3] - box[1]) * i / 20000,
              box[0] + (box[2] - box[0]) * i / 20000,
            ),
        ];
        final sw2 = Stopwatch()..start();
        final found = db.camerasAlong(route);
        sw2.stop();
        // ignore: avoid_print
        print(
          'camerasAlong on a ${route.length}-point diagonal: '
          '${found.length} cameras, ${sw2.elapsedMilliseconds} ms',
        );
      }
    },
  );
}
