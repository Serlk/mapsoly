import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

import 'pmtiles.dart';

/// An offline region: a PMTiles archive plus the bundled style to draw it.
class OfflineMap {
  OfflineMap._(this.archive, this.theme, this.darkTheme, this.path);

  final PmTilesArchive archive;
  final vtr.Theme theme;
  final vtr.Theme darkTheme;
  final String path;

  /// Directory where region packs are stored on this device. Each pack is
  /// a folder: `map.pmtiles`, `valhalla/` (routing graph), `places.sqlite`.
  static Future<Directory> packsDirectory() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/packs');
  }

  /// The pack folder this map belongs to.
  Directory get packDirectory => File(path).parent;

  /// Opens the archive named by MAPSOLY_MAP, or the first installed pack.
  /// Returns null when there is no offline map yet.
  static Future<OfflineMap?> load() async {
    var path = Platform.environment['MAPSOLY_MAP'];
    if (path == null) {
      final dir = await packsDirectory();
      if (!dir.existsSync()) return null;
      final files =
          dir
              .listSync()
              .whereType<Directory>()
              .map((d) => '${d.path}/map.pmtiles')
              .where((p) => File(p).existsSync())
              .toList()
            ..sort();
      if (files.isEmpty) return null;
      path = files.first;
    }
    final archive = PmTilesArchive.open(path);
    Future<vtr.Theme> style(String name) async => vtr.ThemeReader().read(
      jsonDecode(await rootBundle.loadString('assets/styles/$name.json'))
          as Map<String, dynamic>,
    );
    return OfflineMap._(
      archive,
      await style('bright'),
      await style('dark'),
      path,
    );
  }
}
