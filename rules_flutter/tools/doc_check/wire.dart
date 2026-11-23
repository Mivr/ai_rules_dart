/// A minimal protobuf wire-format reader: just enough to decode the
/// `stardoc_output.proto` messages without a code generator.
library;

import 'dart:convert';
import 'dart:typed_data';

/// A read position over a byte buffer.
class _Cursor {
  new(this.bytes);

  final Uint8List bytes;
  int pos = 0;

  bool get done => pos >= bytes.length;

  /// Reads one base-128 varint.
  int varint() {
    var result = 0;
    for (var shift = 0; shift <= 63; shift += 7) {
      if (done) break;
      final int byte = bytes[pos++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
    }
    throw const FormatException('truncated or oversized varint');
  }

  /// Reads [length] raw bytes.
  Uint8List take(int length) {
    if (length < 0 || pos + length > bytes.length) {
      throw const FormatException('field runs past the end of the buffer');
    }
    final out = Uint8List.sublistView(bytes, pos, pos + length);
    pos += length;
    return out;
  }

  /// Reads the value that follows a key of the given wire [type].
  Object value(int type) => switch (type) {
    0 => varint(),
    1 => take(8).length,
    2 => take(varint()),
    5 => take(4).length,
    _ => throw FormatException('unsupported wire type $type'),
  };
}

/// One decoded message: each field number maps to its raw values in order.
///
/// A varint, fixed32 or fixed64 value is an `int`; a length-delimited value
/// (string, bytes or nested message) is a [Uint8List].
class WireMessage {
  /// Wraps already-decoded `fields`.
  const new(this._fields);

  /// Decodes [bytes] as one message, throwing [FormatException] on bad input.
  factory parse(Uint8List bytes) {
    final cursor = _Cursor(bytes);
    final fields = <int, List<Object>>{};
    while (!cursor.done) {
      final int key = cursor.varint();
      final Object value = cursor.value(key & 7);
      fields.putIfAbsent(key >> 3, () => <Object>[]).add(value);
    }
    return WireMessage(fields);
  }

  final Map<int, List<Object>> _fields;

  /// Whether [field] occurs at least once.
  bool has(int field) => _fields.containsKey(field);

  /// The last varint value of [field], or 0 when absent.
  int integer(int field) {
    final Object? last = _fields[field]?.last;
    return last is int ? last : 0;
  }

  /// Whether the bool [field] is set.
  bool flag(int field) => integer(field) != 0;

  /// The last string value of [field], or the empty string when absent.
  String string(int field) {
    final Object? last = _fields[field]?.last;
    return last is Uint8List ? utf8.decode(last) : '';
  }

  /// Every string value of repeated [field].
  List<String> strings(int field) => [
    for (final v in _fields[field] ?? const <Object>[])
      if (v is Uint8List) utf8.decode(v),
  ];

  /// Every nested message of repeated [field].
  List<WireMessage> messages(int field) => [
    for (final v in _fields[field] ?? const <Object>[])
      if (v is Uint8List) WireMessage.parse(v),
  ];

  /// The nested message at [field], or null when absent.
  WireMessage? message(int field) {
    final List<WireMessage> all = messages(field);
    return all.isEmpty ? null : all.last;
  }
}
