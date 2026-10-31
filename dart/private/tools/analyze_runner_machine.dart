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
    final rank = switch (diagnostic.level) {
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
  final diagnostics = <BaselineDiagnostic>[];
  for (final raw in out.split('\n')) {
    final line = raw.trimRight();
    if (line.trim().isEmpty) continue;
    final diagnostic = _parseMachineLine(line, project);
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
  final diagnostics = <BaselineDiagnostic>[];
  for (final raw in out.split('\n')) {
    final line = raw.trimRight();
    if (line.trim() == 'Errors in remaining files.') break;
    final match = _defaultContextLine.firstMatch(line);
    if (match == null) continue;
    final level = match[1]!;
    final path = _workspacePath(match[2]!, project);
    final lineNum = match[3]!;
    final colNum = match[4]!;
    final message = unstage(match[5]!, project);
    final code = match[6]!;
    final text =
        '${level.padLeft(7)} - $path:$lineNum:$colNum - $message - $code';
    diagnostics.add(
      BaselineDiagnostic(path: path, code: code, level: level, text: text),
    );
  }
  return diagnostics;
}

/// One machine-format line as `SEVERITY|TYPE|CODE|FILE|LINE|COL|LENGTH|MESSAGE`.
BaselineDiagnostic? _parseMachineLine(String line, String project) {
  final fields = _splitMachineFields(line);
  if (fields == null || fields.length < 8) return null;
  final level = fields[0].trim().toLowerCase();
  final code = fields[2].trim().toLowerCase();
  final lineNumber = int.tryParse(fields[4].trim());
  final column = int.tryParse(fields[5].trim());
  final length = int.tryParse(fields[6].trim());
  if (!_levels.contains(level) ||
      code.isEmpty ||
      lineNumber == null ||
      column == null ||
      length == null) {
    return null;
  }
  final path = _workspacePath(fields[3], project);
  final message = unstage(fields.sublist(7).join('|'), project);
  final text =
      '${level.padLeft(7)} - $path:$lineNumber:$column - $message - $code';
  return BaselineDiagnostic(path: path, code: code, level: level, text: text);
}

/// Splits a machine-format line on unescaped `|`, unescaping `\\` and `\|`.
List<String>? _splitMachineFields(String line) {
  final fields = <String>[];
  final current = StringBuffer();
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == r'\') {
      if (i + 1 >= line.length) return null;
      final next = line[i + 1];
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

/// The workspace path of a machine-format or default-format file field.
String _workspacePath(String raw, String project) {
  var path = unstage(raw, project).replaceAll(r'\', '/');
  while (path.startsWith('./')) {
    path = path.substring(2);
  }
  if (path.startsWith('src/')) path = path.substring(4);
  return path;
}

/// Normalized absolute and symlink-resolved prefixes for [project].
Set<String> _projectRoots(String project) {
  final isAbs = project.startsWith('/') || _windowsAbs.hasMatch(project);
  final dir = Directory(project);
  final lexical = isAbs ? project : dir.absolute.path;
  final roots = <String>{_normalizeSlashPath(lexical)};
  if (dir.existsSync()) {
    try {
      roots.add(_normalizeSlashPath(dir.resolveSymbolicLinksSync()));
    } on FileSystemException catch (e) {
      stderr.writeln('analyze_runner: cannot resolve $project: ${e.message}');
    }
  }
  return roots;
}

String _normalizeSlashPath(String raw) {
  final slashed = raw.replaceAll(r'\', '/');
  final prefix = slashed.startsWith('/')
      ? '/'
      : _windowsDrive.stringMatch(slashed) ?? '';
  final body = slashed.substring(prefix.length);
  final parts = <String>[];
  for (final part in body.split('/')) {
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
  for (final root in _projectRoots(project)) {
    result = result
        .replaceAll('$root/src/', '')
        .replaceAll('${root.replaceAll('/', r'\')}\\src\\', '');
  }
  return result.replaceAllMapped(_diagnosticPath, (m) => m[1]!);
}
