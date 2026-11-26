import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mapsoly/obd/rfcomm_transport.dart';

void main() {
  test('sockaddr_rc layout', () {
    final a = rfcommSockaddr('00:1D:A5:68:98:8B', 1);
    expect(a.length, 10);
    // AF_BLUETOOTH = 31 in host byte order.
    expect(ByteData.sublistView(a).getUint16(0, Endian.host), 31);
    // The address is stored least significant byte first.
    expect(a.sublist(2, 8), [0x8B, 0x98, 0x68, 0xA5, 0x1D, 0x00]);
    expect(a[8], 1);
    expect(a[9], 0);
  });

  test('bad addresses and channels are rejected', () {
    expect(() => rfcommSockaddr('00:1D:A5:68:98', 1), throwsFormatException);
    expect(() => rfcommSockaddr('zz:1D:A5:68:98:8B', 1), throwsFormatException);
    expect(() => rfcommSockaddr('00:1D:A5:68:98:8B', 0), throwsRangeError);
    expect(() => rfcommSockaddr('00:1D:A5:68:98:8B', 31), throwsRangeError);
  });

  test('typical adapter names are recognised', () {
    BluetoothDevice d(String name) =>
        BluetoothDevice('00:1D:A5:68:98:8B', name, paired: true);
    expect(d('OBDII').looksLikeObd, isTrue);
    expect(d('V-LINK').looksLikeObd, isTrue);
    expect(d('ELM327 v1.5').looksLikeObd, isTrue);
    expect(d('JBL Flip 5').looksLikeObd, isFalse);
  });

  test(
    'connecting to an absent adapter fails with an OS error',
    () async {
      // No such device: either Bluetooth is unavailable here or nobody answers.
      await expectLater(
        RfcommObdTransport.connect('00:00:00:00:00:01'),
        throwsA(isA<OSError>()),
      );
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
