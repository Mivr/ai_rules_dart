// Staged-project copying shared by `analyze_runner` and `fix_runner`.
//
// Both runners materialize the staged `<name>.proj` tree into a writable
// scratch directory: `fix_runner` because `dart fix --apply` rewrites sources
// in place, and `analyze_runner` when the staged options enable project lint
// rules the stock SDK `dart analyze` does not know, so the stripped copies
// are checked without mutating Bazel's read-only input tree. The traversals
// are one implementation; the runners spell `src/` allow-list paths
// differently (`analyze_runner` by `src/`-relative paths, `fix_runner` by
// project-relative `src/<rel>` paths), so the allow-list here holds
// project-relative `src/<rel>` entries and `analyze_runner` converts its set.
import 'dart:convert';
import 'dart:io';

/// Copies the tree at [from] to [to], resolving symlinks to their contents.
///
/// The allow-list selects which `src/` entries take part: [projectRoot]-relative
/// `src/<rel>` entries of [allowedSrcPaths] are copied, as is everything outside
/// `src/`. A null [allowedSrcPaths] copies everything. Reading flattens a staged
/// symlink into a real file, so no write can follow one back out into the sandbox.
/// Not `File.copySync`, which carries the source's read-only mode across, and the
/// fixer has to be able to rewrite the copy.
void copyStagedTree(
  String from,
  String to, {
  required String projectRoot,
  Set<String>? allowedSrcPaths,
}) {
  Directory(to).createSync(recursive: true);
  for (final FileSystemEntity entity in Directory(
    from,
  ).listSync(followLinks: false)) {
    final String name = _relative(from, entity.path);
    final String relToProject = _relative(projectRoot, entity.path);
    if (FileSystemEntity.isDirectorySync(entity.path)) {
      copyStagedTree(
        entity.path,
        '$to/$name',
        projectRoot: projectRoot,
        allowedSrcPaths: allowedSrcPaths,
      );
    } else if (FileSystemEntity.isFileSync(entity.path)) {
      if (allowedSrcPaths != null &&
          relToProject.startsWith('src/') &&
          !allowedSrcPaths.contains(relToProject)) {
        continue;
      }
      copyStagedFile(entity.path, '$to/$name');
    }
  }
}

/// Copies [from] to [to] by content, creating parent directories.
void copyStagedFile(String from, String to) {
  final dest = File(to);
  dest.parent.createSync(recursive: true);
  dest.writeAsBytesSync(File(from).readAsBytesSync());
}

/// Repoints the scratch copy's package config at the packages that live
/// outside the copied tree using relative URIs.
///
/// Only the project directory is copied; the pub packages its config reaches
/// through `../../<name>.extpkgs/...` or `../../external/<repo>` stay where the
/// sandbox staged them. Rewriting external entries as relative URIs from
/// `$scratch/.dart_tool` keeps those packages resolvable when [scratch] and
/// [project] are at different depths without embedding the sandbox's absolute
/// path in the declared [scratch] output directory.
void repointPackageConfig(String project, String scratch) {
  final file = File('$scratch/.dart_tool/package_config.json');
  if (!file.existsSync()) return;
  final Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } on FormatException catch (e) {
    stderr.writeln(
      'repointPackageConfig: ignoring unparsable ${file.path}: $e',
    );
    return;
  }
  if (decoded is! Map || decoded['packages'] is! List) return;

  // Trailing slashes: the URIs resolve against the config's directory, not
  // against the config file, and `demo.proj/` must not prefix-match a sibling
  // `demo.projX`.
  final anchor = Uri.directory(Directory('$project/.dart_tool').absolute.path);
  final scratchAnchor = Uri.directory(
    Directory('$scratch/.dart_tool').absolute.path,
  );
  final projectRootUri = Uri.directory(Directory(project).absolute.path);
  var rewrote = false;
  for (final Object? package in decoded['packages'] as List) {
    if (package is! Map) continue;
    final Object? root = package['rootUri'];
    if (root is! String) continue;
    final Uri? parsed = _parseRootUri(root);
    if (parsed == null) continue;
    final Uri resolved = anchor.resolveUri(parsed);
    // A URI that stays inside the project resolves against the copied tree at
    // the same relative path under scratch. Pointing it at the original instead
    // would split every package into two identities — the scratch file the
    // fixer analyzes and the `package:` URI it imports itself by — and the
    // analyzer reports type errors between them, which costs the fixes that
    // depend on resolution.
    final base = _isWithinDirUri(resolved, projectRootUri)
        ? anchor
        : scratchAnchor;
    final String rel = _relativeUri(base, resolved);
    if (rel != root) {
      package['rootUri'] = rel;
      rewrote = true;
    }
  }
  if (rewrote) {
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(decoded)}\n',
    );
  }
}

/// Whether [candidate] names a path inside directory [dirUri].
bool _isWithinDirUri(Uri candidate, Uri dirUri) {
  final candidateStr = candidate.toString();
  final dirStr = dirUri.toString();
  if (candidateStr.startsWith(dirStr)) return true;
  final List<String> candidateParts = candidate.path
      .split('/')
      .where((s) => s.isNotEmpty)
      .toList();
  final List<String> dirParts = dirUri.path
      .split('/')
      .where((s) => s.isNotEmpty)
      .toList();
  if (candidateParts.length < dirParts.length) return false;
  for (var i = 0; i < dirParts.length; i++) {
    if (!_sameSegment(candidateParts[i], dirParts[i], isFirst: i == 0)) {
      return false;
    }
  }
  return true;
}

/// Returns a relative URI path from directory [fromDir] to [toUri].
String _relativeUri(Uri fromDir, Uri toUri) {
  final List<String> fromParts = fromDir.path
      .split('/')
      .where((s) => s.isNotEmpty)
      .toList();
  final List<String> toParts = toUri.path
      .split('/')
      .where((s) => s.isNotEmpty)
      .toList();
  var common = 0;
  while (common < fromParts.length &&
      common < toParts.length &&
      _sameSegment(fromParts[common], toParts[common], isFirst: common == 0)) {
    common++;
  }
  if (common == 0 &&
      fromParts.isNotEmpty &&
      toParts.isNotEmpty &&
      _isWindowsDriveSegment(fromParts.first) &&
      _isWindowsDriveSegment(toParts.first)) {
    return toUri.toString();
  }
  final List<String> parts = [
    ...List.filled(fromParts.length - common, '..'),
    ...toParts.sublist(common),
  ];
  return parts.isEmpty ? '.' : parts.join('/');
}

/// Whether [a] and [b] name the same URI path segment.
bool _sameSegment(String a, String b, {required bool isFirst}) {
  if (a == b) return true;
  if (isFirst && _isWindowsDriveSegment(a) && _isWindowsDriveSegment(b)) {
    return a.toLowerCase() == b.toLowerCase();
  }
  return false;
}

/// Whether [s] is a Windows drive segment such as `c:` or `c:/`.
bool _isWindowsDriveSegment(String s) =>
    s.length >= 2 &&
    ((s.codeUnitAt(0) >= 0x41 && s.codeUnitAt(0) <= 0x5a) ||
        (s.codeUnitAt(0) >= 0x61 && s.codeUnitAt(0) <= 0x7a)) &&
    s.codeUnitAt(1) == 0x3a &&
    (s.length == 2 || s.codeUnitAt(2) == 0x2f || s.codeUnitAt(2) == 0x5c);

/// Parses a package config `rootUri` entry, accepting Windows spellings.
Uri? _parseRootUri(String root) {
  if (_isWindowsDriveSegment(root) || root.startsWith(r'\\')) {
    return Uri.file(root, windows: true);
  }
  final String normalized = root.contains(r'\')
      ? root.replaceAll(r'\', '/')
      : root;
  final Uri? parsed = Uri.tryParse(normalized);
  if (parsed == null || (parsed.hasScheme && !parsed.isScheme('file'))) {
    return null;
  }
  return parsed;
}

/// The part of [path] below [root], in the `/`-separated form the runners use
/// for staged paths.
String _relative(String root, String path) {
  String rel = path.substring(root.length).replaceAll(r'\', '/');
  while (rel.startsWith('/')) {
    rel = rel.substring(1);
  }
  return rel;
}
