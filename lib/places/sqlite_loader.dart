/// Makes package:sqlite3 find the system SQLite on Linux.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart' as sqlite_open;

bool _configured = false;

/// package:sqlite3 2.x opens `libsqlite3.so` on Linux, a name that only
/// exists when the SQLite development package is installed. Falls back to
/// the runtime soname `libsqlite3.so.0` (Alpine `sqlite-libs`, Arch
/// `sqlite`). Idempotent; called by the places databases before opening.
void ensureSqliteLoadable() {
  if (_configured) return;
  _configured = true;
  if (!Platform.isLinux) return;
  sqlite_open.open.overrideFor(sqlite_open.OperatingSystem.linux, () {
    Object? lastError;
    for (final name in const ['libsqlite3.so', 'libsqlite3.so.0']) {
      try {
        return DynamicLibrary.open(name);
      } on ArgumentError catch (e) {
        lastError = e;
      }
    }
    throw StateError('cannot load system SQLite: $lastError');
  });
}
