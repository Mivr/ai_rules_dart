import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// The public surface of the rule set, checked against the corpus.
void main(List<String> args) {
  final String root = _workspaceRoot(args);
  final Map<String, String> sources = _readSources(root);
  final Set<String> exports = _extractExports(sources);
  final Set<String> repositoryRules = _repositoryRuleExports(root, sources);
  final Set<String> rulesAndMacros = _rulesAndMacros(sources)
    ..removeAll(repositoryRules);
  final Map<String, String> listed = _parseNonInstantiable(
    File('$root/dart/tests/corpus/non_instantiable.txt').readAsLinesSync(),
  );
  final String build = _blankLiteralsAndComments(
    File('$root/dart/tests/corpus/BUILD.bazel').readAsStringSync(),
  );

  group('corpus export coverage', () {
    test('the rule set exposes its public surface', () {
      expect(exports, contains('dart_library'));
      expect(exports, contains('DartCodeAssetInfo'));
      expect(exports, contains('parse_semver'));
      expect(exports, contains('freezed_library'));
      expect(exports.length, greaterThan(30));
    });

    test('every public export is instantiated or listed', () {
      final List<String> missing = _missingExports(exports, build, listed);
      expect(
        missing,
        isEmpty,
        reason:
            'public exports neither instantiated in dart/tests/corpus/BUILD.bazel '
            'nor listed in non_instantiable.txt:\n${missing.join('\n')}',
      );
    });

    test('every non-instantiable entry matches a public export', () {
      final List<String> unknown = [
        for (final name in listed.keys)
          if (!exports.contains(name)) name,
      ];
      expect(
        unknown,
        isEmpty,
        reason:
            'non_instantiable.txt names exports that do not exist: $unknown',
      );
    });

    test('no build rule or macro is listed as non-instantiable', () {
      final List<String> refused = [
        for (final name in listed.keys)
          if (rulesAndMacros.contains(name)) name,
      ];
      expect(
        refused,
        isEmpty,
        reason:
            'non_instantiable.txt may hold providers, constants and repository '
            'rules, never build rules or macros: $refused',
      );
    });

    test('every non-instantiable entry gives a reason', () {
      final List<String> empty = [
        for (final entry in listed.entries)
          if (entry.value.trim().isEmpty) entry.key,
      ];
      expect(empty, isEmpty, reason: 'entries without a reason: $empty');
    });
  });

  _registerClassifierTests();
  _registerVisibilityTests(sources);
}

void _registerVisibilityTests(Map<String, String> sources) {
  group('public facade visibility', () {
    test('every public defs.bzl file declares public visibility', () {
      final List<String> nonPublic = [
        for (final entry in sources.entries)
          if (!_hasPublicVisibility(entry.value)) entry.key,
      ];
      expect(
        nonPublic,
        isEmpty,
        reason:
            'public defs.bzl files without visibility("public"):\n'
            '${nonPublic.join('\n')}',
      );
    });
  });
}

void _registerClassifierTests() {
  group('export extraction and classification', () {
    test('ignores docstrings, comments and string literals', () {
      const sample = <String, String>{
        'dart/defs.bzl': '''
"""
fake_doc_rule = _fake
def fake_doc_macro():
"""
# fake_comment_rule = _fake
dart_sample = _dart_sample
SampleInfo = _SampleInfo
DEFAULT_FLAG = "dart_sample(not_a_call)"
def sample_macro(name):
    inner_local = 1
''',
        'dart/pub/defs.bzl': 'parse_semver = _parse_semver\n',
      };
      final Set<String> found = _extractExports(sample);
      expect(
        found,
        equals({
          'dart_sample',
          'SampleInfo',
          'DEFAULT_FLAG',
          'sample_macro',
          'parse_semver',
        }),
      );
      final Set<String> callables = _rulesAndMacros(sample);
      expect(
        callables,
        equals({'dart_sample', 'sample_macro', 'parse_semver'}),
      );
      final String buildText = _blankLiteralsAndComments(
        '# dart_sample(name = "x")\n'
        'other_rule(name = "dart_sample(x)")\n'
        'sample_macro(name = "ok")\n',
      );
      expect(_isInstantiated('dart_sample', buildText), isFalse);
      expect(_isInstantiated('sample_macro', buildText), isTrue);
      expect(
        _hasPublicVisibility(
          '"""\nvisibility("public")\n"""\nvisibility(["//dart/..."])\n',
        ),
        isFalse,
      );
      expect(_hasPublicVisibility('"""doc"""\nvisibility("public")\n'), isTrue);
    });

    test('does not count a call whose value is thrown away', () {
      final String bare = _blankLiteralsAndComments('helper("1.0.0")\n');
      expect(_isInstantiated('helper', bare), isFalse);
      final String used = _blankLiteralsAndComments(
        'rule(\n    name = "x",\n    inputs = [helper()],\n)\n'
        'value = helper("1")\n'
        'rule(\n    name = "y",\n    inputs = [\n        helper(),\n    ],\n)\n',
      );
      expect(_isInstantiated('helper', used), isTrue);
      expect(_isInstantiated('rule', used), isTrue);
      final String multiline = _blankLiteralsAndComments(
        'helper(\n    "1.0.0",\n)\n',
      );
      expect(_isInstantiated('helper', multiline), isFalse);
    });
  });
}

bool _hasPublicVisibility(String text) {
  final String stripped = text.replaceAll(
    RegExp(
      r'#[^\n]*|"""[\s\S]*?"""|'
      r"'''[\s\S]*?'''",
    ),
    '',
  );
  return RegExp(
    r'^visibility\(\s*"public"\s*\)',
    multiLine: true,
  ).hasMatch(stripped);
}

List<String> _missingExports(
  Set<String> exports,
  String blankedBuild,
  Map<String, String> listed,
) => [
  for (final name in exports)
    if (!_isInstantiated(name, blankedBuild) && !listed.containsKey(name)) name,
];

String _workspaceRoot(List<String> args) {
  if (args.isNotEmpty) {
    final String? anchored = _anchorWorkspaceRoot(args.first);
    if (anchored != null) return anchored;
  }
  for (final String? start in [
    Platform.environment['BUILD_WORKSPACE_DIRECTORY'],
    Directory.current.path,
  ]) {
    final String? root = _realRootAbove(start ?? '');
    if (root != null) return root;
  }
  fail('cannot find the workspace root; run the test from the workspace');
}

String? _anchorWorkspaceRoot(String rlocationPath) {
  try {
    final String located = Runfiles.create().rlocation(rlocationPath);
    final file = File(located);
    if (!file.existsSync()) return null;
    final String resolved = file.resolveSymbolicLinksSync();
    return _realRootAbove(File(resolved).parent.path);
  } on Object {
    // Direct `dart test` runs outside Bazel have no runfiles manifest.
    return null;
  }
}

String? _realRootAbove(String start) {
  Directory? directory = start.isEmpty ? null : Directory(start);
  while (directory != null) {
    final moduleFile = File('${directory.path}/MODULE.bazel');
    if (moduleFile.existsSync()) {
      final String root = File(moduleFile.resolveSymbolicLinksSync())
          .parent
          .path;
      if (FileSystemEntity.typeSync('$root/dart', followLinks: false) ==
          FileSystemEntityType.directory) {
        return root;
      }
    }
    final Directory parent = directory.parent;
    if (parent.path == directory.path) return null;
    directory = parent;
  }
  return null;
}

Map<String, String> _readSources(String root) {
  final List<File> extFiles =
      Directory('$root/dart/ext')
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where(
            (file) => file.path.replaceAll(r'\', '/').endsWith('/defs.bzl'),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final files = <File>[
    File('$root/dart/defs.bzl'),
    File('$root/dart/pub/defs.bzl'),
    ...extFiles,
  ];
  return {
    for (final file in files)
      file.path.replaceAll(r'\', '/'): file.readAsStringSync(),
  };
}

Set<String> _extractExports(Map<String, String> sources) {
  final names = <String>{};
  for (final String text in sources.values) {
    final String code = _blankLiteralsAndComments(text);
    for (final RegExpMatch match in RegExp(
      r'^([A-Za-z][A-Za-z0-9_]*)\s*=(?!=)',
      multiLine: true,
    ).allMatches(code)) {
      names.add(match.group(1)!);
    }
    for (final RegExpMatch match in RegExp(
      r'^def\s+([A-Za-z][A-Za-z0-9_]*)',
      multiLine: true,
    ).allMatches(code)) {
      names.add(match.group(1)!);
    }
  }
  names.removeWhere((name) => name.startsWith('_'));
  return names;
}

Set<String> _rulesAndMacros(Map<String, String> sources) {
  final names = <String>{};
  for (final String text in sources.values) {
    final String code = _blankLiteralsAndComments(text);
    for (final RegExpMatch match in RegExp(
      r'^def\s+([A-Za-z][A-Za-z0-9_]*)',
      multiLine: true,
    ).allMatches(code)) {
      final String name = match.group(1)!;
      if (!name.startsWith('_')) names.add(name);
    }
    for (final RegExpMatch match in RegExp(
      r'^([A-Za-z][A-Za-z0-9_]*)\s*=(?!=)\s*([^\n]*)',
      multiLine: true,
    ).allMatches(code)) {
      final String name = match.group(1)!;
      final String rhs = match.group(2)!.trim();
      if (name.startsWith('_') || _isProviderOrConstant(name, rhs)) continue;
      names.add(name);
    }
  }
  return names;
}

bool _isProviderOrConstant(String name, String rhs) {
  if (name.endsWith('Info') || rhs.startsWith('provider(')) return true;
  if (RegExp(r'^[A-Z][A-Z0-9_]*$').hasMatch(name)) return true;
  return RegExp(r'^(?:True|False|None|-?\d|["\x27\[\{]|struct\()')
      .hasMatch(rhs);
}

Set<String> _repositoryRuleExports(String root, Map<String, String> sources) {
  // A repository rule is re-exported like a macro (`pub_package = _pub_package`)
  // but cannot be instantiated in a BUILD file, so the corpus lists it in
  // `non_instantiable.txt`. Follow each facade's re-export through its `load`
  // to the underlying definition and mark the names that resolve to
  // `repository_rule(...)`, so the "no build rule or macro is listed" check
  // below leaves them alone.
  final repositoryRules = <String>{};
  for (final String text in sources.values) {
    final Map<String, ({String path, String symbol})> aliases = {};
    for (final RegExpMatch match in RegExp(
      r'load\(\s*"([^"]+)"\s*,\s*([^)]*)\)',
    ).allMatches(text)) {
      final String label = match.group(1)!;
      if (!label.startsWith('//')) continue;
      for (final RegExpMatch alias in RegExp(
        r'([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"]+)"',
      ).allMatches(match.group(2)!)) {
        aliases[alias.group(1)!] = (
          path: _labelToPath(label),
          symbol: alias.group(2)!,
        );
      }
    }
    final String code = _blankLiteralsAndComments(text);
    for (final RegExpMatch match in RegExp(
      r'^([A-Za-z][A-Za-z0-9_]*)\s*=\s*(_[A-Za-z_][A-Za-z0-9_]*)',
      multiLine: true,
    ).allMatches(code)) {
      final String name = match.group(1)!;
      final String alias = match.group(2)!;
      final ({String path, String symbol})? target = aliases[alias];
      if (target == null) continue;
      final file = File('$root/${target.path}');
      if (!file.existsSync()) continue;
      if (RegExp(
        '^${RegExp.escape(target.symbol)}\\s*=\\s*repository_rule\\(',
        multiLine: true,
      ).hasMatch(file.readAsStringSync())) {
        repositoryRules.add(name);
      }
    }
  }
  return repositoryRules;
}

String _labelToPath(String label) =>
    label.replaceFirst('//', '').replaceFirst(':', '/');

Map<String, String> _parseNonInstantiable(List<String> lines) {
  final entries = <String, String>{};
  for (final line in lines) {
    final String trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final int colon = trimmed.indexOf(':');
    if (colon <= 0) {
      fail('non_instantiable.txt line "$trimmed" is not `name: reason`');
    }
    entries[trimmed.substring(0, colon).trim()] = trimmed
        .substring(colon + 1)
        .trim();
  }
  return entries;
}

/// Whether [blankedBuild] calls [name] and either uses the result or declares
/// a target.
///
/// A call at the start of a statement that passes `name = ...` is a rule or
/// macro declaring a target. Any other call counts only when its value is
/// used, as an argument, an assignment, a list element and so on: a bare
/// `fn(...)` statement throws the value away and instantiates nothing.
bool _isInstantiated(String name, String blankedBuild) {
  final calls = RegExp('(^|[^A-Za-z0-9_])${RegExp.escape(name)}\\s*\\(');
  for (final RegExpMatch match in calls.allMatches(blankedBuild)) {
    final int start = match.start + match.group(1)!.length;
    final int open = match.end - 1;
    final int close = _matchingParen(blankedBuild, open);
    if (!_isBareStatement(blankedBuild, start, close)) return true;
    if (_passesName(blankedBuild.substring(open + 1, close))) return true;
  }
  return false;
}

int _matchingParen(String text, int open) {
  var depth = 0;
  for (var i = open; i < text.length; i++) {
    if (text[i] == '(') depth++;
    if (text[i] == ')' && --depth == 0) return i;
  }
  return text.length;
}

bool _isBareStatement(String text, int start, int close) {
  final int lineStart =
      (start == 0 ? -1 : text.lastIndexOf('\n', start - 1)) + 1;
  if (text.substring(lineStart, start).trim().isNotEmpty) return false;
  if (_bracketDepth(text.substring(0, start)) != 0) return false;
  final String before = text.substring(0, lineStart).trimRight();
  if (before.isNotEmpty && '=+-*/%|&<>,'.contains(before[before.length - 1])) {
    return false;
  }
  final int lineEnd = text.indexOf('\n', close);
  final String after = text.substring(
    close + 1,
    lineEnd < 0 ? text.length : lineEnd,
  );
  return after.trim().isEmpty;
}

int _bracketDepth(String text) {
  var depth = 0;
  for (final String ch in text.split('')) {
    if ('([{'.contains(ch)) depth++;
    if (')]}'.contains(ch)) depth--;
  }
  return depth;
}

bool _passesName(String args) {
  var depth = 0;
  for (var i = 0; i < args.length; i++) {
    if ('([{'.contains(args[i])) depth++;
    if (')]}'.contains(args[i])) depth--;
    if (depth == 0 &&
        RegExp(r'(^|[\s,])name\s*=(?!=)').matchAsPrefix(args, i) != null) {
      return true;
    }
  }
  return false;
}

String _blankLiteralsAndComments(String text) {
  final out = StringBuffer();
  var index = 0;
  while (index < text.length) {
    final String ch = text[index];
    if (ch == '#') {
      index = _skipComment(text, index);
    } else if (ch == '"' || ch == "'") {
      final quote = text.startsWith('$ch$ch$ch', index) ? '$ch$ch$ch' : ch;
      index = _blankString(text, index, quote, out);
    } else {
      out.write(ch);
      index++;
    }
  }
  return out.toString();
}

int _skipComment(String text, int start) {
  final int newline = text.indexOf('\n', start);
  return newline < 0 ? text.length : newline;
}

int _blankString(String text, int start, String quote, StringBuffer out) {
  out.write(quote);
  int index = start + quote.length;
  while (index < text.length) {
    if (text.startsWith(quote, index)) {
      out.write(quote);
      return index + quote.length;
    }
    if (text[index] == r'\' && index + 1 < text.length) {
      out.write(text[index + 1] == '\n' ? ' \n' : '  ');
      index += 2;
      continue;
    }
    out.write(text[index] == '\n' ? '\n' : ' ');
    index++;
  }
  return index;
}
