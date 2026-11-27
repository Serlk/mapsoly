import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/map/route_controller.dart';
import 'package:mapsoly/routing/valhalla_client.dart';

import 'fake_routing.dart';

http.Response error(int code, String text) =>
    json({'error_code': code, 'error': text, 'status_code': 400}, 400);

// Public landmarks of Kaliningrad, where the fixtures were recorded.
const a = LatLng(54.7104, 20.4522);
const b = LatLng(54.7135, 20.4600);
const c = LatLng(54.7180, 20.4700);
const d = LatLng(54.7220, 20.4800);

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late FakeRouting routing;
  late RouteController route;

  setUp(() {
    routing = FakeRouting();
    route = RouteController()
      ..debugClient = routing.client
      ..debounce = Duration.zero;
  });
  tearDown(() => route.dispose());

  group('the simple from / to flow', () {
    test('"to" with a fix starts from the current position', () async {
      route.updateMyPosition(a);
      route.setTo(b, label: 'Музей');
      await settle();
      expect(route.fromIsMyPosition, isTrue);
      expect(route.from, a);
      expect(route.to, b);
      expect(route.toLabel, 'Музей');
      expect(route.routes.length, 3);
      final request = routing.routes.single;
      expect(request['alternates'], 2);
      expect((request['locations'] as List).length, 2);
    });

    test(
      '"to" without a fix waits for a start, then for the position',
      () async {
        route.setTo(b);
        await settle();
        expect(route.needStart, isTrue);
        expect(route.from, isNull);
        expect(route.to, b);
        expect(route.active, isTrue);
        expect(routing.requests, isEmpty);
        // The first fix becomes the start.
        route.updateMyPosition(a);
        await settle();
        expect(route.needStart, isFalse);
        expect(route.fromIsMyPosition, isTrue);
        expect(route.selected, isNotNull);
      },
    );

    test('"from" then "to", swap, clear the ends', () async {
      route.setFrom(a, label: 'Вокзал');
      expect(route.to, isNull);
      route.setTo(b, label: 'Музей');
      await settle();
      expect(route.stops.map(stopTitle), ['Вокзал', 'Музей']);
      route.setTo(c, label: 'Парк'); // replaces the destination
      expect(route.stops.map(stopTitle), ['Вокзал', 'Парк']);
      route.swap();
      expect(route.fromLabel, 'Парк');
      expect(route.toLabel, 'Вокзал');
      route.clearFrom();
      expect(route.needStart, isTrue);
      expect(route.to, a);
      route.clearTo();
      expect(route.active, isFalse);
      expect(route.needStart, isFalse);
    });
  });

  group('a trip with several stops', () {
    test('all stops are sent as breaks, without alternates', () async {
      route.updateMyPosition(a);
      route
        ..addStop(b, label: 'Музей')
        ..addStop(c, label: 'Парк');
      await settle();
      expect(route.stops.length, 3);
      expect(route.stops.first.myPosition, isTrue);
      final request = routing.routes.last;
      expect((request['locations'] as List).map((l) => l['type']), [
        'break',
        'break',
        'break',
      ]);
      expect(request.containsKey('alternates'), isFalse);
      // One leg per stop after the first, each with its own figures.
      expect(route.legTo(0), isNull);
      expect(route.legTo(1)!.lengthMeters.round(), 837);
      expect(route.legTo(2)!.lengthMeters.round(), 1146);
      expect(route.selected!.lengthMeters.round(), 1983);
    });

    test('the first stop added without a fix is a destination', () {
      route.addStop(b, label: 'Музей');
      expect(route.needStart, isTrue);
      expect(route.stops.map(stopTitle), ['Музей']);
      route.setFrom(a, label: 'Вокзал');
      expect(route.needStart, isFalse);
      expect(route.stops.map(stopTitle), ['Вокзал', 'Музей']);
    });

    test('move, remove, insert back, replace', () async {
      route
        ..setFrom(a, label: 'A')
        ..addStop(b, label: 'B')
        ..addStop(c, label: 'C')
        ..addStop(d, label: 'D');
      route.moveStop(3, 1);
      expect(route.stops.map(stopTitle), ['A', 'D', 'B', 'C']);
      route.moveStop(0, 2);
      expect(route.stops.map(stopTitle), ['D', 'B', 'A', 'C']);
      final removed = route.removeStop(1)!;
      expect(route.stops.map(stopTitle), ['D', 'A', 'C']);
      route.insertStop(1, removed);
      expect(route.stops.map(stopTitle), ['D', 'B', 'A', 'C']);
      route.setStop(3, c, label: 'Z');
      expect(route.stops.map(stopTitle), ['D', 'B', 'A', 'Z']);
      await settle();
    });

    test('"my position" moved away from the start becomes a fixed point', () {
      route.updateMyPosition(a);
      route
        ..addStop(b, label: 'B')
        ..addStop(c, label: 'C');
      route.moveStop(0, 1);
      expect(route.stops.any((s) => s.myPosition), isFalse);
      expect(route.stops[1].point, a);
      expect(route.stops.map(stopTitle), ['B', 'Место старта', 'C']);
    });

    test('a saved trip replaces the stops; a lone place starts from here', () {
      route.setStops(const [
        RouteStop(a, label: 'A'),
        RouteStop(c, label: 'C'),
      ]);
      expect(route.stops.map(stopTitle), ['A', 'C']);
      route.setStops(const [RouteStop(b, label: 'Дом')]);
      expect(route.needStart, isTrue);
      route.updateMyPosition(a);
      route.setStops(const [RouteStop(b, label: 'Дом')]);
      expect(route.needStart, isFalse);
      expect(route.stops.map(stopTitle), ['Моё местоположение', 'Дом']);
    });

    test('edits are debounced into one request, with progress shown', () async {
      Future<void> wait(int ms) =>
          Future<void>.delayed(Duration(milliseconds: ms));
      route.debounce = const Duration(milliseconds: 120);
      route.setFrom(a, label: 'A');
      route.addStop(b, label: 'B');
      expect(route.loading, isTrue);
      await wait(60);
      route.addStop(c, label: 'C');
      await wait(60);
      expect(routing.requests, isEmpty);
      await wait(150);
      expect(routing.routes.length, 1);
      expect((routing.routes.single['locations'] as List).length, 3);
      expect(route.loading, isFalse);
      expect(route.selected, isNotNull);
    });

    test('says which stop has no road next to it', () async {
      routing.fail = (action, body) {
        if (action == 'route') {
          return error(171, 'No suitable edges near location');
        }
        // The third stop is in the middle of nowhere.
        final p = (body['locations'] as List).single as Map;
        return p['lat'] == c.latitude
            ? json(<Object>[
                {'edges': null},
              ])
            : null;
      };
      route
        ..setFrom(a, label: 'A')
        ..addStop(b, label: 'B')
        ..addStop(c, label: 'Озеро')
        ..addStop(d, label: 'D');
      await settle();
      expect(route.selected, isNull);
      expect(route.errorStop, 2);
      expect(route.error, 'Рядом с остановкой 3 «Озеро» нет дороги');
    });

    test('says which stop cannot be reached', () async {
      routing.fail = (action, body) {
        final locations = body['locations'] as List;
        if (locations.length > 2) {
          return error(442, 'No path could be found');
        }
        // Only the way to the last stop is missing.
        return (locations.last as Map)['lat'] == d.latitude
            ? error(442, 'No path could be found')
            : null;
      };
      route
        ..setFrom(a, label: 'A')
        ..addStop(b, label: 'B')
        ..addStop(d);
      await settle();
      expect(route.errorStop, 2);
      expect(route.error, 'Не удалось проложить путь до остановки № 3');
      // Removing the stop clears the error and routes again.
      routing.fail = null;
      route.removeStop(2);
      await settle();
      expect(route.error, isNull);
      expect(route.selected, isNotNull);
    });

    test('a two-point failure keeps the plain message', () async {
      routing.fail = (action, body) => error(171, 'No suitable edges');
      route
        ..setFrom(a)
        ..setTo(b);
      await settle();
      expect(route.error, 'Рядом с точкой нет дороги');
      expect(route.errorStop, isNull);
    });
  });

  group('guidance over several legs', () {
    Future<Route> plan() async {
      route
        ..setFrom(a, label: 'Вокзал')
        ..addStop(b, label: 'Музей')
        ..addStop(c, label: 'Парк');
      await settle();
      return route.selected!;
    }

    test('announces the stop ahead, then that it was reached', () async {
      final r = await plan();
      route.startGuidance();
      final firstLeg = r.legs.first;
      route.updateMyPosition(r.shape[2], accuracyM: 5, speedMps: 1.5);
      expect(route.progress, isNotNull);
      // Near the end of the first leg: the stop is announced.
      route.updateMyPosition(
        firstLeg.shape[firstLeg.shape.length - 4],
        accuracyM: 5,
      );
      final ahead = route.stopNotice!;
      expect(ahead.reached, isFalse);
      expect(ahead.number, 2);
      expect(stopTitle(ahead.stop), 'Музей');
      expect(ahead.distanceM, lessThan(200));
      // At the stop.
      route.updateMyPosition(firstLeg.shape.last, accuracyM: 5);
      final reached = route.stopNotice!;
      expect(reached.reached, isTrue);
      expect(stopTitle(reached.stop), 'Музей');
      expect(route.arrival, isNull);
      expect(route.guiding, isTrue);
    });

    test('off the route: the passed stop is dropped, the rest kept', () async {
      final r = await plan();
      route.startGuidance();
      final second = r.legs[1];
      // Past the first stop, a little into the second leg.
      route.updateMyPosition(r.legs.first.shape.last, accuracyM: 5);
      route.updateMyPosition(second.shape[3], accuracyM: 5);
      routing.requests.clear();
      // Then well away from the route, three fixes in a row.
      final p = second.shape[3];
      final away = LatLng(p.latitude + 0.004, p.longitude + 0.004);
      for (var i = 0; i < 3; i++) {
        route.updateMyPosition(away, accuracyM: 5);
      }
      await settle();
      expect(route.stops.map(stopTitle), ['Моё местоположение', 'Парк']);
      final request = routing.routes.single;
      final sent = request['locations'] as List;
      expect(sent.length, 2);
      expect((sent.first as Map)['lat'], away.latitude);
      expect((sent.last as Map)['lat'], c.latitude);
      // Guidance goes on along the new route.
      expect(route.guiding, isTrue);
    });

    test('off the route before any stop: all stops are kept', () async {
      final r = await plan();
      route.startGuidance();
      route.updateMyPosition(r.shape[2], accuracyM: 5);
      final p = r.shape[2];
      final away = LatLng(p.latitude - 0.004, p.longitude - 0.004);
      for (var i = 0; i < 3; i++) {
        route.updateMyPosition(away, accuracyM: 5);
      }
      await settle();
      expect(route.stops.map(stopTitle), [
        'Моё местоположение',
        'Музей',
        'Парк',
      ]);
      expect(route.guiding, isTrue);
    });

    test('arrival ends in a trip summary', () async {
      final r = await plan();
      route.startGuidance();
      for (var i = 0; i < r.shape.length; i += 3) {
        route.updateMyPosition(r.shape[i], accuracyM: 5, speedMps: 1.5);
      }
      route.updateMyPosition(r.shape.last, accuracyM: 5);
      final arrival = route.arrival!;
      expect(arrival.label, 'Парк');
      expect(arrival.distanceM, closeTo(r.lengthMeters, 120));
      expect(route.guiding, isTrue);
      route.clear();
      expect(route.arrival, isNull);
      expect(route.active, isFalse);
    });

    test('traffic is estimated over every leg of the route', () async {
      // The edges request walks each leg; shape indexes continue.
      await plan();
      final edges = await routing.client.edges(route.selected!);
      final traces = routing.requests.where(
        (r) => r['action'] == 'trace_attributes',
      );
      expect(traces.length, 2);
      // Edges of the second leg continue the numbering of the joined shape.
      final offset = route.selected!.legs[1].shapeOffset;
      expect(edges.last.beginShapeIndex, greaterThanOrEqualTo(offset));
    });
  });
}
