import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// The public surface of the rule set, checked against the corpus.
void main(List<String> args) {
  final String root = _workspaceRoot(args);
  final Map<String, String> sources = _readSources(root);
  final Set<String> exports = _extractExports(sources);
  final Set<String> rulesAndMacros = _rulesAndMacros(sources);
  final Map<String, String> listed = _readNonInstantiable(root);
  final String build = _blankComments(
    File('$root/dart/tests/corpus/BUILD.bazel').readAsStringSync(),
  );

  test('the rule set exposes its public surface', () {
    expect(exports, contains('dart_library'));
    expect(exports, contains('DartCodeAssetInfo'));
    expect(exports, contains('parse_semver'));
    expect(exports, contains('freezed_library'));
    expect(exports.length, greaterThan(30));
  });

  test('every public export is instantiated or listed', () {
    final List<String> missing = [
      for (final name in exports)
        if (!_isInstantiated(name, build) && !listed.containsKey(name)) name,
    ];
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
      reason: 'non_instantiable.txt names exports that do not exist: $unknown',
    );
  });

  test('no rule or macro is listed as non-instantiable', () {
    final List<String> refused = [
      for (final name in listed.keys)
        if (rulesAndMacros.contains(name)) name,
    ];
    expect(
      refused,
      isEmpty,
      reason:
          'non_instantiable.txt may hold providers and constants, never rules '
          'or macros: $refused',
    );
  });

  test('every non-instantiable entry gives a reason', () {
    final List<String> empty = [
      for (final entry in listed.entries)
        if (entry.value.trim().isEmpty) entry.key,
    ];
    expect(empty, isEmpty, reason: 'entries without a reason: $empty');
  });
}

String _workspaceRoot(List<String> args) {
  if (args.isNotEmpty) {
    final String start = File(Runfiles.create().rlocation(args.first))
        .parent
        .path;
    final String? root = _rootAbove(start);
    if (root != null) return root;
    fail('cannot find the workspace root above $start');
  }
  for (final String? start in [
    Platform.environment['BUILD_WORKSPACE_DIRECTORY'],
    Directory.current.path,
  ]) {
    final String? root = _rootAbove(start ?? '');
    if (root != null) return root;
  }
  fail('cannot find the workspace root; run the test from the workspace');
}

String? _rootAbove(String start) {
  Directory? directory = start.isEmpty ? null : Directory(start);
  while (directory != null) {
    if (File('${directory.path}/MODULE.bazel').existsSync()) {
      return directory.path;
    }
    final Directory parent = directory.parent;
    if (parent.path == directory.path) return null;
    directory = parent;
  }
  return null;
}

Map<String, String> _readSources(String root) {
  final files = <File>[
    File('$root/dart/defs.bzl'),
    File('$root/dart/pub/defs.bzl'),
    ...Directory('$root/dart/ext')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('/defs.bzl')),
  ];
  return {for (final file in files) file.path: file.readAsStringSync()};
}

Set<String> _extractExports(Map<String, String> sources) {
  final names = <String>{};
  for (final String text in sources.values) {
    final String code = _blankComments(_blankDocstrings(text));
    for (final RegExpMatch match in RegExp(
      r'^([A-Za-z][A-Za-z0-9_]*)\s*=',
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
  for (final MapEntry<String, String> entry in sources.entries) {
    if (entry.key.contains('/dart/ext/')) {
      names.addAll(_defs(entry.value));
    } else if (!entry.key.endsWith('/dart/pub/defs.bzl')) {
      names.addAll(
        _assignments(entry.value).where((name) => !name.endsWith('Info')),
      );
    }
  }
  return names;
}

Set<String> _defs(String text) {
  final String code = _blankComments(_blankDocstrings(text));
  return {
    for (final RegExpMatch match in RegExp(
      r'^def\s+([A-Za-z][A-Za-z0-9_]*)',
      multiLine: true,
    ).allMatches(code))
      if (!match.group(1)!.startsWith('_')) match.group(1)!,
  };
}

Set<String> _assignments(String text) {
  final String code = _blankComments(_blankDocstrings(text));
  return {
    for (final RegExpMatch match in RegExp(
      r'^([A-Za-z][A-Za-z0-9_]*)\s*=',
      multiLine: true,
    ).allMatches(code))
      if (!match.group(1)!.startsWith('_')) match.group(1)!,
  };
}

Map<String, String> _readNonInstantiable(String root) {
  final file = File('$root/dart/tests/corpus/non_instantiable.txt');
  final entries = <String, String>{};
  for (final String raw in file.readAsLinesSync()) {
    final String line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final int colon = line.indexOf(':');
    if (colon <= 0) {
      fail('non_instantiable.txt line "$line" is not `name: reason`');
    }
    entries[line.substring(0, colon).trim()] = line.substring(colon + 1).trim();
  }
  return entries;
}

bool _isInstantiated(String name, String build) =>
    RegExp('(^|[^A-Za-z0-9_])${RegExp.escape(name)}\\s*\\(').hasMatch(build);

String _blankDocstrings(String text) => text
    .replaceAll(RegExp(r'"""[\s\S]*?"""'), '')
    .replaceAll(RegExp(r"'''[\s\S]*?'''"), '');

String _blankComments(String text) => text.replaceAll(RegExp(r'#[^\n]*'), '');
