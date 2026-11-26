import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/places/normalize.dart';

void main() {
  // The same vectors are checked against the Python implementation:
  //   python tool/places/ru_normalize.py test/places/normalize_cases.json
  final cases =
      jsonDecode(File('test/places/normalize_cases.json').readAsStringSync())
          as Map<String, dynamic>;

  test('text normalisation matches the shared vectors', () {
    for (final c in (cases['text'] as List).cast<List>()) {
      expect(normalizeText(c[0] as String), c[1], reason: 'input "${c[0]}"');
    }
  });

  test('house number normalisation matches the shared vectors', () {
    for (final c in (cases['house'] as List).cast<List>()) {
      expect(
        normalizeHouseNumber(c[0] as String),
        c[1],
        reason: 'input "${c[0]}"',
      );
    }
  });

  test('case, ё and abbreviations fold to the same form', () {
    expect(normalizeText('УЛ. ОЗЁРНАЯ'), normalizeText('улица озерная'));
    expect(normalizeText('Ленинский пр-т'), normalizeText('ленинский просп.'));
    expect(normalizeText('пр-кт Мира'), normalizeText('проспект мира'));
    expect(normalizeText('Тверской б-р'), 'тверской бульвар');
    expect(normalizeText('наб. Тараса Шевченко'), 'набережная тараса шевченко');
  });

  test('fast and general paths agree', () {
    // The hyphen forces the general (regex) path; the rest is identical.
    expect(
      normalizeTokens('Улица Ёлочная - 5'),
      normalizeTokens('Улица Ёлочная 5'),
    );
    expect(normalizeTokens('ул.Мира,д.3'), ['улица', 'мира', 'дом', '3']);
    expect(normalizeTokens('3я Парковая'), ['3', 'парковая']);
    expect(normalizeTokens('дом 5а'), ['дом', '5а']);
  });

  test('displayHouseNumber', () {
    expect(displayHouseNumber('12к1с2'), '12 к1 с2');
    expect(displayHouseNumber('5а'), '5А');
    expect(displayHouseNumber('12/14'), '12/14');
    expect(displayHouseNumber('7'), '7');
    expect(displayHouseNumber('30ак2'), '30А к2');
  });

  group('parseQuery', () {
    QueryReading house(String q) =>
        parseQuery(q).firstWhere((r) => r.house != null);

    test('plain text reading comes first', () {
      final r = parseQuery('ленина');
      expect(r, hasLength(1));
      expect(r.first.tokens, ['ленина']);
      expect(r.first.house, isNull);
      expect(r.first.lastIsPrefix, isTrue);
      expect(parseQuery('ленина ').first.lastIsPrefix, isFalse);
    });

    test('house number in any position', () {
      for (final q in [
        'ленина 5',
        '5 ленина',
        'ул. Ленина, 5',
        'улица Ленина д.5',
      ]) {
        final r = house(q);
        expect(r.house, '5', reason: q);
        expect(r.tokens.where((t) => t != 'улица'), ['ленина'], reason: q);
      }
    });

    test('building and letter suffixes', () {
      expect(house('ленина 5 к2').house, '5к2');
      expect(house('ленина 5 корпус 2 стр 1').house, '5к2с1');
      expect(house('ленина 5к2').house, '5к2');
      expect(house('ленина 5 а').house, '5а');
      expect(house('ленина 5а').house, '5а');
      expect(house('ленина 12/14').house, '12/14');
      expect(house('ленина д. 5 с 1').house, '5с1');
    });

    test('numeric street names give both readings', () {
      final rs = parseQuery('9 мая 12');
      final houses = rs.where((r) => r.house != null).toList();
      expect(houses.map((r) => r.house), containsAll(['12', '9']));
      final r12 = houses.firstWhere((r) => r.house == '12');
      expect(r12.tokens, ['9', 'мая']);
    });

    test('prefix flags', () {
      final a = house('ленина 5');
      expect(a.houseIsPrefix, isTrue);
      expect(a.lastIsPrefix, isFalse);
      final b = house('5 лени');
      expect(b.houseIsPrefix, isFalse);
      expect(b.lastIsPrefix, isTrue);
      final c = house('ленина 5 ');
      expect(c.houseIsPrefix, isFalse);
    });

    test('half-typed abbreviation keeps its raw form', () {
      final r = parseQuery('ленина п').first;
      expect(r.tokens.last, 'поселок');
      expect(r.lastRaw, 'п');
      expect(parseQuery('ленина п ').first.lastRaw, isNull);
    });

    test('a lone number is not a house', () {
      expect(parseQuery('5'), hasLength(1));
    });
  });
}
