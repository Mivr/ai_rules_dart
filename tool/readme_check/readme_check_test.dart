/// Fail-closed check over the README install block (M-7).
///
/// The install block must resolve as written in a fresh root module:
/// a `bazel_dep` on `ai_rules_dart` beside an `archive_override` whose URL,
/// `integrity` and `strip_prefix` describe the same release, with every code
/// fence in the file balanced. Each violation is one finding string; an empty
/// list means the block is honest.
///
/// The live test reads the real `README.md` through its runfiles data file
/// (falling back to an ancestor walk for a direct `dart test` run). The unit
/// tests pin the checker against one inline block per failure shape,
/// including the pre-fix block, so the check would have failed before the
/// fix without needing the old file around.
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// One `bazel_dep` call's facts, each null when its attribute is absent.
class _BazelDep {
  const _BazelDep({
    required this.name,
    required this.version,
    required this.repoName,
  });

  final String? name;
  final String? version;
  final String? repoName;
}

/// One `archive_override` call's facts, each null when absent.
class _ArchiveOverride {
  const _ArchiveOverride({
    required this.module,
    required this.urlTag,
    required this.integrity,
    required this.stripPrefix,
  });

  final String? module;
  final String? urlTag;
  final String? integrity;
  final String? stripPrefix;
}

void main(List<String> args) {
  group('readme install block', () {
    test('the install block resolves as written', () {
      final readme = File(_locateReadme(args)).readAsStringSync();
      final findings = checkReadme(readme);
      expect(findings, isEmpty, reason: '\n${findings.join('\n')}');
    });
  });

  group('checker unit tests', () {
    test('the fixed block passes', () {
      expect(checkReadme(_goodReadme), isEmpty);
    });

    test("the pre-fix block without an override fails", () {
      final findings = checkReadme(_oldReadme);
      expect(findings, isNotEmpty);
      expect(
        findings.any((f) => f.contains('archive_override')),
        isTrue,
        reason: '\n${findings.join('\n')}',
      );
      expect(
        findings.any((f) => f.contains('fence')),
        isTrue,
        reason: '\n${findings.join('\n')}',
      );
    });

    test('a wrong module or repo name fails', () {
      final findings = checkInstallBlock(_wrongNamesBlock);
      expect(findings.where((f) => f.contains('ai_rules_dart')), isNotEmpty);
      expect(findings.where((f) => f.contains('rules_dart')), isNotEmpty);
    });

    test('a version, tag and prefix mismatch fails', () {
      final findings = checkInstallBlock(_mismatchBlock);
      expect(findings.length, 2);
      expect(findings.join('\n'), contains('URL tag'));
      expect(findings.join('\n'), contains('strip_prefix'));
    });

    test('a non-SRI integrity fails', () {
      expect(checkInstallBlock(_hexIntegrityBlock), isNotEmpty);
      expect(checkInstallBlock(_sha384IntegrityBlock), isNotEmpty);
    });

    test('an unbalanced fence fails', () {
      expect(fencesBalanced(' ```dart\nx\n```\n'), isTrue);
      expect(fencesBalanced('````\n## Usage\n'), isFalse);
      expect(fencesBalanced('```dart\nx\n'), isFalse);
    });
  });
}

/// Every finding in [readme]'s install block and fences; empty when honest.
List<String> checkReadme(String readme) {
  final findings = <String>[];
  final block = _installBlock(readme);
  if (block.isEmpty) {
    findings.add('no ```starlark install block in README.md');
  } else {
    findings.addAll(checkInstallBlock(block));
  }
  if (!fencesBalanced(readme)) {
    findings.add('a code fence in README.md is unbalanced');
  }
  return findings;
}

/// Every finding in one install [block]; empty when it resolves as written.
List<String> checkInstallBlock(String block) {
  final findings = <String>[];
  final dep = _parseDep(block);
  if (dep == null) {
    findings.add('no bazel_dep call in the install block');
  } else {
    if (dep.name != 'ai_rules_dart') {
      findings.add('bazel_dep name is "${dep.name}", want "ai_rules_dart"');
    }
    if (dep.repoName != 'rules_dart') {
      findings.add(
        'bazel_dep repo_name is "${dep.repoName}", want "rules_dart"',
      );
    }
  }
  final override = _parseOverride(block);
  if (override == null) {
    findings.add('no archive_override call in the install block');
    return findings;
  }
  if (dep != null && override.module != dep.name) {
    findings.add(
      'archive_override module_name "${override.module}" disagrees '
      'with bazel_dep name "${dep.name}"',
    );
  }
  if (dep != null && override.urlTag != 'v${dep.version}') {
    findings.add(
      'archive_override URL tag "${override.urlTag}" disagrees '
      'with bazel_dep version "${dep.version}"',
    );
  }
  if (dep != null && override.stripPrefix != 'rules_dart-${dep.version}') {
    findings.add(
      'archive_override strip_prefix "${override.stripPrefix}" disagrees '
      'with bazel_dep version "${dep.version}"',
    );
  }
  if (!_isSha256Sri(override.integrity)) {
    findings.add(
      'archive_override integrity "${override.integrity}" '
      'is not a sha256 SRI string',
    );
  }
  return findings;
}

/// Whether every code fence in [text] opens and closes with three backticks.
bool fencesBalanced(String text) {
  var open = false;
  for (final line in text.split('\n')) {
    final run = _leadingBackticks(line);
    if (run < 3) continue;
    if (run > 3) return false;
    open = !open;
  }
  return !open;
}

/// The first ```starlark block's body, or empty when there is none.
String _installBlock(String readme) {
  const open = '```starlark';
  final start = readme.indexOf(open);
  if (start == -1) return '';
  final end = readme.indexOf('```', start + open.length);
  if (end == -1) return '';
  return readme.substring(start + open.length, end);
}

/// The parsed `bazel_dep` call, or null when the block has none.
_BazelDep? _parseDep(String block) {
  final args = _callArgs(block, 'bazel_dep');
  if (args == null) return null;
  return _BazelDep(
    name: _stringArg(args, 'name'),
    version: _stringArg(args, 'version'),
    repoName: _stringArg(args, 'repo_name'),
  );
}

/// The parsed `archive_override` call, or null when the block has none.
_ArchiveOverride? _parseOverride(String block) {
  final args = _callArgs(block, 'archive_override');
  if (args == null) return null;
  return _ArchiveOverride(
    module: _stringArg(args, 'module_name'),
    urlTag: _releaseTag.firstMatch(args)?.group(1),
    integrity: _stringArg(args, 'integrity'),
    stripPrefix: _stringArg(args, 'strip_prefix'),
  );
}

/// The argument list of the first [name] call; calls here nest no parens.
String? _callArgs(String block, String name) {
  final match = RegExp('\\b$name\\(([^)]*)\\)').firstMatch(block);
  return match?.group(1);
}

/// The value of the `"quoted"` [name] argument, or null when absent.
String? _stringArg(String args, String name) {
  final match = RegExp('\\b$name\\s*=\\s*"([^"]*)"').firstMatch(args);
  return match?.group(1);
}

/// Whether [value] is a sha256 SRI string: base64 of exactly 32 bytes.
bool _isSha256Sri(String? value) => value != null && _sri.hasMatch(value);

/// `sha256-` plus the base64 of a 32-byte digest: 43 chars plus one `=`.
final _sri = RegExp(r'^sha256-[A-Za-z0-9+/]{43}=$');

/// The `releases/download/<tag>/` tag of the override URL, when present.
final _releaseTag = RegExp(r'releases/download/([^"/]+)/');

/// The leading backtick run of one line, ignoring indentation.
int _leadingBackticks(String line) {
  final trimmed = line.trimLeft();
  var run = 0;
  while (run < trimmed.length && trimmed[run] == '`') {
    run++;
  }
  return run;
}

/// The README path: the runfiles data file under Bazel, else an ancestor.
String _locateReadme(List<String> args) {
  if (args.isNotEmpty && _underBazel()) {
    final located = Runfiles.create().rlocation(args.first);
    if (File(located).existsSync()) return located;
  }
  var dir = Directory.current;
  while (true) {
    final candidate = File('${dir.path}${Platform.pathSeparator}README.md');
    if (candidate.existsSync()) return candidate.path;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail(
        'cannot locate README.md: neither the runfiles data file nor any '
        'ancestor of the current directory holds one',
      );
    }
    dir = parent;
  }
}

/// Whether the test runs under Bazel, where runfiles resolve.
bool _underBazel() {
  final env = Platform.environment;
  return env.containsKey('TEST_SRCDIR') ||
      env.containsKey('RUNFILES_MANIFEST_FILE') ||
      env.containsKey('RUNFILES_DIR');
}

/// A README with the fixed install block and balanced fences.
const _goodReadme = '''
# Bazel rules for Dart

```starlark
bazel_dep(name = "ai_rules_dart", version = "0.18.0", repo_name = "rules_dart")
archive_override(
    module_name = "ai_rules_dart",
    urls = ["https://github.com/Mivr/rules_dart/releases/download/v0.18.0/rules_dart-v0.18.0.tar.gz"],
    integrity = "sha256-9sFt975mhYbFlKNUJ0F9dExQzCu6yv9Dc+WEGsxVuO0=",
    strip_prefix = "rules_dart-0.18.0",
)
```

## Usage

```shell
bazel run @rules_dart//dart -- --version
```
''';

/// A README with the pre-fix install block and the stray fences.
const _oldReadme = '''
```starlark
bazel_dep(name = "ai_rules_dart", version = "0.14.0", repo_name = "rules_dart")
```

````

## Usage
''';

/// An install block with the wrong module and repo names.
const _wrongNamesBlock = '''
bazel_dep(name = "rules_dart", version = "0.18.0", repo_name = "other")
archive_override(
    module_name = "rules_dart",
    urls = ["https://github.com/Mivr/rules_dart/releases/download/v0.18.0/rules_dart-v0.18.0.tar.gz"],
    integrity = "sha256-9sFt975mhYbFlKNUJ0F9dExQzCu6yv9Dc+WEGsxVuO0=",
    strip_prefix = "rules_dart-0.18.0",
)
''';

/// An install block whose tag and prefix belong to another release.
const _mismatchBlock = '''
bazel_dep(name = "ai_rules_dart", version = "0.18.0", repo_name = "rules_dart")
archive_override(
    module_name = "ai_rules_dart",
    urls = ["https://github.com/Mivr/rules_dart/releases/download/v0.17.0/rules_dart-v0.17.0.tar.gz"],
    integrity = "sha256-9sFt975mhYbFlKNUJ0F9dExQzCu6yv9Dc+WEGsxVuO0=",
    strip_prefix = "rules_dart-0.17.0",
)
''';

/// An install block with a hex checksum instead of an SRI string.
const _hexIntegrityBlock = '''
bazel_dep(name = "ai_rules_dart", version = "0.18.0", repo_name = "rules_dart")
archive_override(
    module_name = "ai_rules_dart",
    urls = ["https://github.com/Mivr/rules_dart/releases/download/v0.18.0/rules_dart-v0.18.0.tar.gz"],
    integrity = "f6c16df7be668586c594a35427417d744c50cc2bbacaff4373e5841acc55b8ed",
    strip_prefix = "rules_dart-0.18.0",
)
''';

/// An install block with a sha384 integrity instead of a sha256 one.
const _sha384IntegrityBlock = '''
bazel_dep(name = "ai_rules_dart", version = "0.18.0", repo_name = "rules_dart")
archive_override(
    module_name = "ai_rules_dart",
    urls = ["https://github.com/Mivr/rules_dart/releases/download/v0.18.0/rules_dart-v0.18.0.tar.gz"],
    integrity = "sha384-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    strip_prefix = "rules_dart-0.18.0",
)
''';
