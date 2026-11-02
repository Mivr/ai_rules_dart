import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Guard checking that the bzl_library target graph is complete, public,
/// and covers all load edges in the root module.
void main(List<String> args) {
  group('bzl_library graph guard', () {
    late final String root;
    late final List<File> bzlFiles;
    late final List<_BzlTarget> targets;
    late final Map<String, _BzlTarget> fileToTarget;

    setUpAll(() {
      root = _findWorkspaceRoot(args);
      bzlFiles = _findNonTestBzlFiles(root);
      targets = _loadAllBzlLibraryTargets(root);
      fileToTarget = _indexTargetsBySource(targets);
    });

    test(
      'every root-module non-test .bzl file has a bzl_library target',
      () => _verifyCoverage(bzlFiles, targets, fileToTarget, root),
    );

    test(
      'every root-module non-test bzl_library target is public',
      () => _verifyPublicVisibility(targets),
    );

    test(
      'every bzl_library target covers all same-repo and skylib loads',
      () => _verifyLoadsCovered(bzlFiles, fileToTarget, root),
    );
  });
}

void _verifyCoverage(
  List<File> bzlFiles,
  List<_BzlTarget> targets,
  Map<String, _BzlTarget> fileToTarget,
  String root,
) {
  expect(
    bzlFiles,
    isNotEmpty,
    reason: 'expected non-empty root-module non-test .bzl files',
  );
  expect(
    targets,
    isNotEmpty,
    reason: 'expected non-empty non-test bzl_library targets',
  );

  final uncovered = <String>[];
  for (final file in bzlFiles) {
    final String rel = _relPath(root, file);
    if (!fileToTarget.containsKey(rel)) {
      uncovered.add(rel);
    }
  }
  expect(
    uncovered,
    isEmpty,
    reason:
        'uncovered .bzl files without a bzl_library target:\n'
        '${uncovered.join('\n')}',
  );

  final invalidSrcs = <String>[];
  for (final target in targets) {
    if (target.srcs.length != 1) {
      invalidSrcs.add(
        '${target.label} declares srcs=${target.srcs} (expected exactly 1)',
      );
    }
  }
  expect(
    invalidSrcs,
    isEmpty,
    reason: 'targets with invalid srcs:\n${invalidSrcs.join('\n')}',
  );

  expect(
    targets.length,
    equals(bzlFiles.length),
    reason:
        'expected exactly one bzl_library target per non-test .bzl file '
        '(found ${targets.length} targets for ${bzlFiles.length} files)',
  );
}

void _verifyPublicVisibility(List<_BzlTarget> targets) {
  final nonPublic = <String>[];
  for (final target in targets) {
    if (!target.visibility.contains('//visibility:public')) {
      nonPublic.add('${target.label} visibility=${target.visibility}');
    }
  }
  expect(
    nonPublic,
    isEmpty,
    reason:
        'non-test bzl_library targets without public visibility:\n'
        '${nonPublic.join('\n')}',
  );
}

void _verifyLoadsCovered(
  List<File> bzlFiles,
  Map<String, _BzlTarget> fileToTarget,
  String root,
) {
  final checkResult = _DepsCheckResult();

  for (final file in bzlFiles) {
    final String rel = _relPath(root, file);
    final _BzlTarget? target = fileToTarget[rel];
    if (target == null) continue;

    _checkTargetLoads(file, target, fileToTarget, checkResult);
  }

  expect(
    checkResult.rawBzlDeps,
    isEmpty,
    reason:
        'deps entries must be targets, never raw .bzl paths:\n'
        '${checkResult.rawBzlDeps.join('\n')}',
  );
  expect(
    checkResult.missingDeps,
    isEmpty,
    reason:
        'bzl_library targets with missing load dependencies:\n'
        '${checkResult.missingDeps.join('\n')}',
  );
  expect(
    checkResult.unneededDeps,
    isEmpty,
    reason:
        'bzl_library targets with unneeded dependencies:\n'
        '${checkResult.unneededDeps.join('\n')}',
  );
}

final class _BzlTarget {
  const new({
    required this.packagePath,
    required this.name,
    required this.srcs,
    required this.deps,
    required this.visibility,
  });

  final String packagePath;
  final String name;
  final List<String> srcs;
  final List<String> deps;
  final List<String> visibility;

  String get label => packagePath.isEmpty ? ':$name' : '//$packagePath:$name';
}

class _DepsCheckResult {
  final List<String> rawBzlDeps = [];
  final List<String> missingDeps = [];
  final List<String> unneededDeps = [];
}

void _checkTargetLoads(
  File file,
  _BzlTarget target,
  Map<String, _BzlTarget> fileToTarget,
  _DepsCheckResult result,
) {
  _checkRawBzlDeps(target, result);
  final List<String> loads = _extractLoads(file.readAsStringSync());
  final Set<String> expectedDeps = _resolveExpectedDeps(
    target,
    loads,
    fileToTarget,
    result,
  );
  _checkDepDiscrepancies(target, expectedDeps, result);
}

void _checkRawBzlDeps(_BzlTarget target, _DepsCheckResult result) {
  for (final String dep in target.deps) {
    if (dep.endsWith('.bzl')) {
      result.rawBzlDeps.add('${target.label} has raw bzl path in deps: $dep');
    }
  }
}

Set<String> _resolveExpectedDeps(
  _BzlTarget target,
  List<String> loads,
  Map<String, _BzlTarget> fileToTarget,
  _DepsCheckResult result,
) {
  final expected = <String>{};
  for (final loadPath in loads) {
    _collectLoadDeps(target, loadPath, fileToTarget, expected, result);
  }
  return expected;
}

void _collectLoadDeps(
  _BzlTarget target,
  String loadPath,
  Map<String, _BzlTarget> fileToTarget,
  Set<String> expected,
  _DepsCheckResult result,
) {
  if (loadPath.startsWith('@bazel_skylib//')) {
    final String skylibTarget = loadPath.endsWith('.bzl')
        ? loadPath.substring(0, loadPath.length - 4)
        : loadPath;
    expected.add(skylibTarget);
    return;
  }
  if (loadPath.startsWith('@rules_cc//')) {
    expected.add('@rules_cc//cc/common');
    expected.add('@rules_cc//cc/common:cc_shared_library_info_bzl');
    return;
  }
  if (loadPath.startsWith('//') ||
      loadPath.startsWith(':') ||
      loadPath.startsWith('@rules_dart//')) {
    final String relPath = _loadToFilePath(loadPath, target.packagePath);
    final _BzlTarget? depTarget = fileToTarget[relPath];
    if (depTarget == null) {
      result.missingDeps.add(
        '${target.label} loads $loadPath (file $relPath) which has no target!',
      );
    } else {
      expected.add(depTarget.label);
    }
  }
}

void _checkDepDiscrepancies(
  _BzlTarget target,
  Set<String> expectedDeps,
  _DepsCheckResult result,
) {
  final Set<String> targetDeps = target.deps
      .map((d) => _normalizeTargetLabel(d, target.packagePath))
      .toSet();

  for (final expected in expectedDeps) {
    if (!targetDeps.contains(expected)) {
      result.missingDeps.add(
        '${target.label} misses expected load dependency: $expected',
      );
    }
  }

  for (final String dep in target.deps) {
    final String normDep = _normalizeTargetLabel(dep, target.packagePath);
    if (!expectedDeps.contains(normDep)) {
      result.unneededDeps.add(
        '${target.label} has unneeded dependency in deps: $dep',
      );
    }
  }
}

String _findWorkspaceRoot(List<String> args) {
  if (args.isNotEmpty) {
    final String? root = _anchorRoot(args.first);
    if (root != null) return root;
  }
  final Map<String, String> env = Platform.environment;
  for (final String? start in [
    env['BUILD_WORKSPACE_DIRECTORY'],
    env['BUILD_WORKING_DIRECTORY'],
    Directory.current.path,
  ]) {
    final String? root = _sourceRootAbove(start);
    if (root != null) return root;
  }
  throw StateError(
    'Failed to locate workspace root; ensure test runs unsandboxed',
  );
}

String? _anchorRoot(String arg) {
  try {
    final String located = Runfiles.create().rlocation(arg);
    if (!File(located).existsSync()) return null;
    final String resolved = File(located).resolveSymbolicLinksSync();
    return _sourceRootAbove(Directory(resolved).parent.path);
  } on Object catch (_) {
    // Return null if runfiles lookup fails and fall back to environment.
    return null;
  }
}

String? _sourceRootAbove(String? start) {
  Directory? dir = start == null ? null : Directory(start);
  while (dir != null) {
    final module = File('${dir.path}/MODULE.bazel');
    if (module.existsSync()) {
      final String root = File(module.resolveSymbolicLinksSync()).parent.path;
      if (FileSystemEntity.typeSync('$root/dart', followLinks: false) ==
          FileSystemEntityType.directory) {
        return root;
      }
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
  return null;
}

int _skipDocstring(String text, int start, String triple, StringBuffer out) {
  var i = start;
  while (i < text.length) {
    if (i + 2 < text.length && text.substring(i, i + 3) == triple) {
      out.write('   ');
      return i + 2;
    }
    out.write(text[i] == '\n' ? '\n' : ' ');
    i++;
  }
  return text.length - 1;
}

int _skipComment(String text, int start, StringBuffer out) {
  var i = start;
  while (i < text.length && text[i] != '\n') {
    out.write(' ');
    i++;
  }
  return i - 1;
}

String _blankDocstringsAndComments(String text) {
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    if (i + 2 < text.length &&
        (text.substring(i, i + 3) == '"""' ||
            text.substring(i, i + 3) == "'''")) {
      final String triple = text.substring(i, i + 3);
      out.write('   ');
      i = _skipDocstring(text, i + 3, triple, out);
    } else if (text[i] == '#') {
      i = _skipComment(text, i, out);
    } else {
      out.write(text[i]);
    }
  }
  return out.toString();
}

List<String> _extractLoads(String bzlContent) {
  final String clean = _blankDocstringsAndComments(bzlContent);
  final loads = <String>[];
  final Iterable<RegExpMatch> matches = RegExp(
    r'''^\s*load\s*\(\s*["']([^"']+)["']''',
    multiLine: true,
  ).allMatches(clean);
  for (final m in matches) {
    loads.add(m.group(1)!);
  }
  return loads;
}

String _normalizeTargetLabel(String target, String currentPkg) {
  if (target.startsWith(':')) {
    return currentPkg.isEmpty ? target : '//$currentPkg$target';
  }
  return target;
}

String _loadToFilePath(String loadPath, String currentPkg) {
  String path;
  if (loadPath.startsWith('@rules_dart//')) {
    path = loadPath.substring('@rules_dart//'.length);
  } else if (loadPath.startsWith('//')) {
    path = loadPath.substring('//'.length);
  } else if (loadPath.startsWith(':')) {
    return currentPkg.isEmpty
        ? loadPath.substring(1)
        : '$currentPkg/${loadPath.substring(1)}';
  } else {
    return '';
  }
  return path.replaceAll(':', '/');
}

String _relPath(String root, File file) {
  return file.path.substring(root.length + 1).replaceAll(r'\', '/');
}

List<File> _findNonTestBzlFiles(String root) {
  final files = <File>[];
  final dartDir = Directory('$root/dart');
  if (dartDir.existsSync()) {
    for (final FileSystemEntity entity in dartDir.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('.bzl')) {
        final String rel = _relPath(root, entity);
        if (!rel.startsWith('dart/tests/') &&
            !rel.startsWith('dart/pub/tests/')) {
          files.add(entity);
        }
      }
    }
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

List<_BzlTarget> _loadAllBzlLibraryTargets(String root) {
  final targets = <_BzlTarget>[];
  final dartDir = Directory('$root/dart');
  if (dartDir.existsSync()) {
    for (final FileSystemEntity entity in dartDir.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('BUILD.bazel')) {
        final String rel = _relPath(root, entity);
        if (!rel.startsWith('dart/tests/') &&
            !rel.startsWith('dart/pub/tests/')) {
          final String pkg = entity.parent.path
              .substring(root.length + 1)
              .replaceAll(r'\', '/');
          targets.addAll(_parseBuildFile(pkg, entity.readAsStringSync()));
        }
      }
    }
  }
  targets.sort((a, b) => a.label.compareTo(b.label));
  return targets;
}

Map<String, _BzlTarget> _indexTargetsBySource(List<_BzlTarget> targets) {
  final map = <String, _BzlTarget>{};
  for (final target in targets) {
    for (final String src in target.srcs) {
      final key = target.packagePath.isEmpty
          ? src
          : '${target.packagePath}/$src';
      map[key] = target;
    }
  }
  return map;
}

int _skipStringLiteral(String content, int start, String quote) {
  var i = start;
  while (i < content.length) {
    if (content[i] == quote && content[i - 1] != r'\') {
      return i;
    }
    i++;
  }
  return content.length - 1;
}

int _findCallEnd(String content, int start) {
  var depth = 1;
  for (var i = start; i < content.length; i++) {
    final String ch = content[i];
    if (ch == '"' || ch == "'") {
      i = _skipStringLiteral(content, i + 1, ch);
    } else if (ch == '(') {
      depth++;
    } else if (ch == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return content.length;
}

List<String> _extractAttributeList(String body, String attr) {
  final RegExpMatch? m = RegExp('$attr\\s*=\\s*\\[([^\\]]*)\\]')
      .firstMatch(body);
  if (m == null) return const [];
  return RegExp('''["']([^"']+)["']''')
      .allMatches(m.group(1)!)
      .map((e) => e.group(1)!)
      .toList();
}

_BzlTarget? _parseBzlTarget(String pkgPath, String body) {
  final RegExpMatch? nameMatch = RegExp(r'''name\s*=\s*["']([^"']+)["']''')
      .firstMatch(body);
  if (nameMatch == null) return null;
  return _BzlTarget(
    packagePath: pkgPath,
    name: nameMatch.group(1)!,
    srcs: _extractAttributeList(body, 'srcs'),
    deps: _extractAttributeList(body, 'deps'),
    visibility: _extractAttributeList(body, 'visibility'),
  );
}

List<_BzlTarget> _parseBuildFile(String pkgPath, String content) {
  final targets = <_BzlTarget>[];
  final Iterable<RegExpMatch> matches = RegExp(r'\bbzl_library\s*\(')
      .allMatches(content);
  for (final match in matches) {
    final int end = _findCallEnd(content, match.end);
    final String body = content.substring(match.end, end);
    final _BzlTarget? target = _parseBzlTarget(pkgPath, body);
    if (target != null) {
      targets.add(target);
    }
  }
  return targets;
}
