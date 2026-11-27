import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/routing/route_models.dart' show RouteCosting;
import 'package:mapsoly/user/gpx.dart';
import 'package:mapsoly/user/saved_routes.dart';
import 'package:mapsoly/user/user_places.dart';

const palaceSquare = LatLng(59.9390, 30.3158);
const redSquare = LatLng(55.7539, 37.6208);
const brandenburgGate = LatLng(52.5163, 13.3777);
const eiffelTower = LatLng(48.8584, 2.2945);

final now = DateTime.utc(2026, 11, 26, 12);

/// Names that break naive XML writers.
const hostileNames = [
  '<script>alert(1)</script> & </name></wpt></gpx>',
  '"double" \'single\' `back` =a="b"',
  'Дом 🏠🚗 кафе «Ёлка» 東京 🇷🇺',
  'line one\nline two\r\nline three\ttabbed\rold mac',
  ']]> <![CDATA[ not cdata ]]> <!-- not a comment -->',
  '&amp; &#x41; &unknown; &lt;b&gt; <?pi?> %s \\n \$x',
  'a   b', // inner spaces survive
];

/// A track as written by OsmAnd-like OSM tools: only `<trk>`, two segments,
/// per-point elevation/time/extensions.
const osmTrackOnly = '''<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<gpx version="1.1" creator="OsmAnd 4.6.8" xmlns="http://www.topografix.com/GPX/1/1" xmlns:osmand="https://osmand.net" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
  <metadata>
    <name>2026-11-20_08-15_Fri</name>
    <time>2026-11-20T05:15:02Z</time>
  </metadata>
  <trk>
    <trkseg>
      <trkpt lat="52.5163" lon="13.3777">
        <ele>34.2</ele>
        <time>2026-11-20T05:15:07Z</time>
        <hdop>1.1</hdop>
        <extensions>
          <osmand:speed>3.2</osmand:speed>
        </extensions>
      </trkpt>
      <trkpt lat="52.5160" lon="13.3740"><ele>34.0</ele><time>2026-11-20T05:15:37Z</time></trkpt>
      <trkpt lat="52.5155" lon="13.3690"><ele>33.8</ele><time>2026-11-20T05:16:07Z</time></trkpt>
    </trkseg>
    <trkseg>
      <trkpt lat="52.5150" lon="13.3640"><ele>33.5</ele><time>2026-11-20T05:20:00Z</time></trkpt>
      <trkpt lat="52.5145" lon="13.3501"><ele>33.1</ele><time>2026-11-20T05:21:00Z</time></trkpt>
    </trkseg>
  </trk>
  <extensions>
    <osmand:show_arrows>false</osmand:show_arrows>
    <osmand:color>#ff0000</osmand:color>
  </extensions>
</gpx>
''';

/// A favourites list as POI tools write it: CDATA, entities, symbols, a
/// waypoint without a name and two unusable ones.
const waypointList = '''<?xml version="1.0" encoding="UTF-8"?>
<!-- exported favourites -->
<gpx version="1.1" creator="GPSBabel - https://www.gpsbabel.org" xmlns="http://www.topografix.com/GPX/1/1">
  <metadata>
    <time>2026-10-01T10:00:00.000Z</time>
    <bounds minlat="48.85" minlon="2.29" maxlat="59.94" maxlon="37.63"/>
  </metadata>
  <wpt lat="48.858400" lon="2.294500">
    <ele>33.0</ele>
    <name>Tour Eiffel &amp; Champ-de-Mars</name>
    <cmt>comment only</cmt>
    <sym>Flag, Blue</sym>
    <type>home</type>
  </wpt>
  <wpt lon="30.3158" lat="59.9390">
    <name><![CDATA[Дворцовая <площадь> & "колонна"]]></name>
    <desc><![CDATA[Санкт-Петербург, Дворцовая пл.]]></desc>
    <link href="https://example.org/?a=1&amp;b=2"><text>site</text></link>
  </wpt>
  <wpt lat="55.7539" lon="37.6208"/>
  <wpt lat="52.5163" lon="13.3777"><name>  Caf&#233; &#x1F600; &quot;Tor&quot;
  </name><desc></desc></wpt>
  <wpt lat="95.0" lon="13.0"><name>north of the pole</name></wpt>
  <wpt lat="55,7539" lon="37,6208"><name>decimal commas</name></wpt>
  <wpt lon="37.6"><name>no latitude</name></wpt>
</gpx>
''';

/// Prefixed GPX with Garmin route extensions whose inner points must not be
/// mistaken for route points, and a nested look-alike `<name>`.
const prefixedRoute = '''<?xml version="1.0" encoding="utf-8"?>
<gpx:gpx xmlns:gpx="http://www.topografix.com/GPX/1/1"
         xmlns:gpxx="http://www.garmin.com/xmlschemas/GpxExtensions/v3"
         creator="BaseCamp" version="1.1">
  <gpx:metadata><gpx:name>Trip plans</gpx:name></gpx:metadata>
  <gpx:rte>
    <gpx:name>Berlin &#8594; Paris</gpx:name>
    <gpx:type>cycling</gpx:type>
    <gpx:extensions>
      <gpxx:RouteExtension><gpxx:IsAutoNamed>false</gpxx:IsAutoNamed></gpxx:RouteExtension>
    </gpx:extensions>
    <gpx:rtept lat="52.5163" lon="13.3777">
      <gpx:name>Brandenburger Tor</gpx:name>
      <gpx:extensions>
        <gpxx:RoutePointExtension>
          <gpxx:rpt lat="52.0" lon="13.0"/>
          <gpxx:rpt lat="51.0" lon="12.0"/>
          <gpxx:name>shadow name</gpxx:name>
        </gpxx:RoutePointExtension>
      </gpx:extensions>
    </gpx:rtept>
    <gpx:rtept lat="50.9413" lon="6.9583"></gpx:rtept>
    <gpx:rtept lat="48.8584" lon="2.2945"><gpx:name>Tour Eiffel</gpx:name></gpx:rtept>
  </gpx:rte>
  <gpx:rte>
    <gpx:rtept lat="59.9390" lon="30.3158"/>
    <gpx:rtept lat="xx" lon="30.0"/>
  </gpx:rte>
</gpx:gpx>
''';

/// GPX 1.0 from a web router: the same trip once as `<rte>` and once as
/// `<trk>`, no namespace prefix, name and time directly under `<gpx>`.
const routerGpx10 = '''<?xml version="1.0"?>
<gpx version="1.0" creator="some web router" xmlns="http://www.topografix.com/GPX/1/0">
<name>Walk to the tower</name>
<time>2026-09-09T09:09:09Z</time>
<rte>
<rtept lat="48.8530" lon="2.3499"><name>Notre-Dame</name></rtept>
<rtept lat="48.8584" lon="2.2945"><name>Tour Eiffel</name></rtept>
</rte>
<trk><name>Walk to the tower (line)</name><type>hiking</type><trkseg>
<trkpt lat="48.85301" lon="2.34992"></trkpt>
<trkpt lat="48.8560" lon="2.3200"></trkpt>
<trkpt lat="48.85842" lon="2.29452"></trkpt>
</trkseg></trk>
<trk><name>Somewhere else</name><trkseg>
<trkpt lat="59.9390" lon="30.3158"/><trkpt lat="59.9400" lon="30.3200"/>
</trkseg></trk>
</gpx>
''';

void main() {
  final places = [
    SavedPlace(
      name: 'Дом',
      kind: SavedPlaceKind.home,
      point: palaceSquare,
      address: 'Санкт-Петербург, Дворцовая пл., 2',
    ),
    SavedPlace(name: 'Работа', kind: SavedPlaceKind.work, point: redSquare),
    for (final (i, name) in hostileNames.indexed)
      SavedPlace(
        name: name,
        point: LatLng(48.8584 + i * 0.001234567891, 2.2945 - i * 1e-9),
        address: i.isEven ? name : null,
      ),
  ];
  final routes = [
    SavedRoute(
      name: 'В Москву',
      points: const [
        RoutePoint(palaceSquare, label: 'Дворцовая площадь'),
        RoutePoint(LatLng(57.6261, 39.8845)),
        RoutePoint(redSquare, label: 'Красная площадь'),
      ],
      costing: RouteCosting.auto,
      created: DateTime.utc(2026, 11, 26, 8, 30, 15, 123, 456),
      geometry: [
        for (var i = 0; i <= 300; i++)
          LatLng(59.9390 - i * 0.01395, 30.3158 + i * 0.02435),
      ],
      lengthMeters: 712345.678,
    ),
    SavedRoute(
      name: 'Без линии',
      points: const [RoutePoint(brandenburgGate), RoutePoint(eiffelTower)],
      costing: RouteCosting.pedestrian,
      created: DateTime.utc(2025, 1, 2, 3, 4, 5),
    ),
    for (final (i, name) in hostileNames.indexed)
      SavedRoute(
        name: name,
        points: [
          RoutePoint(eiffelTower, label: name),
          RoutePoint(LatLng(-33.8568 - i, 151.2153), label: '$name!'),
        ],
        costing: RouteCosting.bicycle,
        created: DateTime.utc(2026, 1, 1 + i),
        geometry: const [eiffelTower, LatLng(-33.8568, 151.2153)],
        lengthMeters: 1.5e-7 * (i + 1), // would print with an exponent
      ),
  ];

  group('export -> import', () {
    test('everything comes back equal', () {
      final xml = exportGpx(
        places: places,
        routes: routes,
        name: 'Всё <моё> & "чужое"',
        time: now,
      );
      final r = importGpx(xml, now: now);
      expect(r.error, isNull);
      expect(r.skipped, isEmpty);
      expect(r.places, places);
      expect(r.routes, routes);
      // Belt and braces on the fields equality covers.
      expect(r.places.first.kind, SavedPlaceKind.home);
      expect(r.places.first.id, places.first.id);
      expect(r.routes.first.geometry, hasLength(301));
      expect(r.routes.first.lengthMeters, 712345.678);
      expect(r.routes.first.created, routes.first.created);
      expect(r.routes[1].geometry, isNull);
      expect(r.routes[2].lengthMeters, 1.5e-7);
      expect(r.routes[5].points.first.label, hostileNames[3]);
    });

    test('second generation is identical text', () {
      final xml = exportGpx(places: places, routes: routes, time: now);
      final r = importGpx(xml);
      expect(exportGpx(places: r.places, routes: r.routes, time: now), xml);
    });

    test('places only, routes only, nothing', () {
      var r = importGpx(exportGpx(places: places));
      expect(r.places, places);
      expect(r.routes, isEmpty);
      r = importGpx(exportGpx(routes: routes));
      expect(r.places, isEmpty);
      expect(r.routes, routes);
      r = importGpx(exportGpx());
      expect(r.ok, isTrue);
      expect(r.isEmpty, isTrue);
    });

    test('escaped output: no markup leaks out of a name', () {
      final xml = exportGpx(places: places, routes: routes, time: now);
      expect(xml, isNot(contains('<script>')));
      expect(xml, isNot(contains('<![CDATA[')));
      expect(xml, isNot(contains('<!--')));
      expect(xml, isNot(contains('<?pi')));
      expect(xml, isNot(contains('\r')));
      expect(xml, contains('&lt;script&gt;alert(1)&lt;/script&gt; &amp; '));
      expect(xml, contains('&amp;amp; &amp;#x41; &amp;unknown;'));
      expect(xml, contains('line three\ttabbed&#13;old mac'));
      expect(xml, contains('🏠🚗'));
      // Coordinates are plain decimals.
      expect(
        RegExp('(lat|lon)="([^"]*)"').allMatches(xml).map((m) => m[2]!),
        everyElement(matches(RegExp(r'^-?\d+\.\d+$'))),
      );
      // Only the elements we mean to write.
      final tags = RegExp(
        r'</?([A-Za-z:]+)',
      ).allMatches(xml).map((m) => m[1]).toSet();
      expect(tags, {
        'gpx', 'metadata', 'name', 'time', 'wpt', 'desc', 'extensions', //
        'mapsoly:id', 'mapsoly:kind', 'rte', 'rtept', 'mapsoly:costing',
        'mapsoly:created', 'mapsoly:length', 'trk', 'mapsoly:route',
        'trkseg', 'trkpt',
      });
    });

    test('well-formed for an independent XML parser (xmllint)', () {
      final dir = Directory.systemTemp.createTempSync('mapsoly-gpx-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/all.gpx');
      writeGpxFile(
        file,
        places: [
          ...places,
          // Characters XML cannot carry at all are dropped.
          SavedPlace(name: 'nul\u0000 bell\u0007 esc\u001B', point: redSquare),
          SavedPlace(
            name: 'lone surrogate ${String.fromCharCode(0xD83D)}!',
            point: redSquare,
          ),
          SavedPlace(name: 'non-char ￾￿', point: redSquare),
        ],
        routes: routes,
        name: hostileNames.join(' '),
        time: now,
      );
      expect(File('${file.path}.tmp').existsSync(), isFalse);
      final text = file.readAsStringSync(); // strict UTF-8 decoding
      final r = importGpx(text);
      expect(r.error, isNull);
      expect(r.places, hasLength(places.length + 3));
      expect(r.places[places.length].name, 'nul bell esc');
      expect(r.places[places.length + 1].name, 'lone surrogate !');
      expect(r.places[places.length + 2].name, 'non-char');
      expect(r.routes, routes);

      final ProcessResult lint;
      try {
        lint = Process.runSync('xmllint', ['--noout', '--nonet', file.path]);
      } on ProcessException {
        markTestSkipped('xmllint is not installed');
        return;
      }
      expect(lint.exitCode, 0, reason: '${lint.stderr}');
    });

    test('names are trimmed on the way out, like the importer does', () {
      final r = importGpx(
        exportGpx(
          places: [SavedPlace(name: '  A  ', point: redSquare, address: ' ')],
        ),
      );
      expect(r.places.single.name, 'A');
      expect(r.places.single.address, isNull);
    });

    test('file round trip off the UI thread', () async {
      final dir = Directory.systemTemp.createTempSync('mapsoly-gpx-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/routes.gpx');
      writeGpxFile(file, places: places, routes: routes);
      final r = await importGpxFile(file);
      expect(r.error, isNull);
      expect(r.places, places);
      expect(r.routes, routes);
    });
  });

  group('foreign files', () {
    test('OSM tool, track only -> a route along the track', () {
      final r = importGpx(osmTrackOnly, now: now);
      expect(r.error, isNull);
      expect(r.skipped, isEmpty);
      expect(r.places, isEmpty);
      final route = r.routes.single;
      expect(route.name, '2026-11-20_08-15_Fri');
      expect(route.points, const [
        RoutePoint(LatLng(52.5163, 13.3777)),
        RoutePoint(LatLng(52.5145, 13.3501)),
      ]);
      // Both segments, in order.
      expect(route.geometry, hasLength(5));
      expect(route.geometry![3], const LatLng(52.5150, 13.3640));
      expect(route.costing, RouteCosting.auto);
      expect(route.created, DateTime.utc(2026, 11, 20, 5, 15, 7));
      expect(route.lengthMeters, closeTo(1880, 30));
      expect(route.id, isNotEmpty);
    });

    test('waypoint list -> favourites; bad points listed', () {
      final r = importGpx(waypointList, now: now);
      expect(r.error, isNull);
      expect(r.routes, isEmpty);
      expect(r.places.map((p) => p.name), [
        'Tour Eiffel & Champ-de-Mars',
        'Дворцовая <площадь> & "колонна"',
        'Точка 3',
        'Café 😀 "Tor"',
      ]);
      // <type>home</type> of a foreign file does not make a home.
      expect(
        r.places.map((p) => p.kind),
        everyElement(SavedPlaceKind.favorite),
      );
      expect(r.places[0].point, eiffelTower);
      expect(r.places[0].address, 'comment only');
      expect(r.places[1].point, palaceSquare);
      expect(r.places[1].address, 'Санкт-Петербург, Дворцовая пл.');
      expect(r.places[2].point, redSquare);
      expect(r.places[3].address, isNull);
      expect(r.places.map((p) => p.id).toSet(), hasLength(4));
      expect(r.skipped.single.reason, 'Точка без корректных координат');
      expect(r.skipped.single.count, 3);
      expect('${r.skipped.single}', contains('3'));
    });

    test('prefixed elements, Garmin extensions', () {
      final r = importGpx(prefixedRoute, now: now);
      expect(r.error, isNull);
      final route = r.routes.single;
      expect(route.name, 'Berlin → Paris');
      expect(route.costing, RouteCosting.bicycle);
      expect(route.points, const [
        RoutePoint(brandenburgGate, label: 'Brandenburger Tor'),
        RoutePoint(LatLng(50.9413, 6.9583)),
        RoutePoint(eiffelTower, label: 'Tour Eiffel'),
      ]);
      expect(route.geometry, isNull);
      expect(route.lengthMeters, isNull);
      expect(route.created, now);
      expect(
        {for (final s in r.skipped) s.reason: s.count},
        {
          'Точка маршрута без корректных координат': 1,
          'Маршрут, в котором меньше двух точек': 1,
        },
      );
    });

    test('GPX 1.0 with the same trip as route and track', () {
      final r = importGpx(routerGpx10, now: now);
      expect(r.error, isNull);
      expect(r.routes, hasLength(2));
      final walk = r.routes[0];
      // The unnamed route of a multi-route file gets a dated default name.
      expect(walk.name, 'Маршрут 09.09.2026');
      expect(walk.points.map((p) => p.label), ['Notre-Dame', 'Tour Eiffel']);
      // The matching track became its line, not a second route.
      expect(walk.geometry, hasLength(3));
      expect(walk.lengthMeters, closeTo(4120, 80));
      expect(walk.created, DateTime.utc(2026, 9, 9, 9, 9, 9));
      final other = r.routes[1];
      expect(other.name, 'Somewhere else');
      expect(other.points.first.point, palaceSquare);
      expect(other.geometry, hasLength(2));
    });

    test('track types map to costing', () {
      String trk(String type) =>
          '<gpx><trk><type>$type</type><trkseg><trkpt lat="1" lon="1"/>'
          '<trkpt lat="1.1" lon="1"/></trkseg></trk></gpx>';
      RouteCosting of(String type) =>
          importGpx(trk(type)).routes.single.costing;
      expect(of('cycling'), RouteCosting.bicycle);
      expect(of('Mountain Biking'), RouteCosting.bicycle);
      expect(of('hiking'), RouteCosting.pedestrian);
      expect(of('running'), RouteCosting.pedestrian);
      expect(of('pedestrian'), RouteCosting.pedestrian);
      expect(of('driving'), RouteCosting.auto);
      expect(of(''), RouteCosting.auto);
    });

    test('our extension names in a foreign namespace mean nothing', () {
      final r = importGpx(
        '<gpx xmlns:x="urn:someone:else"><wpt lat="1" lon="2"><name>n</name>'
        '<extensions><x:id>stolen</x:id><x:kind>home</x:kind>'
        '<id>plain</id><kind>work</kind></extensions></wpt></gpx>',
      );
      expect(r.places.single.kind, SavedPlaceKind.favorite);
      expect(r.places.single.id, isNot(anyOf('stolen', 'plain')));
    });

    test('our namespace under another prefix is still ours', () {
      final r = importGpx(
        '<gpx><wpt lat="1" lon="2"><extensions xmlns:m="$mapsolyGpxNamespace">'
        '<m:id>abc</m:id><m:kind>work</m:kind></extensions></wpt></gpx>',
      );
      expect(r.places.single.kind, SavedPlaceKind.work);
      expect(r.places.single.id, 'abc');
      expect(r.places.single.name, 'Точка 1');
    });
  });

  group('hostile input', () {
    test('decimal commas are not coordinates', () {
      final r = importGpx(
        '<gpx><trk><trkseg>'
        '<trkpt lat="55,7539" lon="37,6208"/><trkpt lat="55,7540" lon="37,6210"/>'
        '<trkpt lat="55.7541" lon="37.6212"/>'
        '</trkseg></trk></gpx>',
      );
      expect(r.ok, isTrue);
      expect(r.isEmpty, isTrue);
      expect(
        {for (final s in r.skipped) s.reason: s.count},
        {
          'Точка трека без корректных координат': 2,
          'Трек, в котором меньше двух точек': 1,
        },
      );
    });

    test('other non-numbers are not coordinates either', () {
      for (final bad in [
        'NaN',
        'Infinity',
        '',
        ' ',
        '1e999',
        '0x10',
        '5 5',
        '--1',
        '1.2.3',
        '١٢',
      ]) {
        final r = importGpx('<gpx><wpt lat="$bad" lon="1"/></gpx>');
        expect(r.places, isEmpty, reason: bad);
        expect(r.skipped.single.count, 1, reason: bad);
      }
      for (final (ok, value) in [
        ('+1.5', 1.5),
        ('-.5', -0.5),
        ('1.', 1.0),
        (' 2 ', 2.0),
        ('1.5E1', 15.0),
      ]) {
        final r = importGpx('<gpx><wpt lat="$ok" lon="1"/></gpx>');
        expect(r.places.single.point.latitude, value, reason: ok);
      }
    });

    test('entity expansion is impossible: DOCTYPE is refused', () {
      const bomb = '''<?xml version="1.0"?>
<!DOCTYPE lolz [
 <!ENTITY lol "lol">
 <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
 <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
 <!ENTITY xxe SYSTEM "file:///etc/passwd">
]>
<gpx><wpt lat="1" lon="1"><name>&lol3; &xxe;</name></wpt></gpx>''';
      final r = importGpx(bomb);
      expect(r.error, contains('DOCTYPE'));
      expect(r.isEmpty, isTrue);
    });

    test('undeclared entities stay text, references are bounded', () {
      final r = importGpx(
        '<gpx><wpt lat="1" lon="1"><name>&xxe; &lol; &#65;&#x42; &#0; '
        '&#xD800; &#99999999999; & alone &amp;amp;</name></wpt></gpx>',
      );
      expect(
        r.places.single.name,
        '&xxe; &lol; AB � � &#99999999999; & alone &amp;',
      );
    });

    test('size cap', () {
      final big = '<gpx>${' ' * 2000}</gpx>';
      expect(
        importGpx(big, limits: const GpxLimits(maxBytes: 1000)).error,
        'Файл слишком большой',
      );
      expect(
        importGpx(big, limits: const GpxLimits(maxBytes: 3000)).ok,
        isTrue,
      );
      expect(
        importGpxBytes(Uint8List(21 * 1024 * 1024)).error,
        'Файл слишком большой',
      );
    });

    test('point cap, counted over all kinds of points', () {
      final b = StringBuffer('<gpx><wpt lat="1" lon="1"/><trk><trkseg>');
      for (var i = 0; i < 1000; i++) {
        b.write('<trkpt lat="1.${i + 1000}" lon="1"/>');
      }
      b.write('</trkseg></trk></gpx>');
      var r = importGpx('$b', limits: const GpxLimits(maxPoints: 1000));
      expect(r.error, contains('слишком много точек'));
      expect(r.isEmpty, isTrue);
      r = importGpx('$b', limits: const GpxLimits(maxPoints: 1001));
      expect(r.ok, isTrue);
      expect(r.routes.single.geometry, hasLength(1000));
    });

    test(
      'the default limits take a 200 000 point track in reasonable time',
      () {
        final b = StringBuffer('<gpx><trk><trkseg>\n');
        for (var i = 0; i < 200000; i++) {
          b.writeln(
            '<trkpt lat="${48 + i * 1e-5}" lon="2.5"><ele>1</ele>'
            '<time>2026-01-01T00:00:00Z</time></trkpt>',
          );
        }
        b.write('</trkseg></trk></gpx>');
        final watch = Stopwatch()..start();
        final r = importGpx('$b');
        expect(r.error, isNull);
        expect(r.routes.single.geometry, hasLength(200000));
        expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
        expect(
          importGpx(
            '$b'.replaceFirst('<trk>', '<wpt lat="1" lon="1"/><trk>'),
          ).error,
          isNotNull,
        );
      },
    );

    test('nesting cap', () {
      final deep = '<gpx>${'<a>' * 500}${'</a>' * 500}</gpx>';
      expect(importGpx(deep).error, contains('вложенность'));
      final fine = '<gpx>${'<a>' * 50}${'</a>' * 50}</gpx>';
      expect(importGpx(fine).ok, isTrue);
    });

    test('long names are cut, never in the middle of a character', () {
      final r = importGpx(
        '<gpx><wpt lat="1" lon="1"><name>${'я' * 499}😀${'x' * 5000}</name>'
        '</wpt></gpx>',
      );
      final name = r.places.single.name;
      expect(name.length, 499);
      expect(name.runes.last, 'я'.runes.single);
    });

    for (final (what, input) in [
      ('empty', ''),
      ('whitespace', '  \n '),
      ('plain text', 'lat,lon\n55.75,37.62\n'),
      ('json', '{"type":"FeatureCollection"}'),
      ('binary', '\u0000\u0001\u0002PK\u0003\u0004'),
    ]) {
      test('not XML at all ($what)', () {
        final r = importGpx(input);
        expect(r.error, 'Это не GPX-файл');
        expect(r.isEmpty, isTrue);
      });
    }

    test('XML that is not GPX', () {
      for (final other in [
        '<kml xmlns="http://www.opengis.net/kml/2.2"><Document/></kml>',
        '<html><body><gpx><wpt lat="1" lon="1"/></gpx></body></html>',
        '<osm version="0.6"><node id="1" lat="1" lon="1"/></osm>',
      ]) {
        expect(importGpx(other).error, 'Это не GPX-файл', reason: other);
      }
    });

    for (final (what, input) in [
      ('truncated in a tag', '<gpx><wpt lat="1" lon="1"><na'),
      ('truncated in an attribute', '<gpx><wpt lat="1'),
      ('truncated after a point', '<gpx><trk><trkseg><trkpt lat="1" lon="1"/>'),
      ('unclosed comment', '<gpx><!-- <wpt lat="1" lon="1"/></gpx>'),
      ('unclosed CDATA', '<gpx><name><![CDATA[x</name></gpx>'),
      ('unclosed PI', '<?xml version="1.0"<gpx></gpx>'),
      ('mismatched end tag', '<gpx><wpt lat="1" lon="1"></rte></gpx>'),
      ('stray end tag', '<gpx></gpx></gpx>'),
      ('two roots', '<gpx></gpx><gpx></gpx>'),
      ('unquoted attribute', '<gpx><wpt lat=1 lon=1/></gpx>'),
      ('attribute without value', '<gpx><wpt lat lon="1"/></gpx>'),
      ('tag inside a tag', '<gpx><wpt <b> lat="1"/></gpx>'),
      ('"<" in an attribute', '<gpx><wpt lat="<1" lon="1"/></gpx>'),
      ('empty tag name', '<gpx>< /></gpx>'),
      ('empty end tag', '<gpx></></gpx>'),
      ('bad self-closing', '<gpx><wpt lat="1" lon="1"/ ></gpx>'),
    ]) {
      test('malformed: $what', () {
        final r = importGpx(input);
        expect(r.error, isNotNull);
        expect(r.error, contains('XML'));
        expect(r.isEmpty, isTrue);
      });
    }

    test('never throws on mangled copies of a real file', () {
      // Cut the file at every position and flip characters around: the
      // importer must answer with a result each time.
      for (final source in [waypointList, prefixedRoute, osmTrackOnly]) {
        for (var cut = 0; cut < source.length; cut += 7) {
          importGpx(source.substring(0, cut));
          importGpx(source.substring(cut));
          importGpx(
            source.replaceRange(
              cut,
              cut + 1,
              const ['<', '>', '&', '"'][cut % 4],
            ),
          );
        }
      }
    });

    test('comments, processing instructions and a BOM are skipped', () {
      final r = importGpx(
        '﻿<?xml version="1.0"?><!-- a --><?style x?>\n<gpx><!-- <wpt lat="9" '
        'lon="9"/> --><wpt lat="1" lon="2"><!-- c --><name>A<!-- no -->'
        '</name></wpt></gpx><!-- tail -->\n',
      );
      expect(r.error, isNull);
      expect(r.places.single.point, const LatLng(1, 2));
    });

    test('attribute quoting and spacing variants', () {
      final r = importGpx(
        "<gpx>\n<wpt\n\tlat = '59.9390'\r\n lon=\"30.3158\"\n>"
        "<name >A</name ></wpt><wpt lat='1' lon='2' /></gpx>",
      );
      expect(r.error, isNull);
      expect(r.places.first.point, palaceSquare);
      expect(r.places.first.name, 'A');
      expect(r.places.last.point, const LatLng(1, 2));
    });

    test('points outside their container are ignored', () {
      final r = importGpx(
        '<gpx><trkpt lat="1" lon="1"/><rtept lat="1" lon="1"/>'
        '<metadata><wpt lat="1" lon="1"/></metadata>'
        '<trk><trkpt lat="1" lon="1"/><trkpt lat="2" lon="1"/></trk>'
        '<rte><rte><rtept lat="1" lon="1"/></rte></rte></gpx>',
      );
      expect(r.error, isNull);
      expect(r.places, isEmpty);
      expect(r.routes, isEmpty);
    });
  });

  group('files', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('mapsoly-gpx-'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('missing file', () async {
      final r = await importGpxFile(File('${dir.path}/nope.gpx'));
      expect(r.error, 'Файл не удалось прочитать');
    });

    test('too large a file is refused before it is read', () async {
      final file = File('${dir.path}/big.gpx')
        ..writeAsStringSync('<gpx>${' ' * 5000}</gpx>');
      final r = await importGpxFile(
        file,
        limits: const GpxLimits(maxBytes: 4096),
      );
      expect(r.error, 'Файл слишком большой');
    });

    test(
      'Latin-1 when declared, UTF-16 refused, other encodings refused',
      () async {
        const body = '<gpx><wpt lat="1" lon="2"><name>Café</name></wpt></gpx>';
        final latin = File('${dir.path}/latin.gpx')
          ..writeAsBytesSync(
            latin1.encode('<?xml version="1.0" encoding="ISO-8859-1"?>$body'),
          );
        expect((await importGpxFile(latin)).places.single.name, 'Café');

        final utf16 = File('${dir.path}/utf16.gpx')
          ..writeAsBytesSync([
            0xFF, 0xFE, //
            for (final c in body.codeUnits) ...[c & 0xFF, c >> 8],
          ]);
        expect((await importGpxFile(utf16)).error, contains('кодировка'));

        final cp1251 = File('${dir.path}/cp1251.gpx')
          ..writeAsBytesSync(
            latin1.encode('<?xml version="1.0" encoding="windows-1251"?>$body'),
          );
        expect((await importGpxFile(cp1251)).error, contains('кодировка'));
      },
    );

    test('invalid UTF-8 does not throw', () async {
      final file = File('${dir.path}/bad.gpx')
        ..writeAsBytesSync([
          ...utf8.encode('<gpx><wpt lat="1" lon="2"><name>a'),
          0xFF, 0xC3, 0x28, //
          ...utf8.encode('b</name></wpt></gpx>'),
        ]);
      final r = await importGpxFile(file);
      expect(r.error, isNull);
      expect(r.places.single.name, startsWith('a'));
    });
  });
}
