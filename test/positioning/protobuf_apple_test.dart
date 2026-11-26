import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mapsoly/positioning/online/apple_wps.dart';
import 'package:mapsoly/positioning/online/protobuf_lite.dart';

Uint8List unhex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Request for 02:00:00:00:00:01 and ..:02 with neighbours, byte-identical
/// to the one a reference Python client sent to the live endpoint on
/// 2026-11-26 (HTTP 200, well-formed answer).
const requestGolden =
    '00010005656e5f55530013636f6d2e6170706c652e6c6f636174696f6e64000a382e'
    '312e313242343131000000010000002e12130a1130323a30303a30303a30303a3030'
    '3a303112130a1130323a30303a30303a30303a30303a303218002000';

/// Real answer of the live endpoint for the (non-existent) BSSID
/// 02:00:00:00:00:02: latitude = longitude = -180e8, accuracy -1.
const unknownGolden =
    '0001000000010000004312410a1130323a30303a30303a30303a30303a3032122c08'
    '8098f7f8bcffffffff01108098f7f8bcffffffff0118ffffffffffffffffff0128ff'
    'ffffffffffffffff01';

/// Answer in the exact field layout observed live (location fields 1, 2, 3,
/// 4, 5, 6, 11, 12; device field 21 = channel; octets without leading
/// zeros), with synthetic values: two known APs, one unknown, one in the
/// southern/western hemisphere.
const responseGolden =
    '000100000001000000ce122b0a0b323a303a303a303a303a3112190880d49aa91610'
    'c0e0c0b50b18282000280f300a583e609d05a80106122b0a0b323a303a303a613a62'
    '3a63121908b9b49ba91610f188c4b50b18162000280d300a583e609d05a8010b123b'
    '0a0b323a303a303a303a303a32122c088098f7f8bcffffffff01108098f7f8bcffff'
    'ffff0118ffffffffffffffffff0128ffffffffffffffffff0112350a0b323a303a30'
    '3a303a303a33122308c0fff3b1f3ffffffff0110ecc9e9d5c7ffffffff0118232000'
    '280f300a583e609d05a80124';

void main() {
  group('protobuf_lite', () {
    test('varint round trip incl. negatives and 64-bit values', () {
      for (final v in [
        0,
        1,
        127,
        128,
        300,
        16384,
        5992000000,
        -1,
        -18000000000,
        0x7fffffffffffffff,
        -0x8000000000000000,
      ]) {
        final w = ProtoWriter()..writeInt(1, v);
        final f = readProto(w.toBytes()).single;
        expect(f.number, 1);
        expect(f.wireType, wireVarint);
        expect(f.varint, v, reason: 'value $v');
      }
    });

    test('known encodings', () {
      // Examples from the protobuf encoding documentation.
      expect(hex((ProtoWriter()..writeInt(1, 150)).toBytes()), '089601');
      expect(
        hex((ProtoWriter()..writeString(2, 'testing')).toBytes()),
        '120774657374696e67',
      );
      expect(
        hex((ProtoWriter()..writeInt(1, -1)).toBytes()),
        '08ffffffffffffffffff01',
      );
      final nested = ProtoWriter()
        ..writeMessage(3, ProtoWriter()..writeInt(1, 150));
      expect(hex(nested.toBytes()), '1a03089601');
    });

    test('reads mixed messages and skips fixed-width fields', () {
      final data = unhex(
        '089601' // 1: varint 150
        '1d01020304' // 3: fixed32
        '210102030405060708' // 4: fixed64
        '120568656c6c6f', // 2: "hello"
      );
      final f = readProto(data);
      expect(f.map((x) => x.number), [1, 3, 4, 2]);
      expect(f[1].bytes, [1, 2, 3, 4]);
      expect(f[2].bytes!.length, 8);
      expect(f[3].string, 'hello');
    });

    test('malformed input throws ProtoFormatException', () {
      for (final bad in ['08', '0896', '1205686', '0b', '00', '12ff01']) {
        final padded = bad.length.isOdd ? '${bad}0' : bad;
        expect(
          () => readProto(unhex(padded)),
          throwsA(isA<ProtoFormatException>()),
          reason: bad,
        );
      }
    });
  });

  group('Apple WPS codec', () {
    test('request matches the framing accepted by the live endpoint', () {
      final req = encodeAppleWpsRequest([
        '02:00:00:00:00:01',
        '02:00:00:00:00:02',
      ]);
      expect(hex(req), requestGolden);
      // "only what was asked" flips field 4 to 1.
      final only = encodeAppleWpsRequest([
        '02:00:00:00:00:01',
        '02:00:00:00:00:02',
      ], neighbours: false);
      expect(
        hex(only),
        '${requestGolden.substring(0, requestGolden.length - 2)}01',
      );
    });

    test('request length field is 32 bit (more than 255 payload bytes)', () {
      final many = [
        for (var i = 0; i < 100; i++)
          '02:00:00:00:00:${i.toRadixString(16).padLeft(2, '0')}',
      ];
      final req = encodeAppleWpsRequest(many);
      const header = 2 + 7 + 21 + 12 + 4 + 4;
      final declared = ByteData.sublistView(req).getUint32(header - 4);
      expect(declared, req.length - header);
      expect(declared, 100 * 21 + 4);
      final fields = readProto(Uint8List.sublistView(req, header));
      expect(fields.where((f) => f.number == 2).length, 100);
    });

    test('decodes a real "unknown BSSID" answer', () {
      final r = decodeAppleWpsResponse(unhex(unknownGolden));
      expect(r.ok, isTrue);
      expect(r.found, isEmpty);
      expect(r.unknown, ['02:00:00:00:00:02']);
    });

    test('decodes known, unknown and negative coordinates', () {
      final r = decodeAppleWpsResponse(unhex(responseGolden));
      expect(r.found.length, 3);
      expect(r.unknown, ['02:00:00:00:00:02']);
      final a = r.found[0];
      // Apple strips leading zeros ("2:0:0:0:0:1"); we normalise.
      expect(a.bssid, '02:00:00:00:00:01');
      expect(a.lat, closeTo(59.92, 1e-9));
      expect(a.lon, closeTo(30.65, 1e-9));
      expect(a.accuracyM, 40);
      expect(a.channel, 6);
      final b = r.found[1];
      expect(b.bssid, '02:00:00:0a:0b:0c');
      expect(b.lat, closeTo(59.92012345, 1e-9));
      expect(b.lon, closeTo(30.65054321, 1e-9));
      expect(b.accuracyM, 22);
      final c = r.found[2];
      expect(c.lat, closeTo(-33.85, 1e-9));
      expect(c.lon, closeTo(-151.208333, 1e-9));
      expect(c.channel, 36);
    });

    test('rejects truncated or mis-framed answers', () {
      final good = unhex(responseGolden);
      expect(
        () => decodeAppleWpsResponse(Uint8List.sublistView(good, 0, 5)),
        throwsFormatException,
      );
      expect(
        () => decodeAppleWpsResponse(
          Uint8List.sublistView(good, 0, good.length - 3),
        ),
        throwsFormatException,
      );
    });
  });

  group('AppleWps client', () {
    test('sends the expected request and decodes the answer', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response.bytes(unhex(responseGolden), 200);
      });
      final r = await AppleWps(
        client: client,
      ).lookup(['02:00:00:00:00:01', '02:00:00:00:00:02']);
      expect(seen.method, 'POST');
      expect(seen.url.toString(), 'https://gs-loc.apple.com/clls/wloc');
      expect(hex(seen.bodyBytes), requestGolden);
      expect(seen.headers['User-Agent'], AppleWps.userAgent);
      expect(
        seen.headers['Content-Type'],
        startsWith('application/x-www-form-urlencoded'),
      );
      // Nothing that could identify the user.
      expect(
        seen.headers.keys.map((k) => k.toLowerCase()),
        isNot(anyOf(contains('cookie'), contains('authorization'))),
      );
      expect(r.ok, isTrue);
      expect(r.found.length, 3);
    });

    test('fails soft on HTTP errors, garbage and exceptions', () async {
      final e500 = await AppleWps(
        client: MockClient((_) async => http.Response('nope', 500)),
      ).lookup(['02:00:00:00:00:01']);
      expect(e500.ok, isFalse);
      expect(e500.error, 'HTTP 500');

      final garbage = await AppleWps(
        client: MockClient((_) async => http.Response('<html>hi</html>', 200)),
      ).lookup(['02:00:00:00:00:01']);
      expect(garbage.ok, isFalse);
      expect(garbage.found, isEmpty);

      final thrown = await AppleWps(
        client: MockClient((_) async => throw Exception('offline')),
      ).lookup(['02:00:00:00:00:01']);
      expect(thrown.ok, isFalse);

      final empty = await AppleWps(
        client: MockClient((_) async => fail('must not be called')),
      ).lookup([]);
      expect(empty.ok, isTrue);
    });
  });
}
