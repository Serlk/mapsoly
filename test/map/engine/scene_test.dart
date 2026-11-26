import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/map/engine/maplibre/scene.dart';
import 'package:mapsoly/map/engine/maplibre/style.dart';

void main() {
  const a = LatLng(55.75, 37.61),
      b = LatLng(55.76, 37.63),
      c = LatLng(55.77, 37.60);

  group('diffScene', () {
    const base = SceneState(style: 'bright|/p');

    test('first state and a style change only load the style', () {
      final next = SceneState(
        style: 'dark|/p',
        routes: routesGeoJson([a, b], []),
      );
      for (final old in [null, base]) {
        final ops = diffScene(old, next);
        expect(ops, hasLength(1));
        expect((ops.single as LoadStyle).style, 'dark|/p');
      }
    });

    test('after a style load everything that is not empty is sent', () {
      final next = SceneState(
        style: 'bright|/p',
        routes: routesGeoJson([a, b], []),
        points: pointsGeoJson(position: a),
        accuracy: accuracyGeoJson(a, 20),
        traffic: 'yandex-1',
      );
      final ops = diffScene(const SceneState(style: 'bright|/p'), next);
      expect(ops.whereType<SetGeoJson>().map((o) => o.source).toSet(), {
        MapIds.routes,
        MapIds.points,
        MapIds.accuracy,
      });
      final traffic = ops.whereType<SetTraffic>().single;
      expect(traffic.add, 'yandex-1');
      expect(traffic.remove, isNull);
    });

    test('nothing changed, nothing sent', () {
      final s = SceneState(
        style: 'bright|/p',
        points: pointsGeoJson(position: a),
      );
      final same = SceneState(
        style: 'bright|/p',
        points: pointsGeoJson(position: a),
      );
      expect(diffScene(s, same), isEmpty);
    });

    test('a moving position touches only the points and the circle', () {
      final routes = routesGeoJson(
        [a, b, c],
        [
          [a, c],
        ],
      );
      SceneState at(LatLng p) => SceneState(
        style: 'bright|/p',
        routes: routes,
        points: pointsGeoJson(position: p, to: c),
        accuracy: accuracyGeoJson(p, 10),
        traffic: 'yandex-1',
      );
      final ops = diffScene(at(a), at(b));
      expect(ops.map((o) => (o as SetGeoJson).source), [
        MapIds.points,
        MapIds.accuracy,
      ]);
    });

    test('traffic refresh, switch and off', () {
      SceneState t(String? traffic) => SceneState(style: 's', traffic: traffic);
      var op = diffScene(t('yandex-1'), t('yandex-2')).single as SetTraffic;
      expect((op.remove, op.add), ('yandex-1', 'yandex-2'));
      op = diffScene(t('yandex-2'), t('google-9')).single as SetTraffic;
      expect((op.remove, op.add), ('yandex-2', 'google-9'));
      op = diffScene(t('google-9'), t(null)).single as SetTraffic;
      expect((op.remove, op.add), ('google-9', null));
    });
  });

  group('GeoJSON', () {
    test('routes: alternatives first, lon/lat order, kinds', () {
      final json =
          jsonDecode(
                routesGeoJson(
                  [a, b],
                  [
                    [a, c],
                    [b],
                  ],
                ),
              )
              as Map;
      final features = (json['features'] as List).cast<Map>();
      expect(features.map((f) => f['properties']['kind']), ['alt', 'route']);
      expect(features.last['geometry']['coordinates'], [
        [37.61, 55.75],
        [37.63, 55.76],
      ]);
      expect(
        routesGeoJson(null, [
          [a, b],
        ]),
        SceneState.emptyGeoJson,
      );
    });

    test('points: only pins carry an icon', () {
      final json =
          jsonDecode(pointsGeoJson(position: a, from: a, to: b, picked: c))
              as Map;
      final props = [
        for (final f in json['features'] as List)
          (f as Map)['properties'] as Map,
      ];
      expect(props.map((p) => p['kind']), ['position', 'from', 'to', 'picked']);
      expect(props.map((p) => p['icon']), [
        null,
        null,
        MapIds.pinTo,
        MapIds.pinPicked,
      ]);
      expect(pointsGeoJson(), SceneState.emptyGeoJson);
    });

    test(
      'accuracy: closed polygon, default radius, empty without position',
      () {
        final json = jsonDecode(accuracyGeoJson(a, null)) as Map;
        final ring =
            ((json['features'] as List).single
                    as Map)['geometry']['coordinates'][0]
                as List;
        expect(ring.first, ring.last);
        expect(ring.length, greaterThan(24));
        expect(accuracyGeoJson(null, 30), SceneState.emptyGeoJson);
      },
    );
  });
}
