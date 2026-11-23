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
    final int c = segment.codeUnitAt(i);
    if (c == 0x25 && i + 2 < segment.length) {
      final int? hex = int.tryParse(segment.substring(i + 1, i + 3), radix: 16);
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
/// directly after the package name (`package:pkg//x.dart`), or hides a
/// separator in one decoded segment (`package:pkg/..%2F..%2Fx.dart`). The front
/// end reports leaving the package, but a tool that resolves against the real
/// filesystem reads a host file instead, so the staged-source check refuses it
/// before they run.
///
/// Dot segments are removed first, from the whole path, the way Dart does
/// before it resolves a URI (`.` skips, `..` pops the nearest earlier segment,
/// an empty one included, and a dot segment before the package name drops:
/// `package:./pkg/x.dart` is `package:pkg/x.dart`); then an empty segment
/// directly after the package name escapes, whatever spelling led to it
/// (`package:pkg/.//x.dart`, `package:pkg/a/..//x.dart`,
/// `package:pkg/%2E//x.dart`, `package:./pkg//x.dart`,
/// `package:%2e%2e/pkg//x.dart`).
///
/// An empty segment is a real segment (RFC 3986), and only its position
/// matters. Directly after the package name the front end resolves the doubled
/// slash as an absolute path: `package:pkg//x.dart` reads the host file
/// `/x.dart` and `package:pkg///x.dart` reads `//x.dart`, not the package's
/// file, so that spelling is refused. After the first path segment the doubled
/// slash stays inside the package: `package:pkg/src//b.dart` reads
/// `lib/src/b.dart`, so it is accepted, and the empty segment counts for a
/// later `..` (`package:pkg/src//../b.dart` reads `lib/src/b.dart`, not
/// `lib/b.dart`), which the depth count below follows. A decoded `/` or `\`
/// is refused as well: it climbs without counting, and a filesystem resolver
/// may honour it. A query or fragment suffix is dropped before classifying
/// (the front end reads the file the path part names), so an escaping path
/// still escapes with one, while a path that stays inside its package is
/// still false with one. False for any other URI, including a `package:` URI
/// that stays inside its package (an unknown package name fails closed
/// downstream, where the analyzer cannot resolve it, so it is not refused
/// here).
bool isEscapingPackageUri(String uri) {
  if (!uri.startsWith('package:')) return false;
  // A query or fragment names no file: the front end reads the file the path
  // part names, so the path part alone is classified below.
  final String rest = _stripLeadingDotSegments(
    uri.substring('package:'.length).split(_queryOrFragment).first,
  );
  // The package name ends at the first separator: `/` or `\` (the front end
  // reads `\` like `/` everywhere), or either one percent-encoded in either
  // hex case. An empty package name escapes: it names no package file.
  final ({int index, int length})? sep = _firstPackageSeparator(rest);
  if (sep == null) return false;
  if (sep.index <= 0) return true;
  final String tail = rest.substring(sep.index + sep.length);
  return _collapsesToEmpty(tail.replaceAll(r'\', '/')) != false;
}

/// The part of [text] after its `package:` scheme, minus the leading dot
/// segments (see [_stripLeadingDotSegments]).
String _packagePath(String text) =>
    _stripLeadingDotSegments(text.substring('package:'.length));

/// Drops the dot segments (`.`, `..`, percent-encoded in either hex case) that
/// lead [rest], the text after `package:`: Dart removes dot segments from the
/// whole path, so they vanish before the package name (`./demo//x.dart` is
/// `demo//x.dart`). A `/` or `\` ends each one.
String _stripLeadingDotSegments(String rest) {
  var s = rest;
  for (int i = s.indexOf(_separator); i >= 0; i = s.indexOf(_separator)) {
    final String seg = decodeUriSegment(s.substring(0, i));
    if (seg != '.' && seg != '..') break;
    s = s.substring(i + 1);
  }
  return s;
}

final _separator = RegExp(r'[/\\]');
final _queryOrFragment = RegExp('[?#]');

/// Whether the schemeless reference [ref], made from a file whose directory
/// below its package's `lib/` is [dirSegments], reads a host file: the front
/// end resolves it against the file's `package:` URI, so after dot-segment
/// removal an empty segment directly after the package name escapes
/// (`..//x.dart` from `lib/src/c.dart` is `package:pkg//x.dart`). A `..`
/// above the package name is dropped, then an empty segment directly after
/// the package name escapes.
bool _relativeReachesHostFile(String ref, List<String> dirSegments) {
  final String text = ref.replaceAll(r'\', '/').split(_queryOrFragment).first;
  if (text.startsWith('/') || text.contains(':')) return false;
  return _collapsesToEmpty(
        [...dirSegments, text].join('/'),
        dropSurplus: true,
      ) ==
      true;
}

/// Removes RFC 3986 dot segments from the `/`-separated package path [path],
/// the way Dart does before it resolves a URI: `.` skips and `..` pops the
/// nearest earlier segment, an empty one included, so `src//../b.dart` is
/// `src`, `b.dart`. Each segment is decoded once. When [dropSurplus] is true,
/// a `..` above the package name is dropped, then an empty segment directly
/// after the package name escapes. True when an empty segment then directly
/// follows the package name and something follows it (the front end resolves
/// that as an absolute path); null when the path escapes: a `..` above the
/// package root (unless [dropSurplus]), or a decoded `/` or `\`, which climbs
/// without counting and which a filesystem resolver may honour; false
/// otherwise.
bool? _collapsesToEmpty(String path, {bool dropSurplus = false}) {
  final out = <String>[];
  for (final String raw in path.split('/')) {
    final String seg = decodeUriSegment(raw);
    if (seg == '.') continue;
    if (seg == '..') {
      if (out.isNotEmpty) {
        out.removeLast();
      } else if (!dropSurplus) {
        return null;
      }
      continue;
    }
    if (seg.contains('/') || seg.contains(r'\')) return null;
    out.add(seg);
  }
  return out.length > 1 && out.first.isEmpty;
}

/// The first separator between a `package:` URI's package name and its path:
/// a `/` or `\`, or either one percent-encoded in either hex case. Null when
/// the URI names no path.
({int index, int length})? _firstPackageSeparator(String rest) {
  for (var i = 0; i < rest.length; i++) {
    final int c = rest.codeUnitAt(i);
    if (c == 0x2f || c == 0x5c) return (index: i, length: 1);
    if (c == 0x25 && i + 2 < rest.length) {
      final int? hex = int.tryParse(rest.substring(i + 1, i + 3), radix: 16);
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
        _isWindowsDriveSegment(path.substring(0, 2)) &&
        (path.codeUnitAt(2) == 0x2f || path.codeUnitAt(2) == 0x5c));

bool _isWindowsDriveSegment(String s) =>
    s.length == 2 && RegExp('[A-Za-z]:').hasMatch(s);

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
  final String slashed = path.replaceAll(r'\', '/');
  final absolute = _isAbsoluteStagedPath(slashed)
      ? slashed
      : '${Directory.current.path.replaceAll(r'\', '/')}/$slashed';
  final bool unc = absolute.startsWith('//');
  final parts = <String>[];
  for (final String part in absolute.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      // `..` clamps at the filesystem root the way the analyzer clamps it:
      // past `/`, past a drive (`C:`), or past a UNC share's host.
      final int floor = unc
          ? (parts.length <= 2 ? parts.length : 2)
          : (parts.isNotEmpty && _isWindowsDriveSegment(parts.first) ? 1 : 0);
      if (parts.length > floor) parts.removeLast();
      continue;
    }
    parts.add(part);
  }
  final String joined = parts.join('/');
  if (unc) return '//$joined';
  if (absolute.startsWith('/')) return '/$joined';
  return joined;
}

/// Applies the `/`-separated segments [raws] to the [base] directory stack the
/// way RFC 3986 dot-segment removal does, with an empty segment counted as a
/// segment: `.` skips, `..` pops the nearest earlier segment of [raws] (an
/// empty one included) and otherwise pops [base] while deeper than [floor],
/// anything else appends. Above [floor], `..` either fails ([failAboveFloor])
/// or is dropped. Empty segments only count; the joined path leaves them out,
/// so `a//b` names `a/b`. Null when a decoded segment still holds a `/`, which
/// names no readable file, or on a failing `..`.
String? _climbSegments(
  List<String> base,
  int floor,
  Iterable<String> raws,
  bool failAboveFloor,
) {
  final List<String> stack = base.toList();
  final added = <String>[];
  for (final raw in raws) {
    final String seg = decodeUriSegment(raw);
    if (seg == '.') continue;
    if (seg == '..') {
      if (added.isNotEmpty) {
        added.removeLast();
      } else if (stack.length > floor) {
        stack.removeLast();
      } else if (failAboveFloor) {
        return null;
      }
      continue;
    }
    if (seg.contains('/')) return null;
    added.add(seg);
  }
  return [...stack, ...added.where((s) => s.isNotEmpty)].join('/');
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
///
/// Empty segments follow RFC 3986: inside a relative reference they are real
/// segments that a `..` pops (`src//../b.dart` from `pkg/lib/a.dart` is
/// `pkg/lib/src/b.dart`) and that otherwise name the same file as without them
/// (`sibling//helper.dart` is `sibling/helper.dart`). A `/`-absolute reference
/// holding one yields null: the front end does not resolve it like the
/// skipped spelling.
String? resolveStagedRelativeTarget(String uri, String fromPath) {
  final String text = uri.contains(r'\') ? uri.replaceAll(r'\', '/') : uri;
  // A fragment names no file: the front end reports a URI with one instead of
  // reading through it, whatever path precedes it.
  if (text.contains('#')) return null;
  // A query names no file either: the front end reads the file the path part
  // names, so the path part alone is classified and resolved below. Cutting
  // here also keeps a `:` inside the query from looking like a scheme.
  final int query = text.indexOf('?');
  final String path = query < 0 ? text : text.substring(0, query);
  if (path.contains(':')) return null;
  if (path.startsWith('//')) return null;
  final String from = normalizeStagedPath(fromPath);
  // An empty reference names the importing file itself (RFC 3986).
  if (path.isEmpty) return from;
  final bool rooted = from.startsWith('/');
  final bool drive =
      !rooted &&
      from.contains('/') &&
      _isWindowsDriveSegment(from.split('/').first);
  final List<String> stack = from.split('/');
  // Drop the file name: the URI resolves against its directory.
  if (stack.isNotEmpty) stack.removeLast();
  final floor = rooted || drive ? 1 : 0;
  final bool absolute = path.startsWith('/');
  final List<String> base = absolute ? stack.sublist(0, floor) : stack;
  final String queue = absolute ? path.substring(1) : path;
  if (absolute && queue.contains('//')) return null;
  final String? joined = _climbSegments(base, floor, queue.split('/'), false);
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
bool isFileSchemeDirectiveUri(String uri) =>
    uri.length >= 5 &&
    uri.codeUnitAt(4) == 0x3a &&
    uri.substring(0, 4).toLowerCase() == 'file';

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
  final String text = uri.contains(r'\') ? uri.replaceAll(r'\', '/') : uri;
  if (text.startsWith('//')) return true;
  final int colon = uri.indexOf(':');
  if (colon <= 0) return false;
  return _isSchemeStart(uri.codeUnitAt(0)) &&
      uri.substring(1, colon).codeUnits.every(_isSchemeChar);
}

/// Whether [uri] has an empty path segment that the guard must refuse because
/// the front end does not read the file the skipped spelling names. An empty
/// segment is a real segment (RFC 3986); where it sits decides:
///
/// * `package:` URI: dot segments are removed from the whole path first, then
///   an empty segment directly after the package name is refused
///   (`package:c//s/t.dart` and `package:c///s/t.dart` read the host files
///   `/s/t.dart` and `//s/t.dart`, not the package's). After the first path
///   segment it is not (`package:c/s//t.dart` reads `lib/s/t.dart`).
/// * Multi-root (`org-dartlang-root:///`) and `/`-absolute URIs: any empty
///   segment is refused.
/// * Schemeless relative URI: never refused here. `sibling//helper.dart` reads
///   the sibling file, so the resolvers ([resolveStagedRelativeTarget],
///   [resolveDirectiveUri]) count the empty segment and the caller accepts the
///   directive exactly when the target is a declared input.
///
/// False for URIs with no path to resolve: an empty reference, a query or
/// fragment alone, a `//` authority, or any scheme but `package:` and the
/// multi-root scheme (those never reach a path resolver: their own checks
/// refuse them).
bool hasEmptyPathSegment(String uri) {
  String text = uri.contains(r'\') ? uri.replaceAll(r'\', '/') : uri;
  final bool packaged = uri.startsWith('package:');
  if (text.startsWith(defaultMultiRootPrefix)) {
    text = text.substring(defaultMultiRootPrefix.length);
  } else if (text.startsWith('package:')) {
    final String rest = _packagePath(text);
    final int slash = rest.indexOf('/');
    if (slash < 0) return false;
    text = rest.substring(slash + 1);
  } else {
    if (text.contains(':')) return false;
    if (!text.startsWith('/') || text.startsWith('//')) return false;
    text = text.substring(1);
  }
  final String clean = text.split(_queryOrFragment).first;
  if (packaged) return _collapsesToEmpty(clean, dropSurplus: true) == true;
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
  for (final String dir in packageDirs.values) {
    if (dir.isEmpty) continue;
    if (fromKey == dir || fromKey.startsWith('$dir/')) {
      final List<String> segs = dir.split('/');
      if (segs.length > best.length) best = segs;
    }
  }
  return best;
}

/// Applies the segments of a directive path onto [base] (see
/// [_climbSegments]): `.` segments are dropped, each `..` pops while deeper
/// than [floor], and a decoded `/` (`%2F`) names no file, since no file can be
/// read through it. For a [_PathKind] other than `root`, an empty
/// segment is a real segment that a later `..` pops (a schemeless relative or a `package:` path
/// after its first segment); a trailing one names a directory, so the path
/// fails. Otherwise any empty segment fails, since the front end resolves it
/// absolutely. Above [floor], `..` either fails (a `package` kind, for
/// `package:` URIs, where the front end reports leaving the package) or is
/// dropped (relative and absolute URIs, which the front end clamps to the
/// package directory or the multi-root).
String? _resolvePath(
  String path,
  List<String> base,
  int floor,
  _PathKind kind,
) {
  final List<String> raws = path.split('/');
  if (raws.last.isEmpty) return null;
  if (kind == _PathKind.root && raws.contains('')) return null;
  return _climbSegments(base, floor, raws, kind == _PathKind.package);
}

/// How [_resolvePath] reads a path: `root` for the multi-root and
/// `/`-absolute URIs (any empty segment fails, `..` above the floor is
/// dropped), `package` for a `package:` path (empty segments count, `..` above
/// the package fails), `relative` for a schemeless path (empty segments count,
/// `..` above the floor is dropped).
enum _PathKind { root, package, relative }

/// The key a directive URI (`import`, `export`, `part`, `part of`) in the file
/// named `fromKey` refers to: the key of the file the front end reads.
///
/// `packageDirs` maps each package name to its directory key (`pkg/lib`).
/// [multiRootPrefix] is the scheme the absolute URIs of multi-root files start
/// with (`org-dartlang-root:///`). Null when the URI names no workspace file:
/// an unknown package or scheme, an escape above a `package:` directory, an
/// empty path segment the front end does not resolve like a skipped one (see
/// [hasEmptyPathSegment]), a fragment, an authority, or a decoded `/`. A `?...` query is
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
  final String text = uri.contains(r'\') ? uri.replaceAll(r'\', '/') : uri;
  if (text.startsWith(multiRootPrefix)) {
    final String absolute = text.substring(multiRootPrefix.length);
    return _resolvePath(absolute, const [], 0, _PathKind.root);
  }
  if (text.startsWith('package:')) {
    final String rest = _packagePath(text);
    if (rest.contains('?') || rest.contains('#')) return null;
    final int slash = rest.indexOf('/');
    if (slash <= 0) return null;
    final String? dir = packageDirs[rest.substring(0, slash)];
    if (dir == null) return null;
    final List<String> base = dir.isEmpty ? const <String>[] : dir.split('/');
    final String inner = rest.substring(slash + 1);
    // Directly after the package name an empty segment reads a host file.
    if (_collapsesToEmpty(inner, dropSurplus: true) == true) return null;
    return _resolvePath(inner, base, base.length, _PathKind.package);
  }
  // A fragment names no file: the front end reports a URI with one instead of
  // reading through it. A query names no file either: the front end reads the
  // file the path part names, so the path part alone is classified and
  // resolved below.
  if (text.contains('#')) return null;
  final int query = text.indexOf('?');
  final String path = query < 0 ? text : text.substring(0, query);
  if (path.contains(':')) return null;
  if (path.startsWith('//')) return null;
  // An empty reference names the importing file itself (RFC 3986).
  if (path.isEmpty) return fromKey;
  if (path.startsWith('/')) {
    final List<String> base = _packageDirOf(fromKey, packageDirs);
    // The one leading `/` marks absoluteness; any further empty segment fails.
    return _resolvePath(path.substring(1), base, base.length, _PathKind.root);
  }
  final int slash = fromKey.lastIndexOf('/');
  final List<String> base = slash < 0
      ? const <String>[]
      : fromKey.substring(0, slash).split('/');
  final int floor = _packageDirOf(fromKey, packageDirs).length;
  // The front end resolves it against the library's `package:` URI.
  if (floor > 0 &&
      base.length >= floor &&
      _relativeReachesHostFile(path, base.sublist(floor))) {
    return null;
  }
  return _resolvePath(path, base, floor, _PathKind.relative);
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
    final String ch = s[i++];
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
  final String esc = s[i++];
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
      final int? code = _unescapeHexCode(s, i, 2);
      if (code == null) throw const _Unparsable();
      out.writeCharCode(code);
      return i + 2;
    case 'u':
      if (i < s.length && s[i] == '{') {
        final (int, int)? braced = _unescapeBracedCode(s, i);
        if (braced == null) throw const _Unparsable();
        out.writeCharCode(braced.$1);
        return braced.$2;
      }
      final int? code = _unescapeHexCode(s, i, 4);
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
  final int close = s.indexOf('}', i + 1);
  if (close < 0) return null;
  final int? code = int.tryParse(s.substring(i + 1, close), radix: 16);
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
    final _Token? token = peek();
    _ahead = null;
    return token;
  }

  _Token? _scan() {
    final String src = _src;
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
    final String src = _src;
    final int n = src.length;
    final String ch = src[_at];
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
    final String src = _src;
    final int n = src.length;
    final String ch = src[_at];
    final int code = ch.codeUnitAt(0);
    if (_isIdentStart(code)) {
      final int start = _at;
      while (_at < n && _isIdentChar(src.codeUnitAt(_at))) {
        _at++;
      }
      final String word = src.substring(start, _at);
      if (word == 'r' && _at < n && (src[_at] == "'" || src[_at] == '"')) {
        return _string(raw: true);
      }
      return _Token(_identKind, word);
    }
    if (_isDigit(code)) {
      final int start = _at;
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
    final String src = _src;
    final String quote = src[_at];
    final bool triple = src.startsWith(quote * 3, _at);
    final String delim = triple ? quote * 3 : quote;
    int contentStart = _at + delim.length;
    final int endQuote = _skipString(_at, raw: raw);
    final int contentEnd = endQuote - delim.length;
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
    final String src = _src;
    final int n = src.length;
    final String quote = src[quoteAt];
    final bool triple = src.startsWith(quote * 3, quoteAt);
    final String delim = triple ? quote * 3 : quote;
    int at = quoteAt + delim.length;
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
    final String src = _src;
    final int n = src.length;
    var at = start;
    var depth = 1;
    while (at < n) {
      final String ch = src[at];
      if (ch == '/' && at + 1 < n && src[at + 1] == '/') {
        at = _skipLine(src, at + 2);
        continue;
      }
      if (ch == '/' && at + 1 < n && src[at + 1] == '*') {
        at = _skipBlockComment(src, at);
        continue;
      }
      final int code = ch.codeUnitAt(0);
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
    final _Token? token = _lexer.take();
    if (token == null) throw const _Unparsable();
    return token;
  }

  bool _is(String text, int kind) {
    final _Token? token = _peek();
    return token != null && token.kind == kind && token.text == text;
  }

  bool _ident(String text) => _is(text, _identKind);

  bool _punct(String text) => _is(text, _punctKind);

  void _expect(String text) {
    if (!_punct(text)) throw const _Unparsable();
    _lexer.take();
  }

  /// Consumes up to and including `text`. A directive keyword (`library`,
  /// `import`, `export`, `part`) or an annotation where only an `import` or
  /// `export` tail can appear — right after the URI string or an `if`
  /// condition — opens a new directive on a missing `;`: consuming it would
  /// swallow that directive unchecked, so the skip stops at the boundary and
  /// the main loop parses the next directive from there. A keyword anywhere
  /// else in the tail (a `show`/`hide` name, an `as` prefix) is consumed as
  /// before: only a keyword right after the URI or a condition can open one.
  /// The tail always starts right after the URI string or an `if` alternative,
  /// so the stop is armed from the first token.
  void _skipPast(String text) {
    var afterOperand = true;
    while (!_punct(text)) {
      final _Token? token = _peek();
      if (token != null && afterOperand && _isDirectiveStart(token)) {
        return;
      }
      final _Token consumed = _take();
      afterOperand =
          consumed.kind == _stringKind ||
          (consumed.kind == _punctKind && consumed.text == ')');
    }
    _lexer.take();
  }

  /// Whether [token] can open a new directive: a directive keyword or an
  /// annotation (see [_skipPast]).
  bool _isDirectiveStart(_Token token) {
    if (token.kind == _punctKind && token.text == '@') return true;
    return token.kind == _identKind &&
        (token.text == 'library' ||
            token.text == 'import' ||
            token.text == 'export' ||
            token.text == 'part');
  }

  void _identToken() {
    if (_take().kind != _identKind) throw const _Unparsable();
  }

  /// A dotted identifier such as `foo` or `foo.bar.baz`.
  String _dottedIdent() {
    final _Token first = _take();
    if (first.kind != _identKind) throw const _Unparsable();
    final out = StringBuffer(first.text);
    while (_punct('.')) {
      _lexer.take();
      final _Token next = _take();
      if (next.kind != _identKind) throw const _Unparsable();
      out
        ..write('.')
        ..write(next.text);
    }
    return out.toString();
  }

  /// Adjacent string literals are one URI.
  String _string() {
    final _Token token = _take();
    if (token.kind != _stringKind) throw const _Unparsable();
    final out = StringBuffer(token.raw ? token.text : _unescape(token.text));
    while (_peek()?.kind == _stringKind) {
      final _Token next = _take();
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
        final _Token token = _take();
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
        final _Token token = _take();
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
    final String text = _dottedIdent();
    String? value;
    if (_punct('=')) {
      _lexer.take();
      _expect('=');
      value = _string();
    }
    _expect(')');
    const prefix = 'dart.library.';
    if (text.startsWith(prefix)) {
      final bool present = _vm.contains(text.substring(prefix.length));
      if (!present) return false;
      return value == null || value == 'true';
    }
    return value == '';
  }

  /// `import` or `export` after its keyword: the URI, then any `if`
  /// alternatives, then the rest of the directive, which names nothing to read.
  ScanRef _uriDirective(String kind, List<ScanRef> refs) {
    final String declared = _string();
    if (collectAll) refs.add(ScanRef(kind, declared));
    var chosen = declared;
    var picked = false;
    while (_ident('if')) {
      _lexer.take();
      _expect('(');
      final bool holds = _condition();
      final String alternative = _string();
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
    final _Token? token = _peek();
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

  /// Whether the prologue ends here with a declaration named by a directive
  /// keyword: `(` or `<` follows (after gaps), so `part() => 1` or
  /// `part<T>() => 2` declares a function rather than opening a directive.
  /// Keywords are built-in identifiers, so any of the four can name one.
  bool _isDeclarationStart() => _punct('(') || _punct('<');

  /// The tail of a `library` directive after its keyword: `;` or a dotted name
  /// and `;`. A following `(` or `<` declares a function named `library` and
  /// ends the prologue instead. Anything else is a syntax error, never the
  /// end of the prologue: no other valid top-level declaration starts with
  /// `library`, so the scan fails and the caller refuses the file instead of
  /// never checking what follows. The first name wins.
  bool _parseLibraryTail() {
    _lexer.take();
    if (_punct(';')) {
      _lexer.take();
    } else if (_peek()?.kind == _identKind) {
      _libraryName ??= _dottedIdent();
      _expect(';');
    } else if (_isDeclarationStart()) {
      return false;
    } else {
      throw const _Unparsable();
    }
    return true;
  }

  /// An `import` or `export` directive after its keyword: the URI string must
  /// follow. A following `(` or `<` declares a function named by the keyword
  /// and ends the prologue instead. Anything else is a syntax error, never
  /// the end of the prologue: no other valid top-level declaration starts
  /// with `import` or `export`, so the scan fails and the caller refuses the
  /// file instead of never checking what follows.
  bool _parseImportOrExport(String kind, List<ScanRef> refs) {
    _lexer.take();
    if (_peek()?.kind == _stringKind) {
      final ScanRef ref = _uriDirective(kind, refs);
      if (!collectAll) refs.add(ref);
      return true;
    }
    if (_isDeclarationStart()) return false;
    throw const _Unparsable();
  }

  /// A `part` directive after its keyword: `part of` (a URI or a library
  /// name) or a part URI, each followed by `;`. A following `(` or `<`
  /// declares a function named `part` and ends the prologue instead. Anything
  /// else is a syntax error, never the end of the prologue: no other valid
  /// top-level declaration starts with `part`, so the scan fails and the
  /// caller refuses the file instead of never checking what follows.
  /// The first `part of` library name wins.
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
    } else if (_isDeclarationStart()) {
      return false;
    } else {
      throw const _Unparsable();
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

/// The result type of [scanAllDirectiveUrisChecked], named for local variables.
typedef _Checked = ({List<ScanRef> refs, bool unparsable});

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
  final List<String> paths = fileContents.keys.toList()..sort();
  for (final path in paths) {
    final String? content = fileContents[path];
    if (content == null) continue;
    final _Checked checked = scanAllDirectiveUrisChecked(content);
    if (checked.unparsable) {
      errors.add(unparsableDirectiveDiagnostic(tool, path));
      continue;
    }
    for (final ScanRef ref in checked.refs) {
      // A URI spanning lines is refused however it spells its target: the
      // front end's multi-line first-line rule reads a different file than
      // the resolvers below see (see [hasLineBreak]).
      if (hasLineBreak(ref.uri)) {
        errors.add(
          "$tool: $path ${ref.kind} '${ref.uri}' is not a declared input.",
        );
        continue;
      }
      final bool disallowed = ref.isPart || ref.isPartOf
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
    for (final FileSystemEntity entity in dir.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File && entity is! Link) continue;
      if (!entity.path.endsWith('.dart')) continue;
      final String key = entity.path.replaceAll(r'\', '/');
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
  final String want = normalizeStagedPath(root);
  if (target == want) return true;
  return target.startsWith('$want/');
}

/// Every staged spelling of [root]: as passed and with symlinks resolved.
/// Staged trees hold symlinks, and the analyzer may spell one staged file through
/// either, so a target matching either spelling counts as declared.
Set<String> _stagedRootSpellings(String root) {
  final spellings = <String>{normalizeStagedPath(root)};
  try {
    final String resolved = Directory(root).resolveSymbolicLinksSync();
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
  final Map<String, String> contents = readStagedDartSources(roots);
  final List<String> paths = contents.keys.toList()..sort();
  for (final path in paths) {
    final String? content = contents[path];
    if (content == null) continue;
    final String from = normalizeStagedPath(path.replaceAll(r'\', '/'));
    final _Checked checked = scanAllDirectiveUrisChecked(content);
    if (checked.unparsable) {
      errors.add(unparsableDirectiveDiagnostic(tool, path));
      continue;
    }
    for (final ScanRef ref in checked.refs) {
      final String? violation = _stagedRefViolation(
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
  final (:tool, :path, :ref, :from) = target;
  final String uri = ref.uri;
  final refused = "$tool: $path ${ref.kind} '$uri' is not a declared input.";
  // A URI spanning lines is refused however it spells its target: the
  // front end's multi-line first-line rule reads a different file than
  // the resolvers below see (see [hasLineBreak]).
  if (hasLineBreak(uri)) return refused;
  // An empty segment right after a package name, or in an absolute URI, reads
  // a host file (see [hasEmptyPathSegment]): refuse it before resolving.
  if (hasEmptyPathSegment(uri)) return refused;
  if (uri.startsWith(multiRootPrefix) || uri.startsWith('dart:')) return null;
  if (uri.startsWith('package:')) {
    return isEscapingPackageUri(uri) ? refused : null;
  }
  if (isFileSchemeDirectiveUri(uri) ||
      isDisallowedDirectiveUri(uri, multiRootPrefix: multiRootPrefix)) {
    return refused;
  }
  // A relative reference from a library under `lib/` is resolved by the front
  // end against the library's `package:` URI (see [_relativeReachesHostFile]).
  if (_libRelativeReachesHostFile(uri, from)) return refused;
  final String? resolved = resolveStagedRelativeTarget(uri, from);
  // A null resolution names no declared file (a `//` authority, a
  // fragment, or a decoded `/`): it is refused, never passed. A resolved
  // target is refused unless the file exists in the staged tree (see
  // [requireTargetsExist] above): the front end may read an absolute
  // host path the scanner sees as a relative staged path, so only a
  // staged file backs a declared input.
  final bool gone = requireTargetsExist && !File(resolved ?? '').existsSync();
  return resolved == null || !declared(resolved) || gone ? refused : null;
}

/// Whether the schemeless [uri] in the staged file [from] reads a host file
/// once resolved against the `package:` URI of a library under a `lib/`
/// directory on [from]'s path (see [_relativeReachesHostFile]).
bool _libRelativeReachesHostFile(String uri, String from) {
  final List<String> segs = from.split('/');
  return [
    for (var i = 0; i < segs.length - 1; i++)
      if (segs[i] == 'lib') segs.sublist(i + 1, segs.length - 1),
  ].any((dir) => _relativeReachesHostFile(uri, dir));
}
