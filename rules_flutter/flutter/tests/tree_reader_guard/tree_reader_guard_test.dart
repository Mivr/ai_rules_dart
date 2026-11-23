/// Guard verifying that all root-module `dart_test` targets reading the checkout
/// outside declared inputs carry both `external` and `tree-reader` tags.
library;

import 'dart:io';

import 'package:test/test.dart';

/// A violation where a tree reader is missing a required tag.
typedef Violation = ({
  String packagePath,
  String targetName,
  String missingTag,
});

/// The result of scanning a BUILD file text for `dart_test` targets.
typedef ScanResult = ({
  int dartTestCount,
  int treeReaderCount,
  List<Violation> violations,
});

/// Formats [violation] as a human-readable failure description.
String _formatViolation(Violation violation) =>
    'package "${violation.packagePath}", target "${violation.targetName}": '
    'missing tag "${violation.missingTag}"';

/// If [text] has a string delimiter starting at [index], returns it; else null.
String? _quoteDelimiterAt(String text, int index) {
  if (text.startsWith('"""', index)) return '"""';
  if (text.startsWith("'''", index)) return "'''";
  if (index < text.length) {
    final String char = text[index];
    if (char == '"' || char == "'") return char;
  }
  return null;
}

/// Skips a string literal starting at [start] with delimiter [delim],
/// returning the index immediately after its closing delimiter.
int _skipStringLiteral(String text, int start, String delim) {
  int i = start + delim.length;
  while (i < text.length) {
    if (text[i] == r'\' && i + 1 < text.length) {
      i += 2;
      continue;
    }
    if (text.startsWith(delim, i)) {
      return i + delim.length;
    }
    i++;
  }
  return text.length;
}

/// Strips comments (`# ...`) outside string literals from Starlark [text].
String _stripComments(String text) {
  final buffer = StringBuffer();
  var i = 0;
  while (i < text.length) {
    final String? delim = _quoteDelimiterAt(text, i);
    if (delim != null) {
      final int end = _skipStringLiteral(text, i, delim);
      buffer.write(text.substring(i, end));
      i = end;
      continue;
    }
    if (text[i] == '#') {
      final int newline = text.indexOf('\n', i);
      if (newline == -1) break;
      buffer.write('\n');
      i = newline + 1;
      continue;
    }
    buffer.write(text[i]);
    i++;
  }
  return buffer.toString();
}

/// Whether [char] is an identifier character in Starlark.
bool _isIdentChar(String char) {
  final int code = char.codeUnitAt(0);
  return (code >= 97 && code <= 122) ||
      (code >= 65 && code <= 90) ||
      (code >= 48 && code <= 57) ||
      code == 95;
}

/// Whether [text] has a call to [callName] opening at [index].
bool _isCallStart(String text, int index, String callName) {
  if (index > 0 && _isIdentChar(text[index - 1])) return false;
  if (!text.startsWith(callName, index)) return false;
  int next = index + callName.length;
  while (next < text.length &&
      (text[next] == ' ' ||
          text[next] == '\t' ||
          text[next] == '\n' ||
          text[next] == '\r')) {
    next++;
  }
  return next < text.length && text[next] == '(';
}

/// Finds the index of the matching closing parenthesis for `(` at [openParenIdx].
int _findMatchingParen(String text, int openParenIdx) {
  var depth = 1;
  int i = openParenIdx + 1;
  while (i < text.length) {
    final String? delim = _quoteDelimiterAt(text, i);
    if (delim != null) {
      i = _skipStringLiteral(text, i, delim);
      continue;
    }
    final String char = text[i];
    if (char == '(') {
      depth++;
    } else if (char == ')') {
      depth--;
      if (depth == 0) return i;
    }
    i++;
  }
  return -1;
}

/// Extracts the inner argument bodies of every `dart_test(...)` call in [text].
List<String> _extractDartTests(String text) {
  final String stripped = _stripComments(text);
  final blocks = <String>[];
  var i = 0;
  while (i < stripped.length) {
    final String? delim = _quoteDelimiterAt(stripped, i);
    if (delim != null) {
      i = _skipStringLiteral(stripped, i, delim);
      continue;
    }
    if (_isCallStart(stripped, i, 'dart_test')) {
      final int openParen = stripped.indexOf('(', i);
      final int closeParen = _findMatchingParen(stripped, openParen);
      if (closeParen != -1) {
        blocks.add(stripped.substring(openParen + 1, closeParen));
        i = closeParen + 1;
        continue;
      }
    }
    i++;
  }
  return blocks;
}

/// Extracts all string literal values from `tags = [...]` in [block].
Set<String> _extractTags(String block) {
  final RegExpMatch? match = RegExp(
    r'\btags\s*=\s*\[([^\]]*)\]',
    dotAll: true,
  ).firstMatch(block);
  if (match == null) return const <String>{};
  final tags = <String>{};
  for (final RegExpMatch m in RegExp(
    '''["']([^"']+)["']''',
  ).allMatches(match.group(1)!)) {
    tags.add(m.group(1)!);
  }
  return tags;
}

/// Pattern 1: target's env or env_inherit names GUARD_ROOT_ANCHOR or
/// BUILD_WORKSPACE_DIRECTORY.
bool _matchesPattern1(String block) {
  final RegExpMatch? envMatch = RegExp(
    r'\benv\s*=\s*\{([^}]*)\}',
    dotAll: true,
  ).firstMatch(block);
  if (envMatch != null) {
    final String c = envMatch.group(1)!;
    if (c.contains('GUARD_ROOT_ANCHOR') ||
        c.contains('BUILD_WORKSPACE_DIRECTORY')) {
      return true;
    }
  }
  final RegExpMatch? inheritMatch = RegExp(
    r'\benv_inherit\s*=\s*\[([^\]]*)\]',
    dotAll: true,
  ).firstMatch(block);
  if (inheritMatch != null) {
    final String c = inheritMatch.group(1)!;
    if (c.contains('GUARD_ROOT_ANCHOR') ||
        c.contains('BUILD_WORKSPACE_DIRECTORY')) {
      return true;
    }
  }
  return false;
}

/// Pattern 2: target's Dart source calls resolveSymbolicLinksSync and looks for
/// MODULE.bazel.
bool _matchesPattern2(
  String block,
  String packagePath,
  String? Function(String) readFile,
) {
  final srcPaths = <String>[];
  final RegExpMatch? mainMatch = RegExp(r'''\bmain\s*=\s*["']([^"']+)["']''')
      .firstMatch(block);
  if (mainMatch != null) {
    srcPaths.add(mainMatch.group(1)!);
  }
  final RegExpMatch? srcsMatch = RegExp(
    r'\bsrcs\s*=\s*\[([^\]]*)\]',
    dotAll: true,
  ).firstMatch(block);
  if (srcsMatch != null) {
    for (final RegExpMatch m in RegExp(
      '''["']([^"']+)["']''',
    ).allMatches(srcsMatch.group(1)!)) {
      srcPaths.add(m.group(1)!);
    }
  }
  for (final sp in srcPaths) {
    final String clean = sp.startsWith(':') ? sp.substring(1) : sp;
    final relPath = packagePath.isEmpty ? clean : '$packagePath/$clean';
    final String? content = readFile(relPath);
    if (content != null &&
        content.contains('resolveSymbolicLinksSync') &&
        content.contains('MODULE.bazel')) {
      return true;
    }
  }
  return false;
}

/// Scans Starlark BUILD content for `dart_test` targets and verifies required
/// tags on tree readers.
ScanResult scanBuildText({
  required String packagePath,
  required String buildContent,
  required String? Function(String) readFile,
}) {
  final List<String> blocks = _extractDartTests(buildContent);
  var dartTestCount = 0;
  var treeReaderCount = 0;
  final violations = <Violation>[];

  for (final block in blocks) {
    dartTestCount++;
    final bool isTreeReader =
        _matchesPattern1(block) ||
        _matchesPattern2(block, packagePath, readFile);
    if (!isTreeReader) continue;

    treeReaderCount++;
    final RegExpMatch? nameMatch = RegExp(r'''\bname\s*=\s*["']([^"']+)["']''')
        .firstMatch(block);
    final String targetName =
        nameMatch?.group(1) ??
        RegExp(r'\bname\s*=\s*([a-zA-Z0-9_]+)').firstMatch(block)?.group(1) ??
        'unknown_target';

    final Set<String> tags = _extractTags(block);
    if (!tags.contains('external')) {
      violations.add((
        packagePath: packagePath,
        targetName: targetName,
        missingTag: 'external',
      ));
    }
    if (!tags.contains('tree-reader')) {
      violations.add((
        packagePath: packagePath,
        targetName: targetName,
        missingTag: 'tree-reader',
      ));
    }
  }

  return (
    dartTestCount: dartTestCount,
    treeReaderCount: treeReaderCount,
    violations: violations,
  );
}

/// Verifies whether [dir] looks like the rules_flutter repository root.
bool _isWorkspaceRoot(Directory dir) {
  final module = File('${dir.path}/MODULE.bazel');
  final tests = Directory('${dir.path}/flutter/tests');
  return module.existsSync() && tests.existsSync();
}

/// Resolves the rules_flutter workspace root directory.
String? _findWorkspaceRoot() {
  final String? fromBwd = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (fromBwd != null &&
      fromBwd.isNotEmpty &&
      _isWorkspaceRoot(Directory(fromBwd))) {
    return fromBwd;
  }
  final String? anchor = Platform.environment['GUARD_ROOT_ANCHOR'];
  final String? runfiles = Platform.environment['TEST_SRCDIR'];
  if (anchor != null && runfiles != null) {
    final link = File('$runfiles/$anchor');
    if (link.existsSync()) {
      Directory dir = File(link.resolveSymbolicLinksSync()).parent;
      for (var depth = 0; depth < 16; depth++) {
        if (_isWorkspaceRoot(dir)) return dir.path;
        if (dir.path == dir.parent.path) break;
        dir = dir.parent;
      }
    }
  }
  if (_isWorkspaceRoot(Directory.current)) {
    return Directory.current.path;
  }
  return null;
}

/// Finds every `BUILD.bazel` file under `flutter/` and `tools/`.
List<File> _findWorkspaceBuildFiles(String workspaceRoot) {
  final results = <File>[];
  for (final dirName in const <String>['flutter', 'tools']) {
    final dir = Directory('$workspaceRoot/$dirName');
    if (!dir.existsSync()) continue;
    for (final FileSystemEntity entity in dir.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File &&
          entity.uri.pathSegments.isNotEmpty &&
          entity.uri.pathSegments.last == 'BUILD.bazel') {
        results.add(entity);
      }
    }
  }
  results.sort((File a, File b) => a.path.compareTo(b.path));
  return results;
}

/// Computes the path of [fullPath] relative to [root].
String _relative(String root, String fullPath) {
  final String normalizedRoot = root.replaceAll(r'\', '/');
  final String normalizedPath = fullPath.replaceAll(r'\', '/');
  if (normalizedPath.startsWith('$normalizedRoot/')) {
    return normalizedPath.substring(normalizedRoot.length + 1);
  }
  return normalizedPath;
}

/// Unit tests using synthetic BUILD texts to verify tree reader tag checks.
void _syntheticBuildTests() {
  test('detects tree readers and missing tags from synthetic input', () {
    const syntheticBuild = '''
dart_test(
    name = "missing_tree_reader",
    env = {"GUARD_ROOT_ANCHOR": "anchor"},
    tags = ["external"],
    main = "missing_tr_test.dart",
)

dart_test(
    name = "missing_external",
    env_inherit = ["BUILD_WORKSPACE_DIRECTORY"],
    tags = ["tree-reader"],
    main = "missing_ext_test.dart",
)

dart_test(
    name = "synthetic_non_reader",
    tags = ["some_tag"],
    main = "non_reader_test.dart",
)

dart_test(
    name = "tagged_reader",
    env = {"GUARD_ROOT_ANCHOR": "anchor"},
    tags = ["external", "tree-reader"],
    main = "tagged_reader_test.dart",
)
''';

    final ScanResult result = scanBuildText(
      packagePath: 'synthetic_pkg',
      buildContent: syntheticBuild,
      readFile: (_) => null,
    );

    expect(result.dartTestCount, equals(4));
    expect(result.treeReaderCount, equals(3));

    final List<String> reported = result.violations
        .map(_formatViolation)
        .toList();
    expect(
      reported,
      contains(
        'package "synthetic_pkg", target "missing_tree_reader": missing tag "tree-reader"',
      ),
    );
    expect(
      reported,
      contains(
        'package "synthetic_pkg", target "missing_external": missing tag "external"',
      ),
    );
    expect(
      reported.any((String msg) => msg.contains('synthetic_non_reader')),
      isFalse,
    );
    expect(
      reported.any((String msg) => msg.contains('tagged_reader')),
      isFalse,
    );
  });
}

/// Unit tests verifying detection of Pattern 2 tree readers in Dart sources.
void _pattern2SourceTests() {
  test('detects Pattern 2 tree reader from Dart source inspection', () {
    const syntheticBuild = '''
dart_test(
    name = "pattern2_missing_tag",
    tags = ["external"],
    main = "p2_test.dart",
)
''';

    final ScanResult result = scanBuildText(
      packagePath: 'p2_pkg',
      buildContent: syntheticBuild,
      readFile: (String p) => p == 'p2_pkg/p2_test.dart'
          ? 'void check() { f.resolveSymbolicLinksSync(); read("MODULE.bazel"); }'
          : null,
    );

    expect(result.treeReaderCount, equals(1));
    expect(
      result.violations.map(_formatViolation),
      contains(
        'package "p2_pkg", target "pattern2_missing_tag": missing tag "tree-reader"',
      ),
    );
  });
}

/// Verifies that every root-module tree-reading test carries required tags.
void _workspaceReaderTests() {
  test(
    'all root-module tree-reading tests carry external and tree-reader tags',
    () {
      final String? root = _findWorkspaceRoot();
      expect(root, isNotNull, reason: 'Failed to locate workspace root');

      final List<File> buildFiles = _findWorkspaceBuildFiles(root!);
      expect(buildFiles, isNotEmpty, reason: 'Found no BUILD.bazel files');

      var totalDartTests = 0;
      var totalTreeReaders = 0;
      final violations = <Violation>[];

      for (final buildFile in buildFiles) {
        final String pkgPath = _relative(root, buildFile.parent.path);
        final String content = buildFile.readAsStringSync();
        final ScanResult result = scanBuildText(
          packagePath: pkgPath,
          buildContent: content,
          readFile: (String relPath) {
            final file = File('$root/$relPath');
            return file.existsSync() ? file.readAsStringSync() : null;
          },
        );
        totalDartTests += result.dartTestCount;
        totalTreeReaders += result.treeReaderCount;
        violations.addAll(result.violations);
      }

      expect(
        totalDartTests,
        greaterThan(0),
        reason: 'Expected dart_test targets',
      );
      expect(
        totalTreeReaders,
        greaterThan(0),
        reason: 'Expected tree-reading targets',
      );
      expect(
        violations,
        isEmpty,
        reason:
            'Tree readers missing required tags:\n'
            '${violations.map(_formatViolation).join('\n')}',
      );
    },
  );
}

void main() {
  group('tree_reader_guard unit tests', () {
    _syntheticBuildTests();
    _pattern2SourceTests();
  });
  _workspaceReaderTests();
}
