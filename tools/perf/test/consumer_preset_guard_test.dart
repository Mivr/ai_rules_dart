import 'dart:io';

import 'package:test/test.dart';

import 'repo_root.dart';

/// Normalizes a Bazel flag value string, returning 'true' or 'false' for
/// boolean values, or stripped string value otherwise.
String _normalizeFlagValue(String? raw, {required bool isNegated}) {
  if (isNegated) return 'false';
  if (raw == null) return 'true';
  final unquoted = raw.replaceAll('"', '').replaceAll("'", '').trim();
  switch (unquoted.toLowerCase()) {
    case '1':
    case 'true':
    case 'yes':
      return 'true';
    case '0':
    case 'false':
    case 'no':
      return 'false';
    default:
      return unquoted;
  }
}

/// Normalizes a Bazel flag name by replacing hyphens with underscores.
String _normalizeFlagName(String name) => name.replaceAll('-', '_');

/// Maps each unconditional setting in [rcText] to its normalized value.
///
/// Lines with a `:config` suffix (`common:ci`) and comments are skipped.
Map<String, String> settings(String rcText) {
  final out = <String, String>{};
  for (final String raw in rcText.split('\n')) {
    final String line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    // Strip trailing inline comments.
    final String code = line.split(RegExp(r'\s+#')).first.trim();
    // Match unconditional commands: common, build, test, run, startup, etc.
    final RegExpMatch? m = RegExp(
      r'^[a-z_]+\s+--(?:no-?([A-Za-z0-9_-]+)|([A-Za-z0-9_-]+))(?:[=\s](.*))?$',
    ).firstMatch(code);
    if (m == null) continue;
    final bool isNegated = m.group(1) != null;
    final String name = _normalizeFlagName(m.group(1) ?? m.group(2)!);
    out[name] = _normalizeFlagValue(m.group(3), isNegated: isNegated);
  }
  return out;
}

/// Loads all repository settings by parsing `.bazelrc` and recursively
/// following any `import` / `try-import` paths.
Map<String, String> loadRepoSettings(String root) {
  final out = <String, String>{};
  final visited = <String>{};

  void loadRc(String relPath) {
    final normalized = relPath.replaceFirst(RegExp(r'^%workspace%/'), '');
    if (!visited.add(normalized)) return;
    final file = File('$root/$normalized');
    if (!file.existsSync()) return;
    final text = file.readAsStringSync();
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      final importMatch = RegExp(
        r'^(?:try-)?import\s+(?:%workspace%/)?([^\s#]+)',
      ).firstMatch(line);
      if (importMatch != null) {
        loadRc(importMatch.group(1)!);
      }
    }
    out.addAll(settings(text));
  }

  loadRc('.bazelrc');
  return out;
}

/// Settings both [shipped] and [repo] carry whose values differ.
List<String> disagreements(
  Map<String, String> shipped,
  Map<String, String> repo,
) => <String>[
  for (final MapEntry<String, String> e in shipped.entries)
    if (repo.containsKey(e.key) && repo[e.key] != e.value) e.key,
];

/// Whether the README names [file] and shows an `import` line for it.
bool readmeNamesFile(String readme, String file) =>
    readme.contains(file) &&
    RegExp(
      r'^import\s+.*' + RegExp.escape(file) + r'\s*$',
      multiLine: true,
    ).hasMatch(readme);

/// Tests whether a glob pattern from gitattributes matches [path].
bool _gitPatternMatches(String pattern, String path) {
  var pat = pattern.trim();
  if (pat.isEmpty) return false;

  final bool isDirOnly = pat.endsWith('/');
  if (isDirOnly) {
    pat = pat.substring(0, pat.length - 1);
  }

  final bool isRootAnchored = pat.startsWith('/');
  if (isRootAnchored) {
    pat = pat.substring(1);
  }

  final regexBuf = StringBuffer('^');
  final bool matchAnywhere = !isRootAnchored && !pat.contains('/');
  if (matchAnywhere) {
    regexBuf.write('(?:.*/)?');
  }

  for (var i = 0; i < pat.length; i++) {
    final c = pat[i];
    if (c == '*' && i + 1 < pat.length && pat[i + 1] == '*') {
      regexBuf.write('.*');
      i++;
      if (i + 1 < pat.length && pat[i + 1] == '/') {
        regexBuf.write('/?');
        i++;
      }
    } else if (c == '*') {
      regexBuf.write('[^/]*');
    } else if (c == '?') {
      regexBuf.write('[^/]');
    } else if (r'\.^$|()[]{}*+?'.contains(c)) {
      regexBuf.write(r'\');
      regexBuf.write(c);
    } else {
      regexBuf.write(c);
    }
  }

  if (isDirOnly) {
    regexBuf.write('/.*');
  } else {
    regexBuf.write(r'(?:/.*)?$');
  }

  return RegExp(regexBuf.toString()).hasMatch(path);
}

/// Whether `git archive` would drop [file] under [attributes].
bool archiveIgnores(String attributes, String file) {
  var ignored = false;
  for (final raw in attributes.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final pattern = parts.first;
    final attrs = parts.sublist(1);
    if (_gitPatternMatches(pattern, file)) {
      if (attrs.contains('export-ignore')) {
        ignored = true;
      } else if (attrs.contains('-export-ignore') ||
          attrs.contains('!export-ignore') ||
          attrs.contains('export-ignore=false')) {
        ignored = false;
      }
    }
  }
  return ignored;
}

/// Guards the shipped consumer preset `dart/consumer.bazelrc`.
void main(List<String> args) {
  const file = 'dart/consumer.bazelrc';
  final String root = locateRepoRoot(args);
  String read(String rel) => File('$root/$rel').readAsStringSync();

  group('consumer preset', () {
    test('carries settings', () {
      expect(settings(read(file)), isNotEmpty);
    });

    test("agrees with this repository's .bazelrc on shared settings", () {
      final repo = loadRepoSettings(root);
      expect(disagreements(settings(read(file)), repo), isEmpty);
    });

    test('is named in the README with an import line', () {
      expect(readmeNamesFile(read('README.md'), file), isTrue);
    });

    test('lists each setting from the consumer preset in README', () {
      final readme = read('README.md');
      final presetSettings = settings(read(file));
      for (final name in presetSettings.keys) {
        expect(
          readme.contains(name),
          isTrue,
          reason: 'README should describe setting $name',
        );
      }
    });

    test('is not export-ignored from git archive', () {
      expect(archiveIgnores(read('.gitattributes'), file), isFalse);
    });

    test('does not weaken gates, lockfiles, or hermeticity', () {
      final preset = settings(read(file));
      expect(preset.containsKey('lockfile_mode'), isFalse);
      expect(preset.containsKey('check_direct_dependencies'), isFalse);
    });
  });

  group('guard unit tests', () {
    test('a differing shared value is reported', () {
      expect(
        disagreements(
          settings('common --nobuild_runfile_links\n'),
          settings('common --build_runfile_links\n'),
        ),
        <String>['build_runfile_links'],
      );
    });

    test('boolean flag variants and normalizations are handled', () {
      expect(
        settings(
          'build --no-reuse_sandbox_directories',
        )['reuse_sandbox_directories'],
        'false',
      );
      expect(
        settings(
          'common --reuse-sandbox-directories=0',
        )['reuse_sandbox_directories'],
        'false',
      );
      expect(
        settings(
          'common --reuse-sandbox-directories=no',
        )['reuse_sandbox_directories'],
        'false',
      );
      expect(
        settings(
          'common --reuse_sandbox_directories=yes',
        )['reuse_sandbox_directories'],
        'true',
      );
      expect(
        settings(
          'common --reuse_sandbox_directories=1',
        )['reuse_sandbox_directories'],
        'true',
      );
    });

    test('inline trailing comments are stripped', () {
      expect(
        settings(
          'common --reuse_sandbox_directories # reuse sandboxes\n',
        )['reuse_sandbox_directories'],
        'true',
      );
    });

    test('config-suffixed lines are skipped', () {
      expect(settings('common:ci --announce_rc\n'), isEmpty);
    });

    test('a README without the import line fails', () {
      expect(readmeNamesFile('mentions dart/consumer.bazelrc', file), isFalse);
    });

    test('an export-ignored path is detected via exact or glob pattern', () {
      expect(archiveIgnores('/dart/ export-ignore\n', file), isTrue);
      expect(archiveIgnores('*.bazelrc export-ignore\n', file), isTrue);
      expect(archiveIgnores('dart/*.bazelrc export-ignore\n', file), isTrue);
      expect(archiveIgnores('/dart/** export-ignore\n', file), isTrue);
      expect(
        archiveIgnores('dart/consumer.bazelrc export-ignore\n', file),
        isTrue,
      );
    });

    test('an export-ignore unsetting is respected', () {
      const attrs = '''
*.bazelrc export-ignore
dart/consumer.bazelrc -export-ignore
''';
      expect(archiveIgnores(attrs, file), isFalse);
    });
  });
}
