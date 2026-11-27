import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/settings.dart';

void main() {
  test('what a user types becomes a catalog address', () {
    expect(
      normalizeCatalogUrl('maps.example.org'),
      'https://maps.example.org/catalog.json',
    );
    expect(
      normalizeCatalogUrl(' https://maps.example.org/ '),
      'https://maps.example.org/catalog.json',
    );
    expect(
      normalizeCatalogUrl('http://192.168.1.5:8080'),
      'http://192.168.1.5:8080/catalog.json',
    );
    expect(
      normalizeCatalogUrl('https://example.org/packs/list.json'),
      'https://example.org/packs/list.json',
    );
  });

  test('things that are not server addresses are rejected', () {
    expect(normalizeCatalogUrl(''), isNull);
    expect(normalizeCatalogUrl('   '), isNull);
    expect(normalizeCatalogUrl('ftp://example.org'), isNull);
    expect(normalizeCatalogUrl('file:///etc/passwd'), isNull);
    expect(normalizeCatalogUrl('https://'), isNull);
  });
}
