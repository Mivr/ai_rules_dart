import 'dart:convert';
import 'dart:io';

/// Options parsed from command-line arguments.
class _DefinesFilesOptions {
  /// Creates options for the defines_files tool.
  const new({
    required this.outputPath,
    required this.excludedKeys,
    required this.inputFiles,
  });

  /// The output path where the flagfile will be written.
  final String outputPath;

  /// Defines keys overridden by higher-precedence flags or attrs.
  final Set<String> excludedKeys;

  /// Ordered list of input `.json` or `.env` files.
  final List<String> inputFiles;
}

/// Parses command-line arguments into [_DefinesFilesOptions].
_DefinesFilesOptions _parseArgs(List<String> args) {
  String? outputPath;
  final excludedKeys = <String>{};
  final inputFiles = <String>[];

  var i = 0;
  while (i < args.length) {
    final String arg = args[i];
    if (arg == '--output') {
      if (i + 1 >= args.length) {
        throw const FormatException('Missing argument for --output');
      }
      outputPath = args[++i];
    } else if (arg.startsWith('--output=')) {
      outputPath = arg.substring('--output='.length);
    } else if (arg == '--exclude-define' || arg == '--exclude-key') {
      if (i + 1 >= args.length) {
        throw FormatException('Missing argument for $arg');
      }
      final String val = args[++i];
      excludedKeys.add(val.split('=').first);
    } else if (arg.startsWith('--exclude-define=')) {
      final String val = arg.substring('--exclude-define='.length);
      excludedKeys.add(val.split('=').first);
    } else if (arg.startsWith('--exclude-key=')) {
      final String val = arg.substring('--exclude-key='.length);
      excludedKeys.add(val.split('=').first);
    } else {
      inputFiles.add(arg);
    }
    i++;
  }

  if (outputPath == null || outputPath.isEmpty) {
    throw const FormatException('Missing required --output flag');
  }

  return _DefinesFilesOptions(
    outputPath: outputPath,
    excludedKeys: excludedKeys,
    inputFiles: inputFiles,
  );
}

/// Validates that [key] is non-empty, contains only `[A-Za-z0-9_.]`,
/// and is not a reserved Dart/Flutter define namespace.
void _validateKey(String key, String filePath) {
  if (key.isEmpty) {
    throw FormatException('$filePath: define key must not be empty');
  }
  final validKey = RegExp(r'^[A-Za-z0-9_.]+$');
  if (!validKey.hasMatch(key)) {
    throw FormatException(
      "$filePath: define key '$key' contains invalid characters "
      '(must match [A-Za-z0-9_.])',
    );
  }
  const reservedPrefixes = <String>[
    'dart.vm.',
    'dart.library.',
    'dart.tool.',
    'flutter.',
  ];
  for (final prefix in reservedPrefixes) {
    final String bare = prefix.substring(0, prefix.length - 1);
    if (key.startsWith(prefix) || key == bare) {
      throw FormatException(
        "$filePath: define key '$key' is reserved "
        '(dart.vm.*, dart.library.*, dart.tool.*, flutter.*)',
      );
    }
  }
}

/// Validates that [value] does not contain newlines which would split the flagfile.
void _validateValue(String key, String value, String filePath) {
  if (value.contains('\n') || value.contains('\r')) {
    throw FormatException(
      "$filePath: define key '$key' value contains a newline",
    );
  }
}

/// Represents a scanned JSON string value along with its raw source length.
class _ScannedString {
  /// Creates a scanned JSON string record.
  const new(this.value, this.lengthInSource);

  /// Unescaped string value.
  final String value;

  /// Character length of the string in the source text excluding surrounding quotes.
  final int lengthInSource;
}

/// Scans a quoted string starting at [start] (first char inside quotes).
_ScannedString _scanJsonString(String content, int start, String filePath) {
  final sb = StringBuffer();
  var i = start;
  final int n = content.length;
  while (i < n) {
    final String c = content[i];
    if (c == r'\') {
      if (i + 1 >= n) {
        throw FormatException('$filePath: Incomplete escape in JSON string');
      }
      final String next = content[i + 1];
      if (next == 'n') {
        sb.write('\n');
      } else if (next == 'r') {
        sb.write('\r');
      } else if (next == 't') {
        sb.write('\t');
      } else if (next == 'b') {
        sb.write('\b');
      } else if (next == 'f') {
        sb.write('\f');
      } else if (next == 'u' && i + 5 < n) {
        final int? code = int.tryParse(
          content.substring(i + 2, i + 6),
          radix: 16,
        );
        if (code != null) {
          sb.writeCharCode(code);
          i += 4;
        }
      } else {
        sb.write(next);
      }
      i += 2;
    } else if (c == '"') {
      return _ScannedString(sb.toString(), i - start);
    } else {
      sb.write(c);
      i++;
    }
  }
  throw FormatException('$filePath: Unterminated string in JSON');
}

/// Skips whitespace characters starting at [start] and returns the next index.
int _skipWhitespace(String content, int start) {
  var i = start;
  final int n = content.length;
  while (i < n && content.codeUnitAt(i) <= 32) {
    i++;
  }
  return i;
}

/// Skips a quoted JSON string starting after the opening quote at [start],
/// returning the index immediately after the closing quote.
int _skipQuotedString(String content, int start) {
  var i = start;
  final int n = content.length;
  while (i < n) {
    final String c = content[i];
    if (c == r'\') {
      i += 2;
    } else if (c == '"') {
      return i + 1;
    } else {
      i++;
    }
  }
  return i;
}

/// Skips a composite JSON structure (object or array) starting at [start].
int _skipComposite(
  String content,
  int start,
  String openChar,
  String closeChar,
) {
  var depth = 1;
  int i = start + 1;
  final int n = content.length;
  while (i < n && depth > 0) {
    final String c = content[i];
    if (c == '"') {
      i = _skipQuotedString(content, i + 1);
    } else {
      if (c == openChar) {
        depth++;
      } else if (c == closeChar) {
        depth--;
      }
      i++;
    }
  }
  return i;
}

/// Skips an unquoted scalar JSON value (number, boolean, null) starting at [start].
int _skipScalar(String content, int start) {
  var i = start;
  final int n = content.length;
  while (i < n) {
    final int code = content.codeUnitAt(i);
    if (code <= 32 || code == 44 || code == 125 || code == 93) {
      break;
    }
    i++;
  }
  return i;
}

/// Skips an arbitrary JSON value starting at [start].
int _skipJsonValue(String content, int start) {
  final int i = _skipWhitespace(content, start);
  if (i >= content.length) {
    return i;
  }
  final String first = content[i];
  if (first == '"') {
    return _skipQuotedString(content, i + 1);
  }
  if (first == '{') {
    return _skipComposite(content, i, '{', '}');
  }
  if (first == '[') {
    return _skipComposite(content, i, '[', ']');
  }
  return _skipScalar(content, i);
}

/// Verifies that [content] contains a ':' after optional whitespace.
int _expectColon(String content, int offset, String filePath) {
  final int i = _skipWhitespace(content, offset);
  if (i >= content.length || content[i] != ':') {
    throw FormatException('$filePath: Expected : after key at offset $offset');
  }
  return i + 1;
}

/// Skips an optional comma after whitespace.
int _skipComma(String content, int offset) {
  final int i = _skipWhitespace(content, offset);
  if (i < content.length && content[i] == ',') {
    return i + 1;
  }
  return i;
}

/// Extracts top-level string keys in order from raw [content],
/// detecting any duplicate keys within the same file.
List<String> _extractTopLevelJsonKeys(String content, String filePath) {
  final keys = <String>[];
  final seen = <String>{};
  final int start = _skipWhitespace(content, 0);
  if (start >= content.length || content[start] != '{') {
    throw FormatException('$filePath: JSON must contain a top-level object');
  }
  int i = start + 1;

  while (i < content.length) {
    i = _skipWhitespace(content, i);
    if (i >= content.length || content[i] == '}') {
      break;
    }
    if (content[i] != '"') {
      throw FormatException(
        '$filePath: Expected string key in JSON object at offset $i',
      );
    }
    final _ScannedString key = _scanJsonString(content, i + 1, filePath);
    i += key.lengthInSource + 2;

    if (!seen.add(key.value)) {
      throw FormatException(
        "$filePath: define key '${key.value}' appears twice in $filePath",
      );
    }
    keys.add(key.value);

    i = _expectColon(content, i, filePath);
    i = _skipJsonValue(content, i);
    i = _skipComma(content, i);
  }
  return keys;
}

/// Parses a `.json` file and returns its define entries.
List<MapEntry<String, String>> _parseJsonFile(
  String filePath,
  String content,
  Map<String, String> keyOrigin,
) {
  dynamic decoded;
  try {
    decoded = json.decode(content);
  } on FormatException catch (e) {
    throw FormatException('$filePath: malformed JSON: ${e.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    throw FormatException(
      '$filePath: JSON defines file must contain a top-level JSON object',
    );
  }

  final List<String> orderedKeys = _extractTopLevelJsonKeys(content, filePath);
  final entries = <MapEntry<String, String>>[];

  for (final key in orderedKeys) {
    _validateKey(key, filePath);
    final String? previousFile = keyOrigin[key];
    if (previousFile != null) {
      throw FormatException(
        "$filePath: define key '$key' is defined in both $previousFile and $filePath",
      );
    }
    keyOrigin[key] = filePath;

    final Object? val = decoded[key];
    String stringVal;
    if (val == null) {
      throw FormatException(
        "$filePath: define key '$key' has null value "
        '(null, arrays, and objects are not allowed)',
      );
    } else if (val is List) {
      throw FormatException(
        "$filePath: define key '$key' has array value "
        '(null, arrays, and objects are not allowed)',
      );
    } else if (val is Map) {
      throw FormatException(
        "$filePath: define key '$key' has object value "
        '(null, arrays, and objects are not allowed)',
      );
    } else if (val is bool) {
      stringVal = val ? 'true' : 'false';
    } else if (val is num) {
      stringVal = json.encode(val);
    } else if (val is String) {
      stringVal = val;
    } else {
      throw FormatException(
        "$filePath: define key '$key' has unsupported value type "
        '(null, arrays, and objects are not allowed)',
      );
    }
    _validateValue(key, stringVal, filePath);
    entries.add(MapEntry<String, String>(key, stringVal));
  }
  return entries;
}

/// Parses a `.env` file and returns its define entries.
List<MapEntry<String, String>> _parseEnvFile(
  String filePath,
  String content,
  Map<String, String> keyOrigin,
) {
  final List<String> lines = content.split(RegExp(r'\r?\n'));
  final fileKeys = <String>{};
  final entries = <MapEntry<String, String>>[];

  for (var lineNo = 1; lineNo <= lines.length; lineNo++) {
    final String rawLine = lines[lineNo - 1];
    final String trimmed = rawLine.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) {
      continue;
    }
    final int eqIdx = rawLine.indexOf('=');
    if (eqIdx == -1) {
      throw FormatException(
        "$filePath:$lineNo: line has no '=' separator: '$rawLine'",
      );
    }
    final String key = rawLine.substring(0, eqIdx).trim();
    final String val = rawLine.substring(eqIdx + 1).trim();

    _validateKey(key, filePath);
    if (!fileKeys.add(key)) {
      throw FormatException(
        "$filePath: define key '$key' appears twice in $filePath",
      );
    }
    final String? previousFile = keyOrigin[key];
    if (previousFile != null) {
      throw FormatException(
        "$filePath: define key '$key' is defined in both $previousFile and $filePath",
      );
    }
    keyOrigin[key] = filePath;

    _validateValue(key, val, filePath);
    entries.add(MapEntry<String, String>(key, val));
  }
  return entries;
}

/// Parses all input files in [filePaths] in list order.
List<MapEntry<String, String>> _parseDefinesFiles(List<String> filePaths) {
  final entries = <MapEntry<String, String>>[];
  final keyOrigin = <String, String>{};

  for (final filePath in filePaths) {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('File not found', filePath);
    }
    final String content = file.readAsStringSync();
    if (filePath.endsWith('.json')) {
      entries.addAll(_parseJsonFile(filePath, content, keyOrigin));
    } else if (filePath.endsWith('.env')) {
      entries.addAll(_parseEnvFile(filePath, content, keyOrigin));
    } else {
      throw FormatException(
        '$filePath: unsupported file format (expected .json or .env)',
      );
    }
  }
  return entries;
}

/// Writes the flagfile to [outputPath], omitting [excludedKeys].
void _writeOutput(
  String outputPath,
  List<MapEntry<String, String>> entries,
  Set<String> excludedKeys,
) {
  final buffer = StringBuffer();
  for (final entry in entries) {
    if (excludedKeys.contains(entry.key)) {
      continue;
    }
    buffer.writeln('-D${entry.key}=${entry.value}');
  }
  final outFile = File(outputPath);
  outFile.parent.createSync(recursive: true);
  final tempFile = File(
    '$outputPath.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    tempFile.writeAsStringSync(buffer.toString());
    if (outFile.existsSync()) {
      outFile.deleteSync();
    }
    tempFile.renameSync(outputPath);
  } on Object {
    if (tempFile.existsSync()) {
      tempFile.deleteSync();
    }
    if (outFile.existsSync()) {
      outFile.deleteSync();
    }
    rethrow;
  }
}

/// Best-effort cleanup of an output file on error.
void _deleteOutputFile(String path) {
  try {
    final outFile = File(path);
    if (outFile.existsSync()) {
      outFile.deleteSync();
    }
  } on FileSystemException catch (e) {
    stderr.writeln(
      'Warning: failed to clean up output file $path: ${e.message}',
    );
  }
}

/// Executes the defines_files tool with [args].
///
/// Parses [args] for an output flag and input defines files (.json, .env),
/// resolves environment defines according to precedence, and writes a kernel
/// compile flagfile.
///
/// Returns 0 on success, non-zero on failure.
int run(List<String> args, {StringSink? errSink}) {
  final _DefinesFilesOptions options;
  try {
    options = _parseArgs(args);
  } on FormatException catch (e) {
    stderr.writeln('Error parsing arguments: ${e.message}');
    errSink?.writeln('Error parsing arguments: ${e.message}');
    return 1;
  }

  try {
    final List<MapEntry<String, String>> entries = _parseDefinesFiles(
      options.inputFiles,
    );
    _writeOutput(options.outputPath, entries, options.excludedKeys);
    return 0;
  } on FormatException catch (e) {
    _deleteOutputFile(options.outputPath);
    stderr.writeln('Error: ${e.message}');
    errSink?.writeln('Error: ${e.message}');
    return 1;
  } on FileSystemException catch (e) {
    _deleteOutputFile(options.outputPath);
    stderr.writeln('Error: ${e.message}');
    errSink?.writeln('Error: ${e.message}');
    return 1;
  } on Exception catch (e) {
    _deleteOutputFile(options.outputPath);
    stderr.writeln('Error: $e');
    errSink?.writeln('Error: $e');
    return 1;
  }
}

/// Main entry point for the defines_files command-line tool.
void main(List<String> args) {
  final int code = run(args);
  if (code != 0) {
    exitCode = code;
  }
}
