/// Verifies the contract of `.github/workflows/perf-scale-linux.yaml`.
library;

import 'dart:io';

import 'repo_root.dart';
import 'workflow_steps.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

void _verifyTriggers(String text) {
  _check(
    RegExp(r'^  schedule:\s*$', multiLine: true).hasMatch(text),
    'schedule',
  );
  _check(text.contains('cron:'), 'schedule has a cron entry');
  _check(
    RegExp(r'^  workflow_dispatch:\s*$', multiLine: true).hasMatch(text),
    'workflow_dispatch trigger',
  );
  for (final trigger in [
    'push:',
    'pull_request:',
    'pull_request_target:',
    'workflow_run:',
    'workflow_call:',
    'repository_dispatch:',
  ]) {
    _check(!text.contains(trigger), 'forbidden trigger: $trigger');
  }
  for (final input in ['head_ref', 'sizes', 'seed']) {
    _check(
      RegExp('^      $input:\\s*\$', multiLine: true).hasMatch(text),
      'input $input',
    );
  }
  _check(
    RegExp(r'head_ref:[\s\S]*?required:\s*true').hasMatch(text),
    'head_ref is required',
  );
}

void _verifyPinnedActions(String text, String perfLinux) {
  final uses = RegExp(r'uses:\s*(\S+)(.*)').allMatches(text).toList();
  _check(uses.length >= 4, 'workflow uses actions');
  for (final m in uses) {
    final ref = m.group(1)!;
    _check(
      perfLinux.contains('uses: $ref'),
      'action matches the perf-linux.yaml pin: $ref',
    );
    if (ref.startsWith('actions/upload-artifact@')) continue;
    _check(
      RegExp(r'@[0-9a-f]{40}$').hasMatch(ref) &&
          RegExp(r'#\s*v?\d').hasMatch(m.group(2)!),
      'action pinned to a commit SHA with a version comment: $ref',
    );
  }
}

void _verifySteps(String text) {
  _check(!text.contains('continue-on-error'), 'no continue-on-error');
  _check(RegExp(r'runs-on:\s*ubuntu-latest\b').hasMatch(text), 'ubuntu-latest');
  _check(text.contains('path: tools-src'), 'checks out tools-src');
  _check(text.contains('path: rules-head'), 'checks out rules-head');
  _check(
    RegExp(r'ref:\s*\$\{\{\s*inputs\.head_ref\s*\}\}').hasMatch(text),
    'rules-head checked out at head_ref',
  );
  _check(text.contains('//perf:generate'), 'invokes //perf:generate');
  _check(text.contains('--libraries='), 'generate passes --libraries');
  _check(text.contains('//perf:scale'), 'invokes //perf:scale');
  _check(text.contains('scale_ceilings.json'), 'passes the ceiling table');
  _check(text.contains('--rules-dart='), 'generate passes --rules-dart');
  _check(text.contains('tools-src/tools'), 'Bazel runs from tools-src/tools');
  _check(
    !RegExp(r'\|\|\s*(true|:)\b').hasMatch(text),
    'scale failure is not swallowed',
  );
}

void _verifyUpload(String text) {
  final uploads = parseSteps(text).values
      .where((s) => s.block.contains('actions/upload-artifact@'));
  _check(uploads.length == 1, 'has exactly one upload-artifact step');
  final block = uploads.single.block;
  _check(
    block.contains(r'if: ${{ !cancelled() }}'),
    'upload step runs on !cancelled()',
  );
  _check(block.contains('name: dart-scale'), 'uploads the dart-scale artifact');
  _check(block.contains('path: scale-out'), 'uploads the report directory');
  _check(
    text.contains('--out="\$GITHUB_WORKSPACE/scale-out/dart-scale.json"'),
    'report is written into the uploaded directory',
  );
}

void _verifyShellSafety(String text) {
  var inRun = false;
  var runIndent = 0;
  for (final line in text.split('\n')) {
    final start = RegExp(r'^(\s*)(?:-\s+)?run:\s*\|').firstMatch(line);
    if (start != null) {
      inRun = true;
      runIndent = start.group(1)!.length;
      continue;
    }
    if (!inRun || line.trim().isEmpty) continue;
    if (RegExp(r'^\s*').firstMatch(line)!.group(0)!.length <= runIndent) {
      inRun = false;
      continue;
    }
    _check(!line.contains(r'${{ inputs.'), 'run: block interpolates inputs');
  }
}

void _expectRejected(void Function(String) verify, String text, String why) {
  try {
    verify(text);
  } on StateError {
    return;
  }
  throw StateError('FAIL: mutation not rejected: $why');
}

void _verifyAll(String text, String perfLinux) {
  _verifyTriggers(text);
  _verifyPinnedActions(text, perfLinux);
  _verifySteps(text);
  _verifyUpload(text);
  _verifyShellSafety(text);
}

void main(List<String> args) {
  final workflows = '${locateRepoRoot(args)}/.github/workflows';
  final file = File('$workflows/perf-scale-linux.yaml');
  _check(file.existsSync(), 'perf-scale-linux.yaml exists');
  final text = file.readAsStringSync();
  final perfLinux = File('$workflows/perf-linux.yaml').readAsStringSync();
  void verify(String t) => _verifyAll(t, perfLinux);
  verify(text);
  _expectRejected(verify, 'push:\n$text', 'push trigger');
  _expectRejected(
    verify,
    text.replaceFirst('  schedule:', '  scheduled:'),
    'schedule removed',
  );
  _expectRejected(
    verify,
    text.replaceFirst('timeout-minutes: 360', 'continue-on-error: true'),
    'continue-on-error',
  );
  _expectRejected(
    verify,
    text.replaceFirst(RegExp(r'checkout@[0-9a-f]{40}'), 'checkout@v6'),
    'unpinned action',
  );
  _expectRejected(
    verify,
    text.replaceFirst(r'if: ${{ !cancelled() }}', r'if: ${{ success() }}'),
    'upload not on !cancelled()',
  );
  stdout.writeln('Scale workflow tests passed.');
}
