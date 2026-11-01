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

final _windowsAbs = RegExp(r'^[A-Za-z]:[\\/]');
final _windowsDrive = RegExp(r'^[A-Za-z]:');
final _diagnosticPath = RegExp(r'^(\s*\w+ - )src/', multiLine: true);
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
    final String message = unstage(match[5]!, project);
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
  final String message = unstage(fields.sublist(7).join('|'), project);
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

typedef _Roots = ({List<String> projectRoots, List<String> srcRoots});

typedef _ResolvedFile = ({String path, bool keyed});

_Roots _collectRoots(String project) {
  final bool isAbs = project.startsWith('/') || _windowsAbs.hasMatch(project);
  final dir = Directory(project);
  final String lexical = isAbs ? project : dir.absolute.path;
  final projRootsSet = <String>{
    _normalizeSlashPath(project),
    _normalizeSlashPath(lexical),
  };
  if (dir.existsSync()) {
    try {
      projRootsSet.add(_normalizeSlashPath(dir.resolveSymbolicLinksSync()));
    } on FileSystemException catch (e) {
      // Unresolvable directory symlinks leave only the lexical candidate root.
      stderr.writeln('analyze_runner: cannot resolve $project: ${e.message}');
    }
  }

  final srcRootsSet = <String>{};
  for (final root in projRootsSet) {
    srcRootsSet.add('$root/src');
  }

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

  int byLengthDesc(String a, String b) {
    final int diff = b.length.compareTo(a.length);
    return diff != 0 ? diff : a.compareTo(b);
  }

  final List<String> sortedProjRoots = projRootsSet.toList()
    ..sort(byLengthDesc);
  final List<String> sortedSrcRoots = srcRootsSet.toList()..sort(byLengthDesc);

  return (projectRoots: sortedProjRoots, srcRoots: sortedSrcRoots);
}

_ResolvedFile _resolveDiagnosticFile(String raw, String project, _Roots roots) {
  final bool isAbs = raw.startsWith('/') || _windowsAbs.hasMatch(raw);
  if (isAbs) {
    return _resolveAbsoluteFile(raw, roots);
  }
  return _resolveRelativeFile(raw, project);
}

_ResolvedFile _resolveAbsoluteFile(String raw, _Roots roots) {
  final String norm = _normalizeSlashPath(raw);
  for (final String srcRoot in roots.srcRoots) {
    final prefix = '$srcRoot/';
    if (norm.startsWith(prefix)) {
      final String remainder = norm.substring(prefix.length);
      if (remainder.isNotEmpty) {
        return (path: remainder, keyed: true);
      }
    }
  }
  for (final String projectRoot in roots.projectRoots) {
    final prefix = '$projectRoot/';
    if (norm.startsWith(prefix)) {
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

_ResolvedFile _resolveRelativeFile(String raw, String project) {
  String rel = raw.replaceAll(r'\', '/');
  while (rel.startsWith('./')) {
    rel = rel.substring(2);
  }

  final bool isProjectRel =
      !project.startsWith('/') && !_windowsAbs.hasMatch(project);
  if (isProjectRel) {
    final String normProj = _normalizeSlashPath(project);
    if (normProj.isNotEmpty && normProj != '.') {
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
    (String s) => s.isEmpty || s == '..',
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

List<String> _candidateSrcPrefixes(String project) {
  final _Roots roots = _collectRoots(project);
  final prefixes = <String>{};
  for (final String root in roots.projectRoots) {
    prefixes.add('$root/src/');
    prefixes.add('${root.replaceAll('/', r'\')}\\src\\');
  }
  for (final String srcRoot in roots.srcRoots) {
    prefixes.add('$srcRoot/');
    prefixes.add('${srcRoot.replaceAll('/', r'\')}\\');
  }
  final List<String> sorted = prefixes.toList()
    ..sort((String a, String b) {
      final int diff = b.length.compareTo(a.length);
      return diff != 0 ? diff : a.compareTo(b);
    });
  return sorted;
}

String _normalizeSlashPath(String raw) {
  final String slashed = raw.replaceAll(r'\', '/');
  final String prefix = slashed.startsWith('/')
      ? '/'
      : _windowsDrive.stringMatch(slashed) ?? '';
  final String body = slashed.substring(prefix.length);
  final parts = <String>[];
  for (final String part in body.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..' && parts.isNotEmpty) {
      parts.removeLast();
    } else if (part != '..') {
      parts.add(part);
    }
  }
  if (prefix == '/') return '/${parts.join('/')}';
  if (prefix.isNotEmpty) {
    return parts.isEmpty ? prefix : '$prefix/${parts.join('/')}';
  }
  return parts.join('/');
}

/// Rewrites staged paths in the analyzer's output to the workspace paths they
/// were copied from, so a diagnostic names a file the user can open.
///
/// The analyzer names a file relative to the directory it analyzed — here the
/// staged project, whose sources sit at `src/<workspace path>` — and quotes
/// absolute paths inside some messages (an unresolvable `include:` names the
/// options file that holds it). Both forms lose their staging prefix. Only the
/// `src/` tree is rewritten: nothing outside it has a workspace path.
String unstage(String out, String project) {
  var result = out;
  for (final String prefix in _candidateSrcPrefixes(project)) {
    final pattern = RegExp('(?<![A-Za-z0-9_.-])${RegExp.escape(prefix)}');
    result = result.replaceAll(pattern, '');
  }
  return result.replaceAllMapped(_diagnosticPath, (Match m) => m[1]!);
}
