// Checks shipped plans against their locks, and the planning they come from.
//
// Arguments are pairs of runfiles paths: a `pubspec.lock` and its plan. Each
// pair must plan exactly the lock's hosted entries, or the module that ships
// them makes requests in every module that depends on it.

import 'dart:io';

import 'package:rules_dart_pub_plan/plan.dart';
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

const _lock = '''
packages:
  meta:
    dependency: transitive
    description:
      name: meta
      sha256: "aaaa"
      url: "https://pub.dev"
    source: hosted
    version: "1.2.0"
  local:
    dependency: "direct main"
    description:
      path: "../local"
      relative: true
    source: path
    version: "0.0.1"
sdks:
  dart: ">=3.0.0 <4.0.0"
''';

void main(List<String> args) {
  final Runfiles? runfiles = args.isEmpty ? null : Runfiles.create();
  for (var i = 0; i + 1 < args.length; i += 2) {
    final String lock = args[i];
    final String plan = args[i + 1];
    test('$plan plans exactly the hosted entries of $lock', () {
      final List<String> problems = planProblems(
        File(runfiles!.rlocation(lock)).readAsStringSync(),
        File(runfiles.rlocation(plan)).readAsStringSync(),
      );
      expect(
        problems,
        isEmpty,
        reason: 'regenerate it: bazel run @rules_dart//dart/pub/plan -- write',
      );
    });
  }

  test('a lock plans its hosted entries only, under the extension key', () {
    final Map<String, HostedEntry> entries = hostedEntries(_lock);
    expect(entries.keys, ['meta']);
    expect(
      entries['meta']!.key,
      'pub.plan.v1/hosted/meta/1.2.0/aaaa/https://pub.dev',
    );
  });

  test(
    'a listing plans the locked version: sorted names, sdk, archive url',
    () {
      final HostedEntry entry = hostedEntries(_lock)['meta']!;
      final Map<String, Object> plan = planFromListing({
        'versions': [
          {'version': '1.1.0', 'pubspec': <String, Object?>{}},
          {
            'version': '1.2.0',
            'archive_sha256': 'AAAA',
            'archive_url': 'https://pub.dev/api/archives/meta-1.2.0.tar.gz',
            'pubspec': {
              'dependencies': {'z': '^1.0.0', 'a': '^2.0.0'},
              'environment': {'sdk': '^3.0.0'},
            },
          },
        ],
      }, entry);
      expect(plan, {
        'deps': ['a', 'z'],
        'sdk': '^3.0.0',
        'archive_url': 'https://pub.dev/api/archives/meta-1.2.0.tar.gz',
      });
    },
  );

  test('a listing without an archive url plans the fallback url', () {
    final HostedEntry entry = hostedEntries(_lock)['meta']!;
    final Map<String, Object> plan = planFromListing({
      'versions': [
        {'version': '1.2.0', 'pubspec': <String, Object?>{}},
      ],
    }, entry);
    expect(
      plan['archive_url'],
      'https://pub.dev/packages/meta/versions/1.2.0.tar.gz',
    );
    expect(plan['deps'], isEmpty);
    expect(plan['sdk'], '');
  });

  test('a listing that contradicts the lock is refused', () {
    final HostedEntry entry = hostedEntries(_lock)['meta']!;
    expect(
      () => planFromListing({
        'versions': [
          {
            'version': '1.2.0',
            'archive_sha256': 'bbbb',
            'pubspec': <String, Object?>{},
          },
        ],
      }, entry),
      throwsFormatException,
    );
    expect(
      () => planFromListing({'versions': <Object>[]}, entry),
      throwsFormatException,
    );
  });

  test('a stale plan names what it misses and what it has extra', () {
    final String stale = renderPlan({
      'pub.plan.v1/hosted/meta/1.1.0/aaaa/https://pub.dev': {
        'deps': <String>[],
        'sdk': '',
        'archive_url': 'u',
      },
    });
    final List<String> problems = planProblems(_lock, stale);
    expect(problems, hasLength(2));
    expect(problems.first, contains('no plan for meta 1.2.0'));
    expect(problems.last, contains('meta/1.1.0'));
  });

  test('a plan of the lock has no problems', () {
    final HostedEntry entry = hostedEntries(_lock)['meta']!;
    final String good = renderPlan({
      entry.key: {
        'deps': <String>[],
        'sdk': '',
        'archive_url': entry.fallbackArchiveUrl,
      },
    });
    expect(planProblems(_lock, good), isEmpty);
    expect(
      planProblems(_lock, '{"schema": "pub.plan.v0", "plans": {}}'),
      hasLength(1),
    );
  });
}
