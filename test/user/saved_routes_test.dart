import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/routing/route_models.dart' show RouteCosting;
import 'package:mapsoly/user/saved_routes.dart';

const palaceSquare = LatLng(59.9390, 30.3158);
const redSquare = LatLng(55.7539, 37.6208);
const brandenburgGate = LatLng(52.5163, 13.3777);

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('mapsoly-user-'));
  tearDown(() => dir.deleteSync(recursive: true));

  SavedRoute route(String name, DateTime created, {List<LatLng>? geometry}) =>
      SavedRoute(
        name: name,
        points: const [
          RoutePoint(palaceSquare, label: 'Дворцовая площадь'),
          RoutePoint(redSquare),
        ],
        created: created,
        geometry: geometry,
      );

  test('a route needs two points; via points are the middle', () {
    expect(
      () => SavedRoute(name: 'x', points: const [RoutePoint(redSquare)]),
      throwsArgumentError,
    );
    final r = SavedRoute(
      name: 'x',
      points: const [
        RoutePoint(palaceSquare),
        RoutePoint(brandenburgGate),
        RoutePoint(redSquare),
      ],
    );
    expect(r.start.point, palaceSquare);
    expect(r.destination.point, redSquare);
    expect(r.via.single.point, brandenburgGate);
    expect(r.created.isUtc, isTrue);
  });

  test('geometry is kept at 1e-6 degrees', () {
    final r = route(
      'x',
      DateTime.utc(2026),
      geometry: const [LatLng(59.93901234567, 30.31581234567), redSquare],
    );
    expect(r.geometry!.first, const LatLng(59.939012, 30.315812));
    expect(r.geometry!.last, redSquare);
  });

  test('round trip through the file, newest first', () {
    final store = SavedRoutes.load(dir);
    var notified = 0;
    store.addListener(() => notified++);
    final old = store.save(route('Старый', DateTime.utc(2026, 1, 1)));
    final shape = [
      for (var i = 0; i <= 500; i++)
        LatLng(59.9390 - i * 0.0083, 30.3158 + i * 0.0146),
    ];
    final fresh = store.save(
      SavedRoute(
        name: 'На работу',
        points: const [
          RoutePoint(palaceSquare, label: 'Дворцовая "площадь"'),
          RoutePoint(brandenburgGate, label: 'через Берлин'),
          RoutePoint(redSquare),
        ],
        costing: RouteCosting.bicycle,
        created: DateTime.utc(2026, 11, 26, 8, 30, 15, 123, 456),
        geometry: shape,
        lengthMeters: 712345.678,
      ),
    );
    expect(notified, 2);
    expect(store.routes, [fresh, old]);

    final again = SavedRoutes.load(dir);
    expect(again.loadError, isNull);
    expect(again.routes, [fresh, old]);
    final r = again.routes.first;
    expect(r.costing, RouteCosting.bicycle);
    expect(r.geometry, hasLength(501));
    expect(r.geometry, fresh.geometry);
    expect(r.lengthMeters, 712345.678);
    expect(r.created, DateTime.utc(2026, 11, 26, 8, 30, 15, 123, 456));
    expect(r.points[1].label, 'через Берлин');
    expect(again.routes.last.geometry, isNull);
    // Compact on disk: the shape is not a list of numbers.
    expect(File('${dir.path}/routes.json').lengthSync(), lessThan(501 * 12));
  });

  test('rename, default name, remove, replace by id', () {
    final store = SavedRoutes.load(dir);
    final r = store.save(route('  ', DateTime(2026, 11, 26, 12)));
    expect(r.name, 'Маршрут 26.11.2026');
    expect(store.rename(r.id, ' Домой '), isTrue);
    expect(store.routes.single.name, 'Домой');
    expect(store.rename('nope', 'x'), isFalse);
    store.save(store.routes.single.copyWith(name: 'Ещё раз'));
    expect(store.routes.single.name, 'Ещё раз');
    expect(store.routes.single.id, r.id);
    expect(store.addAll([route('A', DateTime.utc(2026)), r]), 2);
    expect(store.routes, hasLength(2));
    expect(store.remove(r.id), isTrue);
    expect(store.remove(r.id), isFalse);
    expect(SavedRoutes.load(dir).routes.single.name, 'A');
  });

  test('corrupt file: empty store, .bak kept', () {
    final file = File('${dir.path}/routes.json')
      ..writeAsStringSync('{"routes": [');
    final store = SavedRoutes.load(dir);
    expect(store.routes, isEmpty);
    expect(store.damaged, isTrue);
    expect(File('${file.path}.bak').readAsStringSync(), '{"routes": [');
  });

  test('bad routes are skipped; a bad geometry only loses the line', () {
    final point = [55.7539, 37.6208];
    File('${dir.path}/routes.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'routes': [
          {
            'id': 'one-point',
            'name': 'x',
            'points': [
              {'point': point},
            ],
          },
          {
            'id': 'bad-point',
            'points': [
              {'point': point},
              {'point': 'here'},
            ],
          },
          {
            'id': 'ok',
            'name': 'Хороший',
            'costing': 'teleport',
            'created': 'yesterday',
            'lengthMeters': -5,
            'geometry': '\u0001 not a polyline',
            'points': [
              {'point': point, 'label': 3},
              {'point': point},
            ],
          },
          42,
        ],
      }),
    );
    final store = SavedRoutes.load(dir);
    expect(store.routes.single.id, 'ok');
    final r = store.routes.single;
    expect(r.costing, RouteCosting.auto);
    expect(r.geometry, isNull);
    expect(r.lengthMeters, isNull);
    expect(r.points.first.label, isNull);
    expect(store.skippedOnLoad, 3);
    expect(File('${dir.path}/routes.json.bak').existsSync(), isTrue);
  });
}
