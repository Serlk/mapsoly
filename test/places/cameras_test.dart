import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/places/cameras.dart';
import 'package:mapsoly/places/geo.dart';
import 'package:mapsoly/places/places_database.dart';
import 'package:mapsoly/places/user_cameras.dart';

import 'fixture.dart';

// A route going due north along lon 20.5 from lat 54.70 to 54.75 (≈5.56 km),
// then due east along lat 54.75 to lon 20.56 (≈3.85 km).
final _route = <LatLng>[
  for (var i = 0; i <= 50; i++) LatLng(54.70 + i * 0.001, 20.5),
  for (var i = 1; i <= 60; i++) LatLng(54.75, 20.5 + i * 0.001),
];

void main() {
  group('SpeedCamera.appliesTo', () {
    SpeedCamera cam({int? bearing, bool bidir = false}) => SpeedCamera(
      id: 1,
      source: CameraSource.pack,
      type: CameraType.speed,
      rawType: 'maxspeed',
      point: const LatLng(0, 0),
      bearing: bearing,
      bidirectional: bidir,
    );

    test('unknown direction applies to everyone', () {
      expect(cam().appliesTo(123), isTrue);
    });

    test('one direction with tolerance, across north', () {
      final c = cam(bearing: 350);
      expect(c.appliesTo(350), isTrue);
      expect(c.appliesTo(20), isTrue); // 30° off, through 0
      expect(c.appliesTo(300), isTrue); // 50° off
      expect(c.appliesTo(290), isFalse);
      expect(c.appliesTo(170), isFalse); // oncoming traffic
      expect(c.appliesTo(80), isFalse); // crossing road
    });

    test('bidirectional axis', () {
      final c = cam(bearing: 90, bidir: true);
      expect(c.appliesTo(90), isTrue);
      expect(c.appliesTo(270), isTrue);
      expect(c.appliesTo(250), isTrue);
      expect(c.appliesTo(0), isFalse);
      expect(c.appliesTo(180), isFalse);
    });

    test('type codes', () {
      expect(CameraType.fromCode('maxspeed'), CameraType.speed);
      expect(CameraType.fromCode('road_marking;maxspeed'), CameraType.speed);
      expect(CameraType.fromCode('average_speed'), CameraType.averageSpeed);
      expect(CameraType.fromCode('access;road_marking'), CameraType.busLane);
      expect(CameraType.fromCode('maxweight'), CameraType.other);
    });
  });

  group('pack cameras', () {
    late PlacesDatabase db;
    late String path;

    setUpAll(() {
      path = buildFixture(
        const [],
        extra: (d) {
          // 1: on the northbound leg, for northbound traffic.
          addCamera(d, 1, 54.720, 20.5001, bearing: 0, maxspeed: 60);
          // 2: same road, southbound only → must not match.
          addCamera(d, 2, 54.730, 20.4999, bearing: 180, maxspeed: 60);
          // 3: two-way axis north–south → matches.
          addCamera(d, 3, 54.740, 20.5, bearing: 0, bidir: true);
          // 4: on a crossing east–west street right at the route → no match.
          addCamera(d, 4, 54.710, 20.5, bearing: 90, bidir: true);
          // 5: unknown direction, 20 m east of the route → matches.
          addCamera(d, 5, 54.715, 20.5003);
          // 6: unknown direction but 200 m away → outside the corridor.
          addCamera(d, 6, 54.716, 20.5031);
          // 7: on the eastbound leg, eastbound.
          addCamera(d, 7, 54.7501, 20.53, bearing: 92, type: 'traffic_signals');
          // 8: average-speed section along the eastbound leg.
          addCamera(
            d,
            8,
            54.75,
            20.54,
            bearing: 90,
            type: 'average_speed',
            maxspeed: 90,
            endLat: 54.75,
            endLon: 20.555,
          );
          // 9: average-speed section whose end is off the route.
          addCamera(
            d,
            9,
            54.75,
            20.51,
            bearing: 90,
            type: 'average_speed',
            endLat: 54.80,
            endLon: 20.51,
          );
        },
      );
      db = PlacesDatabase.open(path);
    });
    tearDownAll(() {
      db.close();
      File(path).parent.deleteSync(recursive: true);
    });

    test('camerasAlong keeps cameras for the direction of travel', () {
      final res = db.camerasAlong(_route);
      expect(res.map((c) => c.camera.id), [5, 1, 3, 9, 7, 8]);
      final byId = {for (final c in res) c.camera.id: c};
      // 54.70 → 54.72 is 0.02° of latitude ≈ 2224 m.
      expect(byId[1]!.alongM, closeTo(2224, 5));
      expect(byId[1]!.lateralM, closeTo(6.4, 1.5));
      expect(byId[5]!.lateralM, closeTo(19.3, 2));
      // The corner is 5560 m in; camera 7 is 0.03° of longitude further.
      final legEast = distanceM(
        const LatLng(54.75, 20.5),
        const LatLng(54.75, 20.53),
      );
      expect(byId[7]!.alongM, closeTo(5560 + legEast, 8));
      expect(byId[7]!.camera.type, CameraType.trafficSignals);
    });

    test('reverse route sees the opposite set', () {
      final res = db.camerasAlong(_route.reversed.toList());
      expect(res.map((c) => c.camera.id).toSet(), {2, 3, 5});
    });

    test('average-speed section end is located along the route', () {
      final res = db.camerasAlong(_route);
      final zone = res.firstWhere((c) => c.camera.id == 8);
      expect(zone.camera.type, CameraType.averageSpeed);
      expect(zone.zoneEndAlongM, isNotNull);
      final len = distanceM(
        const LatLng(54.75, 20.54),
        const LatLng(54.75, 20.555),
      );
      expect(zone.zoneEndAlongM! - zone.alongM, closeTo(len, 5));
      // Section 9 ends off the route.
      expect(res.firstWhere((c) => c.camera.id == 9).zoneEndAlongM, isNull);
    });

    test('corridor width is respected', () {
      final wide = db.camerasAlong(_route, corridorM: 250);
      expect(wide.map((c) => c.camera.id), contains(6));
    });

    test('camerasNear filters by radius and course', () {
      const p = LatLng(54.719, 20.5);
      final all = db.camerasNear(p, 1500);
      expect(all.map((c) => c.camera.id), [1, 6, 5, 4, 2]);
      expect(all.first.distanceM, closeTo(111, 3));
      expect(all.first.bearingTo, closeTo(3, 3));
      final north = db.camerasNear(p, 1500, courseDeg: 0);
      expect(north.map((c) => c.camera.id), [1, 6, 5]);
      expect(db.camerasNear(p, 50), isEmpty);
      expect(db.cameras.count, 9);
    });

    test('degenerate routes', () {
      expect(db.camerasAlong(const []), isEmpty);
      expect(db.camerasAlong(const [LatLng(54.72, 20.5)]), isEmpty);
      expect(
        db.camerasAlong(const [LatLng(54.72, 20.5), LatLng(54.72, 20.5)]),
        isEmpty,
      );
    });
  });

  group('user camera import', () {
    late UserCameraDatabase user;
    setUp(() => user = UserCameraDatabase.inMemory());
    tearDown(() => user.close());

    test('plain CSV with header', () {
      final r = user.importText('''
lat,lon,type,speed,direction
54.720,20.5001,speed,60,0
54.730,20.4999,average,90,180
54.740,20.5,redlight,,
bad,line,here
91.0,20.5,speed,60,0
''');
      expect(r.format, CameraFileFormat.csv);
      expect(r.imported, 3);
      expect(r.skipped, 2);
      expect(r.errors, hasLength(2));
      final near = user.cameras.near(const LatLng(54.72, 20.5), 5000);
      expect(near, hasLength(3));
      final c = near.first.camera;
      expect(c.source, CameraSource.user);
      expect(c.type, CameraType.speed);
      expect(c.maxSpeedKmh, 60);
      expect(c.bearing, 0);
      expect(c.key, startsWith('user:'));
      final red = near
          .map((n) => n.camera)
          .firstWhere((c) => c.type == CameraType.trafficSignals);
      expect(red.bearing, isNull);
      expect(red.maxSpeedKmh, isNull);
    });

    test('plain CSV without header, semicolons', () {
      final r = user.importText('54.72;20.5;speed;40;270\n54.73;20.5;;;\n');
      expect(r.format, CameraFileFormat.csv);
      expect(r.imported, 2);
      expect(
        user.cameras.near(const LatLng(54.72, 20.5), 10).first.camera.bearing,
        270,
      );
    });

    test('SpeedCam txt: X is longitude, DirType controls direction', () {
      final r = user.importText('''
X,Y,TYPE,SPEED,DirType,Direction
20.5001,54.720,1,60,1,0
20.4999,54.730,4,90,2,90
20.5000,54.740,3,0,0,0
20.5000,54.745,99,50,1,400
''');
      expect(r.format, CameraFileFormat.speedCam);
      expect(r.imported, 4);
      final cams = [
        for (final n in user.cameras.near(const LatLng(54.72, 20.5), 5000))
          n.camera,
      ];
      expect(cams[0].point.latitude, closeTo(54.72, 1e-9));
      expect(cams[0].point.longitude, closeTo(20.5001, 1e-9));
      expect(cams[0].type, CameraType.speed);
      expect(cams[0].bearing, 0);
      expect(cams[0].bidirectional, isFalse);
      expect(cams[1].type, CameraType.averageSpeed);
      expect(cams[1].bidirectional, isTrue);
      expect(cams[1].maxSpeedKmh, 90);
      expect(cams[2].type, CameraType.trafficSignals);
      expect(cams[2].bearing, isNull); // DirType 0: all directions
      expect(cams[2].maxSpeedKmh, isNull); // speed 0 = unknown
      expect(cams[3].type, CameraType.other);
      expect(cams[3].bearing, 40); // 400° wraps
    });

    test('SpeedCam txt with a leading IDX column', () {
      final r = user.importText(
        'IDX,X,Y,TYPE,SPEED,DIRTYPE,DIRECTION\n1,20.5,54.72,1,60,1,180\n',
      );
      expect(r.format, CameraFileFormat.speedCam);
      expect(r.imported, 1);
      final c = user.cameras.near(const LatLng(54.72, 20.5), 10).single.camera;
      expect(c.bearing, 180);
      expect(c.maxSpeedKmh, 60);
    });

    test('re-import skips duplicates; clear empties', () {
      const text = 'lat,lon,type,speed,direction\n54.72,20.5,speed,60,0\n';
      expect(user.importText(text).imported, 1);
      final again = user.importText(text);
      expect(again.imported, 0);
      expect(again.skipped, 1);
      expect(user.count, 1);
      expect(user.clear(), 1);
      expect(user.count, 0);
      expect(user.cameras.near(const LatLng(54.72, 20.5), 100), isEmpty);
    });

    test('user cameras match routes and merge with pack cameras', () {
      user.importText(
        'lat,lon,type,speed,direction\n'
        '54.7200,20.5001,speed,60,0\n54.7300,20.5,speed,40,0\n',
      );
      final mine = user.cameras.along(_route);
      expect(mine, hasLength(2));
      final pack = [
        RouteCamera(
          camera: const SpeedCamera(
            id: 1,
            source: CameraSource.pack,
            type: CameraType.speed,
            rawType: 'maxspeed',
            point: LatLng(54.72, 20.5001),
          ),
          alongM: mine.first.alongM + 10,
          lateralM: 5,
        ),
      ];
      final merged = mergeRouteCameras([pack, mine]);
      expect(merged, hasLength(2));
      expect(merged.first.camera.source, CameraSource.pack);
      expect(merged.last.camera.source, CameraSource.user);
    });

    test('empty and garbage files', () {
      expect(user.importText('').imported, 0);
      expect(user.importText('hello world\nfoo,bar\n').imported, 0);
    });
  });
}
