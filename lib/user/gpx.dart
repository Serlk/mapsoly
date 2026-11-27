/// GPX 1.1 exchange of saved places and routes, readable by other
/// navigation apps and able to read what they write.
///
/// Written file:
/// ```xml
/// <gpx version="1.1" creator="Mapsoly"
///      xmlns="http://www.topografix.com/GPX/1/1" xmlns:mapsoly="urn:mapsoly:gpx:1">
///   <metadata><name>…</name><time>…</time></metadata>
///   <wpt lat=".." lon=".."><name>…</name><desc>address</desc>
///     <extensions><mapsoly:id>…</mapsoly:id><mapsoly:kind>home</mapsoly:kind></extensions></wpt>
///   <rte><name>…</name>
///     <extensions><mapsoly:id/><mapsoly:costing/><mapsoly:created/><mapsoly:length/></extensions>
///     <rtept lat=".." lon=".."><name>label</name></rtept>…</rte>
///   <trk><name>…</name><extensions><mapsoly:route>id of the rte</mapsoly:route></extensions>
///     <trkseg><trkpt lat=".." lon=".."/>…</trkseg></trk>
/// </gpx>
/// ```
/// Other programs ignore the `mapsoly:` elements and still see ordinary
/// waypoints, routes and tracks.
///
/// There is no XML package among the dependencies, so this file has its own
/// small tokenizer. It understands what GPX needs (elements, attributes,
/// namespaces prefixes, CDATA, comments, the five predefined entities and
/// character references) and nothing that makes XML dangerous: a document
/// type declaration is refused, so no entity is ever defined or expanded
/// and nothing external is ever fetched.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

import '../positioning/geo.dart' show haversineM;
import '../routing/route_models.dart' show RouteCosting;
import 'json_store.dart';
import 'saved_routes.dart';
import 'user_places.dart';

/// Namespace of the app's own GPX extension elements.
const String mapsolyGpxNamespace = 'urn:mapsoly:gpx:1';

const String _gpxNamespace = 'http://www.topografix.com/GPX/1/1';

// ---------------------------------------------------------------- export

/// Characters XML 1.0 can carry at all (others cannot even be escaped).
bool _xmlChar(int c) =>
    c == 0x9 ||
    c == 0xA ||
    c == 0xD ||
    (c >= 0x20 && c <= 0xD7FF) ||
    (c >= 0xE000 && c <= 0xFFFD) ||
    (c >= 0x10000 && c <= 0x10FFFF);

/// Escapes [s] for element content or (with [attribute]) a quoted
/// attribute value. Characters XML cannot represent are dropped.
String xmlEscape(String s, {bool attribute = false}) {
  final out = StringBuffer();
  for (final c in s.runes) {
    switch (c) {
      case 0x26:
        out.write('&amp;');
      case 0x3C:
        out.write('&lt;');
      case 0x3E:
        out.write('&gt;');
      case 0x22:
        out.write('&quot;');
      case 0x27:
        out.write('&apos;');
      // A literal CR would be turned into LF by any XML reader.
      case 0xD:
        out.write('&#13;');
      case 0x9 || 0xA when attribute:
        out.write('&#$c;');
      default:
        if (_xmlChar(c)) out.writeCharCode(c);
    }
  }
  return out.toString();
}

/// Shortest decimal text that reads back as the same double, without an
/// exponent (GPX coordinates are `xsd:decimal`).
String _num(double v) {
  final s = v.toString();
  if (!s.contains('e')) return s;
  final fixed = v.toStringAsFixed(15);
  return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
}

/// What the importer does to names: surrounding whitespace is not kept.
String _text(String s) => xmlEscape(s.trim());

/// Builds a GPX 1.1 document with [places] as waypoints and [routes] as
/// routes (plus a track each when the route has a geometry). [name] and
/// [time] go to `<metadata>`; [time] defaults to now.
///
/// Reading the result with [importGpx] gives objects equal to the ones
/// written (same ids), provided names carry no leading or trailing
/// whitespace and no characters XML cannot represent (control characters
/// other than tab and line breaks).
///
/// Nothing is filtered here: places and routes are what the user chose to
/// save and to share, privacy zones do not apply to them.
String exportGpx({
  Iterable<SavedPlace> places = const [],
  Iterable<SavedRoute> routes = const [],
  String? name,
  DateTime? time,
}) {
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<gpx version="1.1" creator="Mapsoly" xmlns="$_gpxNamespace" '
      'xmlns:mapsoly="$mapsolyGpxNamespace">',
    )
    ..writeln('  <metadata>');
  if (name != null && name.trim().isNotEmpty) {
    b.writeln('    <name>${_text(name)}</name>');
  }
  b
    ..writeln(
      '    <time>${(time ?? DateTime.now()).toUtc().toIso8601String()}</time>',
    )
    ..writeln('  </metadata>');

  String at(LatLng p) => 'lat="${_num(p.latitude)}" lon="${_num(p.longitude)}"';

  for (final p in places) {
    b
      ..writeln('  <wpt ${at(p.point)}>')
      ..writeln('    <name>${_text(p.name)}</name>');
    final address = p.address;
    if (address != null && address.trim().isNotEmpty) {
      b.writeln('    <desc>${_text(address)}</desc>');
    }
    b
      ..writeln('    <extensions>')
      ..writeln('      <mapsoly:id>${_text(p.id)}</mapsoly:id>')
      ..writeln('      <mapsoly:kind>${p.kind.name}</mapsoly:kind>')
      ..writeln('    </extensions>')
      ..writeln('  </wpt>');
  }
  // The schema wants every <rte> before the first <trk>.
  for (final r in routes) {
    b
      ..writeln('  <rte>')
      ..writeln('    <name>${_text(r.name)}</name>')
      ..writeln('    <extensions>')
      ..writeln('      <mapsoly:id>${_text(r.id)}</mapsoly:id>')
      ..writeln('      <mapsoly:costing>${r.costing.name}</mapsoly:costing>')
      ..writeln(
        '      <mapsoly:created>${r.created.toIso8601String()}'
        '</mapsoly:created>',
      );
    final length = r.lengthMeters;
    if (length != null && length.isFinite) {
      b.writeln('      <mapsoly:length>${_num(length)}</mapsoly:length>');
    }
    b.writeln('    </extensions>');
    for (final p in r.points) {
      final label = p.label;
      if (label == null || label.trim().isEmpty) {
        b.writeln('    <rtept ${at(p.point)}/>');
      } else {
        b.writeln(
          '    <rtept ${at(p.point)}><name>${_text(label)}</name></rtept>',
        );
      }
    }
    b.writeln('  </rte>');
  }
  for (final r in routes) {
    final shape = r.geometry;
    if (shape == null) continue;
    b
      ..writeln('  <trk>')
      ..writeln('    <name>${_text(r.name)}</name>')
      ..writeln('    <extensions>')
      ..writeln('      <mapsoly:route>${_text(r.id)}</mapsoly:route>')
      ..writeln('    </extensions>')
      ..writeln('    <trkseg>');
    for (final p in shape) {
      b.writeln('      <trkpt ${at(p)}/>');
    }
    b
      ..writeln('    </trkseg>')
      ..writeln('  </trk>');
  }
  b.writeln('</gpx>');
  return b.toString();
}

/// Writes [exportGpx] to [out] (UTF-8, replaced atomically).
///
/// Throws [FileSystemException] when the file cannot be written.
void writeGpxFile(
  File out, {
  Iterable<SavedPlace> places = const [],
  Iterable<SavedRoute> routes = const [],
  String? name,
  DateTime? time,
}) => writeFileAtomic(
  out,
  exportGpx(places: places, routes: routes, name: name, time: time),
);

// ---------------------------------------------------------------- import

/// Bounds on what an import accepts.
class GpxLimits {
  const GpxLimits({
    this.maxBytes = 20 * 1024 * 1024,
    this.maxPoints = 200000,
    this.maxDepth = 64,
    this.maxTextLength = 500,
  });

  /// Largest file (for a string: number of UTF-16 code units).
  final int maxBytes;

  /// Waypoints, route points and track points together.
  final int maxPoints;

  /// Deepest element nesting.
  final int maxDepth;

  /// Names and descriptions are cut to this many characters.
  final int maxTextLength;
}

/// Something the import left out, with the number of times it happened.
class GpxSkipped {
  const GpxSkipped(this.reason, this.count);

  /// Short, in Russian, for the user.
  final String reason;
  final int count;

  @override
  String toString() => count == 1 ? reason : '$reason ($count)';
}

/// Outcome of [importGpx].
class GpxImportResult {
  GpxImportResult._({
    this.places = const [],
    this.routes = const [],
    this.skipped = const [],
    this.error,
  });

  /// Waypoints of the file. Those not written by this app are favourites
  /// with fresh ids.
  final List<SavedPlace> places;

  /// Routes of the file: every `<rte>`, and every track that belongs to no
  /// route (as a route from its first to its last point with the track as
  /// the geometry).
  final List<SavedRoute> routes;

  /// What was left out and why.
  final List<GpxSkipped> skipped;

  /// Set when the file was refused as a whole (in Russian, for the user);
  /// [places] and [routes] are empty then.
  final String? error;

  bool get ok => error == null;

  /// Nothing usable was found (the file may still be valid GPX).
  bool get isEmpty => places.isEmpty && routes.isEmpty;

  @override
  String toString() =>
      'GpxImportResult(${places.length} places, ${routes.length} routes, '
      'skipped $skipped${error == null ? '' : ', error: $error'})';
}

class _Refused implements Exception {
  const _Refused(this.message);
  final String message;
}

const _notXml = _Refused('Файл повреждён: это не корректный XML');

/// Decodes the predefined entities and character references of [s]. A
/// reference to anything else stays as written: no entity can be defined
/// (document type declarations are refused), so there is nothing to expand.
String _unescape(String s) {
  var amp = s.indexOf('&');
  if (amp < 0) return s;
  final out = StringBuffer();
  var from = 0;
  while (amp >= 0) {
    out.write(s.substring(from, amp));
    final semi = s.indexOf(';', amp);
    String? decoded;
    if (semi > amp && semi - amp <= 10) {
      final name = s.substring(amp + 1, semi);
      decoded = switch (name) {
        'amp' => '&',
        'lt' => '<',
        'gt' => '>',
        'quot' => '"',
        'apos' => "'",
        _ => null,
      };
      if (decoded == null && name.startsWith('#')) {
        final code = name.startsWith('#x') || name.startsWith('#X')
            ? int.tryParse(name.substring(2), radix: 16)
            : int.tryParse(name.substring(1));
        if (code != null) {
          decoded = _xmlChar(code) ? String.fromCharCode(code) : '�';
        }
      }
    }
    if (decoded == null) {
      out.write('&');
      from = amp + 1;
    } else {
      out.write(decoded);
      from = semi + 1;
    }
    amp = s.indexOf('&', from);
  }
  out.write(s.substring(from));
  return out.toString();
}

bool _space(int c) => c == 0x20 || c == 0x9 || c == 0xA || c == 0xD;

/// Walks the markup of [s], reporting elements and text. Throws [_Refused]
/// on anything that is not well-formed enough to trust.
void _scanXml(
  String s, {
  required void Function(String name, Map<String, String> attributes) onStart,
  required void Function(String name) onEnd,
  required void Function(String text) onText,
}) {
  final n = s.length;
  var i = 0;
  while (i < n) {
    final lt = s.indexOf('<', i);
    if (lt < 0) {
      onText(_unescape(s.substring(i)));
      break;
    }
    if (lt > i) onText(_unescape(s.substring(i, lt)));
    if (s.startsWith('<!--', lt)) {
      final end = s.indexOf('-->', lt + 4);
      if (end < 0) throw _notXml;
      i = end + 3;
    } else if (s.startsWith('<![CDATA[', lt)) {
      final end = s.indexOf(']]>', lt + 9);
      if (end < 0) throw _notXml;
      onText(s.substring(lt + 9, end));
      i = end + 3;
    } else if (s.startsWith('<?', lt)) {
      final end = s.indexOf('?>', lt + 2);
      if (end < 0) throw _notXml;
      i = end + 2;
    } else if (s.startsWith('<!', lt)) {
      // <!DOCTYPE …>: the only place entities could be declared.
      throw const _Refused(
        'Файл содержит объявление DOCTYPE, такие файлы не принимаются',
      );
    } else if (s.startsWith('</', lt)) {
      final end = s.indexOf('>', lt + 2);
      if (end < 0) throw _notXml;
      final name = s.substring(lt + 2, end).trim();
      if (name.isEmpty) throw _notXml;
      onEnd(name);
      i = end + 1;
    } else {
      // Start tag: name, then attributes up to '>' or '/>'.
      var p = lt + 1;
      while (p < n) {
        final c = s.codeUnitAt(p);
        if (_space(c) || c == 0x3E || c == 0x2F) break;
        if (c == 0x3C) throw _notXml;
        p++;
      }
      final name = s.substring(lt + 1, p);
      if (name.isEmpty || p >= n) throw _notXml;
      final attributes = <String, String>{};
      var selfClosing = false;
      while (true) {
        while (p < n && _space(s.codeUnitAt(p))) {
          p++;
        }
        if (p >= n) throw _notXml;
        final c = s.codeUnitAt(p);
        if (c == 0x3E) {
          p++;
          break;
        }
        if (c == 0x2F) {
          if (p + 1 >= n || s.codeUnitAt(p + 1) != 0x3E) throw _notXml;
          selfClosing = true;
          p += 2;
          break;
        }
        final nameStart = p;
        while (p < n) {
          final a = s.codeUnitAt(p);
          if (a == 0x3D || _space(a)) break;
          if (a == 0x3E || a == 0x3C || a == 0x2F) throw _notXml;
          p++;
        }
        final attribute = s.substring(nameStart, p);
        while (p < n && _space(s.codeUnitAt(p))) {
          p++;
        }
        if (attribute.isEmpty || p >= n || s.codeUnitAt(p) != 0x3D) {
          throw _notXml;
        }
        p++;
        while (p < n && _space(s.codeUnitAt(p))) {
          p++;
        }
        if (p >= n) throw _notXml;
        final quote = s.codeUnitAt(p);
        if (quote != 0x22 && quote != 0x27) throw _notXml;
        final close = s.indexOf(String.fromCharCode(quote), p + 1);
        if (close < 0) throw _notXml;
        final value = s.substring(p + 1, close);
        if (value.contains('<')) throw _notXml;
        attributes[attribute] = _unescape(value);
        p = close + 1;
      }
      onStart(name, attributes);
      if (selfClosing) onEnd(name);
      i = p;
    }
  }
}

final _decimal = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$');

/// A GPX coordinate: a plain decimal number. "55,75", "NaN", "" give null.
double? _coordinate(String? raw) {
  if (raw == null) return null;
  final s = raw.trim();
  if (!_decimal.hasMatch(s)) return null;
  final v = double.tryParse(s);
  return v != null && v.isFinite ? v : null;
}

class _Point {
  _Point(Map<String, String> a)
    : lat = _coordinate(a['lat']),
      lon = _coordinate(a['lon']);
  final double? lat, lon;
  String? name, desc, cmt, id, kind, time;

  LatLng? get point {
    final lat = this.lat, lon = this.lon;
    if (lat == null || lon == null || !validLatLon(lat, lon)) return null;
    return LatLng(lat, lon);
  }
}

class _Route {
  String? name, type, id, costing, created, length;
  final points = <RoutePoint>[];
}

class _Track {
  String? name, type, routeId, firstTime;
  final points = <LatLng>[];
}

RouteCosting _costingFromType(String? type) {
  final t = (type ?? '').toLowerCase();
  for (final c in RouteCosting.values) {
    if (t == c.name) return c;
  }
  if (RegExp('cycl|bik|ride|вело').hasMatch(t)) return RouteCosting.bicycle;
  if (RegExp('walk|hik|run|foot|pedestr|пеш').hasMatch(t)) {
    return RouteCosting.pedestrian;
  }
  return RouteCosting.auto;
}

double _lengthM(List<LatLng> line) {
  var sum = 0.0;
  for (var i = 1; i < line.length; i++) {
    sum += haversineM(
      line[i - 1].latitude,
      line[i - 1].longitude,
      line[i].latitude,
      line[i].longitude,
    );
  }
  return sum;
}

/// An unlinked track is taken for the line of a route when both run between
/// the same two places (within this distance at each end).
const double _sameEndM = 300;

/// Reads a GPX 1.0 / 1.1 document written by this app or by another tool.
///
/// * `<wpt>` becomes a [SavedPlace]: a favourite, unless the file is ours
///   and says home or work.
/// * `<rte>` becomes a [SavedRoute] with its `<rtept>` as points.
/// * `<trk>` written by this app next to a route becomes that route's
///   geometry. A foreign track becomes the geometry of a foreign route in
///   the same file that has none and starts and ends where the track does;
///   otherwise it becomes a route of its own from its first to its last
///   point, with the track as geometry and the length measured along it.
///
/// Objects written by this app keep their ids; everything else gets new
/// ones. Missing names are replaced by defaults. Namespaces and prefixes
/// are understood (`<gpx:trkpt>`), elements are matched by local name.
///
/// Never throws. A file that is too large (see [limits]), not well-formed,
/// not GPX, carries a DOCTYPE or has more points than allowed is refused as
/// a whole ([GpxImportResult.error]). Points with unusable coordinates
/// (missing, out of range, decimal commas) are left out one by one and
/// listed in [GpxImportResult.skipped].
///
/// [now] is the creation time given to routes the file has no time for.
GpxImportResult importGpx(
  String xml, {
  DateTime? now,
  GpxLimits limits = const GpxLimits(),
}) {
  try {
    return _import(xml, now ?? DateTime.now(), limits);
  } on _Refused catch (e) {
    return GpxImportResult._(error: e.message);
  }
}

GpxImportResult _import(String xml, DateTime now, GpxLimits limits) {
  if (xml.length > limits.maxBytes) {
    throw const _Refused('Файл слишком большой');
  }
  if (xml.startsWith('﻿')) xml = xml.substring(1);

  final skipped = <String, int>{};
  void skip(String reason) => skipped[reason] = (skipped[reason] ?? 0) + 1;

  final stack = <String>[]; // local names of the open elements
  final qnames = <String>[]; // the same, as written
  final ours = <bool>[]; // element is in the mapsoly namespace
  final scopes = <(int, Map<String, String>)>[]; // (depth, prefix -> uri)
  final text = StringBuffer();
  var pointCount = 0;
  var sawRoot = false;

  String? metaName, metaTime;
  _Point? point;
  _Route? route;
  _Track? track;
  final places = <SavedPlace>[];
  final routes = <_Route>[];
  final tracks = <_Track>[];
  var waypointNo = 0;

  String? namespaceOf(String prefix) {
    for (var i = scopes.length - 1; i >= 0; i--) {
      final uri = scopes[i].$2[prefix];
      if (uri != null) return uri;
    }
    return null;
  }

  String? clip(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (s.length > limits.maxTextLength) {
      s = s.substring(0, limits.maxTextLength);
      // Do not cut a surrogate pair in half.
      final last = s.codeUnitAt(s.length - 1);
      if (last >= 0xD800 && last <= 0xDBFF) s = s.substring(0, s.length - 1);
    }
    return s;
  }

  _Point newPoint(Map<String, String> attributes) {
    if (++pointCount > limits.maxPoints) {
      throw _Refused(
        'В файле слишком много точек (больше ${limits.maxPoints})',
      );
    }
    return _Point(attributes);
  }

  void onStart(String qname, Map<String, String> attributes) {
    final colon = qname.indexOf(':');
    final local = colon < 0 ? qname : qname.substring(colon + 1);
    final prefix = colon < 0 ? '' : qname.substring(0, colon);
    if (stack.isEmpty) {
      if (sawRoot) throw _notXml; // a second root element
      sawRoot = true;
      if (local != 'gpx') throw const _Refused('Это не GPX-файл');
    }
    if (stack.length >= limits.maxDepth) {
      throw const _Refused('Файл повреждён: слишком глубокая вложенность');
    }
    Map<String, String>? declared;
    for (final a in attributes.entries) {
      if (a.key == 'xmlns') {
        (declared ??= {})[''] = a.value;
      } else if (a.key.startsWith('xmlns:')) {
        (declared ??= {})[a.key.substring(6)] = a.value;
      }
    }
    if (declared != null) scopes.add((stack.length, declared));

    final parent = stack.isEmpty ? '' : stack.last;
    switch (local) {
      case 'wpt' when parent == 'gpx':
        point = newPoint(attributes);
      case 'rte' when parent == 'gpx':
        route = _Route();
      case 'rtept' when parent == 'rte' && route != null:
        point = newPoint(attributes);
      case 'trk' when parent == 'gpx':
        track = _Track();
      case 'trkpt' when parent == 'trkseg' && track != null:
        point = newPoint(attributes);
    }
    stack.add(local);
    qnames.add(qname);
    ours.add(namespaceOf(prefix) == mapsolyGpxNamespace);
    text.clear();
  }

  void onEnd(String qname) {
    if (stack.isEmpty || qnames.last != qname) throw _notXml;
    final local = stack.removeLast();
    qnames.removeLast();
    final mine = ours.removeLast();
    if (scopes.isNotEmpty && scopes.last.$1 == stack.length) {
      scopes.removeLast();
    }
    final parent = stack.isEmpty ? '' : stack.last;
    final grand = stack.length < 2 ? '' : stack[stack.length - 2];
    final value = clip(text.toString());
    text.clear();

    final p = point, r = route, t = track;
    if (mine && parent == 'extensions') {
      // Our own fields; the owner is the element around <extensions>.
      switch ((grand, local)) {
        case ('wpt', 'id'):
          p?.id = value;
        case ('wpt', 'kind'):
          p?.kind = value;
        case ('rte', 'id'):
          r?.id = value;
        case ('rte', 'costing'):
          r?.costing = value;
        case ('rte', 'created'):
          r?.created = value;
        case ('rte', 'length'):
          r?.length = value;
        case ('trk', 'route'):
          t?.routeId = value;
      }
      return;
    }
    switch ((parent, local)) {
      case ('metadata' || 'gpx', 'name'):
        metaName ??= value;
      case ('metadata' || 'gpx', 'time'):
        metaTime ??= value;
      case ('wpt' || 'rtept', 'name'):
        p?.name = value;
      case ('wpt', 'desc'):
        p?.desc = value;
      case ('wpt', 'cmt'):
        p?.cmt = value;
      case ('trkpt', 'time'):
        p?.time = value;
      case ('rte', 'name'):
        r?.name = value;
      case ('rte', 'type'):
        r?.type = value;
      case ('trk', 'name'):
        t?.name = value;
      case ('trk', 'type'):
        t?.type = value;
      case ('gpx', 'wpt') when p != null:
        point = null;
        waypointNo++;
        final at = p.point;
        if (at == null) {
          skip('Точка без корректных координат');
          break;
        }
        final kind = p.id == null
            ? SavedPlaceKind.favorite
            : SavedPlaceKind.values.firstWhere(
                (k) => k.name == p.kind,
                orElse: () => SavedPlaceKind.favorite,
              );
        places.add(
          SavedPlace(
            id: p.id,
            name: p.name ?? 'Точка $waypointNo',
            kind: kind,
            point: at,
            address: p.desc ?? p.cmt,
          ),
        );
      case ('rte', 'rtept') when p != null:
        point = null;
        final at = p.point;
        if (at == null) {
          skip('Точка маршрута без корректных координат');
        } else {
          r?.points.add(RoutePoint(at, label: p.name));
        }
      case ('trkseg', 'trkpt') when p != null:
        point = null;
        final at = p.point;
        if (at == null) {
          skip('Точка трека без корректных координат');
        } else if (t != null) {
          if (t.points.isEmpty) t.firstTime = p.time;
          t.points.add(at);
        }
      case ('gpx', 'rte') when r != null:
        route = null;
        if (r.points.length < 2) {
          skip('Маршрут, в котором меньше двух точек');
        } else {
          routes.add(r);
        }
      case ('gpx', 'trk') when t != null:
        track = null;
        if (t.points.length < 2) {
          skip('Трек, в котором меньше двух точек');
        } else {
          tracks.add(t);
        }
    }
  }

  _scanXml(xml, onStart: onStart, onEnd: onEnd, onText: text.write);
  if (!sawRoot) throw const _Refused('Это не GPX-файл');
  if (stack.isNotEmpty) throw _notXml; // cut off in the middle

  final fileTime = DateTime.tryParse(metaTime ?? '');
  // Tracks that say which route they belong to; then the others by place.
  final geometry = <_Route, List<LatLng>>{};
  final lone = <_Track>[];
  for (final t in tracks) {
    _Route? owner;
    if (t.routeId != null) {
      for (final r in routes) {
        if (r.id == t.routeId && !geometry.containsKey(r)) owner = r;
      }
    } else {
      for (final r in routes) {
        if (r.id != null || geometry.containsKey(r)) continue;
        final a = r.points.first.point, b = r.points.last.point;
        final ta = t.points.first, tb = t.points.last;
        if (haversineM(a.latitude, a.longitude, ta.latitude, ta.longitude) <=
                _sameEndM &&
            haversineM(b.latitude, b.longitude, tb.latitude, tb.longitude) <=
                _sameEndM) {
          owner = r;
          break;
        }
      }
    }
    if (owner != null) {
      geometry[owner] = t.points;
    } else {
      lone.add(t);
    }
  }

  var unnamed = 0;
  String routeName(String? own, DateTime created) {
    if (own != null) return own;
    // The file's own name fits when the file is about one thing.
    if (metaName != null && routes.length + lone.length == 1) {
      return metaName!;
    }
    final base = defaultRouteName(created);
    return ++unnamed == 1 ? base : '$base ($unnamed)';
  }

  final out = <SavedRoute>[];
  for (final r in routes) {
    final created = DateTime.tryParse(r.created ?? '') ?? fileTime ?? now;
    final line = geometry[r];
    final length = double.tryParse(r.length ?? '');
    out.add(
      SavedRoute(
        id: r.id,
        name: routeName(r.name, created),
        points: r.points,
        costing: _costingFromType(r.costing ?? r.type),
        created: created,
        geometry: line,
        lengthMeters: length != null && length.isFinite && length >= 0
            ? length
            : (r.id == null && line != null ? _lengthM(line) : null),
      ),
    );
  }
  for (final t in lone) {
    final created = DateTime.tryParse(t.firstTime ?? '') ?? fileTime ?? now;
    out.add(
      SavedRoute(
        name: routeName(t.name, created),
        points: [RoutePoint(t.points.first), RoutePoint(t.points.last)],
        costing: _costingFromType(t.type),
        created: created,
        geometry: t.points,
        lengthMeters: _lengthM(t.points),
      ),
    );
  }
  return GpxImportResult._(
    places: places,
    routes: out,
    skipped: [for (final e in skipped.entries) GpxSkipped(e.key, e.value)],
  );
}

/// Decodes file bytes: UTF-8 (the GPX default) or, when the XML declaration
/// says so, Latin-1.
String _decode(Uint8List bytes) {
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
          (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
    throw const _Refused('Неподдерживаемая кодировка файла (нужна UTF-8)');
  }
  final head = latin1.decode(
    bytes.sublist(0, bytes.length < 200 ? bytes.length : 200),
  );
  final declared = RegExp(
    '''<\\?xml[^>]*encoding\\s*=\\s*["']([^"']+)["']''',
  ).firstMatch(head)?.group(1)?.toLowerCase();
  switch (declared) {
    case null || 'utf-8' || 'utf8' || 'us-ascii' || 'ascii':
      return utf8.decode(bytes, allowMalformed: true);
    case 'iso-8859-1' || 'latin1' || 'latin-1':
      return latin1.decode(bytes);
    default:
      throw const _Refused('Неподдерживаемая кодировка файла (нужна UTF-8)');
  }
}

/// [importGpx] for bytes already in memory (a shared file, for instance).
GpxImportResult importGpxBytes(
  Uint8List bytes, {
  DateTime? now,
  GpxLimits limits = const GpxLimits(),
}) {
  if (bytes.length > limits.maxBytes) {
    return GpxImportResult._(error: 'Файл слишком большой');
  }
  try {
    return importGpx(_decode(bytes), now: now, limits: limits);
  } on _Refused catch (e) {
    return GpxImportResult._(error: e.message);
  }
}

/// Reads and parses [file] off the UI thread. The size is checked before
/// anything is read. Never throws: a missing or unreadable file is reported
/// in [GpxImportResult.error].
Future<GpxImportResult> importGpxFile(
  File file, {
  DateTime? now,
  GpxLimits limits = const GpxLimits(),
}) async {
  try {
    if (await file.length() > limits.maxBytes) {
      return GpxImportResult._(error: 'Файл слишком большой');
    }
    final path = file.path;
    return await Isolate.run(
      () => importGpxBytes(
        File(path).readAsBytesSync(),
        now: now,
        limits: limits,
      ),
    );
  } on FileSystemException {
    return GpxImportResult._(error: 'Файл не удалось прочитать');
  }
}
