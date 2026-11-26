/// Client for Apple's Wi-Fi positioning endpoint
/// (`https://gs-loc.apple.com/clls/wloc`).
///
/// UNOFFICIAL, UNDOCUMENTED API. Everything known about it is reverse
/// engineered (same request as microG's Apple backend and the public
/// "apple-bssid" style tools). It can change or disappear at any time, so:
///  * all knowledge of the wire format is confined to this file;
///  * every failure is soft: callers get an empty result, never an exception
///    (see [AppleWps.lookup]);
///  * nothing identifying the user or device is sent - the request carries
///    only BSSIDs and a fixed, generic client string.
///
/// Verified against the live endpoint on 2026-11-26:
///  * Request body = binary header + protobuf.
///    Header: int16 1, then three length-prefixed (int16 BE) strings
///    `en_US`, `com.apple.locationd`, `8.1.12B411`, then int32 1 and int32
///    protobuf length (all big endian).
///    Protobuf: repeated field 2 { field 1: bssid string }, field 3 = 0,
///    field 4 = 0 (return neighbours) or 1 (only what was asked).
///  * Headers: `Content-Type: application/x-www-form-urlencoded` and a
///    `locationd/...` User-Agent. No cookies, no tokens.
///  * Response: 10-byte header (int16 1, int32 1, int32 length) + protobuf:
///    repeated field 2 { 1: bssid (leading zeros of each octet stripped!),
///    2: { 1: latitude * 1e8, 2: longitude * 1e8, 3: horizontal accuracy m,
///    5: altitude, 6: vertical accuracy }, 21: channel }.
///    Unknown BSSIDs come back with latitude = longitude = -180e8.
///  * Neighbours (up to ~400 APs within ~300 m) are returned only around the
///    FIRST requested BSSID; further requested BSSIDs are answered
///    individually. 300 BSSIDs in one request were accepted.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models.dart';
import 'protobuf_lite.dart';

/// One access point returned by Apple.
class AppleWifiLocation {
  const AppleWifiLocation({
    required this.bssid,
    required this.lat,
    required this.lon,
    required this.accuracyM,
    this.channel,
  });

  final String bssid;
  final double lat;
  final double lon;
  final double accuracyM;
  final int? channel;
}

/// Result of one request.
class AppleWpsResponse {
  const AppleWpsResponse({
    required this.ok,
    this.found = const [],
    this.unknown = const [],
    this.error,
  });

  /// False when the request failed (network, HTTP status, parse error).
  final bool ok;

  /// APs with a position: the requested ones Apple knows, plus neighbours.
  final List<AppleWifiLocation> found;

  /// Requested BSSIDs Apple explicitly reported as unknown.
  final List<String> unknown;
  final String? error;
}

/// Builds the request body for [bssids].
Uint8List encodeAppleWpsRequest(List<String> bssids, {bool neighbours = true}) {
  final msg = ProtoWriter();
  for (final b in bssids) {
    msg.writeMessage(2, ProtoWriter()..writeString(1, b));
  }
  msg
    ..writeInt(3, 0)
    ..writeInt(4, neighbours ? 0 : 1);
  final body = msg.toBytes();
  final out = BytesBuilder();
  void i16(int v) => out.add([(v >> 8) & 0xff, v & 0xff]);
  void i32(int v) =>
      out.add([(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);
  void str(String s) {
    final b = ascii.encode(s);
    i16(b.length);
    out.add(b);
  }

  i16(1);
  str('en_US');
  str('com.apple.locationd');
  str('8.1.12B411');
  i32(1);
  i32(body.length);
  out.add(body);
  return out.toBytes();
}

/// Decodes a response body. Throws [ProtoFormatException] /
/// [FormatException] when it is not what we expect.
AppleWpsResponse decodeAppleWpsResponse(Uint8List data) {
  if (data.length < 10) throw const FormatException('response too short');
  final declared = (data[6] << 24) | (data[7] << 16) | (data[8] << 8) | data[9];
  if (declared != data.length - 10) {
    throw FormatException(
      'length mismatch: header says $declared, body is ${data.length - 10}',
    );
  }
  final found = <AppleWifiLocation>[];
  final unknown = <String>[];
  for (final f in readProto(Uint8List.sublistView(data, 10))) {
    if (f.number != 2 || f.wireType != wireBytes) continue;
    String? bssid;
    int? lat, lon, acc, channel;
    for (final d in readProto(f.bytes!)) {
      if (d.number == 1 && d.wireType == wireBytes) {
        bssid = normalizeMac(d.string);
      } else if (d.number == 2 && d.wireType == wireBytes) {
        for (final l in readProto(d.bytes!)) {
          if (l.wireType != wireVarint) continue;
          switch (l.number) {
            case 1:
              lat = l.varint;
            case 2:
              lon = l.varint;
            case 3:
              acc = l.varint;
          }
        }
      } else if (d.number == 21 && d.wireType == wireVarint) {
        channel = d.varint;
      }
    }
    if (bssid == null) continue;
    if (lat == null || lon == null) {
      unknown.add(bssid);
      continue;
    }
    final la = lat / 1e8, lo = lon / 1e8;
    if (la.abs() > 90 || lo.abs() > 180 || (la == 0 && lo == 0)) {
      unknown.add(bssid); // -180/-180 marks "not in database"
      continue;
    }
    found.add(
      AppleWifiLocation(
        bssid: bssid,
        lat: la,
        lon: lo,
        // Apple reports about 20..300 m; negative means unknown.
        accuracyM: acc == null || acc <= 0 ? 100.0 : acc.toDouble(),
        channel: channel,
      ),
    );
  }
  return AppleWpsResponse(ok: true, found: found, unknown: unknown);
}

/// The client. Stateless; rate limiting is the caller's job (see
/// `OnlineResolver`).
class AppleWps {
  AppleWps({http.Client? client, Uri? endpoint, this.timeout = _timeout})
    : _client = client ?? http.Client(),
      _ownsClient = client == null,
      endpoint = endpoint ?? Uri.parse('https://gs-loc.apple.com/clls/wloc');

  static const _timeout = Duration(seconds: 15);

  /// The endpoint only answers clients that look like `locationd`. This is a
  /// fixed, widely used string; it does not identify this app or its user.
  static const userAgent = 'locationd/1753.17 CFNetwork/711.1.12 Darwin/14.0.0';

  /// Upper bound of BSSIDs per request (300 verified to work).
  static const maxBssidsPerRequest = 100;

  final http.Client _client;
  final bool _ownsClient;
  final Uri endpoint;
  final Duration timeout;

  /// Looks up [bssids]. With [neighbours] Apple also returns the APs around
  /// the first BSSID. Never throws: failures yield `ok == false`.
  Future<AppleWpsResponse> lookup(
    List<String> bssids, {
    bool neighbours = true,
  }) async {
    if (bssids.isEmpty) return const AppleWpsResponse(ok: true);
    try {
      final response = await _client
          .post(
            endpoint,
            headers: const {
              'Content-Type': 'application/x-www-form-urlencoded',
              'User-Agent': userAgent,
              'Accept': '*/*',
            },
            body: encodeAppleWpsRequest(
              bssids.take(maxBssidsPerRequest).toList(),
              neighbours: neighbours,
            ),
          )
          .timeout(timeout);
      if (response.statusCode != 200) {
        return AppleWpsResponse(
          ok: false,
          error: 'HTTP ${response.statusCode}',
        );
      }
      return decodeAppleWpsResponse(response.bodyBytes);
    } on Object catch (e) {
      return AppleWpsResponse(ok: false, error: '$e');
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
