import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/user/json_store.dart';
import 'package:mapsoly/user/user_places.dart';

// Public landmarks only.
const palaceSquare = LatLng(59.9390, 30.3158);
const redSquare = LatLng(55.7539, 37.6208);
const brandenburgGate = LatLng(52.5163, 13.3777);

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('mapsoly-user-'));
  tearDown(() => dir.deleteSync(recursive: true));

  File file() => File('${dir.path}/places.json');

  test('ids are unique', () {
    final ids = {for (var i = 0; i < 2000; i++) newUserId()};
    expect(ids, hasLength(2000));
  });

  test('missing file: empty store, nothing written until a change', () {
    final store = UserPlaces.load(Directory('${dir.path}/not/there/yet'));
    expect(store.places, isEmpty);
    expect(store.home, isNull);
    expect(store.loadError, isNull);
    expect(Directory('${dir.path}/not').existsSync(), isFalse);
    store.save(SavedPlace(name: 'A', point: redSquare));
    expect(File('${dir.path}/not/there/yet/places.json').existsSync(), isTrue);
  });

  test('round trip through the file, sorted home, work, favourites', () {
    final store = UserPlaces.load(dir);
    var notified = 0;
    store.addListener(() => notified++);
    final cafe = store.save(SavedPlace(name: 'кафе', point: brandenburgGate));
    store.save(SavedPlace(name: 'Аптека', point: redSquare, address: 'ул. 1'));
    final work = store.save(
      SavedPlace(name: '', kind: SavedPlaceKind.work, point: redSquare),
    );
    final home = store.save(
      SavedPlace(
        name: '  Дача  ',
        kind: SavedPlaceKind.home,
        point: palaceSquare,
      ),
    );
    expect(notified, 4);
    expect(work.name, 'Работа'); // default for an empty name
    expect(home.name, 'Дача'); // trimmed
    expect(store.places.map((p) => p.name), [
      'Дача',
      'Работа',
      'Аптека',
      'кафе',
    ]);
    expect(store.home, home);
    expect(store.work, work);
    expect(store.favorites, hasLength(2));
    expect(store.byId(cafe.id), cafe);
    expect(File('${file().path}.tmp').existsSync(), isFalse);

    final again = UserPlaces.load(dir);
    expect(again.places, store.places);
    expect(again.loadError, isNull);
    expect(again.places[2].address, 'ул. 1');
  });

  test('at most one home and one work', () {
    final store = UserPlaces.load(dir);
    final old = store.save(
      SavedPlace(name: 'Старый', kind: SavedPlaceKind.home, point: redSquare),
    );
    final fav = store.save(SavedPlace(name: 'Парк', point: brandenburgGate));
    final fresh = store.save(
      SavedPlace(name: 'Новый', kind: SavedPlaceKind.home, point: palaceSquare),
    );
    expect(store.home, fresh);
    expect(store.byId(old.id), isNull);
    expect(store.places, hasLength(2));

    // A favourite promoted to home replaces the home, keeps its id.
    store.save(fav.copyWith(kind: SavedPlaceKind.home));
    expect(store.home!.id, fav.id);
    expect(store.places, hasLength(1));

    // Work is independent of home.
    store.save(
      SavedPlace(name: 'Офис', kind: SavedPlaceKind.work, point: redSquare),
    );
    store.save(
      SavedPlace(name: 'Офис 2', kind: SavedPlaceKind.work, point: redSquare),
    );
    expect(store.work!.name, 'Офис 2');
    expect(store.home!.id, fav.id);
    expect(UserPlaces.load(dir).places, store.places);
  });

  test('save with the same id updates; rename; remove', () {
    final store = UserPlaces.load(dir);
    final p = store.save(SavedPlace(name: 'A', point: redSquare));
    store.save(p.copyWith(point: palaceSquare, address: 'Дворцовая пл.'));
    expect(store.places.single.point, palaceSquare);
    expect(store.rename(p.id, ' B '), isTrue);
    expect(store.places.single.name, 'B');
    expect(store.rename(p.id, '  '), isTrue);
    expect(store.places.single.name, 'Место');
    expect(store.rename('nope', 'x'), isFalse);
    expect(store.remove('nope'), isFalse);
    expect(store.remove(p.id), isTrue);
    expect(UserPlaces.load(dir).places, isEmpty);
  });

  test('invalid coordinates are refused', () {
    final store = UserPlaces.inMemory();
    expect(
      () => store.save(SavedPlace(name: 'x', point: const LatLng(91, 0))),
      throwsArgumentError,
    );
    expect(store.places, isEmpty);
  });

  test('imported home does not displace the existing one', () {
    final store = UserPlaces.inMemory();
    final mine = store.save(
      SavedPlace(name: 'Мой', kind: SavedPlaceKind.home, point: redSquare),
    );
    final n = store.addAll([
      SavedPlace(name: 'Чужой', kind: SavedPlaceKind.home, point: palaceSquare),
      SavedPlace(name: 'Офис', kind: SavedPlaceKind.work, point: palaceSquare),
      mine.copyWith(name: 'Мой дом'), // same id: an update, still home
    ]);
    expect(n, 3);
    expect(store.home!.name, 'Мой дом');
    expect(store.work!.name, 'Офис');
    expect(store.favorites.single.name, 'Чужой');
  });

  for (final (what, content) in [
    ('garbage', 'not json {{{'),
    ('truncated', '{"version":1,"places":[{"id":"a","na'),
    ('wrong shape', '[1,2,3]'),
    ('no list', '{"version":1,"places":"x"}'),
    ('empty', ''),
  ]) {
    test('corrupt file ($what): empty store, .bak kept', () {
      file().writeAsStringSync(content);
      final store = UserPlaces.load(dir);
      expect(store.places, isEmpty);
      expect(store.damaged, isTrue);
      expect(store.loadError, isNotNull);
      expect(File('${file().path}.bak').readAsStringSync(), content);
      // The store works on and replaces the bad file at the next change.
      store.save(SavedPlace(name: 'A', point: redSquare));
      expect(UserPlaces.load(dir).places, hasLength(1));
      expect(File('${file().path}.bak').readAsStringSync(), content);
    });
  }

  test('bad entries are skipped, good ones kept, original backed up', () {
    final content = jsonEncode({
      'version': 1,
      'places': [
        {
          'id': 'a',
          'name': 'Ок',
          'kind': 'home',
          'point': [55.7539, 37.6208],
        },
        {'id': 'b', 'name': 'нет точки'},
        {
          'id': 'c',
          'name': 'плохая точка',
          'point': [555, 37],
        },
        {
          'id': 'd',
          'name': 7,
          'kind': 'mystery',
          'point': [52.5163, 13.3777],
          'address': 5,
        },
        'junk',
        {
          'id': 'e',
          'name': 'второй дом',
          'kind': 'home',
          'point': [59.9390, 30.3158],
        },
      ],
    });
    file().writeAsStringSync(content);
    final store = UserPlaces.load(dir);
    expect(store.places.map((p) => p.id), ['a', 'd']);
    expect(store.places[1].kind, SavedPlaceKind.favorite);
    expect(store.places[1].name, 'Место');
    expect(store.skippedOnLoad, 3);
    expect(store.damaged, isFalse);
    expect(store.loadError, contains('3'));
    expect(File('${file().path}.bak').readAsStringSync(), content);
  });

  test('a failed write keeps the change in memory and reports it', () {
    // The "directory" is a file: nothing can be created inside it.
    final blocker = File('${dir.path}/blocker')..writeAsStringSync('x');
    final store = UserPlaces.load(Directory(blocker.path));
    store.save(SavedPlace(name: 'A', point: redSquare));
    expect(store.places, hasLength(1));
    expect(store.saveError, isNotNull);
  });
}
