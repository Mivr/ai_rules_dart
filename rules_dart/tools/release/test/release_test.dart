import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:path/path.dart' as p;
import 'package:release/floor.dart';
import 'package:release/git.dart';
import 'package:release/modules.dart';
import 'package:release/release.dart';
import 'package:release/tools.dart';
import 'package:test/test.dart';

const dartSha = 'e7163aab8f9171f54693cd1b99feb7d3cee9602d';
const flutterSha = '876e263d65ca3eb33e4b05f9b0dc55affc5b3887';

const releaseJson =
    '''
{
  "rules_dart": {
    "tag_prefix": "rules_dart-v",
    "baseline": {"tag": "v0.28.3", "commit": "$dartSha"}
  },
  "rules_flutter": {
    "tag_prefix": "rules_flutter-v",
    "baseline": {"tag": "v0.30.2", "commit": "$flutterSha"}
  }
}
''';

Commit c(String subject, [List<String> entries = const []]) =>
    (subject: subject, entries: entries);

void main() {
  final Map<String, ReleaseModule> modules = parseModules(releaseJson);
  final ReleaseModule dart = modules['rules_dart']!;
  final ReleaseModule flutter = modules['rules_flutter']!;

  group('modules', () {
    test('read the prefix and the baseline of each module', () {
      expect(dart.tagPrefix, 'rules_dart-v');
      expect(showVersion(flutter.baseline), 'v0.30.2');
      expect(flutter.baselineCommit, flutterSha);
    });
    test('a tag belongs to the module whose prefix it has', () {
      expect(dart.versionOfTag('rules_dart-v0.29.0'), isNotNull);
      expect(flutter.versionOfTag('rules_dart-v0.29.0'), isNull);
      // The old single-line tags are nobody's here: the baseline stands for them.
      expect(dart.versionOfTag('v0.28.3'), isNull);
      expect(dart.versionOfTag('rules_dart-v0.29.0-rc1'), isNull);
      expect(dart.tagOf((major: 0, minor: 29, patch: 0)), 'rules_dart-v0.29.0');
    });
    test('a malformed file is refused', () {
      expect(() => parseModules('[]'), throwsFormatException);
      expect(
        () => parseModules(
          '{"m": {"tag_prefix": "m-v", "baseline": {"tag": "0.1", "commit": "x"}}}',
        ),
        throwsFormatException,
      );
    });
  });

  group('latestVersion', () {
    test('is the baseline while the module has no tag of its own', () {
      // rules_dart's v0.28.3 tag and rules_flutter's tags are not rules_dart's.
      expect(
        showVersion(latestVersion(dart, ['v0.28.3', 'rules_flutter-v0.40.0'])),
        'v0.28.3',
      );
      expect(showVersion(latestVersion(flutter, [])), 'v0.30.2');
    });
    test('takes the newest of the module, comparing numbers', () {
      expect(
        showVersion(
          latestVersion(dart, [
            'rules_dart-v0.9.0',
            'rules_dart-v0.30.1',
            'rules_dart-v0.30.10',
            'rules_dart-v0.30.2',
            'rules_flutter-v1.0.0',
          ]),
        ),
        'v0.30.10',
      );
    });
    test('does not go below the baseline', () {
      expect(
        showVersion(latestVersion(flutter, ['rules_flutter-v0.1.0'])),
        'v0.30.2',
      );
    });
  });

  group('tagProblem', () {
    test('accepts a newer version', () {
      expect(tagProblem(dart, 'v0.29.0', ['v0.28.3']), isNull);
      expect(
        tagProblem(flutter, 'v0.30.3', ['rules_dart-v0.29.0']),
        isNull,
        reason: 'the other module\'s tag does not count',
      );
    });
    test('refuses the first tag of a module at or below its baseline', () {
      expect(tagProblem(flutter, 'v0.30.2', []), contains('not newer'));
      expect(tagProblem(flutter, 'v0.29.9', []), contains('not newer'));
    });
    test('refuses an existing tag and an older one', () {
      final tags = ['rules_dart-v0.29.0'];
      expect(tagProblem(dart, 'v0.29.0', tags), contains('exists'));
      expect(tagProblem(dart, 'v0.28.9', tags), contains('not newer'));
    });
    test('refuses what is not vMAJOR.MINOR.PATCH', () {
      expect(tagProblem(dart, '0.29.0', []), contains('must look like'));
      expect(tagProblem(dart, 'v0.29', []), contains('must look like'));
      expect(tagProblem(dart, 'v0.29.0-rc1', []), contains('must look like'));
    });
  });

  group('nextVersion', () {
    Version v(String s) => parseVersion(s)!;
    String? next(String latest, List<Commit> commits) {
      final Version? n = nextVersion(v(latest), commits);
      return n == null ? null : showVersion(n);
    }

    test('a fix with an entry bumps the patch', () {
      expect(
        next('v0.30.0', [
          c('fix(kernel): x', ['Fixed thing']),
        ]),
        'v0.30.1',
      );
    });
    test('a feat bumps the minor and resets the patch', () {
      expect(
        next('v0.29.4', [
          c('fix: a', ['A']),
          c('feat(web): b', ['B']),
        ]),
        'v0.30.0',
      );
    });
    test('a breaking commit bumps the minor while the major is 0', () {
      expect(
        next('v0.28.3', [
          c('fix(herm)!: require x', ['Requires x']),
        ]),
        'v0.29.0',
      );
    });
    test('a breaking commit bumps the major from 1.0 on', () {
      expect(
        next('v1.4.2', [
          c('feat!: drop y', ['Removed y']),
        ]),
        'v2.0.0',
      );
      expect(
        next('v1.4.2', [
          c('feat: z', ['Z']),
        ]),
        'v1.5.0',
      );
    });
    test('only skip entries, or none, release nothing', () {
      expect(
        next('v0.30.0', [
          c('ci: a', ['skip']),
          c('docs: b'),
        ]),
        isNull,
      );
      expect(next('v0.30.0', []), isNull);
    });
    test('a feat without an entry still decides the bump of a release', () {
      expect(
        next('v0.30.0', [
          c('feat: hidden', ['skip']),
          c('fix: shown', ['Shown']),
        ]),
        'v0.31.0',
      );
    });
  });

  group('notesBase', () {
    test('starts at the baseline commit before the module has a release', () {
      expect(notesBase(dart, ['v0.28.3', 'rules_flutter-v0.30.3']), dartSha);
      expect(
        notesBase(flutter, const [], before: (major: 0, minor: 30, patch: 3)),
        flutterSha,
      );
    });
    test('starts at the newest published release older than the target', () {
      final published = [
        'rules_dart-v0.29.0',
        'rules_dart-v0.30.0',
        'rules_dart-v0.31.0',
        'rules_flutter-v0.30.9',
      ];
      expect(
        notesBase(dart, published, before: (major: 0, minor: 31, patch: 0)),
        'rules_dart-v0.30.0',
      );
      expect(notesBase(dart, published), 'rules_dart-v0.31.0');
    });
    test('skips a tag that has no published release', () {
      // v0.30.0 was refused by the gate: it is a tag, not a published release.
      expect(
        notesBase(
          dart,
          ['rules_dart-v0.29.0'],
          before: (major: 0, minor: 31, patch: 0),
        ),
        'rules_dart-v0.29.0',
      );
    });
  });

  group('floor', () {
    late Directory root;
    setUp(() {
      root = Directory.systemTemp.createTempSync('release_floor_test');
      File(p.join(root.path, 'rules_flutter/MODULE.bazel'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'bazel_dep(name = "ai_rules_dart", version = "0.28.3", '
          'repo_name = "rules_dart")\n',
        );
      File(p.join(root.path, 'rules_flutter/e2e/hello/MODULE.bazel'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'bazel_dep(name = "ai_rules_dart", version = "0.28.3", '
          'repo_name = "rules_dart")\n',
        );
      File(p.join(root.path, 'rules_flutter/e2e/other/MODULE.bazel'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'bazel_dep(name = "bazel_skylib", version = "1")\n',
        );
      for (final s in floorSites) {
        final File f = File(p.join(root.path, s.path))
          ..createSync(recursive: true);
        final String old = f.existsSync() ? f.readAsStringSync() : '';
        f.writeAsStringSync('$old${_sample[s.what]}\n');
      }
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('a tree where every place agrees passes', () {
      expect(declaredFloor(root.path), '0.28.3');
      expect(checkFloor(root.path), isEmpty);
    });
    test('names the places that disagree', () {
      File(p.join(root.path, 'rules_flutter/e2e/hello/MODULE.bazel'))
          .writeAsStringSync(
            'bazel_dep(name = "ai_rules_dart", version = "0.27.0")\n',
          );
      final List<String> problems = checkFloor(root.path);
      expect(problems, hasLength(1));
      expect(problems.single, contains('e2e/hello/MODULE.bazel'));
      expect(problems.single, contains('0.27.0, not 0.28.3'));
    });
    test('names a place whose text is gone', () {
      File(p.join(root.path, 'rules_flutter/docs/dependencies.md'))
          .writeAsStringSync('nothing here\n');
      expect(
        checkFloor(root.path).single,
        allOf(contains('dependencies.md'), contains('is gone')),
      );
    });
    test('set writes one version at every place and check then passes', () {
      final List<String> changed = setFloor(root.path, '0.29.0');
      expect(
        changed,
        containsAll([
          'rules_flutter/MODULE.bazel',
          'rules_flutter/e2e/hello/MODULE.bazel',
          'rules_flutter/flutter/tests/dependency_floors.json',
          'rules_flutter/docs/dependencies.md',
          'rules_flutter/README.md',
        ]),
      );
      expect(declaredFloor(root.path), '0.29.0');
      expect(checkFloor(root.path), isEmpty);
      final String table = File(
        p.join(root.path, 'rules_flutter/flutter/tests/dependency_floors.json'),
      ).readAsStringSync();
      expect(RegExp('0\\.29\\.0').allMatches(table), hasLength(3));
      expect(table, isNot(contains('0.28.3')));
      // The other dependency of the unrelated module file is untouched.
      expect(
        File(p.join(root.path, 'rules_flutter/e2e/other/MODULE.bazel'))
            .readAsStringSync(),
        contains('bazel_skylib'),
      );
    });
    test('refuses a floor that is not a bare version', () {
      expect(() => setFloor(root.path, 'v0.29.0'), throwsFormatException);
    });
  });

  group('commitsTouching', () {
    late Directory repo;
    final bool hasGit = Process.runSync('git', ['--version']).exitCode == 0;

    Future<void> commit(String path, String message) async {
      File(p.join(repo.path, path))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '$message\n${DateTime.now().microsecondsSinceEpoch}',
        );
      await git(repo.path, ['add', '-A']);
      await git(repo.path, ['commit', '-q', '-m', message]);
    }

    setUp(() async {
      if (!hasGit) return;
      repo = Directory.systemTemp.createTempSync('release_git_test');
      await git(repo.path, ['init', '-q']);
      await git(repo.path, ['config', 'user.email', 'a@b.c']);
      await git(repo.path, ['config', 'user.name', 'a']);
      await git(repo.path, ['config', 'commit.gpgsign', 'false']);
    });
    tearDown(() {
      if (hasGit) repo.deleteSync(recursive: true);
    });

    test('attributes a commit to each module it touches', () async {
      await commit('start.txt', 'chore: start\n\nChangelog: skip');
      final String since = await git(repo.path, ['rev-parse', 'HEAD']);
      await commit('rules_dart/a.txt', 'fix: dart only\n\nChangelog: Dart fix');
      await commit(
        'rules_flutter/b.txt',
        'fix: flutter only\n\nChangelog: Flutter fix',
      );
      File(p.join(repo.path, 'rules_dart/c.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('c');
      File(p.join(repo.path, 'rules_flutter/c.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('c');
      await git(repo.path, ['add', '-A']);
      await git(repo.path, [
        'commit',
        '-q',
        '-m',
        'feat: both\n\nChangelog: Both modules',
      ]);
      await commit('README.md', 'docs: root only\n\nChangelog: skip');

      Future<List<String>> subjects(String module) async => [
        for (final c in await commitsTouching(repo.path, since, 'HEAD', module))
          c.subject,
      ];
      expect(await subjects('rules_dart'), ['feat: both', 'fix: dart only']);
      expect(await subjects('rules_flutter'), [
        'feat: both',
        'fix: flutter only',
      ]);
      final List<Commit> both = await commitsTouching(
        repo.path,
        since,
        'HEAD',
        'rules_dart',
      );
      expect(both.first.entries, ['Both modules']);
    }, skip: hasGit ? false : 'git is not on PATH');
  });

  group('tools', () {
    final ToolSet set = toolSets['rules_dart']!;
    final SetFiles files = {
      'tools.json': utf8.encode('{"dart_version": "3.13.5"}'),
      'files/module_compiler.aot': [1, 2, 3],
      'files/test_runner': List<int>.generate(700, (i) => i % 251),
    };

    test('a consumer workspace takes the modules from the checkout', () {
      final String module = consumerModule(toolSets['rules_flutter']!, '/r');
      expect(module, contains('repo_name = "rules_dart"'));
      expect(
        module,
        contains('module_name = "ai_rules_flutter", path = "/r/rules_flutter"'),
      );
    });

    test('two builds that agree have no differences', () {
      expect(differences(files, Map.of(files)), isEmpty);
      final other = Map.of(files)..['files/module_compiler.aot'] = [1, 2, 4];
      other.remove('files/test_runner');
      expect(differences(files, other), [
        startsWith('files/module_compiler.aot: '),
        'files/test_runner: only in build 1',
      ]);
    });

    test('the archive is the same bytes for the same files', () async {
      final List<int> a = tarGz(files);
      expect(tarGz(Map.fromEntries(files.entries.toList().reversed)), a);
      final Directory dir = Directory.systemTemp.createTempSync('tools_test_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final archive = File(p.join(dir.path, 'a.tar.gz'))..writeAsBytesSync(a);
      final ProcessResult r = await Process.run('tar', [
        '-xzf',
        archive.path,
        '-C',
        dir.path,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      for (final MapEntry<String, List<int>> e in files.entries) {
        expect(File(p.join(dir.path, e.key)).readAsBytesSync(), e.value);
      }
      if (!Platform.isWindows) {
        final FileStat runner = File(p.join(dir.path, 'files/test_runner'))
            .statSync();
        expect(runner.mode & 0x49, 0x49, reason: 'executable');
      }
    });

    Sidecar sidecar(String platform, String? digest) => Sidecar(
      module: 'rules_dart',
      platform: platform,
      version: '3.13.5',
      sha256: digest,
      problems: digest == null ? ['files/x: a != b'] : [],
    );

    test('the table lists what shipped, and says what did not', () {
      final List<int> archive = tarGz(files);
      final String digest = sha256.convert(archive).toString();
      final result = toolsTable(
        set: set,
        tag: 'rules_dart-v0.30.0',
        download: 'https://example.test/d',
        archives: {
          sidecar('linux-x64', digest): archive,
          sidecar('windows-x64', null): null,
        },
      );
      expect(result.table, {
        'release': 'rules_dart-v0.30.0',
        'tools': {
          '3.13.5': {
            'linux-x64': {
              'url':
                  'https://example.test/d/rules_dart-v0.30.0/'
                  'rules_dart-v0.30.0-tools-3.13.5-linux-x64.tar.gz',
              'sha256': digest,
            },
          },
        },
      });
      expect(result.absent, ['windows-x64: files/x: a != b']);
      expect(
        Sidecar.parse(sidecar('linux-x64', digest).encode()).sha256,
        digest,
      );
    });

    test('a wrong archive, a twice-listed or unknown platform is refused', () {
      final List<int> archive = tarGz(files);
      final String digest = sha256.convert(archive).toString();
      Map<String, Object?> table(Map<Sidecar, List<int>?> archives) =>
          toolsTable(
            set: set,
            tag: 't',
            download: 'd',
            archives: archives,
          ).table;
      expect(
        () => table({
          sidecar('linux-x64', digest): [0],
        }),
        throwsFormatException,
      );
      expect(
        () => table({sidecar('linux-x64', digest): null}),
        throwsFormatException,
      );
      expect(
        () => table({
          sidecar('linux-x64', digest): archive,
          sidecar('linux-x64', null): null,
        }),
        throwsFormatException,
      );
      expect(
        () => table({sidecar('plan9-x64', digest): archive}),
        throwsFormatException,
      );
    });
  });
}

/// A file's text with the place of each floor site, at 0.28.3.
const _sample = <String, String>{
  'floor table':
      '{\n  "ai_rules_dart": {\n    "floor": "0.28.3",\n    "current": "0.28.3",\n'
      '    "resolved": "0.28.3",\n    "lifted_by": []\n  }\n}',
  'dependency table':
      '| `ai_rules_dart` (repo `rules_dart`) | 0.28.3 | symbols |',
  'architecture note': 'The Dart side comes from `ai_rules_dart` 0.28.3, which',
  'README floor sentence': 'Its floor is `ai_rules_dart` 0.28.3, released on',
  'README module table':
      '| Every app | `ai_rules_dart` 0.28.3 (repo_name `rules_dart`) | x |',
  'README override snippet':
      'bazel_dep(name = "ai_rules_dart", version = "0.28.3", repo_name = "r")',
};
