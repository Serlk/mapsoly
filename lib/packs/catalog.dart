import 'dart:convert';

/// One file of a region pack as published in the catalog.
class PackFile {
  const PackFile({
    required this.path,
    required this.url,
    required this.size,
    required this.sha256,
  });

  /// Where the file goes inside the pack folder, e.g. `valhalla/tiles.tar`.
  final String path;
  final Uri url;
  final int size;

  /// Lower-case hex digest of the whole file.
  final String sha256;

  factory PackFile.fromJson(Map<String, dynamic> json, Uri base) {
    final path = json['path'] as String;
    // A pack file must stay inside its folder.
    if (path.isEmpty ||
        path.startsWith('/') ||
        path.split('/').any((p) => p == '..' || p.isEmpty)) {
      throw FormatException('Unsafe pack file path: $path');
    }
    return PackFile(
      path: path,
      url: base.resolve(json['url'] as String),
      size: json['size'] as int,
      sha256: (json['sha256'] as String).toLowerCase(),
    );
  }

  Map<String, dynamic> toJson() => {
    'path': path,
    'url': url.toString(),
    'size': size,
    'sha256': sha256,
  };
}

/// A downloadable region: map, routing graph, search index.
class PackInfo {
  const PackInfo({
    required this.id,
    required this.name,
    required this.version,
    required this.files,
    this.bounds,
  });

  /// Folder name on the device; letters, digits, `-` and `_` only.
  final String id;

  /// Name shown to the user.
  final String name;

  /// Changes when the pack is rebuilt (the OSM data date, e.g. 2026-11-25).
  final String version;
  final List<PackFile> files;

  /// West, south, east, north in degrees.
  final List<double>? bounds;

  int get size => files.fold(0, (sum, f) => sum + f.size);

  factory PackInfo.fromJson(Map<String, dynamic> json, Uri base) {
    final id = json['id'] as String;
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
      throw FormatException('Bad pack id: $id');
    }
    return PackInfo(
      id: id,
      name: json['name'] as String? ?? id,
      version: json['version'] as String,
      bounds: (json['bounds'] as List?)
          ?.map((v) => (v as num).toDouble())
          .toList(),
      files: [
        for (final f in json['files'] as List)
          PackFile.fromJson(f as Map<String, dynamic>, base),
      ],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    if (bounds != null) 'bounds': bounds,
    'files': [for (final f in files) f.toJson()],
  };
}

/// The list of packs a server offers. File URLs may be relative to the
/// catalog's own URL.
class PackCatalog {
  const PackCatalog(this.packs);

  final List<PackInfo> packs;

  factory PackCatalog.parse(String body, Uri source) {
    final json = jsonDecode(body) as Map<String, dynamic>;
    final format = json['format'];
    if (format != 1) {
      throw FormatException('Unsupported catalog format: $format');
    }
    return PackCatalog([
      for (final p in json['packs'] as List)
        PackInfo.fromJson(p as Map<String, dynamic>, source),
    ]);
  }
}
