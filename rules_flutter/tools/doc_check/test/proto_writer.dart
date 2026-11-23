/// A tiny protobuf encoder for building `ModuleInfo` fixtures in tests.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Builds one message field by field.
class ProtoWriter {
  final BytesBuilder _out = BytesBuilder();

  void _varint(int value) {
    var rest = value;
    while (rest > 0x7f) {
      _out.addByte((rest & 0x7f) | 0x80);
      rest >>= 7;
    }
    _out.addByte(rest);
  }

  /// Writes varint [field] = [value]; zero is skipped like proto3 does.
  void varint(int field, int value) {
    if (value == 0) return;
    _varint(field << 3);
    _varint(value);
  }

  /// Writes string [field] = [value]; the empty string is skipped.
  void str(int field, String value) {
    if (value.isEmpty) return;
    _bytes(field, utf8.encode(value));
  }

  /// Writes nested message [field] = [message], even when it is empty.
  void msg(int field, ProtoWriter message) => _bytes(field, message.bytes());

  void _bytes(int field, List<int> value) {
    _varint(field << 3 | 2);
    _varint(value.length);
    _out.add(value);
  }

  /// The encoded message.
  Uint8List bytes() => _out.toBytes();
}
