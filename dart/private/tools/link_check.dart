// The `link_modules` check: refuses a closure that asks for `dart.library.mirrors`.
//
// An opted-in `exe` or `aot-snapshot` binary links per-library kernel modules,
// which compile against the JIT platform. Of every `dart.library.*` key the one
// that differs from the AOT answer is `dart.library.mirrors` (true on the JIT
// VM, false in AOT), so a linked binary would answer it wrongly and the front
// end's `dart:mirrors` diagnostic would be lost. This tool reads every `.dart`
// file of the closure and reports, as `<path>:<line>: <what>`:
//
//  * an `import` or `export` of `dart:mirrors`;
//  * `dart.library.mirrors` as the key of an `if (...)` configuration;
//  * that string in a `bool.fromEnvironment` call.
//
// No other `dart.library.*` key and not `dart.vm.product`. Comments are
// skipped. A name built at run time is out of reach. See
// `dart/private/dart_link_check.bzl`.
//
// Usage:
//   link_check --label <label> [--src <file-or-dir>]... --output <stamp>
//
// The tool reads `expandSource` from `import_check.dart` through `srcs`, so the
// relative import reaches it with no package edge.

import 'dart:convert';
import 'dart:io';

import 'import_check.dart' show expandSource;

const _tool = 'link_check';

/// One refused use: the file, its 1-based line and what was found.
typedef LinkHit = ({String path, int line, String what});

final RegExp _importRe = RegExp(
  r'''\b(import|export)\s+r?(['"])[dD][aA][rR][tT]:mirrors\2''',
);
final RegExp _conditionRe = RegExp(
  r'\bif\s*\(\s*dart\s*\.\s*library\s*\.\s*mirrors\b',
);
final RegExp _environmentRe = RegExp(
  r'''\bbool\s*\.\s*fromEnvironment\s*\(\s*r?(['"])dart\.library\.mirrors\1''',
);

/// A source with its comments blanked (same length, newlines kept) and the
/// spans of its string literals.
class MaskedSource {
  new(this.code, this.strings);

  final String code;
  final List<(int, int)> strings;

  /// Whether [offset] lies inside a string literal.
  bool inString(int offset) =>
      strings.any((span) => offset > span.$1 && offset < span.$2);

  /// The 1-based line of [offset].
  int lineOf(int offset) {
    var line = 1;
    for (var i = 0; i < offset && i < code.length; i++) {
      if (code.codeUnitAt(i) == 0x0a) line++;
    }
    return line;
  }
}

/// Lexes [source] just enough to blank comments and find string literals.
MaskedSource maskSource(String source) {
  final lexer = _Lexer(source);
  lexer.code(0, nested: false);
  final blanked = StringBuffer();
  var from = 0;
  for (final (int start, int end) in lexer.comments) {
    blanked.write(source.substring(from, start));
    blanked.write(
      source.substring(start, end).replaceAll(RegExp(r'[^\n]'), ' '),
    );
    from = end;
  }
  blanked.write(source.substring(from));
  return MaskedSource(blanked.toString(), lexer.strings);
}

class _Lexer {
  new(this.s);

  final String s;
  final List<(int, int)> comments = [];
  final List<(int, int)> strings = [];

  bool _at(String text, int i) => s.startsWith(text, i);

  /// Scans code from `from`; a nested scan (a `${...}` interpolation) stops after
  /// its closing brace. Returns the index after what it consumed.
  int code(int from, {required bool nested}) {
    var i = from;
    var depth = 0;
    while (i < s.length) {
      final String c = s[i];
      if (_at('//', i)) {
        i = _record(comments, i, _lineEnd(i), nested);
      } else if (_at('/*', i)) {
        i = _record(comments, i, _blockEnd(i), nested);
      } else if (c == "'" || c == '"') {
        i = _record(strings, i, _string(i, raw: _isRawPrefix(i)), nested);
      } else if (nested && c == '}' && depth == 0) {
        return i + 1;
      } else {
        if (nested && c == '{') depth++;
        if (nested && c == '}') depth--;
        i++;
      }
    }
    return i;
  }

  int _record(List<(int, int)> into, int start, int end, bool nested) {
    if (!nested) into.add((start, end));
    return end;
  }

  bool _isRawPrefix(int i) =>
      i > 0 &&
      s[i - 1] == 'r' &&
      (i < 2 || !RegExp(r'[A-Za-z0-9_$]').hasMatch(s[i - 2]));

  int _lineEnd(int i) {
    final int end = s.indexOf('\n', i);
    return end < 0 ? s.length : end;
  }

  /// The end of the (nested) block comment starting at `from`.
  int _blockEnd(int from) {
    var i = from;
    var depth = 0;
    while (i < s.length) {
      if (_at('/*', i)) {
        depth++;
        i += 2;
      } else if (_at('*/', i)) {
        depth--;
        i += 2;
        if (depth == 0) return i;
      } else {
        i++;
      }
    }
    return s.length;
  }

  /// The end of the string literal whose opening quote is at [start].
  int _string(int start, {required bool raw}) {
    final String q = s[start];
    final bool triple = _at(q * 3, start);
    int i = start + (triple ? 3 : 1);
    while (i < s.length) {
      final String c = s[i];
      if (c == r'\' && !raw) {
        i += 2;
      } else if (c == r'$' && !raw && _at('{', i + 1)) {
        i = code(i + 2, nested: true);
      } else if (c == q && (!triple || _at(q * 3, i))) {
        return i + (triple ? 3 : 1);
      } else if (c == '\n' && !triple) {
        return i;
      } else {
        i++;
      }
    }
    return s.length;
  }
}

/// Every refused use in [source], the file shown as [path], in source order.
List<LinkHit> findMirrorsUses(String path, String source) {
  final MaskedSource masked = maskSource(source);
  final List<(int, String)> found = [
    for (final RegExpMatch m in _importRe.allMatches(masked.code))
      (m.start, '${m.group(1)}s dart:mirrors'),
    for (final RegExpMatch m in _conditionRe.allMatches(masked.code))
      (m.start, 'dart.library.mirrors is a configuration key'),
    for (final RegExpMatch m in _environmentRe.allMatches(masked.code))
      (m.start, "bool.fromEnvironment('dart.library.mirrors')"),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return [
    for (final (int offset, String what) in found)
      if (!masked.inString(offset))
        (path: path, line: masked.lineOf(offset), what: what),
  ];
}

/// The `<path>:<line>: <what>` line of [hit].
String hitLine(LinkHit hit) => '${hit.path}:${hit.line}: ${hit.what}';

/// The line that names [label] and the way out, after [count] hits.
String summaryLine(String label, int count) =>
    '$label: link_modules = True refuses the $count use(s) of dart:mirrors '
    'or dart.library.mirrors above: a module compiles against the JIT platform '
    'and answers that key differently from an AOT build. Unset link_modules '
    'on $label to compile from sources.';

/// The parsed command line.
typedef LinkCheckArgs = ({String label, String output, List<String> srcs});

/// Parses [argv]; throws a [FormatException] naming what is wrong.
LinkCheckArgs parseArgs(List<String> argv) {
  String? label;
  String? output;
  final List<String> srcs = [];
  for (var i = 0; i < argv.length; i++) {
    final String flag = argv[i];
    if (i + 1 >= argv.length) throw FormatException('$flag needs a value');
    final String value = argv[++i];
    switch (flag) {
      case '--label':
        label = value;
      case '--src':
        srcs.add(value);
      case '--output':
        output = value;
      default:
        throw FormatException('unknown flag $flag');
    }
  }
  if (label == null || output == null) {
    throw const FormatException('--label and --output are required');
  }
  return (label: label, output: output, srcs: srcs);
}

/// The sorted, deduplicated hit lines over every source of [args].
List<String> checkSources(LinkCheckArgs args) {
  final Set<String> files = {
    for (final String src in args.srcs) ...expandSource(src),
  };
  final lines = <String>{};
  for (final String file in files.toList()..sort()) {
    final String text = utf8.decode(
      File(file).readAsBytesSync(),
      allowMalformed: true,
    );
    lines.addAll(findMirrorsUses(file, text).map(hitLine));
  }
  return lines.toList();
}

int run(List<String> argv) {
  final LinkCheckArgs args;
  try {
    args = parseArgs(argv);
  } on FormatException catch (e) {
    stderr.writeln('$_tool: ${e.message}');
    return 64;
  }
  final List<String> lines = checkSources(args);
  if (lines.isNotEmpty) {
    stderr.writeln(lines.join('\n'));
    stderr.writeln(summaryLine(args.label, lines.length));
    return 1;
  }
  final out = File(args.output);
  out.parent.createSync(recursive: true);
  out.writeAsStringSync('');
  return 0;
}

void main(List<String> argv) {
  exitCode = run(argv);
}
