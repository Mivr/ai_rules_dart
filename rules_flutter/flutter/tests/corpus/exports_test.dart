/// Public-export coverage guard for the rule corpus.
///
/// Every public export of the ten user-facing `.bzl` entry points must be
/// either instantiated by `flutter/tests/corpus/BUILD.bazel` or listed in
/// `non_instantiable.txt`. A constant or provider belongs in that file; a
/// rule, macro or aspect does not — it has a fixture.
///
/// It also checks the golden scope (`golden_scope.dart`): every fixture is in
/// exactly one of `golden_targets.txt` and `uncovered_golden.txt`.
///
/// The workspace root is discovered from this test's own runfile (or
/// `BUILD_WORKSPACE_DIRECTORY`), like the static guards in `flutter/tests`,
/// so the test reads the sources a change actually wrote rather than a copy
/// frozen into the test target.
library;

import 'dart:io';

import 'package:test/test.dart';

import 'golden_scope.dart';

const List<String> _entryPoints = <String>[
  'flutter/defs.bzl',
  'flutter/android.bzl',
  'flutter/ios.bzl',
  'flutter/linux.bzl',
  'flutter/macos.bzl',
  'flutter/windows.bzl',
  'flutter/web.bzl',
  'flutter/native_assets.bzl',
  'flutter/native_hot_patch.bzl',
  'flutter/dev_files.bzl',
];

bool _isWorkspace(String path) =>
    Directory('$path/flutter/tests/corpus').existsSync() &&
    File('$path/MODULE.bazel').existsSync();

/// The rules_flutter checkout this test runs against, or null when neither
/// the environment nor the runfiles anchor resolves.
String? _workspaceRoot() {
  final Map<String, String> env = Platform.environment;
  final String? fromEnv = env['BUILD_WORKSPACE_DIRECTORY'];
  if (fromEnv != null && fromEnv.isNotEmpty && _isWorkspace(fromEnv)) {
    return fromEnv;
  }
  final String? anchor = env['GUARD_ROOT_ANCHOR'];
  final String? runfiles = env['TEST_SRCDIR'];
  if (anchor == null || anchor.isEmpty || runfiles == null) return null;
  try {
    String current = File('$runfiles/$anchor').resolveSymbolicLinksSync();
    for (var i = 0; i < 8; i++) {
      if (_isWorkspace(current)) return current;
      final String parent = Directory(current).parent.path;
      if (parent == current) break;
      current = parent;
    }
  } on FileSystemException {
    return null;
  }
  return null;
}

/// [text] with comments and quoted strings replaced by spaces. Newlines stay,
/// so a caller can still report line numbers; braces and commas survive.
String _codeOnly(String text) {
  final out = StringBuffer();
  var i = 0;
  while (i < text.length) {
    final String ch = text[i];
    if (ch == '#') {
      while (i < text.length && text[i] != '\n') {
        out.write(' ');
        i++;
      }
      continue;
    }
    if (ch == '"' || ch == "'") {
      final bool triple =
          i + 2 < text.length && text[i + 1] == ch && text[i + 2] == ch;
      final String quote = triple ? ch * 3 : ch;
      out.write(' ' * quote.length);
      i += quote.length;
      while (i < text.length) {
        if (triple &&
            i + 2 < text.length &&
            text.substring(i, i + 3) == quote) {
          out.write('   ');
          i += 3;
          break;
        }
        if (!triple && text[i] == ch) {
          out.write(' ');
          i++;
          break;
        }
        if (text[i] == r'\' && i + 1 < text.length) {
          out.write('  ');
          i += 2;
          continue;
        }
        out.write(text[i] == '\n' ? '\n' : ' ');
        i++;
      }
      continue;
    }
    out.write(ch);
    i++;
  }
  return out.toString();
}

/// The `(name -> kind)` facts a `.bzl` file declares, where kind is one of
/// `def`, `rule`, `aspect` or `provider`. `def` means a Starlark macro.
Map<String, Set<String>> _definitions(String text) {
  final String code = _codeOnly(text);
  final result = <String, Set<String>>{};
  void add(String name, String kind) =>
      result.putIfAbsent(name, () => <String>{}).add(kind);
  for (final RegExpMatch match in RegExp(
    r'^def\s+([A-Za-z_]\w*)\s*\(',
    multiLine: true,
  ).allMatches(code)) {
    add(match.group(1)!, 'def');
  }
  for (final RegExpMatch match in RegExp(
    r'^([A-Za-z_]\w*)\s*=\s*(rule|aspect|provider)\s*\(',
    multiLine: true,
  ).allMatches(code)) {
    add(match.group(1)!, match.group(2)!);
  }
  return result;
}

/// A load()'s local-name -> exported-symbol mapping.
Map<String, String> _loadAliases(String text) {
  final aliases = <String, String>{};
  final Iterable<RegExpMatch> calls = RegExp(
    r'load\s*\(',
    multiLine: true,
  ).allMatches(text);
  for (final call in calls) {
    var depth = 0;
    int end = call.end;
    for (; end < text.length; end++) {
      if (text[end] == '(') depth++;
      if (text[end] == ')') {
        depth--;
        if (depth < 0) break;
      }
    }
    if (end >= text.length) continue;
    final String args = text.substring(call.end, end);
    for (final RegExpMatch match in RegExp(
      r'(?:([A-Za-z_]\w*)\s*=\s*)?"([A-Za-z_]\w*)"',
    ).allMatches(args)) {
      final String? local = match.group(1);
      final String source = match.group(2)!;
      if (local != null) aliases[local] = source;
    }
  }
  return aliases;
}

/// Every public top-level name declared in [text]. Private helper defs are
/// skipped; a provider is public surface even when its name starts with `_`
/// (the corpus lists `_HotPatchFilesInfo` as non-instantiable).
Set<String> _exports(String text) {
  final String code = _codeOnly(text);
  final names = <String>{};
  for (final RegExpMatch match in RegExp(
    r'^def\s+([A-Za-z_]\w*)\s*\(',
    multiLine: true,
  ).allMatches(code)) {
    final String name = match.group(1)!;
    if (!name.startsWith('_')) names.add(name);
  }
  for (final RegExpMatch match in RegExp(
    r'^([A-Za-z_]\w*)\s*=(.*)$',
    multiLine: true,
  ).allMatches(code)) {
    final String name = match.group(1)!;
    final String rhs = match.group(2)!.trimLeft();
    final bool isProvider = rhs.startsWith('provider(');
    if (!name.startsWith('_') || isProvider) names.add(name);
  }
  return names;
}

/// Strips `load(...)` calls, so a name that is merely loaded is not mistaken
/// for a fixture that instantiates it.
String _withoutLoads(String code) {
  final out = StringBuffer();
  var cursor = 0;
  for (final RegExpMatch match in RegExp(r'load\s*\(').allMatches(code)) {
    if (match.start < cursor) continue;
    out.write(code.substring(cursor, match.start));
    var depth = 0;
    int i = match.end - 1;
    for (; i < code.length; i++) {
      if (code[i] == '(') depth++;
      if (code[i] == ')') {
        depth--;
        if (depth == 0) {
          i++;
          break;
        }
      }
    }
    out.write(
      code.substring(match.start, i).replaceAll(RegExp(r'[^\n]'), ' '),
    );
    cursor = i;
  }
  out.write(code.substring(cursor));
  return out.toString();
}

/// The corpus BUILD with comments, strings and load lists blanked, ready for
/// whole-identifier matching.
String _instantiationText(String build) => _withoutLoads(_codeOnly(build));

/// Whether [name] occurs as an identifier in [text].
bool _mentions(String text, String name) =>
    RegExp('(?<![A-Za-z0-9_])${RegExp.escape(name)}(?![A-Za-z0-9_])')
        .hasMatch(text);

Map<String, String> _classifyExports(String root) {
  final allDefs = <String, Set<String>>{};
  final flutter = Directory('$root/flutter');
  for (final FileSystemEntity entity in flutter.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File || !entity.path.endsWith('.bzl')) continue;
    final Map<String, Set<String>> defs = _definitions(
      entity.readAsStringSync(),
    );
    for (final MapEntry<String, Set<String>> entry in defs.entries) {
      allDefs.putIfAbsent(entry.key, () => <String>{}).addAll(entry.value);
    }
  }

  final kinds = <String, String>{};
  for (final String rel in _entryPoints) {
    final file = File('$root/$rel');
    if (!file.existsSync()) {
      throw StateError('public entry point $rel is missing');
    }
    final String text = file.readAsStringSync();
    final String code = _codeOnly(text);
    final Map<String, String> aliases = _loadAliases(text);
    final Map<String, Set<String>> defs = _definitions(text);
    for (final String name in _exports(text)) {
      if (defs[name]?.contains('def') ?? false) {
        kinds[name] = 'macro';
        continue;
      }
      final RegExpMatch? assignment = RegExp(
        '^${RegExp.escape(name)}\\s*=\\s*([^\\n]*)',
        multiLine: true,
      ).firstMatch(code);
      if (assignment == null) {
        kinds[name] = 'macro';
        continue;
      }
      final String rest = assignment.group(1)!.trim();
      if (rest.startsWith('provider(')) {
        kinds[name] = 'provider';
        continue;
      }
      final RegExpMatch? identifier = RegExp(r'^([A-Za-z_]\w*)$')
          .firstMatch(rest);
      if (identifier == null) {
        kinds[name] = 'constant';
        continue;
      }
      final String rhs = identifier.group(1)!;
      final Set<String>? owner =
          allDefs[aliases[rhs] ?? rhs] ?? defs[aliases[rhs] ?? rhs];
      if (owner == null || owner.isEmpty) {
        kinds[name] = 'constant';
      } else if (owner.contains('rule')) {
        kinds[name] = 'rule';
      } else if (owner.contains('aspect')) {
        kinds[name] = 'aspect';
      } else if (owner.contains('provider')) {
        kinds[name] = 'provider';
      } else if (owner.contains('def')) {
        kinds[name] = 'macro';
      } else {
        kinds[name] = 'constant';
      }
    }
  }
  return kinds;
}

List<String> _nonInstantiable(String root) {
  final file = File('$root/flutter/tests/corpus/non_instantiable.txt');
  if (!file.existsSync()) {
    throw StateError('non_instantiable.txt is missing');
  }
  final entries = <String>[];
  for (final String raw in file.readAsLinesSync()) {
    final String line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    entries.add(line);
  }
  return entries;
}

void main() {
  final String? root = _workspaceRoot();
  if (root == null) {
    test('export guard discovers the workspace', () {
      fail(
        'BUILD_WORKSPACE_DIRECTORY does not point at rules_flutter and the '
        'runfiles anchor did not resolve; run this unsandboxed through '
        '//flutter/tests/corpus:exports_test',
      );
    });
    return;
  }

  test('every public export is instantiated or declared non-instantiable', () {
    final Map<String, String> kinds = _classifyExports(root);
    final String build = _instantiationText(
      File('$root/flutter/tests/corpus/BUILD.bazel').readAsStringSync(),
    );
    final List<String> listed = _nonInstantiable(root);
    final problems = <String>[];

    for (final entry in listed) {
      if (!kinds.containsKey(entry)) {
        problems.add('$entry: non_instantiable.txt names no public export');
        continue;
      }
      final String? kind = kinds[entry];
      if (kind == 'rule' || kind == 'macro' || kind == 'aspect') {
        problems.add(
          '$entry: non_instantiable.txt names a $kind; add a corpus fixture',
        );
      }
    }

    for (final MapEntry<String, String> entry in kinds.entries) {
      if (_mentions(build, entry.key)) continue;
      if (listed.contains(entry.key)) continue;
      problems.add(
        '${entry.key}: public ${entry.value} is neither instantiated in '
        'BUILD.bazel nor listed in non_instantiable.txt',
      );
    }

    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('golden covers every buildable fixture and tracks the rest', () {
    String read(String name) =>
        File('$root/flutter/tests/corpus/$name').readAsStringSync();
    final List<String> problems = validateGoldenScope(
      CorpusScopeInput(
        build: read('BUILD.bazel'),
        goldenTargets: read('golden_targets.txt'),
        uncovered: read('uncovered_golden.txt'),
        goldenJson: read('actions.golden.json'),
      ),
    );
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
