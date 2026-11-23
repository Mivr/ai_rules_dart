// The strict-layering check: a target's sources may import only the packages
// its own `deps` provide (and its own package, and `dart:`).

// ignore: avoid_relative_lib_imports, reason: compiled in place through `srcs`.
import '../../guard/lib/directive_guard.dart';

const _tool = 'import_check';

/// What one target states: its label, the packages its sources may import
/// (its own package names plus the packages of its direct deps), and its source
/// text by display path.
typedef ImportCheckRequest = ({
  String label,
  Set<String> allowedPackages,
  Map<String, String> sources,
});

final RegExp _scheme = RegExp('^([A-Za-z][A-Za-z0-9+.-]*):');

final RegExp _badEscape = RegExp('%(?![0-9A-Fa-f]{2})');

/// [path] with its `.` and `..` segments removed, as the front end resolves a
/// directive URI: `./io` and `x/../io` both name `io`; a `..` with nothing
/// before it is dropped.
String _withoutDotSegments(String path) {
  final kept = <String>[];
  for (final String segment in path.split('/')) {
    if (segment == '.') continue;
    if (segment == '..') {
      if (kept.isNotEmpty) kept.removeLast();
      continue;
    }
    kept.add(segment);
  }
  return kept.join('/');
}

/// [uri] as the front end reads it: the scheme lower-cased, `%XX` escapes
/// decoded once, then dot segments removed, or null when it does not decode
/// cleanly.
String? normaliseDirectiveUri(String uri) {
  final Match? m = _scheme.firstMatch(uri);
  final String lowered = m == null
      ? uri
      : m.group(1)!.toLowerCase() + uri.substring(m.group(1)!.length);
  if (_badEscape.hasMatch(lowered)) return null;
  try {
    final String decoded = Uri.decodeFull(lowered);
    final Match? s = _scheme.firstMatch(decoded);
    if (s == null) return decoded;
    final String head = decoded.substring(0, s.group(0)!.length);
    return head + _withoutDotSegments(decoded.substring(head.length));
  } on FormatException {
    return null;
  }
}

/// The violation line for [path] whose directive [uri] does not decode.
String undecodableLine(String label, String path, String uri) =>
    "$label: $path names '$uri', which is not a valid URI: a '%' escape does "
    'not decode to UTF-8. Fix the escape.';

/// The package a `package:` URI names, or null for any other URI. [uri] is
/// judged as [normaliseDirectiveUri] returns it.
String? packageOfUri(String uri) {
  const prefix = 'package:';
  if (!uri.startsWith(prefix)) return null;
  final String rest = uri.substring(prefix.length);
  final int slash = rest.indexOf('/');
  return slash < 0 ? rest : rest.substring(0, slash);
}

/// The violation line for [path] importing [uri] from package [name].
String violationLine(String label, String path, String uri, String name) =>
    "$label: $path imports '$uri', but package '$name' is not a direct "
    'dependency of $label, only of something it depends on. '
    "Add the target that provides package '$name' to $label's deps.";

/// The lines to print for [request], in path then source order. A source that
/// does not scan is refused, never treated as clean.
List<String> checkImports(ImportCheckRequest request) {
  final lines = <String>[];
  final List<String> paths = request.sources.keys.toList()..sort();
  for (final path in paths) {
    final ({List<ScanRef> refs, bool unparsable}) checked =
        scanAllDirectiveUrisChecked(request.sources[path]!);
    if (checked.unparsable) {
      lines.add(unparsableDirectiveDiagnostic(_tool, path));
      continue;
    }
    for (final ScanRef ref in checked.refs) {
      if (ref.kind != 'import' && ref.kind != 'export') continue;
      final String? uri = normaliseDirectiveUri(ref.uri);
      final String? name = uri == null ? null : packageOfUri(uri);
      if (uri != null &&
          (name == null || request.allowedPackages.contains(name))) {
        continue;
      }
      final String line = uri == null
          ? undecodableLine(request.label, path, ref.uri)
          : violationLine(request.label, path, ref.uri, name!);
      if (!lines.contains(line)) lines.add(line);
    }
  }
  return lines;
}

/// Checks the own sources of a module for disallowed package imports.
Future<List<String>> checkModuleImports({
  required String label,
  required Set<String> allowedPackages,
  required Set<String> ownKeys,
  required Future<String?> Function(String key) readSource,
}) async {
  final sources = <String, String>{};
  for (final key in ownKeys) {
    final String? text = await readSource(key);
    if (text != null) {
      sources[key] = text;
    }
  }
  return checkImports((
    label: label,
    allowedPackages: allowedPackages,
    sources: sources,
  ));
}
