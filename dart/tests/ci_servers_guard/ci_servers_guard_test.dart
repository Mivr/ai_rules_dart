import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

late final String _root;
late final String _job;
late final List<String> _jobSteps;

const List<String> _corpus = ['Corpus tests', 'Corpus action graph'];
const List<String> _measured = ['Test', ..._corpus];
const _ubuntu = "matrix.os == 'ubuntu-latest'";
const _shard1 = '$_ubuntu && matrix.shard == 1';
const _ram = '--local_resources=memory=HOST_RAM*.7';
const _folderShutdown = r'--output_base="$outbasedir/$slug" shutdown';

/// Locks the shard-1 Bazel server fix in the `test` job of
/// `.github/workflows/ci.yaml`.
void main(List<String> args) {
  setUpAll(() {
    _root = _repoRoot(args);
    final String workflow = File('$_root/.github/workflows/ci.yaml')
        .readAsStringSync();
    _job = _testJob(workflow);
    _jobSteps = _steps(_job);
  });
  group('shutdown', _checkShutdown);
  group('bounded servers', _checkBounds);
  group('evidence', _checkEvidence);
  group('unchanged', _checkUnchanged);
}

/// The `test:` job: from its header line to the next top-level job.
String _testJob(String workflow) {
  final int from = workflow.indexOf('\n  test:\n');
  expect(from, greaterThanOrEqualTo(0), reason: 'no `test` job in ci.yaml');
  final Match? next = RegExp(r'\n  [\w-]+:\n')
      .allMatches(workflow, from + 1)
      .firstOrNull;
  return workflow.substring(from, next?.start ?? workflow.length);
}

/// The steps of [job], each as its own text block.
List<String> _steps(String job) {
  final List<String> parts = job.split('\n      - ');
  expect(parts.length, greaterThan(1), reason: 'test job has no steps');
  return parts.skip(1).map((String p) => '$p\n').toList();
}

/// The step named exactly [name].
String _step(String name) {
  final Iterable<String> hits = _jobSteps.where(
    (String s) => s.startsWith('name: $name\n'),
  );
  expect(hits, hasLength(1), reason: 'expected exactly one step named $name');
  return hits.first;
}

/// The non-comment lines of [step] that run bazel.
List<String> _bazelLines(String step) => step
    .split('\n')
    .where((String l) => RegExp(r'\bbazel\s').hasMatch(l))
    .where((String l) => !l.trimLeft().startsWith('#'))
    .toList();

void _checkShutdown() {
  test('Test shuts each folder server down before its status is written', () {
    final String step = _step('Test');
    final int shutdown = step.indexOf(_folderShutdown);
    final int status = step.indexOf(r'echo "$rc" >"$logdir/$slug.status"');
    expect(shutdown, greaterThan(0));
    expect(status, greaterThan(shutdown), reason: 'shutdown before status');
    expect(step, contains('::warning::bazel shutdown failed'));
  });
  for (final String name in _corpus) {
    test('$name ends with bazel shutdown and keeps its exit status', () {
      final String step = _step(name);
      final List<String> lines = _bazelLines(step);
      expect(lines.last, contains(' shutdown'));
      expect(step, contains(r'|| status=$?'));
      expect(step.trimRight(), endsWith(r'exit "$status"'));
    });
  }
  test('no step hides a shutdown failure with || true', () {
    for (final String name in _measured) {
      expect(_step(name), isNot(matches(RegExp(r'shutdown[^\n]*\|\| true'))));
    }
  });
}

void _checkBounds() {
  for (final String name in _measured) {
    test('$name sets --max_idle_secs=60, never --batch', () {
      final String step = _step(name);
      expect(step, contains('--max_idle_secs=60'));
      expect(step, isNot(contains('--batch')));
    });
  }
  test('Test servers get the idle option on Linux, before the command', () {
    final String step = _step('Test');
    expect(step, contains(r'if [ "$RUNNER_OS" = "Linux" ]'));
    expect(step, contains('idle=(--max_idle_secs=60)'));
    expect(step, contains(r'bazel "${idle[@]}" --output_base='));
    expect(step, isNot(contains('local_resources')));
  });
  for (final String name in _corpus) {
    test('$name starts every bazel command with the idle option and cap', () {
      final List<String> lines = _bazelLines(_step(name));
      final Iterable<String> cmds = lines.where(
        (String l) => !l.contains(' shutdown'),
      );
      expect(cmds, isNotEmpty);
      for (final line in lines) {
        expect(line, matches(RegExp(r'bazel --max_idle_secs=60 \w+')));
      }
      for (final line in cmds) {
        expect(line, contains('"$_ram"'));
      }
    });
  }
  test('Test servers keep the 15% memory, 1 cpu and 2 GB heap bounds', () {
    expect(_job, contains('startup --host_jvm_args=-Xmx2g\n'));
    expect(_job, contains('build --local_resources=cpu=1\n'));
    expect(_job, contains('build --local_resources=memory=HOST_RAM*.15\n'));
  });
}

void _checkEvidence() {
  test('the memory script is executable and runs free -m', () {
    final script = File('$_root/.github/scripts/ci_mem_report.sh');
    final String text = script.readAsStringSync();
    expect(text, startsWith('#!/usr/bin/env bash\n'));
    expect(text, contains('set -euo pipefail'));
    expect(text, contains('free -m'));
    expect(text, contains('command -v free'));
    expect(text, contains('exit 1'));
    if (!Platform.isWindows) {
      expect(script.statSync().mode & 0x49, isNot(0), reason: 'executable');
    }
  });
  for (final String name in _measured) {
    test('free -m is logged before and after $name', () {
      final String before = _step('Memory report (before $name)');
      final String after = _step('Memory report (after $name)');
      final String cond = name == 'Test' ? _ubuntu : _shard1;
      expect(before, contains('if: $cond\n'));
      expect(after, contains('if: always() && $cond\n'));
      expect(before, contains('ci_mem_report.sh "before $name"'));
      expect(after, contains('ci_mem_report.sh "after $name"'));
      final int at = _jobSteps.indexOf(_step(name));
      expect(_jobSteps.indexOf(before), lessThan(at));
      expect(_jobSteps.indexOf(after), greaterThan(at));
    });
  }
}

void _checkUnchanged() {
  test('job is not continue-on-error', () {
    expect(_job, isNot(contains('continue-on-error')));
  });
  test('matrix keeps ubuntu shards 1 to 3 with their folders', () {
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
    expect(
      _job,
      contains(r'name: test (${{ matrix.os }}, shard ${{ matrix.shard }})'),
    );
  });
  test('Test and corpus steps keep their conditions', () {
    expect(_step('Test'), isNot(contains('if:')));
    for (final String name in _corpus) {
      expect(_step(name), contains('if: $_shard1\n'));
    }
  });
  test('cache keys are unchanged', () {
    expect(_job, contains('cache-version: "3"'));
  });
}

/// The workspace root: the nearest ancestor of the runfile named by the first
/// argument (or of the current directory) that holds MODULE.bazel.
String _repoRoot(List<String> args) {
  final String? env = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  Directory dir = env != null
      ? Directory(env)
      : File(Runfiles.create().rlocation(args.first)).parent;
  while (!File('${dir.path}/MODULE.bazel').existsSync()) {
    expect(dir.parent.path, isNot(dir.path), reason: 'no workspace root');
    dir = dir.parent;
  }
  return dir.path;
}
