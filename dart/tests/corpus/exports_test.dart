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
    });
  });
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

bool _isInstantiated(String name, String blankedBuild) =>
    RegExp('(^|[^A-Za-z0-9_])${RegExp.escape(name)}\\s*\\(')
        .hasMatch(blankedBuild);

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
