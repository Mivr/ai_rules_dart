import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

late final String _root;
late final String _job;
late final List<String> _jobSteps;
late final String _reportScript;

/// Locks the shard-1 disk fix in the `test` job of `.github/workflows/ci.yaml`.
void main(List<String> args) {
  setUpAll(() {
    _root = _repoRoot(args);
    final String workflow = File('$_root/.github/workflows/ci.yaml')
        .readAsStringSync();
    _job = _testJob(workflow);
    _jobSteps = _steps(_job);
    _reportScript = File('$_root/.github/scripts/ci_disk_report.sh')
        .readAsStringSync();
  });
  group('measurement', _checkMeasurement);
  group('cleanup', _checkCleanup);
  group('disk cache', _checkCache);
  group('unchanged', _checkUnchanged);
}

/// The text of the top-level `test:` job.
String _testJob(String workflow) {
  final RegExpMatch? m = RegExp(
    r'^  test:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n)',
    multiLine: true,
    dotAll: true,
  ).firstMatch(workflow);
  if (m == null) {
    fail('no `test` job in ci.yaml');
  }
  return m.group(1)!;
}

/// The steps of [job], each as its own text block.
List<String> _steps(String job) {
  final int start = job.indexOf('\n    steps:\n');
  if (start < 0) {
    fail('test job has no steps');
  }
  return job
      .substring(start)
      .split(RegExp('^      - ', multiLine: true))
      .skip(1)
      .toList();
}

/// The step whose block contains [needle].
String _step(String needle) {
  final Iterable<String> hits = _jobSteps.where(
    (String s) => s.contains(needle),
  );
  expect(hits, hasLength(1), reason: 'expected exactly one step with $needle');
  return hits.first;
}

void _checkMeasurement() {
  test('script logs df -h / and names missing directories', () {
    expect(_reportScript, contains('df -h /'));
    expect(_reportScript, contains('du -sh'));
    expect(_reportScript, contains('missing: '));
  });
  const points = {
    'after cache restore': "matrix.os == 'ubuntu-latest'",
    'after Test': "always() && matrix.os == 'ubuntu-latest'",
    'end of job': "always() && matrix.os == 'ubuntu-latest'",
  };
  points.forEach((String label, String cond) {
    test('report $label', () {
      final String step = _step('ci_disk_report.sh "$label"');
      expect(step, contains('if: $cond\n'));
    });
  });
  test('reports run in order around Test', () {
    final int restore = _jobSteps.indexWhere((s) => s.contains('"after cache'));
    final int test = _jobSteps.indexWhere((s) => s.startsWith('name: Test\n'));
    final int after = _jobSteps.indexWhere((s) => s.contains('"after Test"'));
    final int end = _jobSteps.indexWhere((s) => s.contains('"end of job"'));
    expect(restore, lessThan(test));
    expect(test, lessThan(after));
    expect(after, lessThan(end));
  });
}

void _checkCleanup() {
  test('cleanup runs on ubuntu right after checkout', () {
    expect(_jobSteps.first, contains('actions/checkout'));
    final String step = _jobSteps[1];
    expect(step, contains('ci_free_disk.sh'));
    expect(step, contains("if: matrix.os == 'ubuntu-latest'\n"));
  });
  test('cleanup script names the four paths and fails on removal error', () {
    final String script = File('$_root/.github/scripts/ci_free_disk.sh')
        .readAsStringSync();
    for (final p in const [
      '/usr/share/dotnet',
      '/usr/local/lib/android',
      '/opt/ghc',
      '/opt/hostedtoolcache/CodeQL',
    ]) {
      expect(script, contains(p));
    }
    expect(script, contains('df -h /'));
    expect(script, contains('skip: '));
    expect(script, contains('cannot remove'));
    expect(script, contains(r'exit "$status"'));
  });
}

void _checkCache() {
  test('disk-cache GC has a size and an age cap', () {
    expect(
      _job,
      matches(
        RegExp(
          r'^\s+build --experimental_disk_cache_gc_max_size=\d+[KMGT]\n',
          multiLine: true,
        ),
      ),
    );
    expect(
      _job,
      matches(
        RegExp(
          r'^\s+build --experimental_disk_cache_gc_max_age=\d+[dh]\n',
          multiLine: true,
        ),
      ),
    );
    expect(_job, contains('14 GB'));
  });
  test('cache keys are unchanged', () {
    expect(_job, contains('cache-version: "3"'));
  });
}

void _checkUnchanged() {
  test('job is not continue-on-error', () {
    expect(_job, isNot(contains('continue-on-error')));
  });
  test('matrix keeps ubuntu shards 1 to 3 with their folders', () {
    expect(_job, contains('parallelism: 3'));
    const shard1 = [
      '.',
      'e2e/fix',
      'e2e/link_hook',
      'e2e/codegen',
      'e2e/analyze_composition',
      'e2e/cross_compile',
      'tools',
      'e2e/pub_deps',
    ];
    final String block = shard1.map((String f) => '              $f\n').join();
    expect(
      _job,
      contains(
        '          - os: ubuntu-latest\n            shard: 1\n'
        '            parallelism: 3\n            cache: test-linux-1\n'
        '            folders: |\n$block',
      ),
    );
    for (final n in const ['2', '3']) {
      expect(
        _job,
        contains(
          '          - os: ubuntu-latest\n            shard: $n\n'
          '            parallelism: 3\n            cache: test-linux-$n\n',
        ),
      );
    }
  });
  test('Test and corpus steps keep their conditions', () {
    final String testStep = _step('name: Test\n');
    expect(testStep, isNot(contains('if:')));
    for (final name in const ['Corpus tests', 'Corpus action graph']) {
      expect(
        _step('name: $name\n'),
        contains("if: matrix.os == 'ubuntu-latest' && matrix.shard == 1\n"),
      );
    }
  });
}

String _repoRoot(List<String> args) {
  final List<String?> starts = [
    if (args.isNotEmpty) _located(args.first),
    Platform.environment['BUILD_WORKSPACE_DIRECTORY'],
    Platform.environment['BUILD_WORKING_DIRECTORY'],
    Directory.current.path,
  ];
  for (final candidate in starts) {
    final String? found = candidate == null
        ? null
        : _climb(Directory(candidate));
    if (found != null) {
      return found;
    }
  }
  throw StateError('cannot locate the workspace root');
}

/// The directory of the runfile [path], or null when it does not resolve.
String? _located(String path) {
  try {
    final String file = Runfiles.create().rlocation(path);
    return File(file).existsSync() ? File(file).parent.path : null;
  } on Object catch (_) {
    // Not under Bazel: the environment walk takes over.
    return null;
  }
}

/// Nearest ancestor holding both MODULE.bazel and a dart/ tree.
String? _climb(Directory here) {
  var dir = here;
  while (true) {
    if (File('${dir.path}/MODULE.bazel').existsSync() &&
        Directory('${dir.path}/dart').existsSync()) {
      return dir.path;
    }
    if (dir.parent.path == dir.path) {
      return null;
    }
    dir = dir.parent;
  }
}
