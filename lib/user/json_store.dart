/// Shared plumbing of the user-data stores: a small JSON file that is read
/// tolerantly and replaced atomically.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

var _idCounter = 0;
final _idRandom = math.Random();

/// A new locally unique id: time, a per-process counter and a few random
/// bits (so ids made on two devices in the same microsecond still differ).
String newUserId() {
  final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final n = (_idCounter++).toRadixString(36);
  final r = _idRandom.nextInt(1 << 20).toRadixString(36);
  return '$t-$n-$r';
}

/// Whether [lat], [lon] are usable WGS-84 coordinates.
bool validLatLon(double lat, double lon) =>
    lat.isFinite && lon.isFinite && lat.abs() <= 90 && lon.abs() <= 180;

/// `[lat, lon]` for JSON.
List<double> pointToJson(LatLng p) => [p.latitude, p.longitude];

/// Inverse of [pointToJson]; null when [json] is not a valid point.
LatLng? pointFromJson(Object? json) {
  if (json is! List || json.length != 2) return null;
  final lat = json[0], lon = json[1];
  if (lat is! num || lon is! num) return null;
  if (!validLatLon(lat.toDouble(), lon.toDouble())) return null;
  return LatLng(lat.toDouble(), lon.toDouble());
}

/// Replaces [file] with [content] so that a crash or a full disk leaves
/// either the old or the new file, never a torn one: the content goes to a
/// temporary file in the same directory, which is then renamed over the
/// target.
void writeFileAtomic(File file, String content) {
  file.parent.createSync(recursive: true);
  final tmp = File('${file.path}.tmp');
  tmp.writeAsStringSync(content, flush: true);
  tmp.renameSync(file.path);
}

/// Base of the stores in this directory.
///
/// Subclasses keep a list of items under one key of a JSON object
/// (`{"version": 1, "<key>": [...]}`), parse them one by one with
/// [decodeItem] (returning null for an item they cannot use) and call
/// [changed] after every modification.
abstract class JsonListStore<T> extends ChangeNotifier {
  JsonListStore(this.file, this.key);

  /// Backing file; null keeps everything in memory (tests, or when the
  /// directory could not be determined).
  final File? file;

  /// Name of the list inside the JSON object.
  final String key;

  /// Items in file order. Subclasses expose their own sorted view.
  @protected
  final List<T> items = [];

  /// Set when the file existed but could not be read, or some of its
  /// entries were unusable: a short message for the user. The unreadable
  /// file was copied to `<name>.bak` before anything is written over it.
  String? loadError;

  /// True when the file existed but nothing could be read from it at all.
  bool damaged = false;

  /// Number of entries dropped while loading.
  int skippedOnLoad = 0;

  /// Set when the last write failed (full or read-only disk); the change is
  /// still in effect in memory.
  String? saveError;

  @protected
  T? decodeItem(Map<String, dynamic> json);

  @protected
  Map<String, dynamic> encodeItem(T item);

  /// Further top-level fields to write next to the list.
  @protected
  Map<String, dynamic> get extraJson => const {};

  /// Reads back what [extraJson] wrote.
  @protected
  void decodeExtra(Map<dynamic, dynamic> json) {}

  /// Reads the file. Never throws: a missing file gives an empty store, an
  /// unreadable one an empty store plus [loadError] and a `.bak` copy.
  @protected
  void load() {
    final f = file;
    if (f == null) return;
    try {
      if (!f.existsSync()) return;
      final Object? json;
      try {
        json = jsonDecode(f.readAsStringSync());
      } on FormatException {
        _unreadable(f);
        return;
      }
      final list = json is Map ? json[key] : null;
      if (list is! List) {
        _unreadable(f);
        return;
      }
      decodeExtra(json as Map);
      for (final e in list) {
        T? item;
        if (e is Map) {
          try {
            item = decodeItem(e.cast<String, dynamic>());
          } on Object {
            item = null; // a field of an unexpected type
          }
        }
        if (item == null) {
          skippedOnLoad++;
        } else {
          items.add(item);
        }
      }
      if (skippedOnLoad > 0) {
        _backup(f);
        loadError = 'Часть записей не прочитана ($skippedOnLoad)';
      }
    } on FileSystemException catch (e) {
      debugPrint('${f.path} not loaded: $e');
      damaged = true;
      loadError = 'Файл данных не читается';
    }
  }

  void _unreadable(File f) {
    damaged = true;
    loadError = 'Файл данных повреждён, копия сохранена';
    _backup(f);
  }

  void _backup(File f) {
    try {
      f.copySync('${f.path}.bak');
    } on FileSystemException catch (e) {
      debugPrint('${f.path} not backed up: $e');
    }
  }

  /// Notifies listeners and writes the file.
  @protected
  void changed() {
    notifyListeners();
    final f = file;
    if (f == null) return;
    try {
      writeFileAtomic(
        f,
        jsonEncode({
          'version': 1,
          ...extraJson,
          key: items.map(encodeItem).toList(),
        }),
      );
      saveError = null;
    } on FileSystemException catch (e) {
      debugPrint('${f.path} not saved: $e');
      saveError = 'Не удалось сохранить изменения';
    }
  }
}
