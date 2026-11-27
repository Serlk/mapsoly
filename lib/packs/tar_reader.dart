import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One regular file inside a tar archive.
class TarEntry {
  TarEntry(this.name, this.size, this._file, this._offset);

  final String name;
  final int size;
  final RandomAccessFile _file;
  final int _offset;

  /// Copies the entry to [target], creating its folders.
  void extractTo(File target) {
    target.parent.createSync(recursive: true);
    final out = target.openSync(mode: FileMode.write);
    try {
      _file.setPositionSync(_offset);
      var left = size;
      while (left > 0) {
        final chunk = _file.readSync(left < 1 << 20 ? left : 1 << 20);
        if (chunk.isEmpty) throw const FormatException('Truncated tar');
        out.writeFromSync(chunk);
        left -= chunk.length;
      }
    } finally {
      out.closeSync();
    }
  }
}

/// Walks the regular files of an uncompressed ustar archive, calling
/// [onEntry] for each. Other entry types (folders, links, devices) are
/// skipped: an archive from the network must not create links.
void readTar(File archive, void Function(TarEntry entry) onEntry) {
  final file = archive.openSync();
  try {
    final length = file.lengthSync();
    var pos = 0;
    while (pos + 512 <= length) {
      file.setPositionSync(pos);
      final header = file.readSync(512);
      if (header.length < 512 || header.every((b) => b == 0)) break;
      String field(int start, int len) {
        final bytes = Uint8List.sublistView(header, start, start + len);
        final end = bytes.indexOf(0);
        return utf8.decode(
          end < 0 ? bytes : bytes.sublist(0, end),
          allowMalformed: true,
        );
      }

      final size = int.tryParse(field(124, 12).trim(), radix: 8);
      if (size == null || size < 0) {
        throw const FormatException('Bad tar header');
      }
      final type = header[156];
      final prefix = field(345, 155);
      final name = prefix.isEmpty ? field(0, 100) : '$prefix/${field(0, 100)}';
      final data = pos + 512;
      if (data + size > length) throw const FormatException('Truncated tar');
      // '0' or NUL: a regular file.
      if (type == 0x30 || type == 0) {
        onEntry(TarEntry(name, size, file, data));
      }
      pos = data + (size + 511) ~/ 512 * 512;
    }
  } finally {
    file.closeSync();
  }
}
