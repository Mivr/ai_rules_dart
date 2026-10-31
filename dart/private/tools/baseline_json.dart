// Strict JSON reader for `dart_analysis_config` baseline files.
//
// `dart:convert`'s `jsonDecode` silently overwrites duplicate object keys and
// decodes `-0` or out-of-range integers as `double` values. This reader
// rejects duplicate keys at every nesting level while tracking the enclosing
// entry path so error messages always name the offending entry.
import 'dart:convert';

/// Raised when a baseline file is not valid JSON or not the documented shape.
final class BaselineException implements Exception {
  const BaselineException(this.message);

  /// What is wrong, naming the offending entry.
  final String message;

  @override
  String toString() => message;
}

/// Human-readable JSON type name for [value] in validation diagnostics.
String jsonValueType(dynamic value) {
  if (value == null) return 'null';
  if (value is bool) return 'boolean';
  if (value is int) return 'integer';
  if (value is double) return 'number';
  if (value is String) return 'string';
  if (value is List) return 'array';
  if (value is Map) return 'object';
  return value.runtimeType.toString();
}

/// Parses [text] as JSON, rejecting duplicate object keys and trailing tokens.
dynamic parseBaselineJson(String text) {
  final reader = _JsonReader(text);
  final value = reader.readValue();
  reader.skipWhitespace();
  if (!reader.atEnd) throw reader.error('unexpected trailing content');
  return value;
}

final class _JsonReader {
  _JsonReader(this._text);

  final String _text;
  final List<String> _keyStack = <String>[];
  int _offset = 0;

  bool get atEnd => _offset >= _text.length;

  /// An error naming the enclosing entry (if any) and the current offset.
  BaselineException error(String reason, {String? extraKey}) {
    final start = _offset < 20 ? 0 : _offset - 20;
    final end = _offset + 20 > _text.length ? _text.length : _offset + 20;
    final near = _text.substring(start, end).replaceAll('\n', ' ');
    final keys = [..._keyStack, if (extraKey != null) extraKey];
    final context = keys.isEmpty
        ? ''
        : 'entry ${keys.map((k) => '`$k`').join(' -> ')}: ';
    return BaselineException('$context$reason at offset $_offset near `$near`');
  }

  void skipWhitespace() {
    while (!atEnd && ' \t\r\n'.contains(_text[_offset])) {
      _offset++;
    }
  }

  dynamic readValue() {
    skipWhitespace();
    if (atEnd) throw error('unexpected end of input');
    final character = _text[_offset];
    if (character == '{') return _readObject();
    if (character == '[') return _readArray();
    if (character == '"') return readString();
    if (character == 't') return _readLiteral('true', true);
    if (character == 'f') return _readLiteral('false', false);
    if (character == 'n') return _readLiteral('null', null);
    if (character == '-' || _isDigit(character)) return _readNumber();
    throw error('unexpected character `$character`');
  }

  Map<String, dynamic> _readObject() {
    _offset++;
    final result = <String, dynamic>{};
    skipWhitespace();
    if (!atEnd && _text[_offset] == '}') {
      _offset++;
      return result;
    }
    while (true) {
      final key = _readMemberKey(result);
      _keyStack.add(key);
      result[key] = readValue();
      _keyStack.removeLast();
      skipWhitespace();
      if (atEnd) throw error('unterminated object');
      final separator = _text[_offset++];
      if (separator == '}') return result;
      if (separator != ',') throw error('expected `,` or `}`');
    }
  }

  String _readMemberKey(Map<String, dynamic> existing) {
    skipWhitespace();
    if (atEnd || _text[_offset] != '"') {
      throw error('an object key must be a string');
    }
    final key = readString();
    if (existing.containsKey(key)) {
      throw error('duplicate key `$key`', extraKey: key);
    }
    skipWhitespace();
    if (atEnd || _text[_offset] != ':') {
      throw error('expected `:` after key `$key`', extraKey: key);
    }
    _offset++;
    return key;
  }

  List<dynamic> _readArray() {
    _offset++;
    final result = <dynamic>[];
    skipWhitespace();
    if (!atEnd && _text[_offset] == ']') {
      _offset++;
      return result;
    }
    while (true) {
      result.add(readValue());
      skipWhitespace();
      if (atEnd) throw error('unterminated array');
      final separator = _text[_offset++];
      if (separator == ']') return result;
      if (separator != ',') throw error('expected `,` or `]`');
    }
  }

  String readString() {
    final start = _offset;
    _offset++;
    while (!atEnd) {
      final character = _text[_offset];
      if (character == '"') {
        _offset++;
        try {
          return jsonDecode(_text.substring(start, _offset)) as String;
        } on FormatException catch (e) {
          throw error('invalid string: ${e.message}');
        }
      }
      if (character == r'\') {
        _offset++;
        if (atEnd) throw error('unterminated escape');
      }
      _offset++;
    }
    throw error('unterminated string');
  }

  num _readNumber() {
    final start = _offset;
    if (!atEnd && _text[_offset] == '-') _offset++;
    _consumeDigits();
    final hasFraction = _consumeFraction();
    final hasExponent = _consumeExponent();
    final raw = _text.substring(start, _offset);
    final num decoded;
    try {
      decoded = jsonDecode(raw) as num;
    } on FormatException catch (e) {
      throw error('invalid number `$raw`: ${e.message}');
    }
    if (hasFraction || hasExponent) return decoded.toDouble();
    final intVal = int.tryParse(raw);
    if (intVal == null) throw error('integer out of range `$raw`');
    return intVal;
  }

  bool _consumeFraction() {
    if (atEnd || _text[_offset] != '.') return false;
    _offset++;
    _consumeDigits();
    return true;
  }

  bool _consumeExponent() {
    if (atEnd || (_text[_offset] != 'e' && _text[_offset] != 'E')) return false;
    _offset++;
    if (!atEnd && (_text[_offset] == '+' || _text[_offset] == '-')) _offset++;
    _consumeDigits();
    return true;
  }

  void _consumeDigits() {
    final start = _offset;
    while (!atEnd && _isDigit(_text[_offset])) {
      _offset++;
    }
    if (_offset == start) throw error('expected a digit');
  }

  dynamic _readLiteral(String word, dynamic value) {
    if (!_text.startsWith(word, _offset)) throw error('invalid literal');
    _offset += word.length;
    return value;
  }
}

bool _isDigit(String character) {
  final code = character.codeUnitAt(0);
  return code >= 0x30 && code <= 0x39;
}
