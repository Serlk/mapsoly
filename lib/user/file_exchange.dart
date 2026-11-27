/// Getting files in and out of the app without a file-picker or share
/// plugin: exports go to a folder the user can open in a file manager,
/// imports are chosen in a small built-in browser.
///
/// Everything goes through [FileExchange], so that another platform can
/// plug in its own share sheet and document picker.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../map/ui_kit.dart';
import '../platform/android_bridge.dart';
import 'file_browser.dart';
import 'gpx.dart';
import 'saved_routes.dart';
import 'user_data.dart';
import 'user_places.dart';

/// How files leave and enter the app.
abstract class FileExchange {
  /// The export folder as the user would write it (`~/Documents/Mapsoly`).
  String get exportFolderLabel;

  /// The export folder, created when missing.
  ///
  /// Throws [FileSystemException] when it cannot be created.
  Future<Directory> exportDirectory();

  /// A file in the export folder that does not exist yet, named
  /// `<baseName>-<date>.<extension>` (with `-2`, `-3`… when taken).
  ///
  /// Throws [FileSystemException] when the folder cannot be created.
  Future<File> newExportFile(String baseName, String extension);

  /// Whether [reveal] can do anything on this device.
  bool get canReveal;

  /// Opens the export folder in the system's file manager. Never throws;
  /// false when that did not work.
  Future<bool> reveal();

  /// Lets the user choose a file with one of [extensions] (lower case,
  /// without the dot). Null when cancelled.
  Future<File?> pickFile(
    BuildContext context, {
    required String title,
    required Set<String> extensions,
  });
}

/// Linux (and anything else with a home folder): `~/Documents/Mapsoly`,
/// `xdg-open`, and the built-in [FileBrowserScreen].
class DesktopFileExchange implements FileExchange {
  /// [home] replaces `$HOME` (tests); [now] the clock used in file names.
  DesktopFileExchange({
    Directory? home,
    DateTime Function()? now,
    this.folder = 'Documents/Mapsoly',
  }) : home = home ?? Directory(Platform.environment['HOME'] ?? '/'),
       _now = now ?? DateTime.now;

  /// The export folder, relative to [home].
  final String folder;

  /// The user's home folder; the browser never leaves it.
  final Directory home;
  final DateTime Function() _now;

  Directory get _folder => Directory('${home.path}/$folder');

  @override
  String get exportFolderLabel => '~/$folder';

  @override
  Future<Directory> exportDirectory() async {
    final dir = _folder;
    await dir.create(recursive: true);
    return dir;
  }

  @override
  Future<File> newExportFile(String baseName, String extension) async {
    final dir = await exportDirectory();
    final t = _now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stem = '$baseName-${t.year}-${two(t.month)}-${two(t.day)}';
    for (var n = 1; ; n++) {
      final file = File('${dir.path}/$stem${n == 1 ? '' : '-$n'}.$extension');
      if (!file.existsSync()) return file;
    }
  }

  static String? _opener() {
    if (!Platform.isLinux) return null;
    for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
      if (dir.isEmpty) continue;
      final path = '$dir/xdg-open';
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  late final String? _xdgOpen = _opener();

  @override
  bool get canReveal => _xdgOpen != null;

  @override
  Future<bool> reveal() async {
    final opener = _xdgOpen;
    if (opener == null) return false;
    try {
      final dir = await exportDirectory();
      await Process.start(opener, [dir.path], mode: ProcessStartMode.detached);
      return true;
    } on Exception {
      return false;
    }
  }

  @override
  Future<File?> pickFile(
    BuildContext context, {
    required String title,
    required Set<String> extensions,
  }) => Navigator.of(context).push<File>(
    MaterialPageRoute(
      builder: (context) => FileBrowserScreen(
        title: title,
        home: home,
        start: _folder,
        extensions: extensions,
      ),
    ),
  );
}

/// Android: the app's own folder on the shared storage
/// (`Android/data/<package>/files/Mapsoly`), which needs no permission and
/// no picker plugin. A computer sees it over USB; on the phone, file
/// managers with access to `Android/data` do (the stock one hides that
/// folder since Android 11). Imports are browsed from the same place.
class AndroidFileExchange implements FileExchange {
  AndroidFileExchange({
    Future<String?> Function()? root,
    DateTime Function()? now,
  }) : _root = root ?? _platformRoot,
       _now = now;

  final Future<String?> Function() _root;
  final DateTime Function()? _now;
  DesktopFileExchange? _files;

  static Future<String?> _platformRoot() =>
      androidChannel.invokeMethod<String>('exportDir');

  /// The same folder logic as on the desktop, rooted in the app's folder.
  Future<DesktopFileExchange> _inner() async {
    final known = _files;
    if (known != null) return known;
    final root = await _root();
    if (root == null) {
      throw const FileSystemException('The shared storage is not available');
    }
    return _files = DesktopFileExchange(
      home: Directory(root),
      folder: 'Mapsoly',
      now: _now,
    );
  }

  @override
  String get exportFolderLabel =>
      'Android/data/dev.mapsoly.mapsoly/files/Mapsoly';

  @override
  Future<Directory> exportDirectory() async =>
      (await _inner()).exportDirectory();

  @override
  Future<File> newExportFile(String baseName, String extension) async =>
      (await _inner()).newExportFile(baseName, extension);

  // Nothing opens Android/data from outside without a file-provider.
  @override
  bool get canReveal => false;

  @override
  Future<bool> reveal() async => false;

  @override
  Future<File?> pickFile(
    BuildContext context, {
    required String title,
    required Set<String> extensions,
  }) async {
    final DesktopFileExchange files;
    try {
      files = await _inner();
      // The browser starts in the export folder: it has to exist.
      await files.exportDirectory();
    } on FileSystemException {
      return null;
    }
    if (!context.mounted) return null;
    return files.pickFile(context, title: title, extensions: extensions);
  }
}

/// The exchange for this platform.
FileExchange createFileExchange() =>
    Platform.isAndroid ? AndroidFileExchange() : DesktopFileExchange();

/// Tells the user what was written and where, and offers to open the
/// folder when the platform can.
void showExported(
  BuildContext context,
  FileExchange files,
  String message, {
  File? file,
}) {
  final reveal = files.canReveal;
  showNote(
    context,
    file == null ? message : '$message\n${file.path}',
    action: reveal ? 'Открыть папку' : null,
    onAction: reveal ? files.reveal : null,
    duration: const Duration(seconds: 8),
  );
}

String _counts(int places, int routes) => [
  if (places > 0) plural(places, 'место', 'места', 'мест'),
  if (routes > 0) plural(routes, 'маршрут', 'маршрута', 'маршрутов'),
].join(', ');

/// Writes [places] and [routes] into one new GPX file in the export folder
/// and says where it is.
Future<void> exportGpxFile(
  BuildContext context,
  FileExchange files, {
  Iterable<SavedPlace> places = const [],
  Iterable<SavedRoute> routes = const [],
  required String baseName,
}) async {
  final p = places.toList(), r = routes.toList();
  try {
    final file = await files.newExportFile(baseName, 'gpx');
    writeGpxFile(file, places: p, routes: r);
    if (!context.mounted) return;
    showExported(
      context,
      files,
      'Сохранено: ${_counts(p.length, r.length)}',
      file: file,
    );
  } on FileSystemException {
    if (!context.mounted) return;
    showNote(
      context,
      'Не удалось записать файл в папку ${files.exportFolderLabel}',
    );
  }
}

/// Lets the user choose a GPX file, adds its places and routes to the
/// stores and shows what was taken and what was left out.
Future<void> importGpxInto(
  BuildContext context,
  FileExchange files,
  UserData user,
) async {
  final file = await files.pickFile(
    context,
    title: 'Импорт маршрутов и мест',
    extensions: const {'gpx'},
  );
  if (file == null || !context.mounted) return;
  final result = await importGpxFile(file);
  var places = 0, routes = 0;
  if (result.ok) {
    places = user.places.addAll(result.places);
    routes = user.routes.addAll(result.routes);
  }
  if (!context.mounted) return;
  final String title, text;
  if (!result.ok) {
    title = 'Файл не подошёл';
    text = result.error!;
  } else if (places + routes == 0) {
    title = 'В файле ничего не нашлось';
    text = 'В нём нет ни мест, ни маршрутов, которые можно добавить.';
  } else {
    title = 'Готово';
    text = 'Добавлено: ${_counts(places, routes)}.';
  }
  final name = file.uri.pathSegments.last;
  await showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final quiet = theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      );
      return AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text),
              if (result.skipped.isNotEmpty) ...[
                const SizedBox(height: Ui.pad),
                Text('Пропущено', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                for (final s in result.skipped)
                  Text(
                    s.count == 1 ? s.reason : '${s.reason} — ${s.count}',
                    style: quiet,
                  ),
              ],
              const SizedBox(height: Ui.pad),
              Text(name, style: quiet),
            ],
          ),
        ),
        actions: [
          FilledButton(
            style: Ui.filled,
            onPressed: () => Navigator.pop(context),
            child: const Text('Понятно'),
          ),
        ],
      );
    },
  );
}
