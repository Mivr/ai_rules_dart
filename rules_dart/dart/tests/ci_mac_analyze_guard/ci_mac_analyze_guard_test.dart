import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

const String _expectedStepName =
    'analysis_failure — expect analyzer diagnostics to fail the build, at workspace paths';

late final String _workspaceRoot;
late final String _ciYaml;
late final String _macSmokeJob;
late final List<String> _macSmokeSteps;

void main(List<String> args) {
  setUpAll(() {
    _workspaceRoot = _findRepoRoot(args);
    final workflowFile = File('$_workspaceRoot/.github/workflows/ci.yaml');
    if (!workflowFile.existsSync()) {
      fail('Cannot find ci.yaml at ${workflowFile.path}');
    }
    _ciYaml = workflowFile.readAsStringSync();
    _macSmokeJob = _extractMacSmokeJob(_ciYaml);
    _macSmokeSteps = _extractSteps(_macSmokeJob);
  });

  group('mac-smoke trigger condition', _checkTriggerCondition);
  group('mac-smoke analyzer red path step', _checkAnalyzerStep);
}

void _checkTriggerCondition() {
  test('if: condition names only schedule and workflow_dispatch', () {
    final ifPattern = RegExp(r'^\s+if:\s*(.*)$', multiLine: true);
    final RegExpMatch? match = ifPattern.firstMatch(_macSmokeJob);
    expect(match, isNotNull, reason: 'mac-smoke job missing if: condition');
    final String condition = match!.group(1)!.trim();
    expect(
      condition,
      equals(
        "github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'",
      ),
    );
    expect(condition, isNot(contains('push')));
    expect(condition, isNot(contains('pull_request')));
  });

  test('mac-smoke job does not use continue-on-error', () {
    expect(_macSmokeJob, isNot(contains('continue-on-error')));
  });
}

void _checkAnalyzerStep() {
  test('step is present and unique in mac-smoke', () {
    final List<String> matching = _macSmokeSteps
        .where((String step) => step.contains(_expectedStepName))
        .toList();
    expect(
      matching,
      hasLength(1),
      reason: 'mac-smoke must contain exactly one "$_expectedStepName" step',
    );
  });

  test('step executes in e2e/analysis_failure with expected assertions', () {
    final List<String> matching = _macSmokeSteps
        .where((String step) => step.contains(_expectedStepName))
        .toList();
    expect(matching, isNotEmpty, reason: 'step not found');
    final String step = matching.first;

    expect(
      step,
      contains('working-directory: e2e/analysis_failure'),
      reason: 'step must specify working-directory: e2e/analysis_failure',
    );
    expect(
      step,
      contains('bazel test //:bad_lib'),
      reason: 'step must invoke bazel test //:bad_lib',
    );
    expect(
      step,
      contains('unused_local_variable'),
      reason: 'step must grep for unused_local_variable',
    );
    expect(
      step,
      contains('- lib/bad.dart:4:7 -'),
      reason: 'step must grep for - lib/bad.dart:4:7 -',
    );
    expect(
      step,
      isNot(contains('continue-on-error')),
      reason: 'step must not carry continue-on-error',
    );
    expect(
      step,
      isNot(contains('2>/dev/null |')),
      reason: 'step must not suppress test failure stderr into a pipe',
    );
  });

  test('step runs after Run hello_world and before Consumer query', () {
    final int helloIndex = _macSmokeSteps.indexWhere(
      (String s) => s.contains('name: Run hello_world'),
    );
    final int analyzeIndex = _macSmokeSteps.indexWhere(
      (String s) => s.contains(_expectedStepName),
    );
    final int consumerIndex = _macSmokeSteps.indexWhere(
      (String s) => s.contains('name: Consumer query'),
    );

    expect(helloIndex, isNot(-1), reason: 'Run hello_world step missing');
    expect(analyzeIndex, isNot(-1), reason: 'analyzer red-path step missing');
    expect(consumerIndex, isNot(-1), reason: 'Consumer query step missing');

    expect(
      helloIndex,
      lessThan(analyzeIndex),
      reason: 'step must run after Run hello_world',
    );
    expect(
      analyzeIndex,
      lessThan(consumerIndex),
      reason: 'step must run before Consumer query',
    );
  });
}

/// Locates the repository root by checking environment or runfile ancestor.
String _findRepoRoot(List<String> args) {
  final String? wsEnv = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (wsEnv != null && wsEnv.isNotEmpty) {
    return wsEnv;
  }
  if (args.isNotEmpty) {
    try {
      final String runfile = Runfiles.create().rlocation(args.first);
      Directory current = File(runfile).parent;
      while (current.path != current.parent.path) {
        if (File('${current.path}/MODULE.bazel').existsSync()) {
          return current.path;
        }
        current = current.parent;
      }
    } on Object catch (_) {
      // Not under runfiles, proceed to Directory.current.
    }
  }
  Directory current = Directory.current;
  while (current.path != current.parent.path) {
    if (File('${current.path}/MODULE.bazel').existsSync()) {
      return current.path;
    }
    current = current.parent;
  }
  throw StateError('Could not find workspace root containing MODULE.bazel');
}

/// Extracts the text block for the `mac-smoke` job from the CI workflow.
String _extractMacSmokeJob(String workflow) {
  final exp = RegExp(
    r'^  mac-smoke:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n)',
    multiLine: true,
    dotAll: true,
  );
  final RegExpMatch? match = exp.firstMatch(workflow);
  if (match == null) {
    fail('No mac-smoke job found in ci.yaml');
  }
  return match.group(1)!;
}

/// Splits a job's steps into individual step text blocks.
List<String> _extractSteps(String jobText) {
  final int index = jobText.indexOf('\n    steps:\n');
  if (index == -1) {
    fail('Job has no steps block');
  }
  return jobText
      .substring(index)
      .split(RegExp('^      - ', multiLine: true))
      .skip(1)
      .toList();
}
