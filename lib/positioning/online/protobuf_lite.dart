/// Minimal protobuf wire-format reader/writer (varint and length-delimited
/// fields, plus skipping of fixed32/fixed64), enough for the Apple WPS
/// messages. Deliberately not a general protobuf implementation.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Protobuf wire types.
const int wireVarint = 0;
const int wireFixed64 = 1;
const int wireBytes = 2;
const int wireFixed32 = 5;

/// Serialises protobuf fields.
class ProtoWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);

  /// Writes a base-128 varint. Negative values are written as their 64-bit
  /// two's complement (ten bytes), as protobuf does for int32/int64.
  void writeVarint(int value) {
    var v = value;
    while (true) {
      final bits = v & 0x7f;
      v = v >>> 7;
      if (v == 0) {
        _b.addByte(bits);
        return;
      }
      _b.addByte(bits | 0x80);
    }
  }

  void _tag(int field, int wire) => writeVarint((field << 3) | wire);

  /// int32 / int64 / uint / bool / enum field.
  void writeInt(int field, int value) {
    _tag(field, wireVarint);
    writeVarint(value);
  }

  void writeBytes(int field, List<int> bytes) {
    _tag(field, wireBytes);
    writeVarint(bytes.length);
    _b.add(bytes);
  }

  void writeString(int field, String value) =>
      writeBytes(field, utf8.encode(value));

  /// Embedded message.
  void writeMessage(int field, ProtoWriter message) =>
      writeBytes(field, message.toBytes());

  Uint8List toBytes() => _b.toBytes();
}

/// One decoded field.
class ProtoField {
  ProtoField(this.number, this.wireType, this.varint, this.bytes);

  final int number;
  final int wireType;

  /// Value for varint fields, interpreted as a signed 64-bit integer.
  final int varint;

  /// Payload for length-delimited (and fixed-width) fields.
  final Uint8List? bytes;

  String get string => utf8.decode(bytes!, allowMalformed: true);
}

/// Thrown when a buffer is not valid protobuf.
class ProtoFormatException implements Exception {
  ProtoFormatException(this.message);
  final String message;
  @override
  String toString() => 'ProtoFormatException: $message';
}

/// Decodes all fields of one message. Unknown wire types (groups) raise a
/// [ProtoFormatException]; so does any truncation.
List<ProtoField> readProto(Uint8List data) {
  final out = <ProtoField>[];
  var i = 0;
  int varint() {
    var result = 0, shift = 0;
    while (true) {
      if (i >= data.length) throw ProtoFormatException('truncated varint');
      final b = data[i++];
      if (shift < 64) result |= (b & 0x7f) << shift;
      if (b < 0x80) return result;
      shift += 7;
      if (shift > 70) throw ProtoFormatException('varint too long');
    }
  }

  Uint8List take(int n) {
    if (n < 0 || i + n > data.length) {
      throw ProtoFormatException('truncated field');
    }
    final v = Uint8List.sublistView(data, i, i + n);
    i += n;
    return v;
  }

  while (i < data.length) {
    final key = varint();
    final number = key >>> 3, wire = key & 7;
    if (number == 0) throw ProtoFormatException('field number 0');
    switch (wire) {
      case wireVarint:
        out.add(ProtoField(number, wire, varint(), null));
      case wireBytes:
        out.add(ProtoField(number, wire, 0, take(varint())));
      case wireFixed64:
        out.add(ProtoField(number, wire, 0, take(8)));
      case wireFixed32:
        out.add(ProtoField(number, wire, 0, take(4)));
      default:
        throw ProtoFormatException('unsupported wire type $wire');
    }
  }
  return out;
}
