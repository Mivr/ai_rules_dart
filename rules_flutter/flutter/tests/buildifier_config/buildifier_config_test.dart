/// Buildifier configuration guard.
///
/// The root `.buildifier.json` is the one buildifier configuration in this
/// repository, and the pre-commit hooks prek runs are the one buildifier entry
/// point. This test pins three things:
///
/// - the config sets `"type": "auto"` and `"lint": "warn"`, and its
///   `warningsList` is every warning the pinned buildifier knows (the list
///   `buildifier -config=example` prints) except `unsorted-dict-items`, each
///   named once and in the same order;
/// - the `buildifier` format hook runs with `-lint=off`, so formatting never
///   rewrites a lint finding, and the `buildifier-lint` hook neither turns
///   linting off nor replaces the config or its warning list;
/// - the `keith/pre-commit-buildifier` `rev` and the `buildifier_prebuilt`
///   `bazel_dep` name the same buildifier version. That is the first three
///   version components; a fourth is the ruleset's own packaging revision (see
///   `docs/CHORES.md`), so with three components each they are equal.
///
/// Every input is a `data` dependency read through runfiles: the buildifier
/// binary comes from `@buildifier_prebuilt`, and the three repository files
/// are source labels, so an edit to any of them re-runs this test instead of
/// replaying a cached pass.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dependency_floors/dependency_floors_lib.dart';
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// The one warning `buildifier -config=example` lists that the root config
/// leaves out. It asks for every dict literal sorted by key, a layout rule
/// rather than a defect.
const _excludedWarning = 'unsorted-dict-items';

/// The top-level keys the root config sets, and no others.
const _configKeys = ['type', 'lint', 'warningsList'];

/// The pre-commit repository whose hooks run buildifier.
const _hookRepo = 'https://github.com/keith/pre-commit-buildifier';

/// The hook of [_hookRepo] that formats Starlark files.
const _formatHook = 'buildifier';

/// The hook of [_hookRepo] that reports lint findings.
const _lintHook = 'buildifier-lint';

/// The module whose buildifier this test runs and the hook must match.
const _prebuiltModule = 'buildifier_prebuilt';

/// A buildifier version: three components, and optionally a fourth that is
/// the packaging revision of `buildifier_prebuilt`.
final _version = RegExp(r'^\d+\.\d+\.\d+(\.\d+)?$');

final Runfiles _runfiles = Runfiles.create();

/// The `rev` and the hooks of the one `repos` entry for [_hookRepo].
typedef _HookRepo = ({String rev, List<YamlMap> hooks});

/// The path of the runfile whose `$(rlocationpath)` BUILD.bazel stores in the
/// environment variable [variable], failing when either is missing.
String _runfile(String variable) {
  final String? rlocation = Platform.environment[variable];
  if (rlocation == null || rlocation.isEmpty) {
    throw StateError('$variable is unset; BUILD.bazel sets it from `data`');
  }
  final String path = _runfiles.rlocation(rlocation);
  if (!File(path).existsSync()) {
    throw StateError('$variable names $rlocation, which is not in runfiles');
  }
  return path;
}

/// The contents of the runfile named by [variable].
String _read(String variable) => File(_runfile(variable)).readAsStringSync();

/// [source] decoded as a JSON object; [what] names it in a failure.
Map<String, Object?> _jsonObject(String source, String what) {
  final Object? decoded = jsonDecode(source);
  if (decoded is! Map<String, Object?>) {
    throw StateError('$what is not a JSON object');
  }
  return decoded;
}

/// The `warningsList` of the decoded buildifier config [config], which must
/// be a list of strings; [what] names the config in a failure.
List<String> _warningsList(Map<String, Object?> config, String what) {
  final Object? list = config['warningsList'];
  if (list is! List<Object?> || list.any((warning) => warning is! String)) {
    throw StateError('$what has no warningsList of strings');
  }
  return list.cast<String>();
}

/// The `warningsList` of `buildifier -config=example`: every warning the
/// pinned buildifier knows.
List<String> _exampleWarnings() {
  const what = 'buildifier -config=example';
  final ProcessResult result = Process.runSync(_runfile('BUILDIFIER_TOOL'), [
    '-config=example',
  ]);
  if (result.exitCode != 0) {
    throw StateError('$what exited ${result.exitCode}: ${result.stderr}');
  }
  final Object? stdout = result.stdout;
  if (stdout is! String) {
    throw StateError('$what printed no text');
  }
  return _warningsList(_jsonObject(stdout, what), what);
}

/// The entries of [warnings] named more than once.
Set<String> _duplicates(List<String> warnings) {
  final seen = <String>{};
  return {
    for (final warning in warnings)
      if (!seen.add(warning)) warning,
  };
}

/// The `rev` and hooks of the one `repos` entry in the pre-commit config
/// [source] whose `repo` is [_hookRepo].
_HookRepo _hookRepoEntry(String source) {
  final Object? document = loadYaml(source);
  final Object? repos = document is YamlMap ? document['repos'] : null;
  if (repos is! YamlList) {
    throw StateError('.pre-commit-config.yaml has no `repos` list');
  }
  final List<YamlMap> entries = [
    for (final entry in repos.whereType<YamlMap>())
      if (entry['repo'] == _hookRepo) entry,
  ];
  if (entries.length != 1) {
    throw StateError(
      '.pre-commit-config.yaml lists $_hookRepo ${entries.length} times',
    );
  }
  final Object? rev = entries.single['rev'];
  final Object? hooks = entries.single['hooks'];
  if (rev is! String || hooks is! YamlList) {
    throw StateError('$_hookRepo needs a string `rev` and a `hooks` list');
  }
  return (rev: rev, hooks: hooks.whereType<YamlMap>().toList());
}

/// The one hook in [hooks] whose `id` is [id].
YamlMap _hook(List<YamlMap> hooks, String id) {
  final List<YamlMap> matches = [
    for (final hook in hooks)
      if (hook['id'] == id) hook,
  ];
  if (matches.length != 1) {
    throw StateError('$_hookRepo lists hook $id ${matches.length} times');
  }
  return matches.single;
}

/// The `args` of [hook], or none when it sets no `args`.
List<String> _hookArgs(YamlMap hook) {
  final Object? args = hook['args'];
  if (args == null) return const [];
  if (args is! YamlList || args.any((arg) => arg is! String)) {
    throw StateError('hook ${hook['id']} has `args` that are not strings');
  }
  return args.cast<String>();
}

/// The command-line words [hook] adds to buildifier: an `entry` override,
/// which replaces the upstream entry and its flags, then its `args`.
List<String> _hookWords(YamlMap hook) {
  final Object? entry = hook['entry'];
  final List<String> entryWords = entry is String
      ? entry.trim().split(RegExp(r'\s+'))
      : const <String>[];
  return [...entryWords, ..._hookArgs(hook)];
}

/// The value each `-name=value`, `--name=value`, `-name value` or
/// `--name value` flag in [words] sets for the flag [name].
List<String> _flagValues(List<String> words, String name) {
  final flag = RegExp('^--?$name(?:=(.*))?\$');
  return [
    for (var i = 0; i < words.length; i++)
      if (flag.firstMatch(words[i]) case final match?)
        match.group(1) ?? (i + 1 < words.length ? words[i + 1] : ''),
  ];
}

/// The version of the one `buildifier_prebuilt` `bazel_dep` in [module].
String _prebuiltVersion(String module) {
  final List<String> matches = [
    for (final dep in dependencies(module))
      if (dep.name == _prebuiltModule) dep.version,
  ];
  if (matches.length != 1) {
    throw StateError(
      'MODULE.bazel declares $_prebuiltModule ${matches.length} times',
    );
  }
  return matches.single;
}

/// The buildifier release [version] names: its first three components.
String _buildifierRelease(String version) =>
    version.split('.').take(3).join('.');

void _configTests() {
  late final Map<String, Object?> config;
  late final List<String> example;

  setUpAll(() {
    config = _jsonObject(_read('BUILDIFIER_JSON'), '.buildifier.json');
    example = _exampleWarnings();
  });

  test('sets only type, lint and warningsList', () {
    expect(config.keys, unorderedEquals(_configKeys));
  });

  test('detects the file type and reports lint findings as warnings', () {
    expect(config['type'], equals('auto'));
    expect(config['lint'], equals('warn'));
  });

  test('names each warning once', () {
    final List<String> warnings = _warningsList(config, '.buildifier.json');
    expect(_duplicates(warnings), isEmpty, reason: 'duplicated warnings');
  });

  test('lists every buildifier warning except $_excludedWarning', () {
    final List<String> warnings = _warningsList(config, '.buildifier.json');
    expect(
      example,
      contains(_excludedWarning),
      reason: 'the pinned buildifier no longer has $_excludedWarning',
    );
    final List<String> expected = [
      for (final warning in example)
        if (warning != _excludedWarning) warning,
    ];
    expect(
      expected.toSet().difference(warnings.toSet()),
      isEmpty,
      reason: 'buildifier warnings missing from .buildifier.json',
    );
    expect(
      warnings.toSet().difference(expected.toSet()),
      isEmpty,
      reason: 'entries that are not a warning the root config may enable',
    );
    expect(
      warnings,
      orderedEquals(expected),
      reason: 'warningsList follows the order of buildifier -config=example',
    );
  });
}

void _hookTests() {
  late final List<YamlMap> hooks;

  setUpAll(() {
    hooks = _hookRepoEntry(_read('PRE_COMMIT_CONFIG')).hooks;
  });

  test('the format hook runs with linting off', () {
    expect(_hookArgs(_hook(hooks, _formatHook)), equals(['-lint=off']));
  });

  test('the lint hook lints against the root config', () {
    final List<String> words = _hookWords(_hook(hooks, _lintHook));
    expect(
      _flagValues(words, 'lint'),
      everyElement(isNot('off')),
      reason: '$_lintHook must not turn linting off',
    );
    expect(
      _flagValues(words, 'config'),
      isEmpty,
      reason: '$_lintHook must read the root .buildifier.json',
    );
    expect(
      _flagValues(words, 'warnings'),
      isEmpty,
      reason: '$_lintHook must lint with the warningsList of the root config',
    );
  });
}

void _versionTests() {
  late final String rev;
  late final String prebuilt;

  setUpAll(() {
    rev = _hookRepoEntry(_read('PRE_COMMIT_CONFIG')).rev;
    prebuilt = _prebuiltVersion(_read('MODULE_BAZEL'));
  });

  test('the hook rev and $_prebuiltModule are buildifier versions', () {
    expect(rev, matches(_version), reason: '$_hookRepo rev');
    expect(prebuilt, matches(_version), reason: '$_prebuiltModule version');
  });

  test('the hook rev and $_prebuiltModule name one buildifier release', () {
    expect(
      _buildifierRelease(rev),
      equals(_buildifierRelease(prebuilt)),
      reason:
          '$_hookRepo is at $rev but $_prebuiltModule is at $prebuilt; '
          'they must agree on the first three components',
    );
  });
}

void main() {
  group('root .buildifier.json', _configTests);
  group('pre-commit buildifier hooks', _hookTests);
  group('buildifier version', _versionTests);
}
