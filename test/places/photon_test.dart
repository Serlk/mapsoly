import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:mapsoly/places/photon_geocoder.dart';
import 'package:mapsoly/places/places_database.dart';

// Trimmed from a real response of https://photon.komoot.io/api
// (q=ленинский проспект 5 калининград, 2026-11-26).
const _body = '''
{"type":"FeatureCollection","features":[
{"type":"Feature","properties":{"osm_type":"W","osm_id":117167309,"osm_key":"amenity","osm_value":"bank","type":"house","housenumber":"5","name":"Газпромбанк","street":"Ленинский проспект","district":"Ленинградский район","city":"Калининград","county":"городской округ Калининград","state":"Калининградская область","country":"Россия","postcode":"236007","countrycode":"RU"},"geometry":{"type":"Point","coordinates":[20.5024291,54.7181868]}},
{"type":"Feature","properties":{"osm_type":"W","osm_id":105154972,"osm_key":"building","osm_value":"yes","type":"house","housenumber":"5Г","street":"Ленинский проспект","city":"Калининград","state":"Калининградская область","country":"Россия","countrycode":"RU"},"geometry":{"type":"Point","coordinates":[20.5033517,54.7179233]}},
{"type":"Feature","properties":{"osm_type":"R","osm_id":1,"osm_key":"place","osm_value":"city","type":"city","name":"Калининград","state":"Калининградская область","country":"Россия"},"geometry":{"type":"Point","coordinates":[20.51,54.71]}},
{"type":"Feature","properties":{"type":"street","name":"улица Мира","city":"Гусев"},"geometry":{"type":"Point","coordinates":[22.2,54.59]}},
{"type":"Feature","properties":{"name":"broken"},"geometry":{"type":"Point","coordinates":["x"]}}
]}''';

void main() {
  test('parses a Photon response', () {
    final res = PhotonGeocoder.parseResponse(
      _body,
      near: const LatLng(54.71, 20.51),
    );
    expect(res, hasLength(4));
    expect(res[0].kind, PlaceKind.poi);
    expect(res[0].name, 'Газпромбанк');
    expect(
      res[0].context,
      'Ленинский проспект, 5, Калининград, городской округ Калининград, '
      'Калининградская область, Россия',
    );
    expect(res[0].point.latitude, closeTo(54.7181868, 1e-9));
    expect(res[0].point.longitude, closeTo(20.5024291, 1e-9));
    expect(res[0].online, isTrue);
    expect(res[0].distanceM, closeTo(1035, 30));
    expect(res[1].kind, PlaceKind.house);
    expect(res[1].name, 'Ленинский проспект, 5Г');
    expect(res[1].context, 'Калининград, Калининградская область, Россия');
    expect(res[2].kind, PlaceKind.locality);
    expect(res[3].kind, PlaceKind.street);
    expect(res[0].score, greaterThan(res[1].score)); // server order is kept
  });

  test('sends q, limit, location bias and the neutral User-Agent', () async {
    late http.Request seen;
    final g = PhotonGeocoder(
      client: MockClient((req) async {
        seen = req;
        return http.Response.bytes(
          utf8.encode(_body),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final res = await g.search(
      ' ленина 5 ',
      near: const LatLng(54.71, 20.51),
      limit: 7,
    );
    expect(res, hasLength(4));
    expect(g.lastError, isNull);
    expect(seen.url.host, 'photon.komoot.io');
    expect(seen.url.path, '/api');
    expect(seen.url.queryParameters, {
      'q': 'ленина 5',
      'limit': '7',
      'lat': '54.71000',
      'lon': '20.51000',
    });
    expect(seen.headers['User-Agent'], 'mapsoly/0.1');
  });

  test('fails soft', () async {
    final errors = PhotonGeocoder(
      client: MockClient((_) async => http.Response('nope', 503)),
    );
    expect(await errors.search('ленина'), isEmpty);
    expect(errors.lastError, 'HTTP 503');

    final garbage = PhotonGeocoder(
      client: MockClient((_) async => http.Response('<html>', 200)),
    );
    expect(await garbage.search('ленина'), isEmpty);
    expect(garbage.lastError, isNotNull);

    final offline = PhotonGeocoder(
      client: MockClient((_) async => throw http.ClientException('no route')),
    );
    expect(await offline.search('ленина'), isEmpty);
    expect(offline.lastError, contains('no route'));

    final slow = PhotonGeocoder(
      timeout: const Duration(milliseconds: 20),
      client: MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return http.Response(_body, 200);
      }),
    );
    expect(await slow.search('ленина'), isEmpty);
    expect(slow.lastError, contains('Timeout'));

    var called = false;
    final blank = PhotonGeocoder(
      client: MockClient((_) async {
        called = true;
        return http.Response(_body, 200);
      }),
    );
    expect(await blank.search('   '), isEmpty);
    expect(called, isFalse);
  });
}
