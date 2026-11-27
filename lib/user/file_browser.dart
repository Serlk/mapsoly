/// A small file browser for choosing a file to import.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../map/ui_kit.dart';

/// What a folder holds, as far as the browser shows it.
class _Listing {
  _Listing({this.folders = const [], this.files = const [], this.error});

  final List<Directory> folders;
  final List<File> files;

  /// Why the folder cannot be shown (in Russian), if it cannot.
  final String? error;
}

/// Shows folders and the files with one of [extensions], inside the user's
/// [home] only, and pops with the chosen [File].
///
/// Links are resolved before they are followed: one that leads out of the
/// home folder is not opened. Hidden entries (names starting with a dot)
/// are not listed.
class FileBrowserScreen extends StatefulWidget {
  const FileBrowserScreen({
    super.key,
    required this.title,
    required this.home,
    required this.extensions,
    this.start,
  });

  final String title;
  final Directory home;

  /// Lower case, without the dot. Empty shows every file.
  final Set<String> extensions;

  /// Where to begin when it exists (and is inside [home]); otherwise home.
  final Directory? start;

  @override
  State<FileBrowserScreen> createState() => _FileBrowserScreenState();
}

class _FileBrowserScreenState extends State<FileBrowserScreen> {
  late final String _home = _resolve(widget.home.path) ?? widget.home.path;
  late String _path;
  late _Listing _listing;

  static String _name(String path) => path.substring(path.lastIndexOf('/') + 1);

  static String? _resolve(String path) {
    try {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.notFound) return null;
      return type == FileSystemEntityType.directory
          ? Directory(path).resolveSymbolicLinksSync()
          : File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return null;
    }
  }

  bool _inside(String resolved) =>
      resolved == _home || resolved.startsWith('$_home/');

  @override
  void initState() {
    super.initState();
    final start = widget.start;
    final resolved = start == null ? null : _resolve(start.path);
    _path =
        resolved != null &&
            _inside(resolved) &&
            Directory(resolved).existsSync()
        ? resolved
        : _home;
    _listing = _read(_path);
  }

  _Listing _read(String path) {
    final folders = <Directory>[], files = <File>[];
    try {
      for (final e in Directory(path).listSync(followLinks: false)) {
        final name = _name(e.path);
        if (name.startsWith('.')) continue;
        // What the entry really is, links followed, and where it really is.
        final resolved = _resolve(e.path);
        if (resolved == null || !_inside(resolved)) continue;
        final type = FileSystemEntity.typeSync(resolved);
        if (type == FileSystemEntityType.directory) {
          folders.add(Directory(e.path));
        } else if (type == FileSystemEntityType.file) {
          final dot = name.lastIndexOf('.');
          final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
          if (widget.extensions.isEmpty || widget.extensions.contains(ext)) {
            files.add(File(e.path));
          }
        }
      }
    } on FileSystemException {
      return _Listing(error: 'Эту папку не удалось открыть');
    }
    int byName(FileSystemEntity a, FileSystemEntity b) =>
        _name(a.path).toLowerCase().compareTo(_name(b.path).toLowerCase());
    return _Listing(folders: folders..sort(byName), files: files..sort(byName));
  }

  /// Opens [path] if it is a folder inside home. Returns false otherwise.
  bool _open(String path) {
    final resolved = _resolve(path);
    if (resolved == null || !_inside(resolved)) {
      showNote(context, 'Эта папка находится вне домашней — она не открыта');
      return false;
    }
    setState(() {
      _path = resolved;
      _listing = _read(resolved);
    });
    return true;
  }

  void _up() {
    if (_path == _home) return;
    _open(_path.substring(0, _path.lastIndexOf('/')));
  }

  void _choose(File file) {
    final resolved = _resolve(file.path);
    if (resolved == null || !_inside(resolved)) {
      showNote(context, 'Этот файл находится вне домашней папки');
      return;
    }
    Navigator.of(context).pop(File(resolved));
  }

  String get _shownPath =>
      _path == _home ? '~' : '~${_path.substring(_home.length)}';

  String get _extensions =>
      (widget.extensions.map((e) => '.$e').toList()..sort()).join(', ');

  String get _wanted => widget.extensions.isEmpty
      ? 'файлов'
      : 'файлов ${(widget.extensions.map((e) => '.$e').toList()..sort()).join(', ')}';

  String _details(File f) {
    try {
      final s = f.statSync();
      return '${formatBytes(s.size)} · ${formatDateTime(s.modified)}';
    } on FileSystemException {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final listing = _listing;
    final shortcuts = <(String, IconData, String)>[
      if (widget.start != null && Directory(widget.start!.path).existsSync())
        ('Mapsoly', Icons.folder_special_outlined, widget.start!.path),
      ('Домашняя папка', Icons.home_outlined, _home),
      for (final name in const ['Downloads', 'Загрузки'])
        if (Directory('$_home/$name').existsSync())
          ('Загрузки', Icons.download_outlined, '$_home/$name'),
    ];
    final empty = listing.folders.isEmpty && listing.files.isEmpty;

    // "Back" climbs out of a folder first and closes the browser at home.
    return PopScope(
      canPop: _path == _home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: SubPage(
        title: widget.title,
        onBack: () => Navigator.of(context).pop(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Ui.pad),
              child: Row(
                children: [
                  for (final (label, icon, path) in shortcuts)
                    Padding(
                      padding: const EdgeInsets.only(right: Ui.gap),
                      child: ChoiceChip(
                        showCheckmark: false,
                        avatar: Icon(icon, size: 20),
                        label: Text(label),
                        labelStyle: theme.textTheme.titleSmall,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 12,
                        ),
                        selected: _resolve(path) == _path,
                        onSelected: (_) => _open(path),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Ui.pad, 12, Ui.pad, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _shownPath,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (widget.extensions.isNotEmpty)
                    Text(
                      'Показаны файлы $_extensions',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: Ui.pad),
                children: [
                  if (_path != _home)
                    BigRow(
                      icon: Icons.drive_folder_upload_outlined,
                      title: 'Выше',
                      subtitle: 'В папку, где лежит эта',
                      trailing: const SizedBox.shrink(),
                      onTap: _up,
                    ),
                  if (listing.error != null)
                    _Hint(icon: Icons.folder_off_outlined, text: listing.error!)
                  else if (empty)
                    _Hint(
                      icon: Icons.folder_open_outlined,
                      text: 'Здесь нет папок и $_wanted',
                    ),
                  for (final d in listing.folders)
                    BigRow(
                      icon: Icons.folder_outlined,
                      title: _name(d.path),
                      onTap: () => _open(d.path),
                    ),
                  for (final f in listing.files)
                    BigRow(
                      icon: Icons.insert_drive_file_outlined,
                      title: _name(f.path),
                      subtitle: _details(f),
                      trailing: const SizedBox.shrink(),
                      onTap: () => _choose(f),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A quiet line in place of the list: empty or unreadable folder.
class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Ui.pad, 40, Ui.pad, 24),
      child: Column(
        children: [
          Icon(icon, size: 48, color: colors.outline),
          const SizedBox(height: Ui.pad),
          Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
