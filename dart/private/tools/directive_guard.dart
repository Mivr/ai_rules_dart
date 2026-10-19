// The one shared directive-URI check every Dart compile and analysis action
// runs: no directive spelling may read an undeclared host file.
//
// The Dart front end loads `file:` URIs straight off the host filesystem,
// outside every `--multi-root` (and outside the sandbox roots a spawn sees),
// so a planner that resolves such a URI to nothing and compiles anyway embeds
// undeclared bytes. Every tool that compiles or analyzes Dart sources — the
// modular kernel planner, the whole-program `gen_kernel` wrapper, the
// `dart compile js`/`wasm` runner, and the `dart analyze`/`dart fix` runners —
// rejects these URIs before the compiler runs, with a diagnostic naming the
// file, the directive and the URI.
//
// The prologue scanner and the directive-URI resolution moved here from
// `kernel_module.dart` unchanged, so every tool classifies exactly what the
// planner classifies. `scanAllDirectiveUris` collects the declared URI and
// every `if` alternative without evaluating conditions, for validators that
// have no VM library set: a `file:` spelling in any branch fails, whichever
// configuration would select it.

import 'dart:convert';
import 'dart:io';

/// The multi-root scheme every compile resolves its inputs through.
const defaultMultiRootPrefix = 'org-dartlang-root:///';

/// The path after `multiRootPrefix`, or null for any other URI.
String? _stripPrefix(String uri, String multiRootPrefix) {
  if (uri.startsWith(multiRootPrefix)) {
    return uri.substring(multiRootPrefix.length);
  }
  return null;
}

/// Decodes one raw URI path segment the way the front end does (RFC 3986): each
/// valid `%XX` escape becomes its byte (bytes together decode as UTF-8, either
/// hex case), while anything else — including a lone `%` — stays literal.
/// Decoding happens once: a `%` produced by decoding is never decoded again.
String decodeUriSegment(String segment) {
  if (!segment.contains('%')) return segment;
  final out = StringBuffer();
  final bytes = <int>[];
  void flush() {
    if (bytes.isEmpty) return;
    out.write(utf8.decode(bytes, allowMalformed: true));
    bytes.clear();
  }

  for (var i = 0; i < segment.length; i++) {
    final c = segment.codeUnitAt(i);
    if (c == 0x25 && i + 2 < segment.length) {
      final hex = int.tryParse(segment.substring(i + 1, i + 3), radix: 16);
      if (hex != null && hex >= 0 && hex <= 0xff) {
        bytes.add(hex);
        i += 2;
        continue;
      }
    }
    flush();
    out.writeCharCode(c);
  }
  flush();
  return out.toString();
}

/// The segments of the longest [packageDirs] directory holding `fromKey`, or
/// the empty list when no package holds it (an unpackaged file).
List<String> _packageDirOf(String fromKey, Map<String, String> packageDirs) {
  var best = const <String>[];
  for (final dir in packageDirs.values) {
    if (dir.isEmpty) continue;
    if (fromKey == dir || fromKey.startsWith('$dir/')) {
      final segs = dir.split('/');
      if (segs.length > best.length) best = segs;
    }
  }
  return best;
}

/// Applies the segments of a directive path onto [base]: empty and `.` segments
/// are dropped, each `..` pops while deeper than [floor], and a decoded `/`
/// (`%2F`) names no file, since no file can be read through it. Above [floor],
/// `..` either fails ([failAboveFloor], for `package:` URIs, where the front
/// end reports leaving the package) or is dropped (relative and absolute URIs,
/// which the front end clamps to the package directory or the multi-root).
String? _resolveDirectivePath(
  String path,
  List<String> base,
  int floor,
  bool failAboveFloor,
) {
  final stack = base.toList();
  for (final raw in path.split('/')) {
    if (raw.isEmpty) continue;
    final seg = decodeUriSegment(raw);
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (stack.length > floor) {
        stack.removeLast();
      } else if (failAboveFloor) {
        return null;
      }
      continue;
    }
    if (seg.contains('/')) return null;
    stack.add(seg);
  }
  return stack.join('/');
}

/// The key a directive URI (`import`, `export`, `part`, `part of`) in the file
/// named `fromKey` refers to: the key of the file the front end reads.
///
/// `packageDirs` maps each package name to its directory key (`pkg/lib`).
/// [multiRootPrefix] is the scheme the absolute URIs of multi-root files start
/// with (`org-dartlang-root:///`). Null when the URI names no workspace file:
/// an unknown package or scheme, an escape above a `package:` directory, a
/// query, a fragment, an authority, or a decoded `/`.
///
/// The resolution mirrors the front end exactly: `\` is a separator everywhere,
/// escapes decode once (either hex case), `/`-absolute URIs resolve against the
/// importer's package directory (unpackaged files against the multi-root), and
/// relative URIs against the importer's directory, clamped so `..` never leaves
/// the package directory.
String? resolveDirectiveUri(
  String uri,
  String fromKey,
  Map<String, String> packageDirs, {
  String multiRootPrefix = defaultMultiRootPrefix,
}) {
  final text = uri.contains(r'\') ? uri.replaceAll(r'\', '/') : uri;
  final absolute = _stripPrefix(text, multiRootPrefix);
  if (absolute != null) {
    return _resolveDirectivePath(absolute, const [], 0, false);
  }
  if (text.startsWith('package:')) {
    final rest = text.substring('package:'.length);
    if (rest.contains('?') || rest.contains('#')) return null;
    final slash = rest.indexOf('/');
    if (slash <= 0) return null;
    final dir = packageDirs[rest.substring(0, slash)];
    if (dir == null) return null;
    final base = dir.isEmpty ? const <String>[] : dir.split('/');
    return _resolveDirectivePath(
      rest.substring(slash + 1),
      base,
      base.length,
      true,
    );
  }
  if (text.contains(':')) return null;
  if (text.contains('?') || text.contains('#') || text.startsWith('//')) {
    return null;
  }
  if (text.startsWith('/')) {
    final base = _packageDirOf(fromKey, packageDirs);
    return _resolveDirectivePath(text, base, base.length, false);
  }
  final slash = fromKey.lastIndexOf('/');
  final base = slash < 0
      ? const <String>[]
      : fromKey.substring(0, slash).split('/');
  final floor = _packageDirOf(fromKey, packageDirs).length;
  return _resolveDirectivePath(text, base, floor, false);
}

/// One URI-bearing directive of a source's prologue.
class ScanRef {
  const ScanRef(this.kind, this.uri);

  /// `import`, `export`, `part` or `part of`.
  final String kind;

  /// The URI. A configurable import gives the alternative it takes for the VM.
  final String uri;

  bool get isPart => kind == 'part';

  bool get isPartOf => kind == 'part of';
}

/// The directives of a source's prologue.
class ScanResult {
  const ScanResult(this.refs, {this.libraryName, this.partOfLibrary});

  final List<ScanRef> refs;

  /// The name from `library <name>;`, when declared.
  final String? libraryName;

  /// The library name from `part of <name>;`, when a part names its library by
  /// identifier rather than URI.
  final String? partOfLibrary;
}

/// The directives in the prologue of a Dart source, or null when the prologue has a
/// form this scanner does not read.
ScanResult? scanDirectives(String source, Set<String> vmLibraries) {
  try {
    return _Prologue(_Lexer(source), vmLibraries).parse();
  } on _Unparsable {
    return null;
  }
}

class _Unparsable implements Exception {
  const _Unparsable();
}

const _identKind = 0;
const _stringKind = 1;
const _punctKind = 2;
const _otherKind = 3;

class _Token {
  const _Token(this.kind, this.text, {this.raw = false});

  final int kind;
  final String text;
  final bool raw;
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isIdentStart(int c) =>
    (c >= 0x41 && c <= 0x5a) ||
    (c >= 0x61 && c <= 0x7a) ||
    c == 0x5f ||
    c == 0x24 ||
    c >= 0x80;

bool _isIdentChar(int c) => _isIdentStart(c) || _isDigit(c);

int _skipLine(String src, int start) {
  var at = start;
  while (at < src.length && src[at] != '\n' && src[at] != '\r') {
    at++;
  }
  return at;
}

/// The index just past the block comment that starts at `start`. Dart block
/// comments nest.
int _skipBlockComment(String src, int start) {
  var depth = 0;
  var at = start;
  while (at < src.length) {
    if (src.startsWith('/*', at)) {
      depth++;
      at += 2;
    } else if (src.startsWith('*/', at)) {
      depth--;
      at += 2;
      if (depth == 0) return at;
    } else {
      at++;
    }
  }
  throw const _Unparsable();
}

String _unescape(String s) {
  if (!s.contains('\\')) return s;
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final ch = s[i++];
    if (ch != '\\') {
      out.write(ch);
      continue;
    }
    if (i >= s.length) throw const _Unparsable();
    final esc = s[i++];
    switch (esc) {
      case 'n':
        out.write('\n');
      case 'r':
        out.write('\r');
      case 'f':
        out.write('\f');
      case 'b':
        out.write('\b');
      case 't':
        out.write('\t');
      case 'v':
        out.write('\v');
      case 'x':
        if (i + 2 > s.length) throw const _Unparsable();
        final code = int.tryParse(s.substring(i, i + 2), radix: 16);
        if (code == null) throw const _Unparsable();
        out.writeCharCode(code);
        i += 2;
      case 'u':
        if (i < s.length && s[i] == '{') {
          final close = s.indexOf('}', i + 1);
          if (close < 0) throw const _Unparsable();
          final code = int.tryParse(s.substring(i + 1, close), radix: 16);
          if (code == null || code < 0 || code > 0x10FFFF) {
            throw const _Unparsable();
          }
          out.writeCharCode(code);
          i = close + 1;
        } else {
          if (i + 4 > s.length) throw const _Unparsable();
          final code = int.tryParse(s.substring(i, i + 4), radix: 16);
          if (code == null) throw const _Unparsable();
          out.writeCharCode(code);
          i += 4;
        }
      default:
        out.write(esc);
    }
  }
  return out.toString();
}

/// Reads the tokens of a Dart source one at a time, so a scan that stops at the end
/// of the directives never reads the rest of the file.
class _Lexer {
  _Lexer(this._src);

  final String _src;
  var _at = 0;
  _Token? _ahead;

  _Token? peek() => _ahead ??= _scan();

  _Token? take() {
    final token = peek();
    _ahead = null;
    return token;
  }

  _Token? _scan() {
    final src = _src;
    final n = src.length;
    if (_at == 0) {
      if (src.startsWith('\uFEFF')) _at++;
      if (src.startsWith('#!', _at)) {
        _at = _skipLine(src, _at + 2);
      }
    }
    while (_at < n) {
      final ch = src[_at];
      if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
        _at++;
        continue;
      }
      if (ch == '/' && _at + 1 < n && src[_at + 1] == '/') {
        _at = _skipLine(src, _at + 2);
        continue;
      }
      if (ch == '/' && _at + 1 < n && src[_at + 1] == '*') {
        _at = _skipBlockComment(src, _at);
        continue;
      }
      final code = ch.codeUnitAt(0);
      if (_isIdentStart(code)) {
        final start = _at;
        while (_at < n && _isIdentChar(src.codeUnitAt(_at))) {
          _at++;
        }
        final word = src.substring(start, _at);
        if (word == 'r' && _at < n && (src[_at] == "'" || src[_at] == '"')) {
          return _string(raw: true);
        }
        return _Token(_identKind, word);
      }
      if (_isDigit(code)) {
        final start = _at;
        while (_at < n && _isIdentChar(src.codeUnitAt(_at))) {
          _at++;
        }
        return _Token(_otherKind, src.substring(start, _at));
      }
      if (ch == "'" || ch == '"') return _string(raw: false);
      _at++;
      return _Token(_punctKind, ch);
    }
    return null;
  }

  /// The string literal at `_at`, with its quotes removed and its escapes kept.
  _Token _string({required bool raw}) {
    final src = _src;
    final quote = src[_at];
    final triple = src.startsWith(quote * 3, _at);
    final delim = triple ? quote * 3 : quote;
    var contentStart = _at + delim.length;
    final endQuote = _skipString(_at, raw: raw);
    final contentEnd = endQuote - delim.length;
    if (triple && contentStart < contentEnd) {
      if (src.startsWith('\r\n', contentStart)) {
        contentStart += 2;
      } else if (src[contentStart] == '\n' || src[contentStart] == '\r') {
        contentStart += 1;
      }
    }
    _at = endQuote;
    return _Token(
      _stringKind,
      src.substring(contentStart, contentEnd),
      raw: raw,
    );
  }

  /// The index just past the string literal that starts at `quoteAt`.
  int _skipString(int quoteAt, {required bool raw}) {
    final src = _src;
    final n = src.length;
    final quote = src[quoteAt];
    final triple = src.startsWith(quote * 3, quoteAt);
    final delim = triple ? quote * 3 : quote;
    var at = quoteAt + delim.length;
    while (true) {
      if (at >= n) throw const _Unparsable();
      if (!raw && src[at] == '\\') {
        if (at + 1 >= n) throw const _Unparsable();
        at += 2;
        continue;
      }
      if (!raw && src.startsWith(r'${', at)) {
        at = _skipInterpolation(at + 2);
        continue;
      }
      if (src.startsWith(delim, at)) {
        return at + delim.length;
      }
      if (!triple && (src[at] == '\n' || src[at] == '\r')) {
        throw const _Unparsable();
      }
      at++;
    }
  }

  /// The index just past the `}` that closes a `${...}` string interpolation
  /// whose body starts at `start`.
  int _skipInterpolation(int start) {
    final src = _src;
    final n = src.length;
    var at = start;
    var depth = 1;
    while (at < n) {
      final ch = src[at];
      if (ch == '/' && at + 1 < n && src[at + 1] == '/') {
        at = _skipLine(src, at + 2);
        continue;
      }
      if (ch == '/' && at + 1 < n && src[at + 1] == '*') {
        at = _skipBlockComment(src, at);
        continue;
      }
      final code = ch.codeUnitAt(0);
      if (_isIdentStart(code) || _isDigit(code)) {
        final wordStart = at;
        while (at < n && _isIdentChar(src.codeUnitAt(at))) {
          at++;
        }
        if (at - wordStart == 1 &&
            src[wordStart] == 'r' &&
            at < n &&
            (src[at] == "'" || src[at] == '"')) {
          at = _skipString(at, raw: true);
        }
        continue;
      }
      if (ch == "'" || ch == '"') {
        at = _skipString(at, raw: false);
        continue;
      }
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) return at + 1;
      }
      at++;
    }
    throw const _Unparsable();
  }
}

/// Reads the directive prologue: `library`, `import`, `export`, `part` and `part
/// of`, with the annotations before them. The first other token ends it.
class _Prologue {
  _Prologue(this._lexer, this._vm, {this.collectAll = false});

  final _Lexer _lexer;
  final Set<String> _vm;

  /// When true, every URI of an `import` or `export` directive is collected:
  /// the declared URI and each `if` alternative, without evaluating which one
  /// the configuration selects. Validators without the VM library set use this
  /// so no spelling of a disallowed scheme hides in an unselected branch.
  final bool collectAll;

  _Token? _peek() => _lexer.peek();

  _Token _take() {
    final token = _lexer.take();
    if (token == null) throw const _Unparsable();
    return token;
  }

  bool _is(String text, int kind) {
    final token = _peek();
    return token != null && token.kind == kind && token.text == text;
  }

  bool _ident(String text) => _is(text, _identKind);

  bool _punct(String text) => _is(text, _punctKind);

  void _expect(String text) {
    if (!_punct(text)) throw const _Unparsable();
    _lexer.take();
  }

  /// Consumes up to and including `text`.
  void _skipPast(String text) {
    while (!_punct(text)) {
      _take();
    }
    _lexer.take();
  }

  void _identToken() {
    if (_take().kind != _identKind) throw const _Unparsable();
  }

  /// A dotted identifier such as `foo` or `foo.bar.baz`.
  String _dottedIdent() {
    final first = _take();
    if (first.kind != _identKind) throw const _Unparsable();
    final out = StringBuffer(first.text);
    while (_punct('.')) {
      _lexer.take();
      final next = _take();
      if (next.kind != _identKind) throw const _Unparsable();
      out
        ..write('.')
        ..write(next.text);
    }
    return out.toString();
  }

  /// Adjacent string literals are one URI.
  String _string() {
    final token = _take();
    if (token.kind != _stringKind) throw const _Unparsable();
    final out = StringBuffer(token.raw ? token.text : _unescape(token.text));
    while (_peek()?.kind == _stringKind) {
      final next = _take();
      out.write(next.raw ? next.text : _unescape(next.text));
    }
    return out.toString();
  }

  /// `@name`, `@name.name`, `@name<...>(...)`, or `@name<...>.name(...)`.
  void _annotation() {
    _expect('@');
    _identToken();
    while (_punct('.')) {
      _lexer.take();
      _identToken();
    }
    if (_punct('<')) {
      var depth = 0;
      do {
        final token = _take();
        if (token.kind == _punctKind && token.text == '<') depth++;
        if (token.kind == _punctKind && token.text == '>') depth--;
      } while (depth > 0);
      while (_punct('.')) {
        _lexer.take();
        _identToken();
      }
    }
    if (_punct('(')) {
      var depth = 0;
      do {
        final token = _take();
        if (token.kind == _punctKind && token.text == '(') depth++;
        if (token.kind == _punctKind && token.text == ')') depth--;
      } while (depth > 0);
    }
  }

  /// The `if (...)` test of a configurable import, after its `(`, through its `)`.
  /// True when it holds for the VM. In CFE's configurable-import environment,
  /// available SDK libraries are mapped to `'true'` and all other names are
  /// unspecified (matching only `== ''`).
  bool _condition() {
    final text = _dottedIdent();
    String? value;
    if (_punct('=')) {
      _lexer.take();
      _expect('=');
      value = _string();
    }
    _expect(')');
    const prefix = 'dart.library.';
    if (text.startsWith(prefix)) {
      final present = _vm.contains(text.substring(prefix.length));
      if (!present) return false;
      return value == null || value == 'true';
    }
    return value == '';
  }

  /// `import` or `export` after its keyword: the URI, then any `if`
  /// alternatives, then the rest of the directive, which names nothing to read.
  ScanRef _uriDirective(String kind, List<ScanRef> refs) {
    final declared = _string();
    if (collectAll) refs.add(ScanRef(kind, declared));
    var chosen = declared;
    var picked = false;
    while (_ident('if')) {
      _lexer.take();
      _expect('(');
      final holds = _condition();
      final alternative = _string();
      if (collectAll) refs.add(ScanRef(kind, alternative));
      if (holds && !picked) {
        chosen = alternative;
        picked = true;
      }
    }
    _skipPast(';');
    return ScanRef(kind, chosen);
  }

  ScanResult parse() {
    final refs = <ScanRef>[];
    String? libraryName;
    String? partOfLibrary;
    while (true) {
      final token = _peek();
      if (token == null) break;
      if (token.kind == _punctKind && token.text == '@') {
        _annotation();
        continue;
      }
      if (token.kind != _identKind) break;
      if (token.text == 'library') {
        _lexer.take();
        if (_punct(';')) {
          _lexer.take();
        } else if (_peek()?.kind == _identKind) {
          libraryName ??= _dottedIdent();
          _expect(';');
        } else {
          break;
        }
      } else if (token.text == 'import' || token.text == 'export') {
        _lexer.take();
        if (_peek()?.kind != _stringKind) break;
        final ref = _uriDirective(token.text, refs);
        if (!collectAll) refs.add(ref);
      } else if (token.text == 'part') {
        _lexer.take();
        if (_ident('of')) {
          _lexer.take();
          if (_peek()?.kind == _stringKind) {
            refs.add(ScanRef('part of', _string()));
          } else {
            partOfLibrary ??= _dottedIdent();
          }
          _expect(';');
        } else if (_peek()?.kind == _stringKind) {
          refs.add(ScanRef('part', _string()));
          _expect(';');
        } else {
          break;
        }
      } else {
        break;
      }
    }
    return ScanResult(
      refs,
      libraryName: libraryName,
      partOfLibrary: partOfLibrary,
    );
  }
}

/// Whether `uri` is a `file:` URI in any spelling: any letter case, any
/// authority (`file://localhost/`), a bare path (`file:x.dart`), backslash
/// separators, or a query or fragment suffix. The front end reads all of these
/// off the host filesystem, outside every multi-root.
bool isFileSchemeDirectiveUri(String uri) {
  final colon = uri.indexOf(':');
  if (colon != 4) return false;
  const scheme = 'file';
  for (var i = 0; i < 4; i++) {
    var c = uri.codeUnitAt(i);
    if (c >= 0x41 && c <= 0x5A) c += 0x20;
    if (c != scheme.codeUnitAt(i)) return false;
  }
  return true;
}

bool _isSchemeStart(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

bool _isSchemeChar(int c) =>
    _isSchemeStart(c) ||
    (c >= 0x30 && c <= 0x39) ||
    c == 0x2B ||
    c == 0x2D ||
    c == 0x2E;

/// Whether an `import` or `export` directive URI must fail the build: it names
/// no file the action can read through its declared inputs. That is a `file:`
/// URI in any spelling, or any other URI scheme but `dart:`, `package:` and
/// the multi-root scheme. `dart:` libraries are checked against the VM set and
/// `package:` URIs against the package config by the caller; relative URIs
/// resolve through the declared inputs (or fail as undeclared) by the caller.
bool isDisallowedDirectiveUri(
  String uri, {
  String multiRootPrefix = defaultMultiRootPrefix,
}) {
  if (uri.startsWith(multiRootPrefix)) return false;
  if (uri.startsWith('package:') || uri.startsWith('dart:')) return false;
  if (isFileSchemeDirectiveUri(uri)) return true;
  final colon = uri.indexOf(':');
  if (colon <= 0) return false;
  if (!_isSchemeStart(uri.codeUnitAt(0))) return false;
  for (var i = 1; i < colon; i++) {
    if (!_isSchemeChar(uri.codeUnitAt(i))) return false;
  }
  return true;
}

/// Every URI-bearing directive of a source's prologue: each `import` and
/// `export` contributes its declared URI and every `if` alternative, each
/// `part` and `part of` its URI. Conditions are not evaluated, so no VM
/// library set is needed. An empty list when the prologue does not scan (the
/// compiler then reports the genuine syntax error).
List<ScanRef> scanAllDirectiveUris(String source) {
  try {
    return _Prologue(_Lexer(source), const {}, collectAll: true).parse().refs;
  } on _Unparsable {
    return const [];
  }
}

/// The diagnostics for every disallowed-scheme directive URI in `fileContents`
/// (display path to source text), in path order. Empty when clean. Each names
/// the file, the directive and the URI.
List<String> findDisallowedDirectives(
  Map<String, String> fileContents, {
  String tool = 'dart',
  String multiRootPrefix = defaultMultiRootPrefix,
}) {
  final errors = <String>[];
  final paths = fileContents.keys.toList()..sort();
  for (final path in paths) {
    final content = fileContents[path];
    if (content == null) continue;
    for (final ref in scanAllDirectiveUris(content)) {
      final disallowed = ref.isPart || ref.isPartOf
          ? isFileSchemeDirectiveUri(ref.uri)
          : isDisallowedDirectiveUri(ref.uri, multiRootPrefix: multiRootPrefix);
      if (disallowed) {
        errors.add(
          "$tool: $path ${ref.kind} '${ref.uri}' is not a declared input.",
        );
      }
    }
  }
  return errors;
}

/// The contents of every `.dart` file under [roots], keyed by path, skipping
/// directories that do not exist and files that vanish or do not decode: the
/// compiler reports those itself. Synchronous for the sync build-action
/// runners, which validate their staged sources before invoking the compiler.
Map<String, String> readStagedDartSources(Iterable<String> roots) {
  final contents = <String, String>{};
  for (final root in roots) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      try {
        contents[entity.path] = entity.readAsStringSync();
      } on FileSystemException {
        // Gone between listing and reading; the compiler reports it.
      } on FormatException {
        // Not decodable text; the compiler reports it.
      }
    }
  }
  return contents;
}

/// The diagnostics for every disallowed-scheme directive URI in the `.dart`
/// files under [roots], in path order. Empty when clean. The one shared
/// staged-source check: the web, analyze and fix runners refuse these files
/// before the compiler or analyzer can read the host through them.
List<String> findDisallowedStagedDirectives(
  Iterable<String> roots, {
  required String tool,
  String multiRootPrefix = defaultMultiRootPrefix,
}) {
  return findDisallowedDirectives(
    readStagedDartSources(roots),
    tool: tool,
    multiRootPrefix: multiRootPrefix,
  );
}
