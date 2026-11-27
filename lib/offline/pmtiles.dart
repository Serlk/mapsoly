import 'dart:io';
import 'dart:typed_data';

/// Minimal reader for PMTiles v3 archives (single-file tile pyramids).
///
/// Written in-house because the published `pmtiles` package requires a newer
/// Dart than the Flutter build available on the target phone.
class PmTilesArchive {
  PmTilesArchive._(this._file, this._header, this._root);

  static const _headerLength = 127;
  static const _compressionNone = 1;
  static const _compressionGzip = 2;
  static const _maxLeafCache = 64;

  final RandomAccessFile _file;
  final ByteData _header;
  final _Directory _root;
  final _leaves = <int, _Directory>{};

  int get minZoom => _header.getUint8(100);
  int get maxZoom => _header.getUint8(101);

  /// Bounds in degrees: west, south, east, north.
  List<double> get bounds => [
    for (final o in const [102, 106, 110, 114])
      _header.getInt32(o, Endian.little) / 1e7,
  ];

  static PmTilesArchive open(String path) {
    final file = File(path).openSync();
    try {
      final bytes = _readAt(file, 0, _headerLength);
      final header = ByteData.sublistView(bytes);
      if (bytes.length < _headerLength ||
          String.fromCharCodes(bytes.sublist(0, 7)) != 'PMTiles' ||
          bytes[7] != 3) {
        throw FormatException('Not a PMTiles v3 archive: $path');
      }
      final root = _Directory.parse(
        _decompress(
          _readAt(file, _u64(header, 8), _u64(header, 16)),
          header.getUint8(97),
        ),
      );
      return PmTilesArchive._(file, header, root);
    } catch (_) {
      file.closeSync();
      rethrow;
    }
  }

  /// Whether [storedTile] returns gzip data (else: plain).
  bool get tilesGzipped => _header.getUint8(98) == _compressionGzip;

  /// Returns the decompressed tile, or null if the archive has no such tile.
  Uint8List? tile(int z, int x, int y) {
    final data = storedTile(z, x, y);
    return data == null ? null : _decompress(data, _header.getUint8(98));
  }

  /// Returns the tile exactly as stored (compressed if the archive is, see
  /// [tilesGzipped]), or null if the archive has no such tile.
  Uint8List? storedTile(int z, int x, int y) {
    if (z < minZoom || z > maxZoom) return null;
    final id = tileId(z, x, y);
    var dir = _root;
    // The spec allows at most three directory levels below the root.
    for (var depth = 0; depth < 4; depth++) {
      final i = dir.find(id);
      if (i < 0) return null;
      if (dir.runLengths[i] > 0) {
        if (id >= dir.tileIds[i] + dir.runLengths[i]) return null;
        return _readAt(
          _file,
          _u64(_header, 56) + dir.offsets[i],
          dir.lengths[i],
        );
      }
      dir = _leaf(dir.offsets[i], dir.lengths[i]);
    }
    return null;
  }

  _Directory _leaf(int offset, int length) {
    final cached = _leaves.remove(offset);
    final dir =
        cached ??
        _Directory.parse(
          _decompress(
            _readAt(_file, _u64(_header, 40) + offset, length),
            _header.getUint8(97),
          ),
        );
    _leaves[offset] = dir; // re-insert: most recently used goes last
    if (_leaves.length > _maxLeafCache) _leaves.remove(_leaves.keys.first);
    return dir;
  }

  void close() => _file.closeSync();

  /// Position of a tile on the Hilbert curve across all zoom levels.
  static int tileId(int z, int x, int y) {
    var id = ((1 << (2 * z)) - 1) ~/ 3;
    for (var s = z == 0 ? 0 : 1 << (z - 1); s > 0; s >>= 1) {
      final rx = x & s, ry = y & s;
      id += s * ((3 * rx) ^ ry);
      if (ry == 0) {
        if (rx != 0) {
          x = s - 1 - x;
          y = s - 1 - y;
        }
        final t = x;
        x = y;
        y = t;
      }
    }
    return id;
  }

  static int _u64(ByteData d, int offset) => d.getUint64(offset, Endian.little);

  static Uint8List _readAt(RandomAccessFile f, int offset, int length) {
    f.setPositionSync(offset);
    return f.readSync(length);
  }

  static Uint8List _decompress(Uint8List data, int compression) {
    switch (compression) {
      case _compressionNone:
        return data;
      case _compressionGzip:
        return Uint8List.fromList(gzip.decode(data));
      default:
        throw FormatException('Unsupported PMTiles compression $compression');
    }
  }
}

class _Directory {
  _Directory(this.tileIds, this.runLengths, this.lengths, this.offsets);

  final Int64List tileIds, runLengths, lengths, offsets;

  factory _Directory.parse(Uint8List bytes) {
    var pos = 0;
    int varint() {
      var result = 0, shift = 0;
      while (true) {
        final b = bytes[pos++];
        result |= (b & 0x7f) << shift;
        if (b < 0x80) return result;
        shift += 7;
      }
    }

    final n = varint();
    final ids = Int64List(n), runs = Int64List(n);
    final lengths = Int64List(n), offsets = Int64List(n);
    var last = 0;
    for (var i = 0; i < n; i++) {
      ids[i] = last += varint();
    }
    for (var i = 0; i < n; i++) {
      runs[i] = varint();
    }
    for (var i = 0; i < n; i++) {
      lengths[i] = varint();
    }
    for (var i = 0; i < n; i++) {
      final v = varint();
      // Zero means "immediately after the previous entry".
      offsets[i] = v == 0 && i > 0 ? offsets[i - 1] + lengths[i - 1] : v - 1;
    }
    return _Directory(ids, runs, lengths, offsets);
  }

  /// Index of the last entry whose tile id is <= [id], or -1.
  int find(int id) {
    var lo = 0, hi = tileIds.length - 1, found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (tileIds[mid] <= id) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }
}
