// The one shared directive-URI check every Dart compile and analysis action
// runs: no directive spelling may read an undeclared host file.
//
// This is a public library so rule sets built on rules_dart can enforce the
// same check in their own tools. Depend on it and import it by its stable
// URI:
//
// ```python
// deps = ["@rules_dart//dart/guard:directive_guard"],
// ```
// ```dart
// import 'package:rules_dart_guard/directive_guard.dart';
// ```
//
// The API is three entry points plus the predicates they are built from.
// Every check is pure and synchronous; every failure is a diagnostic string,
// never an exception. A check returns the diagnostics for what it saw, in
// path order, and the empty list when clean; the caller prints each line and
// fails its action when the list is not empty.
//
// * Pass staged roots and get every directive that would read outside them:
//   `findStagedDirectiveViolations(roots, tool: <name>)` reads every `.dart`
//   file under `roots` (missing roots scan as empty) and returns one
//   `"<tool>: <path> <kind> '<uri>' is not a declared input."` line per
//   offending directive. This is the check rules_dart's own runners enforce.
// * Pass file contents and get every disallowed-scheme directive:
//   `findDisallowedDirectives({path: source}, tool: <name>)` checks
//   in-memory sources without touching the filesystem.
// * Pass one URI and resolve it: `resolveDirectiveUri(uri, fromKey,
//   packageDirs)` maps a directive URI to the workspace key the front end
//   reads, or null when the URI names no workspace file. `packageDirs` maps
//   each package name to its directory key.
// * The predicates underneath — `isDisallowedDirectiveUri`,
//   `isFileSchemeDirectiveUri`, `isEscapingPackageUri`,
//   `hasEmptyPathSegment`, `resolveStagedRelativeTarget`,
//   `normalizeStagedPath`, `decodeUriSegment` — classify one URI each, for
//   tools that stage their own trees; `scanAllDirectiveUris(source)` lists a
//   source's directives without evaluating `if` conditions.
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

/// Whether [uri] is a `package:` URI whose path climbs above its package
/// directory (`package:pkg/sub/../../x.dart`), has an empty path segment
/// (`package:pkg//x.dart`), or hides a separator in one decoded segment
/// (`package:pkg/..%2F..%2Fx.dart`). The front end reports leaving the
/// package, but a tool that resolves against the real filesystem reads a host
/// file instead, so the staged-source check refuses it before they run. An
/// empty segment is refused too: the front end resolves the doubled slash as
/// an absolute path, so `package:pkg//x.dart` reads the workspace-root file,
/// not the package's, which no empty-skipping resolver reproduces. A decoded
/// `/` or `\` is refused as well: it climbs without counting, and a
/// filesystem resolver may honour it. A query or fragment suffix is dropped
/// before classifying (the front end reads the file the path part names), so
/// an escaping path still escapes with one, while a path that stays inside
/// its package is still false with one. False for any other URI, including a
/// `package:` URI that stays inside its package (an unknown package name
/// fails closed downstream, where the analyzer cannot resolve it, so it is
/// not refused here).
bool isEscapingPackageUri(String uri) {
  if (!uri.startsWith('package:')) return false;
  var rest = uri.substring('package:'.length);
  // A query or fragment names no file: the front end reads the file the path
  // part names, so the path part alone is classified below.
  final hash = rest.indexOf('#');
  if (hash >= 0) rest = rest.substring(0, hash);
  final query = rest.indexOf('?');
  if (query >= 0) rest = rest.substring(0, query);
  // The package name ends at the first separator: `/` or `\` (the front end
  // reads `\` like `/` everywhere), or either one percent-encoded in either
  // hex case. An empty package name escapes: it names no package file.
  final sep = _firstPackageSeparator(rest);
  if (sep == null) return false;
  if (sep.index <= 0) return true;
  final text = rest.substring(sep.index + sep.length).replaceAll(r'\', '/');
  var depth = 0;
  for (final raw in text.split('/')) {
    // An empty segment resolves absolutely in the front end, outside the
    // package, so it escapes however the siblings resolve.
    if (raw.isEmpty) return true;
    final seg = decodeUriSegment(raw);
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      depth--;
      if (depth < 0) return true;
    } else if (seg.contains('/') || seg.contains(r'\')) {
      // A decoded separator climbs without counting: a filesystem resolver
      // may honour it, so it escapes however the front end spells it.
      return true;
    } else {
      depth++;
    }
  }
  return false;
}

/// The first separator between a `package:` URI's package name and its path:
/// a `/` or `\`, or either one percent-encoded in either hex case. Null when
/// the URI names no path.
({int index, int length})? _firstPackageSeparator(String rest) {
  for (var i = 0; i < rest.length; i++) {
    final c = rest.codeUnitAt(i);
    if (c == 0x2f || c == 0x5c) return (index: i, length: 1);
    if (c == 0x25 && i + 2 < rest.length) {
      final hex = int.tryParse(rest.substring(i + 1, i + 3), radix: 16);
      if (hex == 0x2f || hex == 0x5c) return (index: i, length: 3);
    }
  }
  return null;
}

/// Whether [path] is absolute: POSIX `/`, a Windows drive (`C:/`, `C:\`), or
/// a UNC share (`\\`).
bool _isAbsoluteStagedPath(String path) =>
    path.startsWith('/') ||
    path.startsWith(r'\') ||
    (path.length >= 3 &&
        ((path.codeUnitAt(0) >= 0x41 && path.codeUnitAt(0) <= 0x5a) ||
            (path.codeUnitAt(0) >= 0x61 && path.codeUnitAt(0) <= 0x7a)) &&
        path.codeUnitAt(1) == 0x3a &&
        (path.codeUnitAt(2) == 0x2f || path.codeUnitAt(2) == 0x5c));

bool _isWindowsDriveSegment(String s) =>
    s.length == 2 &&
    ((s.codeUnitAt(0) >= 0x41 && s.codeUnitAt(0) <= 0x5a) ||
        (s.codeUnitAt(0) >= 0x61 && s.codeUnitAt(0) <= 0x7a)) &&
    s.codeUnitAt(1) == 0x3a;

/// [path] as an absolute `/`-separated path: backslashes become separators,
/// a relative path resolves against the current directory, and empty and `.`
/// segments drop out. `..` segments stay (the caller applies them against its
/// own base), except the resolution below, which clamps them at the
/// filesystem root the way the analyzer does.
///
/// Public because tools that stage their own trees compare staged paths the
/// same way the guard does: normalize both sides with this before comparing,
/// so a root passed with a trailing slash or backslashes still matches.
String normalizeStagedPath(String path) {
  final slashed = path.replaceAll(r'\', '/');
  final absolute = _isAbsoluteStagedPath(slashed)
      ? slashed
      : '${Directory.current.path.replaceAll(r'\', '/')}/$slashed';
  final unc = absolute.startsWith('//');
  final parts = <String>[];
  for (final part in absolute.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      // `..` clamps at the filesystem root the way the analyzer clamps it:
      // past `/`, past a drive (`C:`), or past a UNC share's host.
      final floor = unc
          ? (parts.length <= 2 ? parts.length : 2)
          : (parts.isNotEmpty && _isWindowsDriveSegment(parts.first) ? 1 : 0);
      if (parts.length > floor) {
        parts.removeLast();
      }
      continue;
    }
    parts.add(part);
  }
  final joined = parts.join('/');
  if (unc) return '//$joined';
  if (absolute.startsWith('/')) return '/$joined';
  return joined;
}

/// Applies each `/`-separated segment of the relative reference [queue] to
/// the [base] directory stack: `.` and empty segments skip, `..` pops unless
/// already at [floor], anything else appends. Returns the joined path, or null
/// when a decoded segment still holds a `/`, which names no readable file.
String? _applyStagedSegments(List<String> base, int floor, String queue) {
  for (final raw in queue.split('/')) {
    if (raw.isEmpty) continue;
    final seg = decodeUriSegment(raw);
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (base.length > floor) base.removeLast();
      continue;
    }
    if (seg.contains('/')) return null;
    base.add(seg);
  }
  return base.join('/');
}

/// The absolute `/`-separated path a schemeless relative or `/`-absolute
/// directive URI in the staged file [fromPath] refers to, resolved the way the
/// analyzer resolves it on the real filesystem: `\` separates, escapes decode
/// once, a `?...` query is dropped (the front end reads the file the path part
/// names, query or not), and `..` climbs past the staged tree (clamped at the
/// filesystem root, where overshooting names any host path) instead of staying
/// inside the declared inputs.
///
/// An empty reference — `''`, or `'?query'` with no path — names the importing
/// file itself (RFC 3986): a self-import, always declared.
///
/// Null when [uri] is not such a URI: any scheme (`dart:`, `package:`,
/// `file:`, the multi-root scheme, or anything else with a `:`), a fragment
/// (the front end reports a URI with one instead of reading through it), or a
/// `//`-prefixed authority. A decoded `/` also yields null: it names no file,
/// so the compiler reports it and the guard has nothing to confine. Null means
/// "no host file beyond what the scheme check already refuses", never "inside
/// the declared inputs".
String? resolveStagedRelativeTarget(String uri, String fromPath) {
  final text = uri.contains(r'\') ? uri.replaceAll(r'\', '/') : uri;
  // A fragment names no file: the front end reports a URI with one instead of
  // reading through it, whatever path precedes it.
  if (text.contains('#')) return null;
  // A query names no file either: the front end reads the file the path part
  // names, so the path part alone is classified and resolved below. Cutting
  // here also keeps a `:` inside the query from looking like a scheme.
  final query = text.indexOf('?');
  final path = query < 0 ? text : text.substring(0, query);
  if (path.contains(':')) return null;
  if (path.startsWith('//')) return null;
  final from = normalizeStagedPath(fromPath);
  // An empty reference names the importing file itself (RFC 3986).
  if (path.isEmpty) return from;
  final rooted = from.startsWith('/');
  final drive =
      !rooted &&
      from.contains('/') &&
      _isWindowsDriveSegment(from.split('/').first);
  final stack = from.split('/');
  // Drop the file name: the URI resolves against its directory.
  if (stack.isNotEmpty) stack.removeLast();
  final floor = rooted || drive ? 1 : 0;
  final absolute = path.startsWith('/');
  final base = absolute ? stack.sublist(0, floor) : stack;
  final queue = absolute ? path.substring(1) : path;
  final joined = _applyStagedSegments(base, floor, queue);
  if (joined == null) return null;
  // A rooted `from` splits with a leading empty segment, so the join already
  // starts with `/` (or `//` for a UNC share); only fill in a bare `/` when
  // the base ran empty.
  if (rooted) return joined.startsWith('/') ? joined : '/$joined';
  return joined;
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
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7a);

bool _isSchemeChar(int c) =>
    _isSchemeStart(c) ||
    (c >= 0x30 && c <= 0x39) ||
    c == 0x2B ||
    c == 0x2D ||
    c == 0x2E;

/// Whether an `import` or `export` directive URI must fail the build: it names
/// no file the action can read through its declared inputs. That is a `file:`
/// URI in any spelling, a schemeless `//` authority in any separator spelling
/// (`//host/x.dart`, `\\host\x.dart`: the front end resolves those above every
/// root, outside the declared inputs), or any other URI scheme but `dart:`,
/// `package:` and the multi-root scheme. `dart:` libraries are checked against
/// the VM set and `package:` URIs against the package config by the caller.
/// Other schemeless relative URIs are not classified here: the staged-source
/// check resolves those against the importing file's declared location itself,
/// since no caller confines them.
bool isDisallowedDirectiveUri(
  String uri, {
  String multiRootPrefix = defaultMultiRootPrefix,
}) {
  if (uri.startsWith(multiRootPrefix)) return false;
  if (uri.startsWith('package:') || uri.startsWith('dart:')) return false;
  if (isFileSchemeDirectiveUri(uri)) return true;
  // A schemeless `//` authority names no declared file: the front end resolves
  // it above every root, so it reads the host whatever the roots hold. `\`
  // separates like the front end, so a leading `\\` counts too.
  final text = uri.contains(r'\') ? uri.replaceAll(r'\', '/') : uri;
  if (text.startsWith('//')) return true;
  final colon = uri.indexOf(':');
  if (colon <= 0) return false;
  if (!_isSchemeStart(uri.codeUnitAt(0))) return false;
  for (var i = 1; i < colon; i++) {
    if (!_isSchemeChar(uri.codeUnitAt(i))) return false;
  }
  return true;
}

/// Whether [uri] has an empty path segment (`a//b.dart`): the resolvers below
/// skip empty segments, but the front end does not resolve every such spelling
/// the same way — the doubled slash of a `package:` URI resolves as an
/// absolute path, so `package:c//s/t.dart` reads the workspace-root file, not
/// the package's. A directive the guard cannot resolve exactly like the front
/// end is refused, so such URIs fail before the compiler runs. False for URIs
/// with no path to resolve: an empty reference, a query or fragment alone, a
/// `//` authority, or any scheme but `package:` and the multi-root scheme
/// (those never reach a path resolver: their own checks refuse them).
bool hasEmptyPathSegment(String uri) {
  var text = uri.contains(r'\') ? uri.replaceAll(r'\', '/') : uri;
  if (text.startsWith(defaultMultiRootPrefix)) {
    text = text.substring(defaultMultiRootPrefix.length);
  } else if (text.startsWith('package:')) {
    final slash = text.indexOf('/', 'package:'.length);
    if (slash < 0) return false;
    text = text.substring(slash + 1);
  } else {
    if (text.contains(':')) return false;
    if (text.startsWith('//')) return false;
    if (text.startsWith('/')) text = text.substring(1);
  }
  final query = text.indexOf('?');
  final path = query < 0 ? text : text.substring(0, query);
  final hash = path.indexOf('#');
  final clean = hash < 0 ? path : path.substring(0, hash);
  return clean.startsWith('/') || clean.contains('//');
}

/// Whether [uri] spans lines: it holds a `\n` or `\r`.
///
/// A scanned directive URI holding a line break is refused wherever it
/// appears, however the directive names it. The front end drops a
/// whitespace-only (or lone-`\`) first line of a multi-line string literal,
/// so the file it reads differs from the relative path the resolvers below
/// see; reimplementing that first-line rule would risk the next spelling of
/// the same divergence, so multi-line directive URIs are refused outright. A
/// line break can never address a declared file through the resolvers below,
/// so refusing is fail-closed: real directives use single-line URIs.
/// (A single-line literal spelling the break as an escape — `'a\nb.dart'` —
/// is refused too. No clean program names a file that way.)
bool hasLineBreak(String uri) => uri.contains('\n') || uri.contains('\r');

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

/// Applies the segments of a directive path onto [base]: `.` segments are
/// dropped, each `..` pops while deeper than [floor], and a decoded `/`
/// (`%2F`) names no file, since no file can be read through it. An empty
/// segment names no file either: the front end does not resolve every such
/// spelling the way skipping it would (a `package:` doubled slash resolves
/// absolutely), so the path fails and the caller refuses the directive.
/// Above [floor], `..` either fails ([failAboveFloor], for `package:` URIs,
/// where the front end reports leaving the package) or is dropped (relative
/// and absolute URIs, which the front end clamps to the package directory or
/// the multi-root).
String? _resolveDirectivePath(
  String path,
  List<String> base,
  int floor,
  bool failAboveFloor,
) {
  final stack = base.toList();
  for (final raw in path.split('/')) {
    // An empty segment is not skipped: no caller passes a leading `/`, so one
    // here is a doubled slash the front end resolves differently.
    if (raw.isEmpty) return null;
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
/// an unknown package or scheme, an escape above a `package:` directory, an
/// empty path segment (which the front end resolves differently than skipping
/// it would), a fragment, an authority, or a decoded `/`. A `?...` query is
/// dropped and the path part resolved instead: an empty reference names the
/// importing file itself.
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
  // A fragment names no file: the front end reports a URI with one instead of
  // reading through it. A query names no file either: the front end reads the
  // file the path part names, so the path part alone is classified and
  // resolved below.
  if (text.contains('#')) return null;
  final query = text.indexOf('?');
  final path = query < 0 ? text : text.substring(0, query);
  if (path.contains(':')) return null;
  if (path.startsWith('//')) return null;
  // An empty reference names the importing file itself (RFC 3986).
  if (path.isEmpty) return fromKey;
  if (path.startsWith('/')) {
    final base = _packageDirOf(fromKey, packageDirs);
    // The one leading `/` marks absoluteness; any further empty segment fails.
    return _resolveDirectivePath(path.substring(1), base, base.length, false);
  }
  final slash = fromKey.lastIndexOf('/');
  final base = slash < 0
      ? const <String>[]
      : fromKey.substring(0, slash).split('/');
  final floor = _packageDirOf(fromKey, packageDirs).length;
  return _resolveDirectivePath(path, base, floor, false);
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
    i = _unescapeOne(s, i, out);
  }
  return out.toString();
}

/// Consumes the escape starting at `s[i]` (just past the backslash), writes
/// its value to [out], and returns the index just past it.
int _unescapeOne(String s, int i, StringBuffer out) {
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
      final code = _unescapeHexCode(s, i, 2);
      if (code == null) throw const _Unparsable();
      out.writeCharCode(code);
      return i + 2;
    case 'u':
      if (i < s.length && s[i] == '{') {
        final braced = _unescapeBracedCode(s, i);
        if (braced == null) throw const _Unparsable();
        out.writeCharCode(braced.$1);
        return braced.$2;
      }
      final code = _unescapeHexCode(s, i, 4);
      if (code == null) throw const _Unparsable();
      out.writeCharCode(code);
      return i + 4;
    default:
      out.write(esc);
  }
  return i;
}

/// The code point of the [digits]-digit hex escape at `s[i]`, or null when
/// the digits are missing or not hexadecimal.
int? _unescapeHexCode(String s, int i, int digits) {
  if (i + digits > s.length) return null;
  return int.tryParse(s.substring(i, i + digits), radix: 16);
}

/// The (code point, next index) of the `\u{...}` escape at `s[i]`, or null
/// when the brace never closes or the digits are not a valid code point.
(int, int)? _unescapeBracedCode(String s, int i) {
  final close = s.indexOf('}', i + 1);
  if (close < 0) return null;
  final code = int.tryParse(s.substring(i + 1, close), radix: 16);
  if (code == null || code < 0 || code > 0x10FFFF) return null;
  return (code, close + 1);
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
    if (_at == 0) {
      if (src.startsWith('\uFEFF')) _at++;
      if (src.startsWith('#!', _at)) {
        _at = _skipLine(src, _at + 2);
      }
    }
    while (_at < _src.length) {
      if (_skipGap()) continue;
      return _scanToken();
    }
    return null;
  }

  /// Skips one whitespace run or comment; false when [_at] is at a real token.
  bool _skipGap() {
    final src = _src;
    final n = src.length;
    final ch = src[_at];
    if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
      _at++;
      return true;
    }
    if (ch == '/' && _at + 1 < n && src[_at + 1] == '/') {
      _at = _skipLine(src, _at + 2);
      return true;
    }
    if (ch == '/' && _at + 1 < n && src[_at + 1] == '*') {
      _at = _skipBlockComment(src, _at);
      return true;
    }
    return false;
  }

  /// The token starting at [_at]: an identifier (or raw-string prefix),
  /// a number, a string literal, or one punctuation character.
  _Token _scanToken() {
    final src = _src;
    final n = src.length;
    final ch = src[_at];
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
        at = _skipInterpolationWord(src, n, at);
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

  /// The index just past the identifier (or digit run) starting at `at`,
  /// including a raw-string literal when the word is the `r` prefix of one.
  int _skipInterpolationWord(String src, int n, int at) {
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
    return at;
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

  String? _libraryName;
  String? _partOfLibrary;

  ScanResult parse() {
    final refs = <ScanRef>[];
    while (_parseDirective(refs)) {}
    return ScanResult(
      refs,
      libraryName: _libraryName,
      partOfLibrary: _partOfLibrary,
    );
  }

  /// Parses one prologue directive into [refs]; false when the prologue ends
  /// here (end of input or the first non-directive token).
  bool _parseDirective(List<ScanRef> refs) {
    final token = _peek();
    if (token == null) return false;
    if (token.kind == _punctKind && token.text == '@') {
      _annotation();
      return true;
    }
    if (token.kind != _identKind) return false;
    if (token.text == 'library') return _parseLibraryTail();
    if (token.text == 'import' || token.text == 'export') {
      return _parseImportOrExport(token.text, refs);
    }
    if (token.text == 'part') return _parsePartTail(refs);
    return false;
  }

  /// The tail of a `library` directive after its keyword: `;`, a dotted name
  /// and `;`, or anything else, which ends the prologue. The first name wins.
  bool _parseLibraryTail() {
    _lexer.take();
    if (_punct(';')) {
      _lexer.take();
    } else if (_peek()?.kind == _identKind) {
      _libraryName ??= _dottedIdent();
      _expect(';');
    } else {
      return false;
    }
    return true;
  }

  /// An `import` or `export` directive after its keyword: the URI must follow
  /// or the prologue ends here.
  bool _parseImportOrExport(String kind, List<ScanRef> refs) {
    _lexer.take();
    if (_peek()?.kind != _stringKind) return false;
    final ref = _uriDirective(kind, refs);
    if (!collectAll) refs.add(ref);
    return true;
  }

  /// A `part` directive after its keyword: `part of` (a URI or a library
  /// name) or a part URI, each followed by `;`. Anything else ends the
  /// prologue. The first `part of` library name wins.
  bool _parsePartTail(List<ScanRef> refs) {
    _lexer.take();
    if (_ident('of')) {
      _lexer.take();
      if (_peek()?.kind == _stringKind) {
        refs.add(ScanRef('part of', _string()));
      } else {
        _partOfLibrary ??= _dottedIdent();
      }
      _expect(';');
    } else if (_peek()?.kind == _stringKind) {
      refs.add(ScanRef('part', _string()));
      _expect(';');
    } else {
      return false;
    }
    return true;
  }
}

/// Every URI-bearing directive of a source's prologue: each `import` and
/// `export` contributes its declared URI and every `if` alternative, each
/// `part` and `part of` its URI. Conditions are not evaluated, so no VM
/// library set is needed. An empty list when the prologue does not scan (the
/// compiler then reports the genuine syntax error).
List<ScanRef> scanAllDirectiveUris(String source) =>
    scanAllDirectiveUrisChecked(source).refs;

/// A prologue scan: the directives [scanAllDirectiveUris] would list, and
/// whether the prologue did not scan at all. Checks that decide about inputs
/// use this and refuse an unscannable source outright (see
/// [unparsableDirectiveDiagnostic]): an empty directive list would otherwise
/// report a file with a syntax error as clean, whatever it hides past the
/// error.
({List<ScanRef> refs, bool unparsable}) scanAllDirectiveUrisChecked(
  String source,
) {
  try {
    return (
      refs: _Prologue(_Lexer(source), const {}, collectAll: true).parse().refs,
      unparsable: false,
    );
  } on _Unparsable {
    return (refs: const [], unparsable: true);
  }
}

/// The refusal line for a source whose prologue did not scan: it names [path]
/// and says its directives could not be checked, so fixing its syntax error
/// lets the check run. Never clean: the directives past the error are
/// unchecked, so the source is refused however the compiler would report it.
String unparsableDirectiveDiagnostic(String tool, String path) =>
    '$tool: $path has directives that could not be checked; '
    'fix its syntax error and the check will run.';

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
    final checked = scanAllDirectiveUrisChecked(content);
    if (checked.unparsable) {
      errors.add(unparsableDirectiveDiagnostic(tool, path));
      continue;
    }
    for (final ref in checked.refs) {
      // A URI spanning lines is refused however it spells its target: the
      // front end's multi-line first-line rule reads a different file than
      // the resolvers below see (see [hasLineBreak]).
      if (hasLineBreak(ref.uri)) {
        errors.add(
          "$tool: $path ${ref.kind} '${ref.uri}' is not a declared input.",
        );
        continue;
      }
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
/// only directories that do not exist and files that vanish before they are
/// read (the compiler reports those itself). Files that do not decode as UTF-8
/// are decoded with malformed sequences replaced, so the guard still scans
/// every directive they hold: the front end accepts such files, so skipping
/// them would hide their imports. Synchronous for the sync build-action
/// runners, which validate their staged sources before invoking the compiler.
///
/// Staged trees hold symlinks (`ctx.actions.symlink`), which list as `Link`,
/// not `File`: links to `.dart` files are read through the link, so a `file:`
/// import staged as a symlink is still refused. Keys use `/` separators on
/// every platform, so diagnostics read the same on Windows and POSIX.
Map<String, String> readStagedDartSources(Iterable<String> roots) {
  final contents = <String, String>{};
  for (final root in roots) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      final isDart = entity.path.endsWith('.dart');
      if (entity is File) {
        if (!isDart) continue;
      } else if (entity is Link) {
        if (!isDart) continue;
      } else {
        continue;
      }
      final key = entity.path.replaceAll(r'\', '/');
      try {
        // Malformed sequences become U+FFFD, never a skipped file: the front
        // end accepts the file, so the guard scans what it can.
        contents[key] = utf8.decode(
          File(entity.path).readAsBytesSync(),
          allowMalformed: true,
        );
      } on FileSystemException {
        // Gone between listing and reading; the compiler reports it.
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
  bool requireTargetsExist = true,
}) {
  return findStagedDirectiveViolations(
    roots,
    tool: tool,
    multiRootPrefix: multiRootPrefix,
    requireTargetsExist: requireTargetsExist,
  );
}

/// The staged roots a `<name>.proj` project's guard scans: the project itself
/// plus its `<name>.extpkgs` sibling. Nonexistent roots scan as empty, so
/// callers pass both unconditionally.
List<String> projectStagedRoots(String project) {
  var trimmed = project;
  while (trimmed.length > 1 &&
      (trimmed.endsWith('/') || trimmed.endsWith(r'\'))) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  final roots = <String>[project];
  if (trimmed.endsWith('.proj')) {
    roots.add(
      '${trimmed.substring(0, trimmed.length - '.proj'.length)}.extpkgs',
    );
  }
  return roots;
}

/// Whether the absolute `/`-separated [target] is the staged [root] itself or
/// a file under it. Both sides are normalized first, so a root passed with a
/// trailing slash or backslashes still matches.
bool _isWithinStagedRoot(String target, String root) {
  final want = normalizeStagedPath(root);
  if (target == want) return true;
  return target.startsWith('$want/');
}

/// Every staged spelling of [root]: as passed and with symlinks resolved.
/// Staged trees hold symlinks, and the analyzer may spell one staged file through
/// either, so a target matching either spelling counts as declared.
Set<String> _stagedRootSpellings(String root) {
  final spellings = <String>{normalizeStagedPath(root)};
  try {
    final resolved = Directory(root).resolveSymbolicLinksSync();
    spellings.add(normalizeStagedPath(resolved));
  } on FileSystemException {
    // Vanished or unresolvable; the passed spelling still applies.
  }
  return spellings;
}

/// The diagnostics for every directive in the `.dart` files under [roots]
/// that would read a file outside the staged tree, in path order. Empty when
/// clean. The one shared staged-source check every rules_dart tool that reads
/// Dart sources enforces before the compiler or analyzer runs: the analyze,
/// summary, fix and web runners and the link-hook runner call it directly,
/// while the whole-program `gen_kernel` wrapper builds its own input check on
/// the same shared scanner, and the builder shims run their own
/// analyzer-based staged check.
///
/// Beyond the scheme check ([findDisallowedDirectives]), every schemeless
/// relative (and `/`-absolute, which the analyzer reads off the filesystem
/// root) URI is resolved against its importing file's staged path — climbing
/// `..` segments are followed past the staged tree, never clamped — and any
/// target outside [roots] is refused, as is a `package:` URI that climbs above
/// its package ([isEscapingPackageUri]), a URI spanning lines ([hasLineBreak])
/// and any URI that resolves to no file
/// at all (a `//` authority, a fragment, or a decoded `/`). A relative target
/// inside [roots] is refused unless the file exists in the staged tree: the
/// front end reads an absolute path the scanner sees as relative (a
/// multi-line first line the guard keeps but the front end drops), so a
/// target no staged file backs names a host file, never a declared input.
/// The summary runner passes [requireTargetsExist] as false: its projects
/// stage only the target's own files while dependency sources arrive through
/// summaries, so a relative target with no staged file may still resolve
/// against a declared summary (or fail in the analyzer with
/// `uri_does_not_exist` — both closed). Every other caller stages its full
/// closure, so a missing staged file is refused here.
/// Each diagnostic
/// names the file, the directive and the URI.
List<String> findStagedDirectiveViolations(
  Iterable<String> roots, {
  required String tool,
  String multiRootPrefix = defaultMultiRootPrefix,
  bool requireTargetsExist = true,
}) {
  final allowed = <String>{
    for (final root in roots) ..._stagedRootSpellings(root),
  };
  bool declared(String target) =>
      allowed.any((root) => _isWithinStagedRoot(target, root));
  final errors = <String>[];
  final contents = readStagedDartSources(roots);
  final paths = contents.keys.toList()..sort();
  for (final path in paths) {
    final content = contents[path];
    if (content == null) continue;
    final from = normalizeStagedPath(path.replaceAll(r'\', '/'));
    final checked = scanAllDirectiveUrisChecked(content);
    if (checked.unparsable) {
      errors.add(unparsableDirectiveDiagnostic(tool, path));
      continue;
    }
    for (final ref in checked.refs) {
      final violation = _stagedRefViolation(
        (tool: tool, path: path, ref: ref, from: from),
        declared,
        multiRootPrefix,
        requireTargetsExist,
      );
      if (violation != null) errors.add(violation);
    }
  }
  return errors;
}

/// One staged directive reference with the context its violation diagnostic
/// names: the calling tool, the importing file path, the reference, and the
/// importing file's staged path.
typedef _StagedRef = ({String tool, String path, ScanRef ref, String from});

/// The violation line for one staged directive reference, or null when the
/// reference names a declared input. Beyond the scheme check
/// ([findDisallowedDirectives]), every schemeless relative (and `/`-absolute)
/// URI is resolved against its importing file's staged path and refused
/// outside [roots] (via [declared]); a `package:` URI climbing above its
/// package ([isEscapingPackageUri]), a URI spanning lines ([hasLineBreak])
/// and any URI resolving to no file at all (a `//` authority, a fragment, or
/// a decoded `/`) are refused too. A relative target inside [roots] is
/// refused unless the file exists in the staged tree when
/// [requireTargetsExist] holds: the front end may read an absolute host path
/// the scanner sees as a relative staged path, so only a staged file backs a
/// declared input.
String? _stagedRefViolation(
  _StagedRef target,
  bool Function(String) declared,
  String multiRootPrefix,
  bool requireTargetsExist,
) {
  final tool = target.tool;
  final path = target.path;
  final ref = target.ref;
  final from = target.from;
  final uri = ref.uri;
  // A URI spanning lines is refused however it spells its target: the
  // front end's multi-line first-line rule reads a different file than
  // the resolvers below see (see [hasLineBreak]).
  if (hasLineBreak(uri)) {
    return "$tool: $path ${ref.kind} '$uri' is not a declared input.";
  }
  // The resolvers below skip empty segments, but the front end resolves
  // some such spellings absolutely: refuse them before resolving.
  if (hasEmptyPathSegment(uri)) {
    return "$tool: $path ${ref.kind} '$uri' is not a declared input.";
  }
  if (uri.startsWith(multiRootPrefix) || uri.startsWith('dart:')) {
    return null;
  }
  if (uri.startsWith('package:')) {
    if (isEscapingPackageUri(uri)) {
      return "$tool: $path ${ref.kind} '$uri' is not a declared input.";
    }
    return null;
  }
  if (isFileSchemeDirectiveUri(uri) ||
      isDisallowedDirectiveUri(uri, multiRootPrefix: multiRootPrefix)) {
    return "$tool: $path ${ref.kind} '$uri' is not a declared input.";
  }
  final resolved = resolveStagedRelativeTarget(uri, from);
  // A null resolution names no declared file (a `//` authority, a
  // fragment, or a decoded `/`): it is refused, never passed. A resolved
  // target is refused unless the file exists in the staged tree (see
  // [requireTargetsExist] above): the front end may read an absolute
  // host path the scanner sees as a relative staged path, so only a
  // staged file backs a declared input.
  if (resolved == null ||
      !declared(resolved) ||
      (requireTargetsExist && !File(resolved).existsSync())) {
    return "$tool: $path ${ref.kind} '$uri' is not a declared input.";
  }
  return null;
}
