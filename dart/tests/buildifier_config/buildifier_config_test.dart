import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// The one warning of buildifier's full list that the root
/// `.buildifier.json` leaves out.
const String _excludedWarning = 'unsorted-dict-items';

/// The only top-level keys the root `.buildifier.json` may set.
const Set<String> _configKeys = {'type', 'lint', 'warningsList'};

/// The hook mirror whose `rev` tracks the `buildifier_prebuilt` module.
const String _hookRepo = 'keith/pre-commit-buildifier';

/// The format hook of [_hookRepo].
const String _formatHook = 'buildifier';

/// The lint hook of [_hookRepo].
const String _lintHook = 'buildifier-lint';

/// The exact `args` of [_formatHook]: formatting never rewrites a lint.
const List<String> _formatArgs = ['-lint=off'];

/// The module whose `version` must agree with the hook's `rev`.
const String _module = 'buildifier_prebuilt';

/// A `repo:` URL naming [_hookRepo], over HTTPS or SSH, with or without
/// `.git`.
final RegExp _hookRepoUrl = RegExp(
  '(^|[/:])${RegExp.escape(_hookRepo)}(\\.git)?/?\$',
);

/// A buildifier flag that can turn linting off or replace the root config or
/// its warning set, in Go `flag` spelling: one or two dashes, with the value
/// after `=` or in the next argument.
final RegExp _lintFlag = RegExp(r'^--?(lint|config|warnings)(?:=(.*))?$');

/// A version of three numeric components, optionally followed by more.
final RegExp _version = RegExp(r'^(\d+)\.(\d+)\.(\d+)(\..+)?$');

/// A Starlark call to `bazel_dep`, up to its opening parenthesis.
final RegExp _bazelDepCall = RegExp(r'(?<![\w.])bazel_dep\s*\(');

/// One `key = value` call argument.
final RegExp _keywordArgument = RegExp(r'^(\w+)\s*=\s*([\s\S]*)$');

/// A Starlark string literal without escapes, in either quote style.
final RegExp _plainString = RegExp(r'''^(?:"([^"\\]*)"|'([^'\\]*)')$''');

/// Returns what is wrong with the parsed root `.buildifier.json` [config],
/// measured against buildifier's full warning list [example] (its
/// `-config=example` output).
List<String> _configProblems(Object? config, List<String> example) {
  if (config is! Map<String, Object?>) {
    return ['.buildifier.json must be a JSON object'];
  }
  final Set<String> keys = config.keys.toSet();
  return [
    if (!const SetEquality<String>().equals(keys, _configKeys))
      'top-level keys must be exactly $_configKeys, got $keys',
    if (config['type'] != 'auto') '"type" must be "auto"',
    if (config['lint'] != 'warn') '"lint" must be "warn"',
    ..._warningsListProblems(config['warningsList'], example),
  ];
}

/// Returns how [list] differs from [example] without [_excludedWarning]:
/// every missing, extra and duplicated entry.
List<String> _warningsListProblems(Object? list, List<String> example) {
  if (list is! List<Object?> || list.any((Object? w) => w is! String)) {
    return ['"warningsList" must be a list of strings'];
  }
  final List<String> actual = list.cast<String>();
  final Set<String> expected = example.toSet()..remove(_excludedWarning);
  final Set<String> present = actual.toSet();
  final seen = <String>{};
  final Set<String> duplicated = {
    for (final String w in actual)
      if (!seen.add(w)) w,
  };
  return [
    for (final String w in _sorted(expected.difference(present)))
      'missing warning "$w"',
    for (final String w in _sorted(present.difference(expected)))
      'unexpected warning "$w"',
    for (final String w in _sorted(duplicated)) 'duplicated warning "$w"',
  ];
}

/// Returns [values] in sorted order, so problem lists are stable.
List<String> _sorted(Set<String> values) => values.toList()..sort();

/// Returns what is wrong with the buildifier hooks of [preCommit], the text
/// of `.pre-commit-config.yaml`: [_hookRepo] must be listed once, with one
/// [_formatHook] and one [_lintHook], and no other repo may define either id.
List<String> _hookProblems(String preCommit) {
  final List<YamlMap> repos = _repos(preCommit);
  final List<YamlMap> mirrors = _mirrors(repos);
  if (mirrors.length != 1) {
    return ['$_hookRepo must be listed once, found ${mirrors.length}'];
  }
  final List<YamlMap> hooks = _hooks(mirrors.single);
  final List<YamlMap> format = _withId(hooks, _formatHook);
  final List<YamlMap> lint = _withId(hooks, _lintHook);
  return [
    for (final YamlMap repo in repos)
      if (!identical(repo, mirrors.single))
        for (final YamlMap hook in _hooks(repo))
          if (hook['id'] == _formatHook || hook['id'] == _lintHook)
            'id: ${hook['id']} must come only from $_hookRepo',
    if (format.length != 1) 'id: $_formatHook must appear once',
    if (lint.length != 1) 'id: $_lintHook must appear once',
    if (format.length == 1) ..._formatHookProblems(format.single),
    if (lint.length == 1) ..._lintHookProblems(lint.single),
  ];
}

/// Returns the `rev` of the single [_hookRepo] entry of [preCommit], or null
/// when the repo is not listed exactly once or has no `rev`.
String? _hookRev(String preCommit) {
  final List<YamlMap> mirrors = _mirrors(_repos(preCommit));
  if (mirrors.length != 1) {
    return null;
  }
  return switch (mirrors.single.nodes['rev']) {
    YamlScalar(value: final String rev) => rev,
    final YamlScalar rev => rev.span.text,
    _ => null,
  };
}

/// The entries of the top-level `repos` list of [preCommit].
List<YamlMap> _repos(String preCommit) => [
  if (loadYaml(preCommit) case YamlMap(nodes: {'repos': final YamlList repos}))
    ...repos.whereType<YamlMap>(),
];

/// The entries of [repos] whose `repo:` names [_hookRepo].
List<YamlMap> _mirrors(List<YamlMap> repos) => [
  for (final YamlMap repo in repos)
    if (repo['repo'] case final String url when _hookRepoUrl.hasMatch(url))
      repo,
];

/// The `hooks` of one `repos` entry.
List<YamlMap> _hooks(YamlMap repo) => [
  if (repo['hooks'] case final YamlList hooks) ...hooks.whereType<YamlMap>(),
];

/// The entries of [hooks] whose `id` is [id].
List<YamlMap> _withId(List<YamlMap> hooks, String id) => [
  for (final YamlMap hook in hooks)
    if (hook['id'] == id) hook,
];

/// The `args` of [hook] as strings; empty when it sets none.
List<String> _args(YamlMap hook) => [
  if (hook['args'] case final YamlList args)
    for (final Object? arg in args) '$arg',
];

/// Returns what is wrong with [_formatHook]: it keeps the upstream `entry`
/// and runs with exactly [_formatArgs].
List<String> _formatHookProblems(YamlMap hook) {
  final List<String> args = _args(hook);
  return [
    if (hook.containsKey('entry'))
      'id: $_formatHook must keep the upstream entry',
    if (!const ListEquality<String>().equals(args, _formatArgs))
      'id: $_formatHook must have args: $_formatArgs, got $args',
  ];
}

/// Returns what is wrong with [_lintHook]: it keeps the upstream `entry`, and
/// its `args` neither turn linting off nor replace the root config (`-config`)
/// or its warning set (`-warnings`).
List<String> _lintHookProblems(YamlMap hook) => [
  if (hook.containsKey('entry')) 'id: $_lintHook must keep the upstream entry',
  for (final (String name, String? value) in _lintFlags(_args(hook)))
    if (name == 'lint' && value == 'off')
      'id: $_lintHook must not disable linting'
    else if (name == 'config')
      'id: $_lintHook must not override -config'
    else if (name == 'warnings')
      'id: $_lintHook must not override the config warningsList',
];

/// Returns each `-lint`, `-config` and `-warnings` flag in [args] with its
/// value, as Go's `flag` package reads them; the value is null when a
/// two-argument flag is the last argument.
List<(String, String?)> _lintFlags(List<String> args) {
  final flags = <(String, String?)>[];
  for (var i = 0; i < args.length; i++) {
    final RegExpMatch? match = _lintFlag.firstMatch(args[i]);
    if (match == null) {
      continue;
    }
    final String? inline = match[2];
    final bool takesNext = inline == null && i + 1 < args.length;
    flags.add((match[1]!, takesNext ? args[++i] : inline));
  }
  return flags;
}

/// Returns the `version` of every `bazel_dep` call in [module], the text of a
/// `MODULE.bazel`, whose `name` is [name]: the string's contents for a plain
/// string literal, the source text otherwise, null when it has no `version`.
/// A call inside a comment or a string literal does not count.
List<String?> _bazelDepVersions(String module, String name) {
  final (:String source, :String structure) = _blanked(module);
  return [
    for (final RegExpMatch call in _bazelDepCall.allMatches(structure))
      if (_keywordArguments(_callArguments(source, structure, call.end - 1))
          case final Map<String, String> kwargs when kwargs['name'] == name)
        kwargs['version'],
  ];
}

/// Returns two views of the Starlark [code], aligned index for index with it:
/// `source` blanks every `#` comment, and `structure` also blanks every
/// string literal (single, double or triple quoted), so a bracket, comma or
/// call inside a string or a comment is invisible to it.
({String source, String structure}) _blanked(String code) {
  final source = StringBuffer();
  final structure = StringBuffer();
  var i = 0;
  while (i < code.length) {
    final String c = code[i];
    if (c == '"' || c == "'") {
      final int end = _stringEnd(code, i);
      source.write(code.substring(i, end));
      structure.write(' ' * (end - i));
      i = end;
    } else if (c == '#') {
      final int end = _lineEnd(code, i);
      source.write(' ' * (end - i));
      structure.write(' ' * (end - i));
      i = end;
    } else {
      source.write(c);
      structure.write(c);
      i++;
    }
  }
  return (source: source.toString(), structure: structure.toString());
}

/// Returns the index of the newline that ends the line holding [start] in
/// [code], or the length of [code] on its last line.
int _lineEnd(String code, int start) {
  final int newline = code.indexOf('\n', start);
  return newline < 0 ? code.length : newline;
}

/// Returns the index just past the string literal (single, double or
/// triple quoted) that opens at [start] in [code].
int _stringEnd(String code, int start) {
  final String quote = code.startsWith('"""', start)
      ? '"""'
      : code.startsWith("'''", start)
      ? "'''"
      : code[start];
  int i = start + quote.length;
  while (i < code.length && !code.startsWith(quote, i)) {
    i += code[i] == r'\' ? 2 : 1;
  }
  return i + quote.length > code.length ? code.length : i + quote.length;
}

/// Returns the trimmed, non-empty arguments, taken from [source], of the call
/// whose `(` is at [open] in [structure], split at the commas outside any
/// nested bracket. Both views come from [_blanked].
List<String> _callArguments(String source, String structure, int open) {
  final arguments = <String>[];
  var depth = 0;
  int start = open + 1;
  for (var i = start; i < structure.length; i++) {
    final String c = structure[i];
    if ('([{'.contains(c)) {
      depth++;
    } else if (c == ',' && depth == 0) {
      arguments.add(source.substring(start, i));
      start = i + 1;
    } else if (')]}'.contains(c)) {
      if (depth == 0) {
        arguments.add(source.substring(start, i));
        break;
      }
      depth--;
    }
  }
  return [
    for (final String argument in arguments)
      if (argument.trim().isNotEmpty) argument.trim(),
  ];
}

/// Returns the `key = value` arguments of [arguments], each value unquoted
/// when it is a plain string literal.
Map<String, String> _keywordArguments(List<String> arguments) => {
  for (final String argument in arguments)
    if (_keywordArgument.firstMatch(argument) case final RegExpMatch m)
      m[1]!: _unquoted(m[2]!.trim()),
};

/// Returns the contents of the plain string literal [value], or [value]
/// itself when it is any other expression.
String _unquoted(String value) {
  final RegExpMatch? match = _plainString.firstMatch(value);
  return match == null ? value : match[1] ?? match[2]!;
}

/// Returns why the hook [rev] and the module [version] disagree: both must
/// carry three numeric components that agree, and when neither has a fourth
/// component they must be equal strings.
List<String> _versionProblems(String rev, String version) {
  final RegExpMatch? r = _version.firstMatch(rev);
  final RegExpMatch? v = _version.firstMatch(version);
  if (r == null || v == null) {
    return ['rev "$rev" and version "$version" need three numeric components'];
  }
  final bool sameRelease = [
    1,
    2,
    3,
  ].every((int i) => int.parse(r[i]!) == int.parse(v[i]!));
  return [
    if (!sameRelease)
      'rev "$rev" and version "$version" differ in the first three components'
    else if (r[4] == null && v[4] == null && rev != version)
      'rev "$rev" and version "$version" must be equal',
  ];
}

/// Runs `buildifier -config=example` and returns its `warningsList`.
List<String> _exampleWarnings(String buildifier) {
  final ProcessResult result = Process.runSync(buildifier, const [
    '-config=example',
  ], runInShell: Platform.isWindows);
  expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  final Object? example = jsonDecode(result.stdout as String);
  if (example case {'warningsList': final List<Object?> warnings}) {
    return warnings.cast<String>();
  }
  fail('buildifier -config=example printed no warningsList: $example');
}

void main(List<String> args) {
  _configTests();
  _hookTests();
  _moduleTests();

  // `args`, in order: `@buildifier_prebuilt//:buildifier`, then the root
  // `.buildifier.json`, `.pre-commit-config.yaml` and `MODULE.bazel`.
  group('repository', () {
    final runfiles = Runfiles.create();
    final List<String> paths = [for (final a in args) runfiles.rlocation(a)];
    String read(int i) => File(paths[i]).readAsStringSync();

    test('takes buildifier and the three repository files as runfiles', () {
      expect(paths, hasLength(4));
    });

    test(".buildifier.json is buildifier's full list less "
        '$_excludedWarning', () {
      final List<String> example = _exampleWarnings(paths[0]);
      expect(example, contains(_excludedWarning));
      expect(_configProblems(jsonDecode(read(1)), example), isEmpty);
    });

    test('$_formatHook runs $_formatArgs and $_lintHook lints against the '
        'root config', () {
      expect(_hookProblems(read(2)), isEmpty);
    });

    test('the hook rev and the $_module version agree', () {
      final String? rev = _hookRev(read(2));
      final List<String?> versions = _bazelDepVersions(read(3), _module);
      expect(rev, isNotNull, reason: '$_hookRepo needs a rev');
      expect(versions, hasLength(1), reason: 'one bazel_dep on $_module');
      expect(versions.single, isNotNull, reason: '$_module needs a version');
      expect(_versionProblems(rev!, versions.single!), isEmpty);
    });
  });
}

/// Unit tests of [_configProblems] over in-memory configs.
void _configTests() {
  group('configProblems', () {
    const List<String> example = ['a', 'b', _excludedWarning];
    Map<String, Object?> config(List<Object?> warnings) => {
      'type': 'auto',
      'lint': 'warn',
      'warningsList': warnings,
    };

    test('accepts the example list less $_excludedWarning, in any order', () {
      expect(_configProblems(config(['b', 'a']), example), isEmpty);
    });
    test('rejects a missing, extra or duplicated warning', () {
      expect(_configProblems(config(['a']), example), isNotEmpty);
      expect(_configProblems(config(['a', 'b', 'c']), example), isNotEmpty);
      expect(_configProblems(config(['a', 'b', 'a']), example), isNotEmpty);
      expect(_configProblems(config([...example]), example), isNotEmpty);
      expect(_configProblems(config(['a', 'b', 1]), example), isNotEmpty);
    });
    test('rejects another type, lint or top-level key', () {
      for (final MapEntry<String, Object?> change in const {
        'type': 'build',
        'lint': 'fix',
        'mode': 'fix',
      }.entries) {
        final Map<String, Object?> changed = config(['a', 'b'])
          ..[change.key] = change.value;
        expect(_configProblems(changed, example), isNotEmpty);
      }
      expect(_configProblems(['a', 'b'], example), isNotEmpty);
    });
  });
}

/// Unit tests of [_hookProblems], [_hookRev] and [_lintFlags] over in-memory
/// `.pre-commit-config.yaml` texts.
void _hookTests() {
  String preCommit({
    String format = '        args: [-lint=off]\n',
    String lint = '',
    String extra = '',
  }) =>
      'repos:\n'
      '  - repo: https://github.com/keith/pre-commit-buildifier\n'
      '    rev: 10.1.0\n'
      '    hooks:\n'
      '      - id: buildifier\n'
      '$format'
      '      - id: buildifier-lint\n'
      '$lint'
      '$extra';

  group('hookProblems', () {
    test('accepts -lint=off on the format hook and no lint hook args', () {
      expect(_hookProblems(preCommit()), isEmpty);
      expect(_hookRev(preCommit()), '10.1.0');
    });
    test('rejects a format hook without exactly -lint=off', () {
      for (final format in [
        '',
        '        args: [-lint=fix]\n',
        '        args: [-lint=off, -mode=fix]\n',
        '        entry: buildifier -lint=fix\n        args: [-lint=off]\n',
      ]) {
        expect(_hookProblems(preCommit(format: format)), isNotEmpty);
      }
    });
    test('rejects a lint hook that disables linting or overrides config', () {
      for (final lint in [
        '        args: [-lint=off]\n',
        '        args: [--lint, "off"]\n',
        '        args: [-config=other.json]\n',
        '        args: [--config, other.json]\n',
        '        args: [-warnings=all]\n',
        '        entry: buildifier -lint=off\n',
      ]) {
        expect(_hookProblems(preCommit(lint: lint)), isNotEmpty, reason: lint);
      }
    });
    test('rejects a second buildifier entry point', () {
      const local =
          '  - repo: local\n'
          '    hooks:\n'
          '      - id: buildifier\n';
      expect(_hookProblems(preCommit(extra: local)), isNotEmpty);
      final String twice =
          preCommit() + preCommit().substring('repos:\n'.length);
      expect(_hookProblems(twice), isNotEmpty);
      expect(_hookRev(twice), isNull);
    });
  });

  test('lintFlags reads both Go flag spellings', () {
    expect(_lintFlags(['-mode=check', '--lint', 'off', '-config=x', '-v']), [
      ('lint', 'off'),
      ('config', 'x'),
    ]);
    expect(_lintFlags(['-warnings']), [('warnings', null)]);
  });
}

/// Unit tests of [_bazelDepVersions] and [_versionProblems].
void _moduleTests() {
  group('bazelDepVersions', () {
    test('reads the version of the named dependency only', () {
      const module = '''
"""Doc: bazel_dep(name = "buildifier_prebuilt", version = "1.0.0")."""
# bazel_dep(name = "buildifier_prebuilt", version = "2.0.0")
bazel_dep(name = "other", version = "3.0.0", repo_name = "buildifier_prebuilt")
bazel_dep(
    version = '10.1.0',  # a comment with ) and "
    name = "buildifier_prebuilt",
    dev_dependency = True,
)
''';
      expect(_bazelDepVersions(module, _module), ['10.1.0']);
    });
    test('reports a dependency without a version', () {
      const module = 'bazel_dep(name = "buildifier_prebuilt")\n';
      expect(_bazelDepVersions(module, _module), [null]);
    });
  });

  group('versionProblems', () {
    test('accepts versions that agree on three components', () {
      expect(_versionProblems('10.1.0', '10.1.0'), isEmpty);
      expect(_versionProblems('10.1.0', '10.1.0.2'), isEmpty);
      expect(_versionProblems('10.1.0.1', '10.1.0.bcr.1'), isEmpty);
    });
    test('rejects versions that differ or are malformed', () {
      for (final (String rev, String version) in const [
        ('10.2.0', '10.1.0'),
        ('10.1.1.1', '10.1.0.1'),
        ('10.1.00', '10.1.0'),
        ('v10.1.0', '10.1.0'),
        ('10.1', '10.1'),
      ]) {
        expect(_versionProblems(rev, version), isNotEmpty, reason: rev);
      }
    });
  });
}
