// Manual end-to-end check against a real Valhalla. Not run by `flutter test`.
//
//   dart run test/routing/manual_e2e.dart <pack>/valhalla [binary] \
//       [lat,lon lat,lon]
//
// Spawns the backend on the pack, routes with alternates, fetches per-edge
// data, kills the server to see it come back, and shuts everything down.
// With MAPSOLY_VALHALLA_URL set it talks to that server instead and skips
// the kill test.
import 'dart:io';

import 'package:latlong2/latlong.dart';
import 'package:mapsoly/routing/valhalla_service.dart';
import 'package:mapsoly/routing/valhalla_client.dart';

LatLng parsePoint(String s) {
  final parts = s.split(',');
  return LatLng(double.parse(parts[0]), double.parse(parts[1]));
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: manual_e2e.dart <pack>/valhalla [binary] [from to]');
    exit(2);
  }
  final points = args.where((a) => a.contains(',')).map(parsePoint).toList();
  final rest = args.where((a) => !a.contains(',')).toList();
  // Defaults are inside the Kaliningrad test extract.
  final from = points.length == 2 ? points[0] : const LatLng(54.7104, 20.4522);
  final to = points.length == 2 ? points[1] : const LatLng(54.9577, 20.4750);

  final url = Platform.environment['MAPSOLY_VALHALLA_URL'];
  final RoutingBackend backend = url != null && url.isNotEmpty
      ? RemoteValhallaBackend(Uri.parse(url))
      : LocalValhallaBackend(
          dataDirectory: Directory(rest[0]),
          binary: rest.length > 1 ? rest[1] : null,
          onLog: (line) => stdout.writeln('  [valhalla] $line'),
        );
  backend.states.listen((s) => stdout.writeln('state: ${s.name}'));

  var watch = Stopwatch()..start();
  await backend.start();
  stdout.writeln(
    'ready in ${watch.elapsedMilliseconds} ms at ${backend.baseUrl}',
  );
  final client = backend.client;
  final status = await client.status();
  stdout.writeln(
    'version ${status.version}, tiles ${status.tilesetLastModified}',
  );

  for (final costing in RouteCosting.values) {
    for (var i = 0; i < 3; i++) {
      watch = Stopwatch()..start();
      final result = await client.route(
        locations: [from, to],
        costing: costing,
        alternates: 2,
      );
      final routeMs = watch.elapsedMilliseconds;
      if (i < 2) continue; // report the warmed-up run
      stdout.writeln(
        '${costing.name}: ${result.routes.length} route(s) in $routeMs ms',
      );
      for (final route in result.routes) {
        watch = Stopwatch()..start();
        final edges = await client.edges(route);
        final edgesMs = watch.elapsedMilliseconds;
        final edgeTime = edges.fold(0.0, (s, e) => s + e.freeFlowSeconds);
        stdout.writeln(
          '  ${(route.lengthMeters / 1000).toStringAsFixed(1)} km, '
          '${(route.timeSeconds / 60).toStringAsFixed(1)} min, '
          '${route.shape.length} pts, ${route.maneuvers.length} maneuvers; '
          '${edges.length} edges in $edgesMs ms, '
          'sum of edge times ${(edgeTime / 60).toStringAsFixed(1)} min',
        );
      }
      if (costing == RouteCosting.auto) {
        for (final m in result.best.maneuvers.take(4)) {
          stdout.writeln(
            '    ${m.type.name}: ${m.instruction} '
            '(${m.lengthMeters.round()} m)',
          );
        }
      }
    }
  }

  try {
    await client.route(locations: [from, const LatLng(0, 0)]);
  } on ValhallaException catch (e) {
    stdout.writeln('expected error: $e');
  }

  if (backend is LocalValhallaBackend) {
    final pid = backend.pid!;
    stdout.writeln('killing pid $pid');
    final back = backend.states.firstWhere(
      (s) => s == RoutingBackendState.ready,
    );
    Process.killPid(pid, ProcessSignal.sigkill);
    await back.timeout(const Duration(seconds: 30));
    final again = await client.route(locations: [from, to]);
    stdout.writeln(
      'after restart (pid ${backend.pid}): '
      '${(again.best.lengthMeters / 1000).toStringAsFixed(1)} km',
    );
    final lastPid = backend.pid!;
    await backend.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    stdout.writeln(
      'disposed; server process alive: ${Directory('/proc/$lastPid').existsSync()}',
    );
  } else {
    await backend.dispose();
  }
  exit(0);
}
