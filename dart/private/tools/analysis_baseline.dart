// Per-file, per-rule diagnostic ceilings for the `dart_analyze` aspect.
//
// A baseline is JSON: an object whose keys are workspace-relative POSIX file
// paths and whose values map a diagnostic code to a non-negative integer
// ceiling. Codes compare case-insensitively and are stored lower case. The
// aspect slices the whole file per target, and both analysis runners judge each
// `(path, code)` group against its ceiling. A group with no entry has ceiling
// zero, so a diagnostic the baseline never names still fails.
import 'dart:convert';

/// Raised when a baseline file is not valid JSON or not the documented shape.
final class BaselineException implements Exception {
  const BaselineException(this.message);

  /// What is wrong, naming the offending entry.
  final String message;

  @override
  String toString() => message;
}

/// The parsed ceilings of one baseline file.
final class AnalysisBaseline {
  AnalysisBaseline._(this._entries);

  /// Parses [json], naming [source] in every error it raises.
  factory AnalysisBaseline.parse(String json, {String? source}) {
    final prefix = source == null ? 'baseline' : 'baseline `$source`';
    final dynamic root;
    try {
      root = _parseJson(json);
    } on BaselineException catch (e) {
      throw BaselineException('$prefix: ${e.message}');
    }
    if (root is! Map<String, dynamic>) {
      throw BaselineException(
        '$prefix: entry `<root>`: the root must be an object, '
        'not ${_jsonType(root)}',
      );
    }
    final entries = <String, Map<String, int>>{};
    for (final pathEntry in root.entries) {
      entries[pathEntry.key] = _parsePathRules(
        prefix,
        pathEntry.key,
        pathEntry.value,
      );
    }
    return AnalysisBaseline._(entries);
  }

  final Map<String, Map<String, int>> _entries;

  /// The ceiling for [code] in [path], or 0 when the pair is not keyed.
  int ceilingFor(String path, String code) =>
      _entries[path]?[code.toLowerCase()] ?? 0;

  /// Every entry in deterministic sorted order.
  Map<String, Map<String, int>> toJson() => sliceFor(_entries.keys);

  /// The entries for [paths] alone, sorted by path and then by code.
  ///
  /// A path the baseline does not name contributes nothing, so changing an
  /// unrelated entry leaves this slice byte-identical.
  Map<String, Map<String, int>> sliceFor(Iterable<String> paths) {
    final wanted = paths.toSet().toList()..sort();
    final slice = <String, Map<String, int>>{};
    for (final path in wanted) {
      final codes = _entries[path];
      if (codes == null) continue;
      final sortedCodes = codes.keys.toList()..sort();
      slice[path] = {for (final code in sortedCodes) code: codes[code]!};
    }
    return slice;
  }
}

/// Validates and normalizes the rule-to-ceiling map for one file [path].
Map<String, int> _parsePathRules(String prefix, String path, dynamic rules) {
  _checkBaselinePath(prefix, path);
  if (rules is! Map<String, dynamic>) {
    throw BaselineException(
      '$prefix: entry `$path`: the value must be an object mapping '
      'codes to ceilings, not ${_jsonType(rules)}',
    );
  }
  final codes = <String, int>{};
  for (final ruleEntry in rules.entries) {
    final rawCode = ruleEntry.key;
    final where = '$prefix: entry `$path` -> `$rawCode`';
    if (rawCode.isEmpty || rawCode.trim() != rawCode) {
      throw BaselineException('$where: diagnostic code must be non-empty');
    }
    final code = rawCode.toLowerCase();
    if (codes.containsKey(code)) {
      throw BaselineException(
        '$where: duplicate diagnostic code (codes compare '
        'case-insensitively)',
      );
    }
    final ceiling = ruleEntry.value;
    if (ceiling is! int) {
      throw BaselineException(
        '$where: ceiling must be a non-negative integer, got '
        '${_jsonType(ceiling)} ($ceiling)',
      );
    }
    if (ceiling < 0) {
      throw BaselineException(
        '$where: ceiling must be a non-negative integer, got $ceiling',
      );
    }
    codes[code] = ceiling;
  }
  return codes;
}

/// One diagnostic handed to the baseline verdict.
final class BaselineDiagnostic {
  const BaselineDiagnostic({
    required this.path,
    required this.code,
    required this.level,
    required this.text,
  });

  /// The workspace-relative POSIX path the diagnostic names.
  final String path;

  /// The diagnostic code, lower case.
  final String code;

  /// The severity name: `error`, `warning`, or `info`.
  final String level;

  /// The line as printed.
  final String text;
}

/// The observed count and ceiling of one `(path, code)` group.
final class BaselineGroup {
  const BaselineGroup({
    required this.path,
    required this.code,
    required this.observed,
    required this.ceiling,
  });

  /// The workspace-relative POSIX path of the group.
  final String path;

  /// The lower-case diagnostic code of the group.
  final String code;

  /// How many diagnostics the run reported for the group.
  final int observed;

  /// The ceiling the baseline gives the group; 0 when it is not keyed.
  final int ceiling;

  /// Whether the group may pass.
  bool get withinCeiling => observed <= ceiling;
}

/// The groups of one analysis run, keyed by `(path, code)`.
final class BaselineReport {
  BaselineReport._(this.groups, this._byKey);

  /// Groups [diagnostics] by `(path, code)` and looks up each ceiling.
  factory BaselineReport.of(
    Iterable<BaselineDiagnostic> diagnostics,
    AnalysisBaseline baseline,
  ) {
    final counts = <String, int>{};
    final first = <String, BaselineDiagnostic>{};
    for (final diagnostic in diagnostics) {
      final key = _groupKey(diagnostic.path, diagnostic.code);
      counts[key] = (counts[key] ?? 0) + 1;
      first.putIfAbsent(key, () => diagnostic);
    }
    final keys = counts.keys.toList()..sort();
    final groups = <BaselineGroup>[
      for (final key in keys)
        BaselineGroup(
          path: first[key]!.path,
          code: first[key]!.code.toLowerCase(),
          observed: counts[key]!,
          ceiling: baseline.ceilingFor(first[key]!.path, first[key]!.code),
        ),
    ];
    return BaselineReport._(groups, {
      for (final group in groups) _groupKey(group.path, group.code): group,
    });
  }

  /// Every group, sorted by path and then by code.
  final List<BaselineGroup> groups;
  final Map<String, BaselineGroup> _byKey;

  /// Whether no group exceeds its ceiling.
  bool get passes => groups.every((group) => group.withinCeiling);

  /// The group for [path] and [code], if the run reported either.
  BaselineGroup? groupFor(String path, String code) =>
      _byKey[_groupKey(path, code)];
}

String _groupKey(String path, String code) =>
    '$path\u0000${code.toLowerCase()}';

/// The line naming an over-ceiling group's file, code and both counts.
String baselineFailureLine(BaselineGroup group) =>
    'baseline: ${group.path} ${group.code}: observed ${group.observed}, '
    'ceiling ${group.ceiling}';

/// The marker appended to a diagnostic whose group is within its ceiling.
String baselinedMarker(BaselineGroup group) =>
    'baselined (${group.observed}/${group.ceiling})';

/// Rejects a key that is not a workspace-relative POSIX path.
void _checkBaselinePath(String prefix, String path) {
  final where = '$prefix: entry `$path`';
  if (path.startsWith('/') ||
      path.startsWith(r'\') ||
      _windowsDrive.hasMatch(path)) {
    throw BaselineException(
      '$where: the path must be workspace-relative, not an absolute path',
    );
  }
  if (path.split('/').contains('..') || path.split(r'\').contains('..')) {
    throw BaselineException(
      '$where: the path must not contain a `..` component',
    );
  }
  if (path.isEmpty || path.contains(r'\')) {
    throw BaselineException(
      '$where: the path must be a non-empty workspace-relative POSIX path',
    );
  }
}

final _windowsDrive = RegExp(r'^[A-Za-z]:');

String _jsonType(dynamic value) {
  if (value == null) return 'null';
  if (value is bool) return 'boolean';
  if (value is int) return 'integer';
  if (value is double) return 'number';
  if (value is String) return 'string';
  if (value is List) return 'array';
  if (value is Map) return 'object';
  return value.runtimeType.toString();
}

/// Parses [text] as JSON, rejecting duplicate object keys.
dynamic _parseJson(String text) {
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
      skipWhitespace();
      if (atEnd || _text[_offset] != '"') {
        throw error('an object key must be a string');
      }
      final key = readString();
      if (result.containsKey(key)) {
        throw error('duplicate key `$key`', extraKey: key);
      }
      skipWhitespace();
      if (atEnd || _text[_offset] != ':') {
        throw error('expected `:` after key `$key`', extraKey: key);
      }
      _offset++;
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
    var integral = true;
    if (!atEnd && _text[_offset] == '.') {
      integral = false;
      _offset++;
      _consumeDigits();
    }
    if (!atEnd && (_text[_offset] == 'e' || _text[_offset] == 'E')) {
      integral = false;
      _offset++;
      if (!atEnd && (_text[_offset] == '+' || _text[_offset] == '-')) {
        _offset++;
      }
      _consumeDigits();
    }
    final raw = _text.substring(start, _offset);
    try {
      final decoded = jsonDecode(raw) as num;
      return integral ? decoded as int : decoded.toDouble();
    } on FormatException catch (e) {
      throw error('invalid number `$raw`: ${e.message}');
    }
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
