// Machine-format diagnostic parsing and path unstaging for `analyze_runner`.
//
// `dart analyze --format=machine` writes one pipe-separated record per
// diagnostic (`SEVERITY|TYPE|CODE|FILE|LINE|COL|LENGTH|MESSAGE`), escaping `\`
// and `|` inside fields. Context errors in `analysis_options.yaml` or
// `pubspec.yaml` (`parse_error`) raise the exit code to 3 without appearing in
// machine output, so `parseContextDiagnostics` recovers them from default text
// output when the exit code exceeds the parsed diagnostics' severity.
import 'dart:io';

import 'analysis_baseline.dart';

/// The severities the analyzer's machine format may report.
const _levels = {'error', 'warning', 'info'};

const _absUnstageBoundary = '(?<![A-Za-z0-9_.-])';
const _relUnstageBoundary = r'(?<![A-Za-z0-9_.\-/\\])';

final _windowsAbs = RegExp(r'^[A-Za-z]:[\\/]');
final _windowsExtendedPrefix = RegExp(
  r'^(?:[\\/]{2}\?[\\/]|[\\/]\?\?[\\/])(?=[A-Za-z]:[\\/])',
);
final _windowsDrive = RegExp('^[A-Za-z]:');
final _diagnosticPath = RegExp(r'^(\s*\w+ - )src[\\/]', multiLine: true);
final _defaultContextLine = RegExp(
  r'^\s*(error|warning|info) - (.+):(\d+):(\d+) - (.+) - ([a-z0-9_]+)$',
);

/// Highest `dart analyze` exit-code rank among [diagnostics].
int maxDiagnosticRank(
  Iterable<BaselineDiagnostic> diagnostics, {
  required bool fatalInfos,
}) {
  var best = 0;
  for (final diagnostic in diagnostics) {
    final int rank = switch (diagnostic.level) {
      'error' => 3,
      'warning' => 2,
      'info' => fatalInfos ? 1 : 0,
      _ => 0,
    };
    if (rank > best) best = rank;
  }
  return best;
}

/// Parses every machine-format diagnostic, or reports the first unparsable
/// line to stderr and returns null.
List<BaselineDiagnostic>? parseMachineDiagnostics(String out, String project) {
  final _Roots roots = _collectRoots(project);
  final diagnostics = <BaselineDiagnostic>[];
  for (final String raw in out.split('\n')) {
    final String line = raw.trimRight();
    if (line.trim().isEmpty) continue;
    final BaselineDiagnostic? diagnostic = _parseMachineLine(
      line,
      project,
      roots,
    );
    if (diagnostic == null) {
      stderr.writeln('analyze_runner: cannot parse analyzer diagnostic: $line');
      return null;
    }
    diagnostics.add(diagnostic);
  }
  return diagnostics;
}

/// Extracts context errors (`analysis_options.yaml` / `pubspec.yaml` parse
/// errors) from default `dart analyze` output before `Errors in remaining`.
List<BaselineDiagnostic> parseContextDiagnostics(String out, String project) {
  final _Roots roots = _collectRoots(project);
  final diagnostics = <BaselineDiagnostic>[];
  for (final String raw in out.split('\n')) {
    final String line = raw.trimRight();
    if (line.trim() == 'Errors in remaining files.') break;
    final RegExpMatch? match = _defaultContextLine.firstMatch(line);
    if (match == null) continue;
    final String level = match[1]!;
    final _ResolvedFile resolved = _resolveDiagnosticFile(
      match[2]!,
      project,
      roots,
    );
    final String lineNum = match[3]!;
    final String colNum = match[4]!;
    final String message = _unstageWithPatterns(
      match[5]!,
      roots.unstagePatterns,
    );
    final String code = match[6]!;
    final text =
        '${level.padLeft(7)} - ${resolved.path}:$lineNum:$colNum - $message - $code';
    diagnostics.add(
      BaselineDiagnostic(
        path: resolved.path,
        code: code,
        level: level,
        text: text,
        keyed: resolved.keyed,
      ),
    );
  }
  return diagnostics;
}

/// One machine-format line as `SEVERITY|TYPE|CODE|FILE|LINE|COL|LENGTH|MESSAGE`.
BaselineDiagnostic? _parseMachineLine(
  String line,
  String project,
  _Roots roots,
) {
  final List<String>? fields = _splitMachineFields(line);
  if (fields == null || fields.length < 8) return null;
  final String level = fields[0].trim().toLowerCase();
  final String code = fields[2].trim().toLowerCase();
  final int? lineNumber = int.tryParse(fields[4].trim());
  final int? column = int.tryParse(fields[5].trim());
  final int? length = int.tryParse(fields[6].trim());
  if (!_levels.contains(level) ||
      code.isEmpty ||
      lineNumber == null ||
      column == null ||
      length == null) {
    return null;
  }
  final _ResolvedFile resolved = _resolveDiagnosticFile(
    fields[3],
    project,
    roots,
  );
  final String message = _unstageWithPatterns(
    fields.sublist(7).join('|'),
    roots.unstagePatterns,
  );
  final text =
      '${level.padLeft(7)} - ${resolved.path}:$lineNumber:$column - $message - $code';
  return BaselineDiagnostic(
    path: resolved.path,
    code: code,
    level: level,
    text: text,
    keyed: resolved.keyed,
  );
}

/// Splits a machine-format line on unescaped `|`, unescaping `\\` and `\|`.
List<String>? _splitMachineFields(String line) {
  final fields = <String>[];
  final current = StringBuffer();
  for (var i = 0; i < line.length; i++) {
    final String ch = line[i];
    if (ch == r'\') {
      if (i + 1 >= line.length) return null;
      final String next = line[i + 1];
      if (next == r'\' || next == '|') {
        current.write(next);
        i++;
        continue;
      }
    }
    if (ch == '|') {
      fields.add(current.toString());
      current.clear();
    } else {
      current.write(ch);
    }
  }
  fields.add(current.toString());
  return fields;
}

typedef _Roots = ({
  List<String> projectRoots,
  List<String> srcRoots,
  List<RegExp> unstagePatterns,
  bool projectExists,
});

typedef _ResolvedFile = ({String path, bool keyed});

bool _isAbsolutePath(String path) =>
    path.startsWith('/') ||
    _windowsAbs.hasMatch(path) ||
    _windowsExtendedPrefix.hasMatch(path);

_Roots _collectRoots(String project) {
  final dir = Directory(project);
  final bool exists = dir.existsSync();
  final String lexical = _isAbsolutePath(project) ? project : dir.absolute.path;
  final String normLexical = _normalizeSlashPath(lexical);
  final projRootsSet = <String>{normLexical};
  _addLinkTargets(projRootsSet, normLexical);
  if (exists) {
    try {
      projRootsSet.add(_normalizeSlashPath(dir.resolveSymbolicLinksSync()));
    } on FileSystemException catch (e) {
      // Unresolvable directory symlinks leave only the lexical candidate root.
      stderr.writeln('analyze_runner: cannot resolve $project: ${e.message}');
    }
  }

  final srcRootsSet = <String>{
    for (final root in projRootsSet)
      if (root == '/') '/src' else '$root/src',
  };
  final lexicalSrc = normLexical == '/' ? '/src' : '$normLexical/src';
  _addLinkTargets(srcRootsSet, lexicalSrc);

  final srcDir = Directory('$project/src');
  if (srcDir.existsSync()) {
    try {
      srcRootsSet.add(_normalizeSlashPath(srcDir.resolveSymbolicLinksSync()));
    } on FileSystemException catch (e) {
      // Unresolvable src directory symlinks leave only the derived src roots.
      stderr.writeln(
        'analyze_runner: cannot resolve $project/src: ${e.message}',
      );
    }
  }

  final List<String> sortedProjRoots = _sortByLengthDesc(projRootsSet);
  final List<String> sortedSrcRoots = _sortByLengthDesc(srcRootsSet);
  final List<RegExp> unstagePatterns = _buildUnstagePatterns(
    project,
    sortedSrcRoots,
  );

  return (
    projectRoots: sortedProjRoots,
    srcRoots: sortedSrcRoots,
    unstagePatterns: unstagePatterns,
    projectExists: exists,
  );
}

void _addLinkTargets(Set<String> roots, String startPath) {
  var current = startPath;
  for (var hop = 0; hop < 16; hop++) {
    if (!FileSystemEntity.isLinkSync(current)) return;
    try {
      final String target = Link(current).targetSync();
      final next = _isAbsolutePath(target)
          ? target
          : '${File(current).parent.path}/$target';
      final String normNext = _normalizeSlashPath(next);
      if (!roots.add(normNext)) return;
      current = normNext;
    } on FileSystemException catch (e) {
      stderr.writeln('analyze_runner: cannot read link $current: ${e.message}');
      return;
    }
  }
}

List<String> _sortByLengthDesc(Iterable<String> items) {
  final List<String> sorted = items.toList()
    ..sort((String a, String b) {
      final int diff = b.length.compareTo(a.length);
      return diff != 0 ? diff : a.compareTo(b);
    });
  return sorted;
}

_ResolvedFile _resolveDiagnosticFile(String raw, String project, _Roots roots) {
  if (_isAbsolutePath(raw)) {
    return _resolveAbsoluteFile(raw, roots);
  }
  return _resolveRelativeFile(raw, project);
}

_ResolvedFile _resolveAbsoluteFile(String raw, _Roots roots) {
  final String norm = _normalizeSlashPath(raw);
  for (final String srcRoot in roots.srcRoots) {
    final prefix = '$srcRoot/';
    if (_startsWithRootPrefix(norm, prefix)) {
      final String remainder = norm.substring(prefix.length);
      if (remainder.isNotEmpty) {
        return (path: remainder, keyed: true);
      }
    }
  }
  if (roots.projectExists) {
    final String? aliased = _resolveExistingSrcAlias(norm, roots.srcRoots);
    if (aliased != null) {
      return (path: aliased, keyed: true);
    }
  }
  for (final String projectRoot in roots.projectRoots) {
    if (projectRoot == '/') continue;
    final prefix = '$projectRoot/';
    if (_startsWithRootPrefix(norm, prefix)) {
      final String remainder = norm.substring(prefix.length);
      if (remainder.isNotEmpty &&
          remainder != 'src' &&
          !remainder.startsWith('src/')) {
        return (path: remainder, keyed: false);
      }
    }
  }
  return (path: raw, keyed: false);
}

bool _startsWithRootPrefix(String path, String prefix) {
  if (path.startsWith(prefix)) return true;
  if (_windowsDrive.hasMatch(prefix) && path.length >= prefix.length) {
    return path.substring(0, prefix.length).toLowerCase() ==
        prefix.toLowerCase();
  }
  return false;
}

bool _matchesSrcRoot(String resolved, List<String> srcRoots) {
  for (final srcRoot in srcRoots) {
    if (resolved == srcRoot) return true;
    if (_windowsDrive.hasMatch(srcRoot) &&
        resolved.toLowerCase() == srcRoot.toLowerCase()) {
      return true;
    }
  }
  return false;
}

String? _resolveExistingSrcAlias(String norm, List<String> srcRoots) {
  var searchFrom = 0;
  while (true) {
    final int idx = norm.indexOf('/src/', searchFrom);
    if (idx < 0) return null;
    searchFrom = idx + 4;
    final String remainder = norm.substring(idx + 5);
    if (remainder.isEmpty) continue;
    final dir = Directory(norm.substring(0, idx + 4));
    if (!dir.existsSync()) continue;
    try {
      final String resolved = _normalizeSlashPath(
        dir.resolveSymbolicLinksSync(),
      );
      if (_matchesSrcRoot(resolved, srcRoots)) return remainder;
    } on FileSystemException catch (e) {
      stderr.writeln(
        'analyze_runner: cannot resolve ${dir.path}: ${e.message}',
      );
    }
  }
}

_ResolvedFile _resolveRelativeFile(String raw, String project) {
  var rel = raw.replaceAll(r'\', '/');
  while (rel.startsWith('./')) {
    rel = rel.substring(2);
  }

  if (!_isAbsolutePath(project)) {
    final String normProj = _normalizeSlashPath(project);
    if (normProj.isNotEmpty) {
      final prefix = '$normProj/';
      if (rel.startsWith(prefix)) {
        rel = rel.substring(prefix.length);
        while (rel.startsWith('./')) {
          rel = rel.substring(2);
        }
      }
    }
  }

  final List<String> segments = rel.split('/');
  final bool hasInvalidSegment = segments.any(
    (String s) => s.isEmpty || s == '.' || s == '..',
  );
  if (!hasInvalidSegment && rel.startsWith('src/')) {
    final String remainder = rel.substring(4);
    if (remainder.isNotEmpty) {
      return (path: remainder, keyed: true);
    }
  }

  if (hasInvalidSegment) {
    return (path: raw, keyed: false);
  }

  return (path: rel, keyed: false);
}

List<RegExp> _buildUnstagePatterns(String project, List<String> srcRoots) {
  const sep = r'[\\/]';
  final patterns = <RegExp>[];
  for (final srcRoot in srcRoots) {
    if (srcRoot.startsWith('/')) {
      final String body = srcRoot
          .substring(1)
          .split('/')
          .map(RegExp.escape)
          .join('/');
      patterns.add(RegExp('$_absUnstageBoundary/$body/'));
    } else if (_windowsDrive.hasMatch(srcRoot)) {
      final String body = srcRoot.split('/').map(RegExp.escape).join(sep);
      patterns.add(
        RegExp('$_absUnstageBoundary$body$sep', caseSensitive: false),
      );
    }
  }
  if (!_isAbsolutePath(project)) {
    final String normRel = _normalizeSlashPath(project);
    if (normRel.isNotEmpty && !normRel.startsWith('..')) {
      final String body = normRel.split('/').map(RegExp.escape).join(sep);
      patterns.add(
        RegExp(
          '$_relUnstageBoundary$body${sep}src$sep',
          caseSensitive: !_windowsDrive.hasMatch(Directory.current.path),
        ),
      );
    }
  }
  return patterns;
}

String _normalizeSlashPath(String raw) {
  final String stripped = raw.replaceFirst(_windowsExtendedPrefix, '');
  final String slashed = stripped.replaceAll(r'\', '/');
  final String? drive = _windowsDrive.stringMatch(slashed);
  final String prefix = slashed.startsWith('/')
      ? '/'
      : (drive?.toUpperCase() ?? '');
  final String body = slashed.substring(prefix.length);
  final parts = <String>[];
  for (final String part in body.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty && parts.last != '..') {
        parts.removeLast();
      } else if (prefix.isEmpty) {
        parts.add('..');
      }
    } else {
      parts.add(part);
    }
  }
  if (prefix == '/') return '/${parts.join('/')}';
  if (prefix.isNotEmpty) {
    return parts.isEmpty ? prefix : '$prefix/${parts.join('/')}';
  }
  return parts.join('/');
}

String _unstageWithPatterns(String out, List<RegExp> patterns) {
  var result = out;
  for (final pattern in patterns) {
    result = result.replaceAll(pattern, '');
  }
  return result.replaceAllMapped(_diagnosticPath, (Match m) => m[1]!);
}

/// Rewrites staged paths in the analyzer's output to the workspace paths they
/// were copied from, so a diagnostic names a file the user can open.
///
/// The analyzer names a file relative to the directory it analyzed — here the
/// staged project, whose sources sit at `src/<workspace path>` — and quotes
/// absolute paths inside some messages (an unresolvable `include:` names the
/// options file that holds it). Both forms lose their staging prefix. Only the
/// `src/` tree is rewritten: nothing outside it has a workspace path.
String unstage(String out, String project) =>
    _unstageWithPatterns(out, _collectRoots(project).unstagePatterns);
