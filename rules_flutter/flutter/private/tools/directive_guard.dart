// Flutter's half of the directive-URI check: the whole-program kernel compile
// (`frontend_server` behind `flutter_kernel_compile_action`) resolves its
// inputs through the app multi-root scheme across its `--filesystem-root`
// values, so the shared staged-source check cannot confine it. Only that
// Flutter-specific entry point lives here (`findDisallowedFlutterDirectives`,
// run by `kernel_filter.dart` over every declared source before the compiler
// runs); the prologue scanner, the scheme classifiers and the staged-path
// resolution it builds on come from rules_dart's public guard library
// (`@rules_dart//dart/guard:directive_guard`,
// `package:rules_dart_guard/directive_guard.dart`).
//
// The front end behind `flutter_kernel_compile_action` (`frontend_server`)
// loads `file:` URIs straight off the host filesystem, outside every
// `--filesystem-root`, so a compile that mounts the exec root would embed
// undeclared bytes and Bazel would cache the stale result. `kernel_filter.dart`
// runs this check over every declared source before the compiler runs, and
// verifies the compiler's own read set after it: together with the sandbox —
// or remote execution — exposing only declared inputs, these three layers are
// what keep undeclared bytes out of the dill, whatever a directive's spelling.
//
// Empty path segments and a leading `/` are decided here, not by the shared
// check (which refuses or skips them, and whose floor version this module
// resolves at):
//
// * A `package:` URI with an empty segment after the first segment that
//   follows the package name (`package:demo/src//d.dart`) is allowed unless
//   it climbs above its package once empty segments count as segments. An
//   empty segment directly after the package name (`package:demo//x.dart`)
//   makes the front end read the host path `/x.dart`, so it stays refused.
// * A schemeless relative URI with an empty segment (`../lib/src//d.dart`) is
//   resolved by RFC 3986 dot-segment removal with empty segments counted (so
//   `src//../b.dart` is `src/b.dart`, never `b.dart`), and is allowed exactly
//   when that names a declared source or a declared multi-root key.
// * A schemeless URI with exactly one leading `/` and no empty segment after
//   it, in a library under a package's `lib/` directory, resolves under that
//   `lib/` and is allowed exactly when the result is a declared source. A
//   `//` prefix, an empty segment after the slash, or a library outside any
//   `lib/` stays refused.

import 'dart:convert';
import 'dart:io';

import 'package:rules_dart_guard/directive_guard.dart';

/// The multi-root scheme a whole-program Flutter kernel compile resolves its
/// inputs through (see `APP_SCHEME` in `app_entrypoint.bzl`).
const flutterMultiRootPrefix = 'org-dartlang-app:///';

/// The multi-root key naming the declared input source [path]: the
/// exec-root-relative path with its longest `--filesystem-root` prefix
/// stripped, then with a generated file's `bazel-out/<config>/bin/` prefix
/// stripped to the workspace-relative path it is staged at. Mirrors the
/// derivation in rules_dart's whole-program `gen_kernel` wrapper (whose
/// filesystem roots include the bin root, so the same strip falls out of its
/// prefix loop): the compile runs with the exec root as its working directory,
/// so an absolute declared path under it becomes relative, a staged file's key
/// drops the staging-root prefix, and a generated file's key drops the
/// bin-directory prefix. A relative directive URI resolved against one
/// declared source's key therefore names the same key the front end looks up
/// whether the target lives in the source tree or in `bazel-out` — a `part`
/// and its `part of` meet in either direction, in the app's own package and in
/// dependency packages.
///
/// Every key in the comparison uses this function, so the strip cannot admit
/// an undeclared file: a stale output in `bazel-out` that no target declares
/// holds a key no declared source holds, and a `file:` URI naming it is
/// refused by the scheme check before keys are compared. The front end finds
/// each key where it is — every kernel entrypoint compiles under a `package:`
/// or app-scheme URI routed across the staging root — so a generated sibling
/// staged beside its importer reads a declared input, not the host. Paths
/// already relative, or absolute but under no root and outside the working
/// directory (tests), keep the [stripFsRootPrefix] spelling, which stays
/// consistent because every key in the comparison uses this function.
String flutterSourceKey(String path, List<String> fsRoots) {
  String slash = path.replaceAll(r'\', '/');
  final String cwd = Directory.current.path
      .replaceAll(r'\', '/')
      .replaceFirst(RegExp(r'/+$'), '');
  if (slash == cwd) {
    slash = '';
  } else if (slash.startsWith('$cwd/')) {
    slash = slash.substring(cwd.length + 1);
  }
  slash = slash.replaceFirst(RegExp(r'^(?:\./)+'), '');
  String? best;
  for (final rawRoot in fsRoots) {
    final String root = rawRoot
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp(r'/+$'), '')
        .replaceFirst(RegExp(r'^(?:\./)+'), '');
    if (root.isEmpty || root == '.') continue;
    if ((slash == root || slash.startsWith('$root/')) &&
        (best == null || root.length > best.length)) {
      best = root;
    }
  }
  if (best != null) {
    slash = slash == best ? '' : slash.substring(best.length + 1);
  }
  // A generated file's exec path names it under `bazel-out/<config>/bin/`;
  // its key is the workspace-relative path it is staged at (see above).
  // Sources never live under `bazel-out/`, so the prefix cannot collide with
  // one. Both sides of every comparison use this function, so whatever
  // spelling a repository's generated files arrive under, their keys meet the
  // importers' keys exactly when the files are staged as siblings — the same
  // condition under which the front end resolves the import.
  final RegExpMatch? bin = RegExp('^bazel-out/[^/]+/bin/').firstMatch(slash);
  if (bin != null) {
    slash = slash.substring(bin[0]!.length);
  }
  return slash;
}

/// The exec-root-relative path of [path] with its longest `--filesystem-root`
/// prefix stripped (`<root>/` only; a bare `<root>` without the slash is not a
/// prefix). Mirrors rules_dart's whole-program `gen_kernel` wrapper.
String stripFsRootPrefix(String path, List<String> fsRoots) {
  final String slashPath = path.replaceAll(r'\', '/');
  var bestRootLen = -1;
  String? bestRel;
  for (final rawRoot in fsRoots) {
    final String root = rawRoot
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp(r'/+$'), '');
    if (root.isEmpty || root == '.') continue;
    final prefix = '$root/';
    if (slashPath.startsWith(prefix) && root.length > bestRootLen) {
      bestRootLen = root.length;
      bestRel = slashPath.substring(prefix.length);
    }
  }
  return bestRel ?? slashPath.replaceFirst(RegExp(r'^(?:\./)+'), '');
}

/// The multi-root key a schemeless relative directive URI in the declared
/// source with key [fromKey] refers to: the front end resolves the URI against
/// the importing file's key and finds each key where it is, whether in the
/// source tree or in the staging root, so a generated sibling staged beside
/// its importer names a declared input. `\` separates and escapes decode once,
/// as in [resolveStagedRelativeTarget]; a `..` climbing above the key root
/// drops away, the way the front end's own resolution stays inside the
/// multi-root space, and the caller accepts the result only when some declared
/// source holds that key. Mirrors rules_dart's whole-program wrapper.
///
/// Null when [uri] is not a relative URI (any scheme, a fragment, a
/// `//`-prefixed authority, or a `/`-absolute path, which names a host file
/// outside every root) or when a decoded `/` names no file. An empty path
/// segment counts as a segment for `..` (RFC 3986: `src//../b.dart` is
/// `src/b.dart`) and is then dropped from the key, as the front end reads
/// `a//b.dart` as `a/b.dart`; a URI ending in an empty segment names a
/// directory and yields null. A `?...` query is dropped and the path part
/// resolved instead: an empty reference names the importing file itself. Null
/// never means "declared": the caller refuses it unless the filesystem-path
/// check already accepted it.
String? resolveFlutterKeyRelativeTarget(String uri, String fromKey) {
  final String? path = _relativePathPart(uri);
  if (path == null || path.startsWith('/')) return null;
  // An empty reference names the importing file itself (RFC 3986).
  if (path.isEmpty) return fromKey;
  final List<String>? parts = _resolveRelativeParts(path, fromKey);
  return parts?.where((p) => p.isNotEmpty).join('/');
}

/// The path part of the schemeless [uri] with `\` read as `/` and any query
/// dropped, or null when it holds a fragment (which names no file: the front
/// end reports it instead of reading through it) or a `:` (a scheme).
String? _relativePathPart(String uri) {
  final String text = uri.contains(r'\') ? uri.replaceAll(r'\', '/') : uri;
  if (text.contains('#')) return null;
  final int query = text.indexOf('?');
  final String path = query < 0 ? text : text.substring(0, query);
  return path.contains(':') ? null : path;
}

/// Applies the raw URI path segments [raw] to [stack], RFC 3986 style: an
/// empty segment is a real segment (it is what a following `..` removes), `.`
/// is dropped and `..` pops. A `..` on an empty [stack] is dropped, or makes
/// the result null when [refuseEscape]. Null too for a decoded `/`.
List<String>? _resolveSegments(
  List<String> stack,
  Iterable<String> raw, {
  required bool refuseEscape,
}) {
  for (final part in raw) {
    if (part.isEmpty) {
      stack.add('');
      continue;
    }
    final String seg = decodeUriSegment(part);
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (stack.isNotEmpty) {
        stack.removeLast();
      } else if (refuseEscape) {
        return null;
      }
      continue;
    }
    if (seg.contains('/')) return null;
    stack.add(seg);
  }
  return stack;
}

/// The segments (empty ones included) the nonempty relative [path] names when
/// resolved against the directory of the file [fromPath]; null when it escapes
/// through a decoded `/` or ends in an empty segment (a directory, no file).
List<String>? _resolveRelativeParts(String path, String fromPath) {
  final List<String> stack = [
    for (final part in fromPath.split('/'))
      if (part.isNotEmpty) part,
  ];
  // Drop the file name: the URI resolves against its directory.
  if (stack.isNotEmpty) stack.removeLast();
  final List<String>? parts = _resolveSegments(
    stack,
    path.split('/'),
    refuseEscape: false,
  );
  return parts == null || (parts.isNotEmpty && parts.last.isEmpty)
      ? null
      : parts;
}

/// Reads every existing source in [sources] for the directive scan.
///
/// The front end decodes malformed UTF-8 instead of reporting it, so the
/// guard scans what it can rather than skipping the file. Missing or
/// unreadable files stay out of the map; the compiler reports those itself.
Map<String, String> _readDeclaredSourceContents(List<String> sources) {
  final contents = <String, String>{};
  for (final path in sources) {
    try {
      contents[path] = utf8.decode(
        File(path).readAsBytesSync(),
        allowMalformed: true,
      );
    } on FileSystemException {
      // Missing or unreadable here; the compiler reports it.
    }
  }
  return contents;
}

/// The refusal diagnostic for a directive that names no declared input.
/// Every refusal in [findDisallowedFlutterDirectives] shares this shape so
/// each names the file, the directive and the URI the same way.
String _refuseFlutterDirective(
  String tool,
  String path,
  String kind,
  String uri,
) => "$tool: $path $kind '$uri' is not a declared input.";

/// Whether the directive [uri] in the declared source with staged path [from]
/// and multi-root key [fromKey] names a file the compile may read.
///
/// A URI spanning lines is refused however it spells its target: the front
/// end drops a whitespace-only first line of a multi-line string literal and
/// reads a different file than the resolvers see. Otherwise `dart:` is always
/// allowed, the app scheme must name a declared key (an empty segment is
/// refused there), `package:` must stay inside its package ([_isAllowedPackage]
/// states the empty-segment rule), `file:` and other unexpected schemes are
/// refused, and a schemeless URI is decided by [_isAllowedSchemeless].
bool _isAllowedFlutterDirective(
  String uri,
  String from,
  String fromKey,
  Set<String> declared,
  Set<String> declaredKeys, {
  required String multiRootPrefix,
}) {
  if (uri.contains('\n') || uri.contains('\r')) return false;
  if (uri.startsWith('dart:')) return true;
  if (uri.startsWith(multiRootPrefix)) {
    if (hasEmptyPathSegment(uri)) return false;
    // The app scheme resolves only across the compile's `--filesystem-root`
    // values, which name nothing but staged declared inputs: a URI that
    // names no declared key fails the build here instead of at the front
    // end, where the message would name the URI but not the file that
    // reads it.
    final String? key = resolveDirectiveUri(
      uri,
      '',
      const {},
      multiRootPrefix: multiRootPrefix,
    );
    return key != null && declaredKeys.contains(key);
  }
  if (uri.startsWith('package:')) return _isAllowedPackage(uri);
  if (isFileSchemeDirectiveUri(uri) ||
      isDisallowedDirectiveUri(uri, multiRootPrefix: multiRootPrefix)) {
    return false;
  }
  return _isAllowedSchemeless(uri, from, fromKey, declared, declaredKeys);
}

/// Normalises dot segments in [rest] before and after the package name as
/// `Uri.normalizePath` does, where an empty segment counts as a segment.
/// Returns null if any segment decodes to a directory separator.
List<String>? _normalizePackageSegments(String rest) {
  final output = <String>[];
  var appendSlash = false;
  for (final String raw in rest.split('/')) {
    appendSlash = false;
    final String seg = decodeUriSegment(raw);
    if (seg.contains('/') || seg.contains(r'\')) return null;
    if (seg == '..') {
      if (output.isNotEmpty) {
        output.removeLast();
        if (output.isEmpty) output.add('');
      }
      appendSlash = true;
    } else if (seg == '.') {
      appendSlash = true;
    } else {
      output.add(raw);
    }
  }
  if (appendSlash) output.add('');
  return output;
}

/// Whether the `package:` [uri] stays inside its package.
///
/// Decides on the URI the front end will read by removing dot segments before
/// and after the package name as `Uri.normalizePath` does (an empty segment
/// counts as a segment, so `src//../b.dart` still pops it). Refuses package
/// names that are empty, `.`, or `..` after removal, package names holding
/// percent escapes that are not dot segments, and an empty segment directly
/// after the package name when something follows it. Any other empty segment
/// is allowed unless the path climbs above the package root.
bool _isAllowedPackage(String uri) {
  String rest = uri.substring('package:'.length).replaceAll(r'\', '/');
  final int cut = rest.indexOf(RegExp('[#?]'));
  if (cut >= 0) rest = rest.substring(0, cut);
  final List<String>? normalized = _normalizePackageSegments(rest);
  if (normalized == null || normalized.isEmpty) return false;
  final String pkg = normalized.first;
  if (pkg.isEmpty || pkg == '.' || pkg == '..' || pkg.contains('%')) {
    return false;
  }
  final List<String> segments = normalized.sublist(1);
  if (segments.isNotEmpty && segments.first.isEmpty) return false;
  return _resolveSegments([], segments, refuseEscape: true) != null;
}

/// Whether the schemeless [uri] in the declared source [from] (key [fromKey])
/// names a declared input.
///
/// A single leading `/` goes to [_isAllowedLeadingSlash], an empty segment to
/// [_isAllowedEmptySegment]; every other spelling must resolve to a declared
/// source beside the importing file or to a declared multi-root key.
bool _isAllowedSchemeless(
  String uri,
  String from,
  String fromKey,
  Set<String> declared,
  Set<String> declaredKeys,
) {
  final String text = uri.replaceAll(r'\', '/');
  if (text.startsWith('/')) {
    return _isAllowedLeadingSlash(text, from, fromKey, declared, declaredKeys);
  }
  if (_hasRelativeEmptySegment(uri)) {
    return _isAllowedEmptySegment(uri, from, fromKey, declared, declaredKeys);
  }
  final String? target = resolveStagedRelativeTarget(uri, from);
  if (target != null && declared.contains(target)) return true;
  final String? keyTarget = resolveFlutterKeyRelativeTarget(uri, fromKey);
  return keyTarget != null && declaredKeys.contains(keyTarget);
}

/// The path of [filePath] under its containing `lib` directory, or null when
/// the file is not in a `lib` directory.
String? _libRelativePath(String filePath) {
  final List<String> segments = filePath.replaceAll(r'\', '/').split('/');
  if (segments.length < 2) return null;
  final List<String> dirs = segments.sublist(0, segments.length - 1);
  final int libIndex = dirs.lastIndexOf('lib');
  if (libIndex < 0) return null;
  final List<String> rest = [
    for (final s in segments.sublist(libIndex + 1))
      if (s.isNotEmpty) s,
  ];
  return rest.isEmpty ? null : rest.join('/');
}

/// Whether the schemeless [uri] with an empty path segment escapes from a
/// library under `lib/`.
///
/// The front end resolves a `lib/` source's relative reference against its
/// `package:` URI: a `..` above the package name is dropped, then an empty
/// segment directly after the package name escapes.
bool _escapesLibPackage(String uri, String from, String fromKey) {
  final String? rel = _libRelativePath(fromKey) ?? _libRelativePath(from);
  if (rel == null) return false;
  final String text = uri.contains(r'\') ? uri.replaceAll(r'\', '/') : uri;
  try {
    final Uri base = Uri.parse('package:p/$rel');
    final List<String> segs = base.resolve(text).pathSegments;
    return segs.length > 1 && segs[1].isEmpty;
  } on FormatException {
    // Malformed URI cannot name a declared input.
    return true;
  }
}

/// Whether the schemeless [uri] with an empty path segment escapes from a
/// source outside `lib/`.
///
/// Such a file is compiled under `org-dartlang-app:///<key>`. The reference is
/// resolved against that URI the way the front end does, and is refused when
/// the resolved path has an empty first segment (surplus `..` segments leave
/// the scheme root and the empty segment survives, naming a host path),
/// whatever is declared at the staged path. A `lib/` importer is decided by
/// [_escapesLibPackage] instead.
bool _escapesAppRoot(String uri, String from, String fromKey) {
  if ((_libRelativePath(fromKey) ?? _libRelativePath(from)) != null) {
    return false;
  }
  final String text = uri.contains(r'\') ? uri.replaceAll(r'\', '/') : uri;
  try {
    final String key = fromKey
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp('^/+'), '');
    final Uri base = Uri.parse('org-dartlang-app:///$key');
    final List<String> segs = base.resolve(text).pathSegments;
    return segs.isNotEmpty && segs.first.isEmpty;
  } on FormatException {
    // Malformed URI cannot name a declared input.
    return true;
  }
}

/// Whether the schemeless relative [uri] holds an empty path segment (`a//b`).
///
/// The shared `hasEmptyPathSegment` never refuses a relative URI for one, so
/// it cannot route the spelling here; `src//d.dart/` must reach
/// [_isAllowedEmptySegment], which refuses a URI ending in an empty segment.
bool _hasRelativeEmptySegment(String uri) =>
    _relativePathPart(uri)?.contains('//') ?? false;

/// Whether the schemeless [uri] with an empty path segment names a declared
/// source or key by its RFC 3986 resolution, empty segments counted.
///
/// For a source under `lib/`, the reference resolves against the library's
/// `package:` URI: a `..` above the package name is dropped, then an empty
/// segment directly after the package name escapes. For a source outside
/// `lib/` it resolves against its `org-dartlang-app:///` URI and is refused
/// when the resolved path starts with an empty segment ([_escapesAppRoot]).
///
/// The staged-path resolution of the shared check skips empty segments, so
/// `src//../b.dart` would name `b.dart` there but `src/b.dart` in the front
/// end; the decision here uses the RFC resolution only, for the staged path
/// and for the multi-root key.
bool _isAllowedEmptySegment(
  String uri,
  String from,
  String fromKey,
  Set<String> declared,
  Set<String> declaredKeys,
) {
  if (_escapesLibPackage(uri, from, fromKey)) return false;
  if (_escapesAppRoot(uri, from, fromKey)) return false;
  final String? keyTarget = resolveFlutterKeyRelativeTarget(uri, fromKey);
  if (keyTarget != null && declaredKeys.contains(keyTarget)) return true;
  final String? path = _relativePathPart(uri);
  if (path == null || path.isEmpty) return false;
  final List<String>? parts = _resolveRelativeParts(path, from);
  if (parts == null) return false;
  final String staged = parts.where((p) => p.isNotEmpty).join('/');
  final root = from.startsWith('/') ? '/' : '';
  return declared.contains(normalizeStagedPath('$root$staged'));
}

/// Whether the schemeless [text] starting with `/` names a declared source
/// under the `lib/` directory of the package holding the importing file.
///
/// The front end resolves a library's `/src/flow.dart` against the library's
/// own URI, `package:demo/demo.dart`, to `package:demo/src/flow.dart`, which
/// is the file `lib/src/flow.dart` of that package. The guard has no package
/// config, so the package directory comes from the importing file's own path:
/// the directory above a `lib` directory component, taken from the multi-root
/// key ([fromKey]) or the staged path ([from]). When several components are
/// named `lib` every reading must name a declared source. Refused: a `//`
/// prefix, an empty segment after the slash, a file in no `lib/` directory, a
/// `..` that climbs above `lib/`, and a result that is not declared.
bool _isAllowedLeadingSlash(
  String text,
  String from,
  String fromKey,
  Set<String> declared,
  Set<String> declaredKeys,
) {
  final String? path = _relativePathPart(text);
  if (path == null || path.startsWith('//')) return false;
  final List<String> segments = path.substring(1).split('/');
  if (segments.any((s) => s.isEmpty)) return false;
  final List<String> byKey = _libCandidates(segments, fromKey);
  if (byKey.isNotEmpty && byKey.every(declaredKeys.contains)) return true;
  final List<String> byPath = [
    for (final c in _libCandidates(segments, from)) normalizeStagedPath(c),
  ];
  return byPath.isNotEmpty && byPath.every(declared.contains);
}

/// The path `/<segments>` names under each `lib` directory of [filePath]:
/// one candidate per directory component named `lib`. Empty when there is no
/// such directory or [segments] climb above it.
List<String> _libCandidates(List<String> segments, String filePath) {
  final List<String> dirs = filePath.split('/')..removeLast();
  final absolute = filePath.startsWith('/') ? '/' : '';
  final List<String>? under = _resolveSegments(
    [],
    segments,
    refuseEscape: true,
  );
  if (under == null) return const [];
  return [
    for (var i = 0; i < dirs.length; i++)
      if (dirs[i] == 'lib')
        absolute +
            [
              ...dirs.take(i + 1).where((d) => d.isNotEmpty),
              ...under,
            ].join('/'),
  ];
}

/// A diagnostic for every input source with a directive URI that names no
/// file the action can read through its declared inputs: a `file:` URI in any
/// spelling, any other scheme but `dart:`, `package:` and the app scheme, a
/// `package:` URI climbing above its package or holding an empty segment right
/// after the package name, an empty path segment in a relative URI that
/// resolves to no declared input, a `/`-prefixed URI that names no declared
/// source under its package's `lib/`, or a relative URI resolving to no
/// declared input source. The front end reads such a URI
/// off the host, outside every `--filesystem-root`, so the wrapper refuses
/// before compiling. Climbing `..` segments are followed past the declared
/// inputs, never clamped: enough segments name any host path. Empty when
/// clean. Each diagnostic names the file, the directive and the URI.
///
/// A relative URI is accepted when it resolves to a declared source beside the
/// importing file, or when it resolves to a declared source's multi-root key
/// ([resolveFlutterKeyRelativeTarget] over [flutterSourceKey]): the front end
/// finds each key where it is, so a generated sibling in the staging root
/// beside a source-tree importer reads a declared input, not the host.
///
/// [sources] are filesystem paths of the declared Dart sources (read in the
/// compile's working directory; missing or unreadable files are skipped — the
/// compiler reports those itself — while every source that exists is decoded
/// with `allowMalformed` so malformed bytes never skip the check).
/// [fsRoots] are the `--filesystem-root`
/// values the compile forwards to the front end.
List<String> findDisallowedFlutterDirectives(
  List<String> sources,
  List<String> fsRoots, {
  String tool = 'flutter',
  String multiRootPrefix = flutterMultiRootPrefix,
}) {
  final Map<String, List<String>> verdicts = scanFlutterDirectivesPerSource(
    sources,
    fsRoots,
    tool: tool,
    multiRootPrefix: multiRootPrefix,
  );
  return [
    for (final path in verdicts.keys.toList()..sort()) ...verdicts[path]!,
  ];
}

/// The diagnostics [findDisallowedFlutterDirectives] returns, per source: one
/// entry for every [sources] path that exists and is readable (an empty list
/// when that source is clean), in its diagnostics' order.
Map<String, List<String>> scanFlutterDirectivesPerSource(
  List<String> sources,
  List<String> fsRoots, {
  String tool = 'flutter',
  String multiRootPrefix = flutterMultiRootPrefix,
}) {
  final Map<String, String> contents = _readDeclaredSourceContents(sources);
  return _directiveVerdicts(
    contents,
    _declaredSet(contents.keys, fsRoots),
    fsRoots,
    tool: tool,
    multiRootPrefix: multiRootPrefix,
  );
}

/// The diagnostics for only the [subset] of sources, checked against the full
/// [declared] set (every declared source that exists and is readable): a
/// source's verdict depends on its own content, the declared set and
/// [fsRoots], so a caller that knows which sources changed rescans just those.
/// Per-source results as in [scanFlutterDirectivesPerSource]; a [subset] path
/// that cannot be read is absent from the result.
Map<String, List<String>> scanFlutterDirectivesAgainst(
  List<String> subset,
  Iterable<String> declared,
  List<String> fsRoots, {
  String tool = 'flutter',
  String multiRootPrefix = flutterMultiRootPrefix,
}) => _directiveVerdicts(
  _readDeclaredSourceContents(subset),
  _declaredSet(declared, fsRoots),
  fsRoots,
  tool: tool,
  multiRootPrefix: multiRootPrefix,
);

/// The normalised paths and multi-root keys of the declared sources.
typedef _DeclaredSet = ({Set<String> paths, Set<String> keys});

_DeclaredSet _declaredSet(Iterable<String> paths, List<String> fsRoots) => (
  paths: {for (final path in paths) normalizeStagedPath(path)},
  keys: {for (final path in paths) flutterSourceKey(path, fsRoots)},
);

Map<String, List<String>> _directiveVerdicts(
  Map<String, String> contents,
  _DeclaredSet declared,
  List<String> fsRoots, {
  required String tool,
  required String multiRootPrefix,
}) {
  final verdicts = <String, List<String>>{};
  for (final MapEntry<String, String> entry in contents.entries) {
    final String path = entry.key;
    final String from = normalizeStagedPath(path);
    final String fromKey = flutterSourceKey(path, fsRoots);
    verdicts[path] = [
      for (final ref in scanAllDirectiveUris(entry.value))
        if (!_isAllowedFlutterDirective(
          ref.uri,
          from,
          fromKey,
          declared.paths,
          declared.keys,
          multiRootPrefix: multiRootPrefix,
        ))
          _refuseFlutterDirective(tool, path, ref.kind, ref.uri),
    ];
  }
  return verdicts;
}
