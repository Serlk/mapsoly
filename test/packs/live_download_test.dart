import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mapsoly/offline/pmtiles.dart';
import 'package:mapsoly/packs/pack_store.dart';
import 'package:mapsoly/places/places_database.dart';
import 'package:mapsoly/settings.dart';

/// Downloads a real pack from the map server and checks what lands on disk.
/// Opt-in (network, ~110 MB): run with MAPSOLY_LIVE_PACK=crimean and
/// MAPSOLY_LIVE_DIR=<empty folder>.
void main() {
  final id = Platform.environment['MAPSOLY_LIVE_PACK'];
  final dir = Platform.environment['MAPSOLY_LIVE_DIR'];

  test(
    'a pack from the live catalog installs completely',
    () async {
      // flutter_test blocks real HTTP unless overrides are cleared.
      HttpOverrides.global = null;
      final store = PackStore(Directory(dir!), client: http.Client());
      final catalog = await store.fetchCatalog(Uri.parse(defaultCatalogUrl));
      final pack = catalog.packs.firstWhere((p) => p.id == id);
      final started = DateTime.now();
      final installed = await store.download(pack).done;
      final seconds = DateTime.now().difference(started).inSeconds;
      // ignore: avoid_print
      print('downloaded ${pack.size ~/ 1000000} MB in $seconds s');

      // The map opens and has tiles.
      final archive = PmTilesArchive.open(
        '${installed.directory.path}/map.pmtiles',
      );
      expect(archive.maxZoom, 14);
      final b = archive.bounds;
      // ignore: avoid_print
      print('map bounds $b');
      archive.close();

      // The search index opens and finds something.
      final places = PlacesDatabase.open(
        '${installed.directory.path}/places.sqlite',
      );
      final hits = places.search('ленина 1', limit: 3);
      // ignore: avoid_print
      print('search: ${hits.map((h) => '${h.name} (${h.context})').toList()}');
      expect(hits, isNotEmpty);
      places.close();

      // Routing tiles went to the shared graph; the tar is gone.
      expect(
        File('${installed.directory.path}/routing.tar').existsSync(),
        isFalse,
      );
      final shared = store.sharedRouting;
      expect(File('${shared.path}/valhalla.json').existsSync(), isTrue);
      final tiles = shared
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.gph'))
          .length;
      // ignore: avoid_print
      print(
        'routing tiles: $tiles, build ${File('${shared.path}/build.txt').readAsStringSync().trim()}',
      );
      expect(tiles, greaterThan(10));
      store.close();
    },
    skip: id == null || dir == null
        ? 'set MAPSOLY_LIVE_PACK and MAPSOLY_LIVE_DIR'
        : null,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
