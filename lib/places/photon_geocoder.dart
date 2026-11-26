/// Online fallback geocoder: Photon (https://photon.komoot.io), no key.
///
/// Used when no region pack is installed or the offline search finds nothing.
/// Fails soft: any network or format problem yields an empty list.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'geo.dart';
import 'places_database.dart';

class PhotonGeocoder {
  PhotonGeocoder({
    http.Client? client,
    Uri? endpoint,
    this.timeout = const Duration(seconds: 6),
    this.userAgent = 'mapsoly/0.1',
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       endpoint = endpoint ?? Uri.parse('https://photon.komoot.io/api');

  final http.Client _client;
  final bool _ownsClient;
  final Uri endpoint;
  final Duration timeout;
  final String userAgent;

  /// Description of the last failure, null after a successful request.
  String? lastError;

  /// Searches [query]; [near] biases results towards a location.
  /// Never throws; returns an empty list on failure (see [lastError]).
  Future<List<PlaceResult>> search(
    String query, {
    LatLng? near,
    int limit = 10,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    // The public instance supports lang=default|de|en|fr only; "default"
    // returns local (Russian) names, so no lang parameter is sent.
    final uri = endpoint.replace(
      queryParameters: {
        'q': q,
        'limit': '$limit',
        if (near != null) 'lat': near.latitude.toStringAsFixed(5),
        if (near != null) 'lon': near.longitude.toStringAsFixed(5),
      },
    );
    try {
      final resp = await _client
          .get(uri, headers: {'User-Agent': userAgent})
          .timeout(timeout);
      if (resp.statusCode != 200) {
        lastError = 'HTTP ${resp.statusCode}';
        return const [];
      }
      final out = parseResponse(utf8.decode(resp.bodyBytes), near: near);
      lastError = null;
      return out;
    } catch (e) {
      lastError = e.toString();
      return const [];
    }
  }

  /// Parses a Photon GeoJSON response. Throws [FormatException] on garbage.
  static List<PlaceResult> parseResponse(String body, {LatLng? near}) {
    final json = jsonDecode(body);
    if (json is! Map || json['features'] is! List) {
      throw const FormatException('not a Photon response');
    }
    final out = <PlaceResult>[];
    final features = json['features'] as List;
    for (var i = 0; i < features.length; i++) {
      final f = features[i];
      if (f is! Map) continue;
      final geom = f['geometry'];
      final props = f['properties'];
      if (geom is! Map || props is! Map) continue;
      final coords = geom['coordinates'];
      if (coords is! List || coords.length < 2) continue;
      final lon = coords[0], lat = coords[1];
      if (lon is! num || lat is! num) continue;
      String? s(String k) {
        final v = props[k];
        return v is String && v.isNotEmpty ? v : null;
      }

      final type = s('type') ?? '';
      final street = s('street');
      final hn = s('housenumber');
      final address = street == null
          ? null
          : (hn == null ? street : '$street, $hn');
      var name = s('name');
      final ctx = <String>[];
      if (name == null) {
        name = address ?? s('city') ?? s('county') ?? s('state');
        if (name == null) continue;
      } else if (address != null && address != name) {
        ctx.add(address);
      }
      for (final k in const ['city', 'county', 'state', 'country']) {
        final v = s(k);
        if (v != null && v != name && !ctx.contains(v)) ctx.add(v);
      }
      final kind = switch (type) {
        'house' => s('name') == null ? PlaceKind.house : PlaceKind.poi,
        'street' => PlaceKind.street,
        'locality' ||
        'district' ||
        'city' ||
        'county' ||
        'state' ||
        'country' => PlaceKind.locality,
        _ => PlaceKind.poi,
      };
      final point = LatLng(lat.toDouble(), lon.toDouble());
      out.add(
        PlaceResult(
          kind: kind,
          name: name,
          context: ctx.isEmpty ? null : ctx.join(', '),
          point: point,
          category: s('osm_value') ?? type,
          categoryLabel: '',
          score: (features.length - i).toDouble(),
          distanceM: near == null ? null : distanceM(near, point),
          online: true,
        ),
      );
    }
    return out;
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
