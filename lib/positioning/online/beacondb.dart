/// Client for beaconDB (`https://api.beacondb.net/v1/geolocate`), a public,
/// key-less service speaking the Mozilla Location Service / Ichnaea
/// geolocate protocol.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';

/// A position returned by beaconDB.
class BeaconDbFix {
  const BeaconDbFix(this.lat, this.lon, this.accuracyM);
  final double lat;
  final double lon;
  final double accuracyM;
}

/// Outcome of a request: a [fix], a definite "not found", or an [error].
class BeaconDbResult {
  const BeaconDbResult.found(BeaconDbFix this.fix)
    : notFound = false,
      error = null;
  const BeaconDbResult.notFound() : fix = null, notFound = true, error = null;
  const BeaconDbResult.failed(String this.error) : fix = null, notFound = false;

  final BeaconDbFix? fix;

  /// True when the service answered that it cannot locate the input (404).
  final bool notFound;
  final String? error;
}

String? _radioName(RadioType r) => switch (r) {
  RadioType.gsm => 'gsm',
  RadioType.umts => 'wcdma',
  RadioType.lte => 'lte',
  RadioType.nr => 'nr',
  _ => null,
};

/// Builds the MLS geolocate request body.
///
/// Only radio measurements are sent. `considerIp` is false and the IP
/// fallback is disabled so the service never answers with a GeoIP guess.
/// APs whose SSID opts out (`_nomap`) are not sent; SSIDs are never sent.
Map<String, Object?> buildGeolocateRequest({
  List<WifiObservation> wifi = const [],
  List<CellObservation> cells = const [],
}) {
  final body = <String, Object?>{
    'considerIp': false,
    'fallbacks': {'ipf': false, 'lacf': true},
  };
  final aps = [
    for (final o in wifi)
      if (!o.optedOut)
        <String, Object?>{
          'macAddress': o.bssid,
          if (o.effectiveDbm != null) 'signalStrength': o.effectiveDbm!.round(),
          if (o.frequencyMhz != null) 'frequency': o.frequencyMhz,
          'age': o.age.inMilliseconds,
        },
  ];
  if (aps.isNotEmpty) body['wifiAccessPoints'] = aps;
  final towers = [
    for (final c in cells)
      if (c.hasFullId && _radioName(c.radio) != null)
        <String, Object?>{
          'radioType': _radioName(c.radio),
          'mobileCountryCode': c.mcc,
          'mobileNetworkCode': c.mnc,
          'locationAreaCode': c.area,
          'cellId': c.cellId,
          if (c.pci != null) 'psc': c.pci,
          if (c.signalDbm != null) 'signalStrength': c.signalDbm!.round(),
          if (c.timingAdvance != null) 'timingAdvance': c.timingAdvance,
        },
  ];
  if (towers.isNotEmpty) body['cellTowers'] = towers;
  return body;
}

/// beaconDB client. Never throws; see [BeaconDbResult].
class BeaconDb {
  BeaconDb({
    http.Client? client,
    Uri? endpoint,
    this.userAgent = 'mapsoly/0.1',
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       endpoint =
           endpoint ?? Uri.parse('https://api.beacondb.net/v1/geolocate');

  final http.Client _client;
  final bool _ownsClient;
  final Uri endpoint;

  /// Neutral client string, as the beaconDB usage policy asks; contains no
  /// user or device identifier.
  final String userAgent;
  final Duration timeout;

  Future<BeaconDbResult> geolocate({
    List<WifiObservation> wifi = const [],
    List<CellObservation> cells = const [],
  }) async {
    final body = buildGeolocateRequest(wifi: wifi, cells: cells);
    if (!body.containsKey('wifiAccessPoints') &&
        !body.containsKey('cellTowers')) {
      return const BeaconDbResult.notFound();
    }
    try {
      final r = await _client
          .post(
            endpoint,
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': userAgent,
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
      if (r.statusCode == 404) return const BeaconDbResult.notFound();
      if (r.statusCode != 200) {
        return BeaconDbResult.failed('HTTP ${r.statusCode}');
      }
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is! Map || j['location'] is! Map) {
        return const BeaconDbResult.failed('unexpected response');
      }
      // The IP fallback is disabled in the request; ignore one anyway.
      if (j['fallback'] == 'ipf') return const BeaconDbResult.notFound();
      final loc = j['location'] as Map;
      final lat = (loc['lat'] as num?)?.toDouble();
      final lon = (loc['lng'] as num?)?.toDouble();
      final acc = (j['accuracy'] as num?)?.toDouble();
      if (lat == null || lon == null) {
        return const BeaconDbResult.failed('unexpected response');
      }
      return BeaconDbResult.found(BeaconDbFix(lat, lon, acc ?? 1000));
    } on Object catch (e) {
      return BeaconDbResult.failed('$e');
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
