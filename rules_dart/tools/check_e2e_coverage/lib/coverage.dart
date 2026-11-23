/// Coverage checking for the e2e workspaces.
///
/// Every top-level e2e workspace (`e2e/<name>/MODULE.bazel`) must be run by
/// some job in `.github/workflows/`: named by a
/// `bazel run //e2e_runner:e2e_runner` invocation's `--workspace=` argument,
/// by a `working-directory: e2e/<name>`, by a `workspace:` or `folders:`
/// matrix entry, or by a `WORKSPACES:` token. The six nested child helper
/// modules are exempt (their enclosing top-level workspace must be covered),
/// and a reference to an `e2e/<name>` directory that holds no module fails.
library;

import 'dart:io';

import 'package:yaml/yaml.dart';

/// The six nested child helper modules, exempted from their own coverage.
const Set<String> nestedHelperModules = {
  'e2e/analyze_composition/dep_module',
  'e2e/pub_lock_cross_module/module_b',
  'e2e/pub_lock_cross_module/module_c',
  'e2e/pub_lock_scc/spoke_facts',
  'e2e/pub_scanner_intruder/intruder',
  'e2e/pub_symlink/cycle',
};

/// Walks up from [cwd] to the first directory holding both `e2e/` and
/// `.github/workflows/`, the repository root the coverage check scans.
String resolveRepoRoot(String cwd) {
  var dir = Directory(cwd).absolute.path;
  while (true) {
    if (Directory('$dir/e2e').existsSync() &&
        Directory('$dir/.github/workflows').existsSync()) {
      return dir;
    }
    final parent = Directory(dir).parent.path;
    if (parent == dir) {
      throw StateError('cannot find repository root from $cwd');
    }
    dir = parent;
  }
}

/// Repo-relative paths of every `e2e/*/MODULE.bazel` (top-level) module.
Set<String> topLevelModules(String repoRoot) =>
    _topLevelModules('$repoRoot/e2e');

/// Repo-relative paths of every nested `e2e/*/**/MODULE.bazel` module.
Set<String> nestedModules(String repoRoot) => _nestedModules('$repoRoot/e2e');

Set<String> _topLevelModules(String e2eRoot) {
  final result = <String>{};
  final root = Directory(e2eRoot);
  if (!root.existsSync()) return result;
  for (final entry in root.listSync(followLinks: false)) {
    if (entry is! Directory) continue;
    final name = _dirName(entry);
    if (name.startsWith('bazel-')) continue;
    if (File('${entry.path}/MODULE.bazel').existsSync()) {
      result.add('e2e/$name');
    }
  }
  return result;
}

Set<String> _nestedModules(String e2eRoot) {
  final result = <String>{};
  final root = Directory(e2eRoot);
  if (!root.existsSync()) return result;
  for (final entry in root.listSync(recursive: true, followLinks: false)) {
    if (entry is! File || !entry.path.endsWith('MODULE.bazel')) continue;
    final rel = entry.parent.path
        .substring(e2eRoot.length)
        .replaceFirst(RegExp(r'^[/\\]'), '')
        .replaceAll(r'\', '/');
    if (rel.isEmpty || !rel.contains('/')) continue;
    if (rel.split('/').any((s) => s.startsWith('bazel-'))) continue;
    result.add('e2e/$rel');
  }
  return result;
}

/// The last non-empty path segment of [entry], its directory name.
String _dirName(FileSystemEntity entry) {
  final segments = entry.uri.pathSegments.where((s) => s.isNotEmpty).toList();
  return segments.isEmpty ? '' : segments.last;
}

final RegExp _workspacesAssign = RegExp(
  r'''\bWORKSPACES=(?:['"]([^'"]*)['"]|([^\s;#]+))''',
);
final RegExp _repoVarPrefix = RegExp(
  r'^(?:\$\{GITHUB_WORKSPACE\}|\$GITHUB_WORKSPACE|\$\{ws\}|\$ws)(?:/|$)',
);
final RegExp _absDrive = RegExp(r'^[A-Za-z]:[/\\]');

String _unquote(String raw) {
  var clean = raw.trim();
  if ((clean.startsWith('"') && clean.endsWith('"')) ||
      (clean.startsWith("'") && clean.endsWith("'"))) {
    clean = clean.substring(1, clean.length - 1).trim();
  }
  return clean.replaceAll(RegExp(r'[)/\\;\s]+$'), '');
}

String _normalizeRel(String path) {
  final parts = <String>[];
  for (final part in path.replaceAll(r'\', '/').split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty && parts.last != '..') {
        parts.removeLast();
      } else {
        parts.add('..');
      }
    } else {
      parts.add(part);
    }
  }
  return parts.join('/');
}

String _joinBase(String baseDir, String subDir) {
  final cleanSub = _unquote(subDir);
  if (cleanSub.isEmpty) return baseDir;
  if (_repoVarPrefix.hasMatch(cleanSub)) {
    final rel = cleanSub.replaceFirst(_repoVarPrefix, '');
    return rel.isEmpty ? '.' : _normalizeRel(rel);
  }
  if (cleanSub.startsWith('/') || _absDrive.hasMatch(cleanSub)) {
    return cleanSub;
  }
  final cleanBase = _repoVarPrefix.hasMatch(baseDir)
      ? baseDir.replaceFirst(_repoVarPrefix, '')
      : baseDir;
  final combined = cleanBase.isEmpty || cleanBase == '.'
      ? cleanSub
      : '$cleanBase/$cleanSub';
  final normalized = _normalizeRel(combined);
  return normalized.isEmpty ? '.' : normalized;
}

/// The repo-relative `e2e/...` path a workflow path or `--workspace=` value
/// names when resolved from [baseDir], or null if it does not name one.
String? e2eRefFromWorkspace(String value, {String baseDir = '.'}) {
  var clean = _unquote(value);
  if (clean.isEmpty) return null;
  var effectiveBase = baseDir;
  if (_repoVarPrefix.hasMatch(clean)) {
    clean = clean.replaceFirst(_repoVarPrefix, '');
    effectiveBase = '.';
  } else if (_repoVarPrefix.hasMatch(effectiveBase)) {
    effectiveBase = effectiveBase.replaceFirst(_repoVarPrefix, '');
  }
  if (clean.isEmpty || clean.contains(r'$')) return null;
  if (clean.startsWith('/') || _absDrive.hasMatch(clean)) {
    final norm = _normalizeRel(clean);
    final match = RegExp(r'(?:^|/)e2e/(.+)$').firstMatch(norm);
    return match == null ? null : 'e2e/${match.group(1)!}';
  }
  if (effectiveBase.contains(r'$')) return null;
  final combined = effectiveBase.isEmpty || effectiveBase == '.'
      ? clean
      : '$effectiveBase/$clean';
  final normalized = _normalizeRel(combined);
  if (normalized.startsWith('e2e/') && normalized.length > 4) {
    return normalized;
  }
  return null;
}

/// Extracts every e2e workspace reference from a workflow's parsed YAML.
///
/// A reference is a `working-directory:`/`workspace:` value under `e2e/`, a
/// `folders:`/`WORKSPACES:` list, or a `cd` / `e2e_runner --workspace=`
/// argument in a `run:` block resolved relative to the active directory.
Set<String> extractReferences(Object? workflow) {
  final refs = <String>{};
  _walkWorkflow(refs, workflow, currentWd: '.');
  return refs;
}

void _addRefValue(Set<String> refs, Object? value, {String baseDir = '.'}) {
  if (value == null) return;
  if (value is List) {
    for (final item in value) {
      _addRefValue(refs, item, baseDir: baseDir);
    }
    return;
  }
  final r = e2eRefFromWorkspace(value.toString(), baseDir: baseDir);
  if (r != null) refs.add(r);
}

void _addRefTokens(Set<String> refs, Object? value, {String baseDir = '.'}) {
  if (value == null) return;
  if (value is List) {
    for (final item in value) {
      _addRefTokens(refs, item, baseDir: baseDir);
    }
    return;
  }
  for (final token in value.toString().split(RegExp(r'[\s,]+'))) {
    if (token.isNotEmpty) _addRefValue(refs, token, baseDir: baseDir);
  }
}

final RegExp _shellScanToken = RegExp(
  r'\(|\)'
  r'''|\bcd\s+(?:['"]([^'"]+)['"]|([^\s;&|)]+))'''
  r'''|--workspace(?:=|\s+)(?:['"]([^'"]+)['"]|([^\s)"';&|]+))''',
);

void _applyRunMatch(
  Set<String> refs,
  RegExpMatch match,
  List<String> dirStack, {
  required bool hasRunner,
  required bool hasDirectBazel,
}) {
  final full = match.group(0)!;
  if (full == '(') {
    dirStack.add(dirStack.last);
  } else if (full == ')') {
    if (dirStack.length > 1) dirStack.removeLast();
  } else if (full.startsWith('cd')) {
    final dir = match.group(1) ?? match.group(2);
    if (dir == null) return;
    if (hasDirectBazel) _addRefValue(refs, dir, baseDir: dirStack.last);
    dirStack[dirStack.length - 1] = _joinBase(dirStack.last, dir);
  } else if (hasRunner) {
    final arg = match.group(3) ?? match.group(4);
    if (arg != null) _addRefValue(refs, arg, baseDir: dirStack.last);
  }
}

void _scanRunLine(Set<String> refs, String line, List<String> dirStack) {
  final wsAssign = _workspacesAssign.firstMatch(line);
  if (wsAssign != null) {
    final val = wsAssign.group(1) ?? wsAssign.group(2);
    _addRefTokens(refs, val, baseDir: dirStack.last);
  }
  final hasRunner = line.contains('e2e_runner');
  final hasDirectBazel = !hasRunner && RegExp(r'\bbazel\b').hasMatch(line);
  for (final match in _shellScanToken.allMatches(line)) {
    _applyRunMatch(
      refs,
      match,
      dirStack,
      hasRunner: hasRunner,
      hasDirectBazel: hasDirectBazel,
    );
  }
}

void _addRunRefs(Set<String> refs, Object? value, {String baseDir = '.'}) {
  if (value == null) return;
  final joined = value.toString().replaceAll(RegExp(r'\\\r?\n'), ' ');
  final dirStack = <String>[baseDir];
  for (final rawLine in joined.split('\n')) {
    final trimmed = rawLine.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    _scanRunLine(refs, trimmed, dirStack);
  }
}

String _defaultsRunWd(Map node, String fallback) {
  final defaults = node['defaults'];
  if (defaults is Map) {
    final runMap = defaults['run'];
    if (runMap is Map && runMap['working-directory'] != null) {
      return _joinBase(fallback, runMap['working-directory'].toString());
    }
  }
  return fallback;
}

void _walkWorkflow(Set<String> refs, Object? node, {String currentWd = '.'}) {
  if (node is List) {
    for (final item in node) {
      _walkWorkflow(refs, item, currentWd: currentWd);
    }
  } else if (node is Map) {
    _walkWorkflowMap(refs, node, currentWd: currentWd);
  }
}

void _walkWorkflowMap(Set<String> refs, Map node, {String currentWd = '.'}) {
  var effectiveWd = _defaultsRunWd(node, currentWd);
  if (node.containsKey('working-directory')) {
    final wd = node['working-directory']?.toString() ?? '.';
    effectiveWd = _joinBase('.', wd);
    _addRefValue(refs, wd, baseDir: '.');
  }
  node.forEach((key, value) {
    switch (key.toString()) {
      case 'working-directory':
        break;
      case 'workspace':
        _addRefValue(refs, value, baseDir: '.');
      case 'folders':
      case 'WORKSPACES':
        _addRefTokens(refs, value, baseDir: '.');
      case 'run':
        if (value is String) {
          _addRunRefs(refs, value, baseDir: effectiveWd);
        } else {
          _walkWorkflow(refs, value, currentWd: effectiveWd);
        }
      default:
        _walkWorkflow(refs, value, currentWd: effectiveWd);
    }
  });
}

/// Checks coverage and returns the list of failures (empty means clean).
///
/// Every top-level workspace and every nested workspace that is not one of
/// the six child helpers must be referenced; every reference must name a real
/// module. A failure names the uncovered module's `MODULE.bazel` or the
/// dangling reference's directory.
List<String> checkCoverage({
  required String repoRoot,
  required Set<String> topLevel,
  required Set<String> nested,
  required Set<String> references,
}) {
  final failures = <String>[];
  final sortedRequired = [
    ...topLevel,
    ...nested.difference(nestedHelperModules),
  ]..sort();
  final allModules = {...topLevel, ...nested};
  for (final module in sortedRequired) {
    if (!references.contains(module)) {
      failures.add('uncovered e2e workspace: $repoRoot/$module/MODULE.bazel');
    }
  }
  final sortedRefs = references.toList()..sort();
  for (final ref in sortedRefs) {
    if (!allModules.contains(ref)) {
      failures.add('workflow references a missing module: $repoRoot/$ref');
    }
  }
  return failures;
}

/// Parses a workflow file's text into YAML, tolerating empty files.
Object? parseWorkflow(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  return loadYaml(trimmed);
}
