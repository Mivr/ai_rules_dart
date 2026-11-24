/// A small line-based reader for the facts a `.bzl` source gives that the
/// `ModuleInfo` extract does not: whether a function returns a value, what a
/// private function's docstring says, the module docstring of every file in a
/// load closure, and the `load()` edges that define that closure.
library;

import 'package:doc_check/stardoc_model.dart';

/// A top-level `def` read from source.
class SourceDef {
  /// Creates a definition record.
  const new({
    required this.function,
    required this.returnsValue,
    required this.structured,
  });

  /// The def with its docstring split into summary, parameters and returns.
  final FunctionDoc function;

  /// Whether the docstring has an `Args:` or `Returns:` section.
  final bool structured;

  /// Whether some `return` of the body (nested defs excluded) yields a value.
  final bool returnsValue;
}

/// One parsed `.bzl` file.
class SourceFile {
  /// Creates a parsed file.
  const new({
    required this.label,
    required this.hasModuleDoc,
    required this.defs,
    required this.loads,
  });

  /// Parses [text], the content of the file labelled [label].
  factory parse(String label, String text) {
    final List<String> lines = text.split('\n');
    return SourceFile(
      label: label,
      hasModuleDoc: _moduleDoc(lines).trim().isNotEmpty,
      defs: _scanDefs(label, lines),
      loads: _loadLabels(label, text),
    );
  }

  /// The file's label, e.g. `//dart:defs.bzl`.
  final String label;

  /// Whether the file opens with a non-empty docstring.
  final bool hasModuleDoc;

  /// Top-level definitions by name.
  final List<SourceDef> defs;

  /// Absolute labels of the files this one `load()`s from this repository.
  final List<String> loads;
}

/// The docstring text of the first statement in [lines], or empty.
String _moduleDoc(List<String> lines) {
  for (var i = 0; i < lines.length; i++) {
    final String t = lines[i].trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    return _stringAt(lines, i)?.text ?? '';
  }
  return '';
}

/// A string literal that starts a line and the index of its last line.
class _Literal {
  const new(this.text, this.lastLine);

  final String text;
  final int lastLine;
}

_Literal? _stringAt(List<String> lines, int index) {
  String t = lines[index].trim();
  if (t.startsWith('r')) t = t.substring(1);
  for (final quote in const ['"""', "'''"]) {
    if (t.startsWith(quote)) return _tripleAt(lines, index, t, quote);
  }
  for (final quote in const ['"', "'"]) {
    if (t.startsWith(quote)) {
      final int end = _closing(t, quote, 1);
      return _Literal(end < 0 ? '' : t.substring(1, end), index);
    }
  }
  return null;
}

_Literal _tripleAt(List<String> lines, int index, String first, String quote) {
  final buffer = StringBuffer();
  String rest = first.substring(3);
  var i = index;
  while (true) {
    final int end = rest.indexOf(quote);
    if (end >= 0) {
      buffer.write(rest.substring(0, end));
      return _Literal(buffer.toString(), i);
    }
    buffer.writeln(rest);
    i++;
    if (i >= lines.length) return _Literal(buffer.toString(), lines.length - 1);
    rest = lines[i];
  }
}

int _closing(String text, String quote, int from) {
  for (var i = from; i < text.length; i++) {
    if (text[i] == r'\') {
      i++;
    } else if (text.startsWith(quote, i)) {
      return i;
    }
  }
  return -1;
}

final _loadPattern = RegExp(r'''^load\(\s*["']([^"']+)["']''', multiLine: true);

List<String> _loadLabels(String label, String text) {
  final String package = label.substring(0, label.indexOf(':'));
  final result = <String>[];
  for (final RegExpMatch match in _loadPattern.allMatches(text)) {
    final String target = match.group(1)!;
    if (target.startsWith('//')) {
      result.add(target);
    } else if (target.startsWith(':')) {
      result.add('$package$target');
    }
  }
  return result;
}

List<SourceDef> _scanDefs(String label, List<String> lines) {
  final defs = <SourceDef>[];
  var i = 0;
  while (i < lines.length) {
    if (!lines[i].startsWith('def ')) {
      i++;
      continue;
    }
    final int signatureEnd = _signatureEnd(lines, i);
    int end = signatureEnd + 1;
    while (end < lines.length && _continuesBody(lines[end])) {
      end++;
    }
    defs.add(
      _readDef(
        label,
        lines.sublist(i, signatureEnd + 1).join('\n'),
        lines.sublist(signatureEnd + 1, end),
      ),
    );
    i = end;
  }
  return defs;
}

bool _continuesBody(String line) {
  if (line.trim().isEmpty) return true;
  return line.startsWith(' ') || line.startsWith('\t') || line.startsWith('#');
}

/// The index of the line that ends the `def` signature starting at [from].
int _signatureEnd(List<String> lines, int from) {
  var depth = 0;
  for (var i = from; i < lines.length; i++) {
    depth += _lineDepth(lines[i]);
    if (depth <= 0) return i;
  }
  return lines.length - 1;
}

/// The net bracket depth change of [line], ignoring strings and comments.
int _lineDepth(String line) {
  var depth = 0;
  for (var c = 0; c < line.length; c++) {
    if (line[c] == '#') break;
    final int next = _skipQuoted(line, c);
    if (next < 0) break;
    c = next;
    depth += _depthChange(line[c]);
  }
  return depth;
}

int _depthChange(String ch) {
  if ('([{'.contains(ch)) return 1;
  return ')]}'.contains(ch) ? -1 : 0;
}

/// The index of the closing quote when a string starts at [at], [at] itself
/// when no string does, and -1 when the string never closes.
int _skipQuoted(String text, int at) {
  final String ch = text[at];
  if (ch != '"' && ch != "'") return at;
  return _closing(text, ch, at + 1);
}

SourceDef _readDef(String label, String signature, List<String> body) {
  final String name = RegExp(r'def\s+(\w+)').firstMatch(signature)!.group(1)!;
  var docLines = 0;
  var doc = '';
  for (var i = 0; i < body.length; i++) {
    final String t = body[i].trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    final _Literal? literal = _stringAt(body, i);
    if (literal != null) {
      doc = literal.text;
      docLines = literal.lastLine + 1;
    }
    break;
  }
  final sections = _Sections.parse(doc);
  final List<_Param> params = _parameters(signature);
  return SourceDef(
    function: FunctionDoc(
      name: name,
      doc: sections.summary,
      params: [
        for (final p in params)
          ParamDoc(
            name: p.name,
            doc: sections.args[p.name] ?? '',
            defaultValue: p.defaultValue,
            mandatory: p.defaultValue.isEmpty,
            role: p.role,
          ),
      ],
      returnDoc: sections.returns,
      origin: OriginKey(name, label),
    ),
    returnsValue: _returnsValue(body.sublist(docLines)),
    structured: _structured.hasMatch(doc),
  );
}

final RegExp _structured = RegExp(r'^\s*(Args|Returns):\s*$', multiLine: true);

/// A docstring split at its section headers.
class _Sections {
  const new(this.summary, this.args, this.returns);

  factory parse(String doc) {
    final summary = <String>[];
    final returns = <String>[];
    final args = _ArgsReader();
    var section = '';
    for (final String line in doc.split('\n')) {
      final RegExpMatch? header = _header.firstMatch(line);
      if (header != null) {
        section = header.group(1)!;
        args.restart();
      } else if (section.isEmpty) {
        summary.add(line);
      } else if (section == 'Returns') {
        returns.add(line.trim());
      } else if (section == 'Args') {
        args.add(line);
      }
    }
    return _Sections(
      _squash(summary.join(' ')),
      args.entries,
      _squash(returns.join(' ')),
    );
  }

  final String summary;
  final Map<String, String> args;
  final String returns;
}

final RegExp _header = RegExp(r'^\s*([A-Z][A-Za-z ]*):\s*$');

final RegExp _argEntry = RegExp(r'^\s*\*{0,2}(\w+)\s*(?:\([^)]*\))?:\s*(.*)$');

/// Collects the `name: text` entries of an `Args:` section, joining the
/// wrapped continuation lines of each entry to its text.
class _ArgsReader {
  final Map<String, String> entries = {};
  int? _entryIndent;
  String? _current;

  /// Forgets the entry indentation when a new section starts.
  void restart() {
    _entryIndent = null;
    _current = null;
  }

  void add(String line) {
    final String text = line.trim();
    final int indent = line.length - line.trimLeft().length;
    if (text.isNotEmpty) _entryIndent ??= indent;
    final RegExpMatch? item = _argEntry.firstMatch(line);
    final String? current = _current;
    if (item != null && indent == _entryIndent) {
      final String name = item.group(1)!;
      _current = name;
      entries[name] = item.group(2)!.trim();
    } else if (current != null && text.isNotEmpty) {
      entries[current] = '${entries[current]} $text'.trim();
    }
  }
}

class _Param {
  const new(this.name, this.defaultValue, this.role);

  final String name;
  final String defaultValue;
  final int role;
}

List<_Param> _parameters(String signature) {
  final int open = signature.indexOf('(');
  var depth = 0;
  int start = open + 1;
  final parts = <String>[];
  for (var i = open; i < signature.length; i++) {
    final int next = _skipQuoted(signature, i);
    if (next < 0) break;
    i = next;
    depth += _depthChange(signature[i]);
    if (depth == 0 || (signature[i] == ',' && depth == 1)) {
      parts.add(signature.substring(start, i));
      start = i + 1;
      if (depth == 0) break;
    }
  }
  return [for (final part in parts) ?_param(part)];
}

_Param? _param(String part) {
  final String text = part
      .split('\n')
      .map((l) => l.contains('#') && !l.contains('"') ? l.split('#').first : l)
      .join(' ')
      .trim();
  final RegExpMatch? match = RegExp(
    r'^(\*{0,2})(\w+)\s*(?:=\s*(.*))?$',
    dotAll: true,
  ).firstMatch(text);
  if (match == null) return null;
  final int stars = match.group(1)!.length;
  return _Param(
    match.group(2)!,
    (match.group(3) ?? '').trim(),
    stars == 2 ? 5 : (stars == 1 ? 4 : 1),
  );
}

final _returnPattern = RegExp(r'(?:^|:\s*)return\b[ \t]*([^#\n]*)');

/// Whether [body] holds a `return <value>` outside any nested `def`.
bool _returnsValue(List<String> body) {
  var inTriple = false;
  int? nestedIndent;
  for (final line in body) {
    if (line.trim().isEmpty) continue;
    final int indent = line.length - line.trimLeft().length;
    if (inTriple) {
      if (line.contains('"""')) inTriple = false;
      continue;
    }
    if (nestedIndent != null) {
      if (indent > nestedIndent) continue;
      nestedIndent = null;
    }
    final String t = line.trim();
    if (t.startsWith('def ')) {
      nestedIndent = indent;
      continue;
    }
    if (t.startsWith('#')) continue;
    final String? value = _returnPattern.firstMatch(t)?.group(1)?.trim();
    if (value != null && value.isNotEmpty && value != 'None') return true;
    if ('"""'.allMatches(t).length.isOdd) inTriple = true;
  }
  return false;
}

String _squash(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();
