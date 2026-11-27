import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/routing/valhalla_client.dart';

// Fixtures are real responses of Valhalla 3.6.0 on the Kaliningrad extract.
String fixture(String name) =>
    File('test/routing/fixtures/$name').readAsStringSync();

Map<String, dynamic> fixtureJson(String name) =>
    jsonDecode(fixture(name)) as Map<String, dynamic>;

http.Response jsonResponse(String body, [int status = 200]) => http.Response(
  body,
  status,
  headers: {'content-type': 'application/json;charset=utf-8'},
);

void main() {
  group('RouteResult', () {
    final result = RouteResult.fromJson(
      fixtureJson('route_auto_alternates.json'),
      costing: RouteCosting.auto,
    );

    test('has the best route and both alternates', () {
      expect(result.routes.length, 3);
      expect(result.best, same(result.routes.first));
      expect(result.alternates.length, 2);
      expect(result.routes.map((r) => r.lengthMeters.round()), [
        42219,
        42538,
        38799,
      ]);
      expect(result.routes.map((r) => r.timeSeconds), [
        1964.2,
        2261.696,
        2350.18,
      ]);
      expect(result.best.duration, const Duration(milliseconds: 1964200));
      expect(result.best.costing, RouteCosting.auto);
    });

    test('decodes geometry', () {
      final shape = result.best.shape;
      expect(shape.length, 632);
      expect(shape.first.latitude, closeTo(54.710553, 1e-9));
      expect(shape.first.longitude, closeTo(20.452158, 1e-9));
      expect(shape.last.latitude, closeTo(54.95781, 1e-9));
      expect(shape.last.longitude, closeTo(20.475216, 1e-9));
      expect(result.routes[1].shape.length, 753);
      expect(result.routes[2].shape.length, 668);
      expect(result.best.summary.southWest, isNotNull);
      expect(result.best.summary.northEast, isNotNull);
    });

    test('parses maneuvers with Russian instructions', () {
      final maneuvers = result.best.maneuvers.toList();
      expect(maneuvers.length, 16);

      final start = maneuvers.first;
      expect(start.type, ManeuverType.startLeft);
      expect(start.typeCode, 3);
      expect(start.instruction, 'Двигайтесь на запад по Харьковская улица.');
      expect(start.beginShapeIndex, 0);

      final turn = maneuvers[1];
      expect(turn.type, ManeuverType.left);
      expect(turn.typeCode, 15);
      expect(turn.instruction, 'Поверните налево на проспект Победы.');
      expect(turn.streetNames, ['проспект Победы']);
      expect(turn.beginShapeIndex, 12);
      expect(turn.lengthMeters, closeTo(3770, 1e-6));
      expect(turn.timeSeconds, 195.106);
      expect(turn.verbalPreTransition, isNotEmpty);
      expect(turn.travelMode, 'drive');

      final arrive = maneuvers.last;
      expect(arrive.type, ManeuverType.destination);
      expect(arrive.instruction, 'Вы прибыли в пункт назначения.');
      expect(arrive.beginShapeIndex, 631);
      expect(arrive.endShapeIndex, result.best.shape.length - 1);
    });

    test('maneuvers tile the shape and add up to the summary', () {
      for (final route in result.routes) {
        final maneuvers = route.maneuvers.toList();
        for (var i = 1; i < maneuvers.length; i++) {
          expect(maneuvers[i].beginShapeIndex, maneuvers[i - 1].endShapeIndex);
        }
        final length = maneuvers.fold(0.0, (s, m) => s + m.lengthMeters);
        final time = maneuvers.fold(0.0, (s, m) => s + m.timeSeconds);
        // Valhalla rounds every maneuver to 1 m / 1 ms.
        expect(length, closeTo(route.lengthMeters, 20));
        expect(time, closeTo(route.timeSeconds, 1));
      }
    });

    test('per-leg summary matches the trip for a single leg', () {
      final route = result.best;
      expect(route.legs.length, 1);
      expect(route.legs.single.summary.lengthMeters, route.lengthMeters);
      expect(route.legs.single.summary.timeSeconds, route.timeSeconds);
      expect(route.legs.single.shapeOffset, 0);
      expect(route.legs.single.encodedShape, startsWith('qpgjgB{rh_f@'));
    });

    test('joins legs and shifts shape indexes', () {
      final route = RouteResult.fromJson(
        fixtureJson('route_pedestrian_two_legs.json'),
      ).best;
      expect(route.legs.length, 2);
      expect(route.legs[0].shape.length, 29);
      expect(route.legs[1].shape.length, 56);
      // The joint point is kept once.
      expect(route.shape.length, 29 + 56 - 1);
      expect(route.legs[1].shapeOffset, 28);
      expect(route.shape[28], route.legs[1].shape.first);
      expect(route.legs[1].maneuvers.first.beginShapeIndex, 28);
      expect(route.maneuvers.last.endShapeIndex, route.shape.length - 1);
      expect(
        route.legs[0].summary.lengthMeters + route.legs[1].summary.lengthMeters,
        closeTo(route.lengthMeters, 1e-6),
      );
      expect(route.legs[0].summary.lengthMeters, closeTo(837, 1e-6));
    });

    test('rejects a body without a trip', () {
      expect(() => RouteResult.fromJson(const {}), throwsFormatException);
    });
  });

  group('RouteEdge', () {
    final edges = RouteEdge.listFromJson(
      fixtureJson('trace_attributes_auto.json'),
    );

    test('parses ids, speeds and shape indexes', () {
      expect(edges.length, 235);
      final first = edges.first;
      expect(first.id, 518657520394);
      expect(first.wayId, 44388054);
      expect(first.speedKmh, 35);
      expect(first.lengthMeters, closeTo(52, 1e-6));
      expect(first.roadClass, 'residential');
      expect(first.use, 'road');
      expect(first.names, ['Харьковская улица']);
      expect(first.beginShapeIndex, 0);
      expect(first.endShapeIndex, 1);
      expect(first.freeFlowSeconds, closeTo(5.396, 1e-9));
      expect(edges[1].freeFlowSeconds, closeTo(20.833 - 5.396, 1e-9));
      expect(edges.every((e) => e.id != null), isTrue);
    });

    test('covers the whole route shape and time', () {
      final route = RouteResult.fromJson(
        fixtureJson('route_auto_alternates.json'),
      ).best;
      for (var i = 1; i < edges.length; i++) {
        expect(edges[i].beginShapeIndex, edges[i - 1].endShapeIndex);
      }
      expect(edges.last.endShapeIndex, route.shape.length - 1);
      final length = edges.fold(0.0, (s, e) => s + e.lengthMeters);
      final time = edges.fold(0.0, (s, e) => s + e.freeFlowSeconds);
      expect(length, closeTo(route.lengthMeters, 20));
      expect(time, closeTo(route.timeSeconds, 1));
      expect(edges.last.elapsedSeconds, closeTo(route.timeSeconds, 1));
    });

    test('applies leg offsets', () {
      final shifted = RouteEdge.listFromJson(
        fixtureJson('trace_attributes_auto.json'),
        shapeOffset: 100,
        elapsedOffset: 60,
      );
      expect(shifted.first.beginShapeIndex, 100);
      expect(shifted.first.elapsedSeconds, closeTo(65.396, 1e-9));
      expect(shifted.first.freeFlowSeconds, closeTo(5.396, 1e-9));
    });
  });

  group('ValhallaClient', () {
    test('sends a /route request and parses the answer', () async {
      late http.Request seen;
      final client = ValhallaClient(
        Uri.parse('http://127.0.0.1:8002'),
        httpClient: MockClient((request) async {
          seen = request;
          return jsonResponse(fixture('route_auto_alternates.json'));
        }),
      );
      final result = await client.route(
        locations: const [LatLng(54.7104, 20.4522), LatLng(54.9577, 20.475)],
        alternates: 2,
        headingDegrees: 370,
        costingOptions: const {'use_tolls': 0},
      );
      expect(result.routes.length, 3);
      expect(seen.method, 'POST');
      expect(seen.url.toString(), 'http://127.0.0.1:8002/route');
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body['costing'], 'auto');
      expect(body['alternates'], 2);
      expect(body['language'], 'ru-RU');
      expect(body['units'], 'kilometers');
      expect(body['costing_options'], {
        'auto': {'use_tolls': 0},
      });
      final locations = body['locations'] as List;
      expect(locations.length, 2);
      expect(locations[0], {
        'lat': 54.7104,
        'lon': 20.4522,
        'type': 'break',
        'heading': 10,
      });
      expect(locations[1]['type'], 'break');
    });

    test('via points are "through" and costing names match Valhalla', () {
      final body = ValhallaClient.buildRouteRequest(
        locations: const [LatLng(1, 2), LatLng(3, 4), LatLng(5, 6)],
        costing: RouteCosting.bicycle,
      );
      expect(body['costing'], 'bicycle');
      expect((body['locations'] as List).map((l) => l['type']), [
        'break',
        'through',
        'break',
      ]);
      expect(body.containsKey('alternates'), isFalse);
      expect(RouteCosting.pedestrian.name, 'pedestrian');
    });

    test('with stopAtVias every location is a stop of its own', () {
      final body = ValhallaClient.buildRouteRequest(
        locations: const [LatLng(1, 2), LatLng(3, 4), LatLng(5, 6)],
        stopAtVias: true,
      );
      expect((body['locations'] as List).map((l) => l['type']), [
        'break',
        'break',
        'break',
      ]);
    });

    test('a route through a stop has a leg with its own totals per stop', () {
      final route = RouteResult.fromJson(
        fixtureJson('route_pedestrian_two_legs.json'),
      ).best;
      expect(route.legs.length, 2);
      expect(route.legs.map((l) => l.summary.lengthMeters.round()), [
        837,
        1146,
      ]);
      expect(
        route.legs.fold(0.0, (s, l) => s + l.summary.timeSeconds),
        closeTo(route.timeSeconds, 0.01),
      );
      // The second leg starts where the first ended, in the joined shape.
      expect(route.shape[route.legs[1].shapeOffset], route.legs[0].shape.last);
    });

    test('keeps a base path prefix', () async {
      late Uri seen;
      final client = ValhallaClient(
        Uri.parse('https://example.org/valhalla/'),
        httpClient: MockClient((request) async {
          seen = request.url;
          return jsonResponse(fixture('status.json'));
        }),
      );
      final status = await client.status();
      expect(seen.toString(), 'https://example.org/valhalla/status');
      expect(status.version, '3.6.0');
      expect(status.tilesetLastModified, isNotNull);
    });

    test('turns Valhalla errors into ValhallaException', () async {
      final client = ValhallaClient(
        Uri.parse('http://127.0.0.1:8002'),
        httpClient: MockClient(
          (_) async => jsonResponse(fixture('error_no_road.json'), 400),
        ),
      );
      await expectLater(
        client.route(locations: const [LatLng(54.7, 20.4), LatLng(55.5, 19)]),
        throwsA(
          isA<ValhallaException>()
              .having((e) => e.errorCode, 'errorCode', 171)
              .having((e) => e.httpStatus, 'httpStatus', 400)
              .having((e) => e.noRoadNearby, 'noRoadNearby', isTrue)
              .having(
                (e) => e.message,
                'message',
                'No suitable edges near location',
              ),
        ),
      );
    });

    test('non-JSON error bodies still raise ValhallaException', () {
      expect(
        () => ValhallaClient.parseResponse(502, utf8.encode('<html>bad')),
        throwsA(
          isA<ValhallaException>().having((e) => e.httpStatus, 'status', 502),
        ),
      );
    });

    test('connection failures raise ValhallaUnavailableException', () async {
      final client = ValhallaClient(
        Uri.parse('http://127.0.0.1:8002'),
        httpClient: MockClient(
          (_) async => throw const SocketException('Connection refused'),
        ),
      );
      await expectLater(
        client.status(),
        throwsA(isA<ValhallaUnavailableException>()),
      );
      expect(await client.isHealthy(), isFalse);
    });

    test('edges() walks each leg and shifts indexes', () async {
      final route = RouteResult.fromJson(
        fixtureJson('route_auto_alternates.json'),
        costing: RouteCosting.auto,
      ).best;
      late Map<String, dynamic> seen;
      final client = ValhallaClient(
        Uri.parse('http://127.0.0.1:8002'),
        httpClient: MockClient((request) async {
          expect(request.url.path, '/trace_attributes');
          seen = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse(fixture('trace_attributes_auto.json'));
        }),
      );
      final edges = await client.edges(route);
      expect(seen['encoded_polyline'], route.legs.single.encodedShape);
      expect(seen['shape_match'], 'edge_walk');
      expect(seen['costing'], 'auto');
      expect(edges.length, 235);
      expect(edges.last.endShapeIndex, route.shape.length - 1);
    });

    test('edges() falls back to map matching', () async {
      final route = RouteResult.fromJson(
        fixtureJson('route_auto_alternates.json'),
      ).best;
      final matches = <String>[];
      final client = ValhallaClient(
        Uri.parse('http://127.0.0.1:8002'),
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          matches.add(body['shape_match'] as String);
          if (body['shape_match'] == 'edge_walk') {
            return jsonResponse(
              '{"error_code":443,"error":"Exact route match algorithm failed '
              'to find path","status_code":400,"status":"Bad Request"}',
              400,
            );
          }
          return jsonResponse(fixture('trace_attributes_auto.json'));
        }),
      );
      expect((await client.edges(route)).length, 235);
      expect(matches, ['edge_walk', 'map_snap']);
    });

    test('locate() returns the snapped point', () async {
      final client = ValhallaClient(
        Uri.parse('http://127.0.0.1:8002'),
        httpClient: MockClient(
          (_) async => jsonResponse(fixture('locate_verbose.json')),
        ),
      );
      final snapped = await client.locate(const LatLng(54.7104, 20.4522));
      expect(snapped, isNotNull);
      expect(snapped!.point.latitude, closeTo(54.710553, 1e-9));
      expect(snapped.point.longitude, closeTo(20.452158, 1e-9));
      expect(snapped.wayId, 44388054);
      expect(snapped.edgeId, 511778861834);
      expect(snapped.distanceMeters, 17.2);
    });

    test('locate() returns null when nothing is near', () async {
      final client = ValhallaClient(
        Uri.parse('http://127.0.0.1:8002'),
        httpClient: MockClient(
          (_) async => jsonResponse(
            '[{"input_lat":0.0,"input_lon":0.0,"edges":null,"nodes":null}]',
          ),
        ),
      );
      expect(await client.locate(const LatLng(0, 0)), isNull);
    });
  });
}
