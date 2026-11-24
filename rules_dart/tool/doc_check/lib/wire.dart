/// A minimal protobuf wire-format reader.
///
/// The doc checker decodes Bazel's `stardoc_output.proto` messages itself so
/// it needs no generated code and no external package. Only the four wire
/// types a proto3 message of that schema can contain are accepted; anything
/// else is a malformed input and throws a [FormatException].
library;

import 'dart:convert';
import 'dart:typed_data';

/// One decoded field: its number and either a varint/fixed value or bytes.
class WireField {
  /// Creates a field with [number], and exactly one of [value] or [bytes].
  const new(this.number, {this.value = 0, this.bytes});

  /// The proto field number.
  final int number;

  /// The integer value of a varint or fixed-width field; 0 for bytes fields.
  final int value;

  /// The payload of a length-delimited field, null for the other wire types.
  final Uint8List? bytes;

  /// The payload decoded as UTF-8 text; empty for a non-bytes field.
  String get text => bytes == null ? '' : utf8.decode(bytes!);
}

/// Splits a serialized message into its fields, in wire order.
List<WireField> readFields(Uint8List data) {
  final cursor = _Cursor(data);
  final fields = <WireField>[];
  while (!cursor.done) {
    final int tag = cursor.varint();
    final int number = tag >> 3;
    if (number == 0) {
      throw const FormatException('proto field number 0 is invalid');
    }
    fields.add(_readValue(cursor, number, tag & 7));
  }
  return fields;
}

WireField _readValue(_Cursor cursor, int number, int wireType) {
  switch (wireType) {
    case 0:
      return WireField(number, value: cursor.varint());
    case 1:
      return WireField(number, value: cursor.fixed(8));
    case 2:
      final int length = cursor.varint();
      return WireField(number, bytes: cursor.take(length));
    case 5:
      return WireField(number, value: cursor.fixed(4));
  }
  throw FormatException('unsupported proto wire type $wireType');
}

class _Cursor {
  new(this._data);

  final Uint8List _data;
  int _at = 0;

  bool get done => _at >= _data.length;

  int varint() {
    var result = 0;
    for (var shift = 0; shift < 64; shift += 7) {
      if (done) throw const FormatException('truncated proto varint');
      final int byte = _data[_at++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
    }
    throw const FormatException('proto varint longer than 10 bytes');
  }

  int fixed(int width) {
    final Uint8List bytes = take(width);
    var result = 0;
    for (int i = width - 1; i >= 0; i--) {
      result = (result << 8) | bytes[i];
    }
    return result;
  }

  Uint8List take(int length) {
    if (length < 0 || _at + length > _data.length) {
      throw const FormatException('truncated proto field');
    }
    final slice = Uint8List.sublistView(_data, _at, _at + length);
    _at += length;
    return slice;
  }
}
