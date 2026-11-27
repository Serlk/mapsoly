import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mapsoly/routing/valhalla_client.dart';

String fixture(String name) =>
    File('test/routing/fixtures/$name').readAsStringSync();

http.Response json(Object body, [int status = 200]) => http.Response(
  body is String ? body : jsonEncode(body),
  status,
  headers: {'content-type': 'application/json;charset=utf-8'},
);

/// A `/route` answer with one leg per pair of stops, made from the legs of
/// the recorded two-leg response (repeated as needed).
String tripWithStops(int stops) {
  final recorded =
      jsonDecode(fixture('route_pedestrian_two_legs.json'))
          as Map<String, dynamic>;
  final trip = recorded['trip'] as Map<String, dynamic>;
  final legs = trip['legs'] as List;
  final out = [for (var i = 0; i < stops - 1; i++) legs[i % legs.length]];
  double sum(String key) => out.fold(
    0.0,
    (s, l) => s + (((l as Map)['summary'] as Map)[key] as num).toDouble(),
  );
  return jsonEncode({
    'trip': {
      ...trip,
      'legs': out,
      'summary': {
        ...trip['summary'] as Map<String, dynamic>,
        'length': sum('length'),
        'time': sum('time'),
      },
    },
  });
}

/// A routing server that answers from fixtures and records what it was
/// asked. [fail] may turn a request into an error.
class FakeRouting {
  final requests = <Map<String, dynamic>>[];
  http.Response? Function(String action, Map<String, dynamic> body)? fail;

  late final client = ValhallaClient(
    Uri.parse('http://routing.test'),
    httpClient: MockClient((request) async {
      final action = request.url.pathSegments.last;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      requests.add({'action': action, ...body});
      final failure = fail?.call(action, body);
      if (failure != null) return failure;
      if (action == 'locate') {
        return json([
          {
            'edges': [
              {'correlated_lat': 1, 'correlated_lon': 2},
            ],
          },
        ]);
      }
      if (action == 'trace_attributes') {
        return json(fixture('trace_attributes_auto.json'));
      }
      final n = (body['locations'] as List).length;
      return json(
        n == 2 ? fixture('route_auto_alternates.json') : tripWithStops(n),
      );
    }),
  );

  List<Map<String, dynamic>> get routes => [
    for (final r in requests)
      if (r['action'] == 'route') r,
  ];
}
