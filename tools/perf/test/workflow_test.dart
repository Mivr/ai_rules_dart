/// Unit test verifying `.github/workflows/perf-linux.yaml` contract rules.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

bool _isRulesDartRepoRoot(Directory dir) {
  final moduleFile = File('${dir.path}/MODULE.bazel');
  if (!moduleFile.existsSync()) return false;
  final dartType = FileSystemEntity.typeSync(
    '${dir.path}/dart',
    followLinks: false,
  );
  return dartType == FileSystemEntityType.directory;
}

String? _walkUpForRepoRoot(String startPath) {
  var current = Directory(startPath);
  while (true) {
    final moduleFile = File('${current.path}/MODULE.bazel');
    if (moduleFile.existsSync()) {
      final realModuleDir = File(moduleFile.resolveSymbolicLinksSync()).parent;
      if (_isRulesDartRepoRoot(realModuleDir)) return realModuleDir.path;
      if (_isRulesDartRepoRoot(realModuleDir.parent)) {
        return realModuleDir.parent.path;
      }
    }
    final parent = current.parent;
    if (parent.path == current.path) return null;
    current = parent;
  }
}

String? _resolveFromRunfilesAnchor(String rlocationArg) {
  try {
    final mapped = Runfiles.create().rlocation(rlocationArg);
    final anchor = File(mapped);
    if (!anchor.existsSync()) return null;
    final resolvedAnchor = File(anchor.resolveSymbolicLinksSync());
    return _walkUpForRepoRoot(resolvedAnchor.parent.path);
  } on StateError catch (e) {
    stderr.writeln('Runfiles anchor lookup unavailable: $e');
    return null;
  } on FileSystemException catch (e) {
    stderr.writeln('Runfiles anchor symlink resolution skipped: $e');
    return null;
  } on ArgumentError catch (e) {
    stderr.writeln('Invalid runfiles anchor path: $e');
    return null;
  }
}

String _locateRepoRoot(List<String> args) {
  if (args.isNotEmpty) {
    final fromAnchor = _resolveFromRunfilesAnchor(args.first);
    if (fromAnchor != null) return fromAnchor;
  }
  final bwd = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (bwd != null) {
    final fromBwd = _walkUpForRepoRoot(bwd);
    if (fromBwd != null) return fromBwd;
  }
  final fromCwd = _walkUpForRepoRoot(Directory.current.path);
  if (fromCwd != null) return fromCwd;
  throw StateError('Unable to locate rules_dart repository root');
}

void _verifyTriggers(String text) {
  _check(text.contains('workflow_dispatch:'), 'has workflow_dispatch trigger');
  for (final trigger in [
    'push:',
    'pull_request:',
    'pull_request_target:',
    'schedule:',
    'workflow_run:',
    'workflow_call:',
    'repository_dispatch:',
    'release:',
    'issues:',
    'issue_comment:',
  ]) {
    _check(!text.contains(trigger), 'forbidden trigger: $trigger');
  }
}

void _verifyInputs(String text) {
  final inputsMatch = RegExp(r'inputs:\s*\n((?:\s+.*\n)+)').firstMatch(text);
  _check(inputsMatch != null, 'inputs block present');
  final inputsBlock = inputsMatch!.group(1)!;

  final inputNames = RegExp(
    r'^\s{6}([a-zA-Z0-9_-]+):\s*$',
    multiLine: true,
  ).allMatches(inputsBlock).map((m) => m.group(1)!).toSet();
  _check(
    inputNames.length == 4 &&
        inputNames.contains('head_ref') &&
        inputNames.contains('target_loc') &&
        inputNames.contains('repeats') &&
        inputNames.contains('seed'),
    'inputs must contain exactly head_ref, target_loc, repeats, seed',
  );

  _check(
    RegExp(r'head_ref:[\s\S]*?required:\s*true').hasMatch(inputsBlock),
    'head_ref is required: true',
  );
  _check(
    RegExp(r'required:\s*true').allMatches(inputsBlock).length == 1,
    'only head_ref is required: true',
  );
  _check(
    RegExp(r'type:\s*string').allMatches(inputsBlock).length == 4,
    'all 4 inputs use type: string',
  );
  _check(
    RegExp(r'target_loc:[\s\S]*?default:\s*"500000"').hasMatch(inputsBlock),
    'target_loc default: "500000"',
  );
  _check(
    RegExp(r'repeats:[\s\S]*?default:\s*"3"').hasMatch(inputsBlock),
    'repeats default: "3"',
  );
  _check(
    RegExp(r'seed:[\s\S]*?default:\s*"1"').hasMatch(inputsBlock),
    'seed default: "1"',
  );
  _check(
    !RegExp(r'default:\s*\d+\s*(?:$|#)', multiLine: true).hasMatch(inputsBlock),
    'defaults must be quoted strings, not bare integers',
  );
}

void _verifyRunnerAndCost(String text) {
  _check(
    RegExp(r'permissions:\s*\n\s*contents:\s*read').hasMatch(text) ||
        text.contains('permissions: contents: read'),
    'permissions: contents: read',
  );
  _check(!text.contains('contents: write'), 'no contents: write');
  _check(!text.contains('pull-requests: write'), 'no write permissions');

  _check(
    RegExp(r'runs-on:\s*ubuntu-latest\b').hasMatch(text),
    'runs-on: ubuntu-latest',
  );
  _check(!text.contains('ubuntu-22.04'), 'runs-on must not be ubuntu-22.04');
  _check(!text.contains('macos'), 'runs-on must not be macos');
  _check(!text.contains('windows'), 'runs-on must not be windows');

  final timeoutMatch = RegExp(r'timeout-minutes:\s*(\d+)').firstMatch(text);
  _check(timeoutMatch != null, 'timeout-minutes declared');
  final timeout = int.parse(timeoutMatch!.group(1)!);
  _check(timeout == 300, 'timeout-minutes must be exactly 300, got $timeout');
}

void _verifyCaches(String text) {
  _check(
    !RegExp(r'uses:\s*actions/cache').hasMatch(text),
    'no actions/cache step',
  );
  for (final cacheKey in [
    'disk-cache',
    'repository-cache',
    'external-cache',
    'cache-save',
    'bazelisk-cache',
  ]) {
    final match = RegExp('$cacheKey:\\s*([^\n\r#]+)').firstMatch(text);
    if (match != null) {
      final val = match
          .group(1)!
          .trim()
          .replaceAll('"', '')
          .replaceAll("'", '')
          .toLowerCase();
      _check(val == 'false', '$cacheKey must be absent or false, got $val');
    }
  }
  _check(
    !RegExp(
      r'[\w-]*cache[\w-]*:\s*(true|yes|1|"true"|\x27true\x27)',
      caseSensitive: false,
    ).hasMatch(text),
    'no cache may be enabled',
  );
}

void _verifyCheckoutsAndSteps(String text) {
  _check(text.contains('path: tools-src'), 'checks out tools-src');
  _check(text.contains('path: rules-head'), 'checks out rules-head');
  _check(
    RegExp(r'ref:\s*(\$\{\{\s*inputs\.head_ref\s*\}\}|\$HEAD_REF)')
        .hasMatch(text),
    'rules-head checked out at head_ref',
  );

  _check(text.contains('//perf:generate'), 'invokes //perf:generate');
  _check(text.contains('--target-loc'), 'generate passes --target-loc');
  _check(text.contains('--seed'), 'generate passes --seed');
  _check(text.contains('--rules-dart'), 'generate passes --rules-dart');
  _check(text.contains('--out='), 'generate passes --out');

  _check(text.contains('--nobuild'), 'runs unmeasured --nobuild lockfile pass');
  _check(
    text.contains('test -f ') && text.contains('MODULE.bazel.lock'),
    'checks test -f ... MODULE.bazel.lock',
  );

  _check(text.contains('//perf:runner'), 'invokes //perf:runner');
  _check(
    RegExp(r'inputs\.repeats').hasMatch(text),
    'workflow references inputs.repeats',
  );
  final hasRepeatsDynamic = RegExp(
    r'(seq\s+1\s+["$({]*inputs\.repeats|--repeats=["$({]*inputs\.repeats|\$REPEATS)',
  ).hasMatch(text);
  _check(
    hasRepeatsDynamic,
    'runner repeats step takes count dynamically from inputs.repeats',
  );
  _check(
    !RegExp(r'seq\s+1\s+\d+\b').hasMatch(text),
    'runner loop must not use a hardcoded fixed number',
  );
  _check(
    !RegExp(r'--repeats=\d+\b').hasMatch(text),
    'runner --repeats must not use a hardcoded fixed number',
  );

  _check(text.contains('//perf:summarize'), 'invokes //perf:summarize');
  _check(text.contains('GITHUB_STEP_SUMMARY'), 'writes GITHUB_STEP_SUMMARY');
  _check(
    text.contains('shutdown'),
    'shuts down tooling / scratch Bazel server',
  );
}

void _verifyArtifactUpload(String text) {
  _check(text.contains('name: dart-sol'), 'uploads artifact dart-sol');
  _check(
    RegExp(r'path:\s*dart-sol\.json\b').hasMatch(text),
    'uploads path dart-sol.json',
  );
  final retentionMatch = RegExp(r'retention-days:\s*(\d+)').firstMatch(text);
  _check(retentionMatch != null, 'retention-days declared');
  _check(
    retentionMatch!.group(1) == '3',
    'retention-days must be exactly 3, got ${retentionMatch.group(1)}',
  );
  _check(
    RegExp(r'retention-days:\s*3\b').allMatches(text).length == 1,
    'retention-days is 3',
  );
  _check(
    text.contains('!cancelled()') && text.contains("inputs.head_ref != ''"),
    'upload step guarded with !cancelled() && inputs.head_ref != \'\'',
  );
  _check(!text.contains('bazel-bin'), 'no build outputs uploaded');
  _check(!text.contains('bazel-out'), 'no build outputs uploaded');
}

void _verifyShellSafety(String text) {
  final lines = text.split('\n');
  var inRunBlock = false;
  var runIndent = 0;
  for (final line in lines) {
    final runStart = RegExp(r'^(\s*)(?:-\s+)?run:\s*\|').firstMatch(line);
    if (runStart != null) {
      inRunBlock = true;
      runIndent = runStart.group(1)!.length;
      continue;
    }
    if (!inRunBlock) continue;
    if (line.trim().isEmpty) continue;
    final indent = RegExp(r'^\s*').firstMatch(line)!.group(0)!.length;
    if (indent <= runIndent) {
      inRunBlock = false;
      continue;
    }
    _check(
      !line.contains(r'${{ inputs.'),
      'run: block must read env vars rather than interpolating inputs: $line',
    );
  }
  _check(
    !RegExp(r'\[\s+-d\s+[^\]]*rules-head/\.git').hasMatch(text),
    'rev-parse HEAD must not require rules-head/.git to be a directory',
  );
}

/// Verifies all contract constraints against [text].
void verifyWorkflowYaml(String text) {
  _verifyTriggers(text);
  _verifyInputs(text);
  _verifyRunnerAndCost(text);
  _verifyCaches(text);
  _verifyCheckoutsAndSteps(text);
  _verifyArtifactUpload(text);
  _verifyShellSafety(text);
}

void _expectStateError(void Function() action, String message) {
  try {
    action();
  } on StateError catch (e) {
    _check(e.message.isNotEmpty, message);
    return;
  }
  throw StateError('FAIL: $message (expected StateError)');
}

void _testWorkflowMutations(String validText) {
  _expectStateError(
    () => verifyWorkflowYaml(
      validText.replaceFirst('retention-days: 3', 'retention-days: 5'),
    ),
    'fails when retention-days is not 3',
  );
  _expectStateError(
    () => verifyWorkflowYaml(
      validText.replaceFirst('retention-days: 3', 'retention-days: 1'),
    ),
    'fails when retention-days is 1',
  );
  _expectStateError(
    () => verifyWorkflowYaml(
      validText.replaceFirst('disk-cache: false', 'disk-cache: true'),
    ),
    'fails when disk-cache is enabled',
  );
  _expectStateError(
    () => verifyWorkflowYaml(
      validText.replaceFirst('bazelisk-cache: false', 'bazelisk-cache: true'),
    ),
    'fails when bazelisk-cache is enabled',
  );
  _expectStateError(
    () => verifyWorkflowYaml(
      validText.replaceFirst('timeout-minutes: 300', 'timeout-minutes: 10'),
    ),
    'fails when timeout-minutes is not 300',
  );
  _expectStateError(
    () => verifyWorkflowYaml(
      validText.replaceFirst('runs-on: ubuntu-latest', 'runs-on: macos-latest'),
    ),
    'fails when runs-on is not ubuntu-latest',
  );
  _expectStateError(
    () => verifyWorkflowYaml('push:\n$validText'),
    'fails when push trigger is present',
  );
  _expectStateError(
    () => verifyWorkflowYaml(
      validText.replaceFirst('default: "3"', 'default: 3'),
    ),
    'fails when repeats default is unquoted integer',
  );
  _expectStateError(
    () => verifyWorkflowYaml(
      validText.replaceFirst('contents: read', 'contents: write'),
    ),
    'fails when contents: write is granted',
  );
  _expectStateError(
    () => verifyWorkflowYaml(
      validText.replaceFirst(RegExp(r'seq\s+1\s+.*'), 'seq 1 3; do'),
    ),
    'fails when runner repeats uses a hardcoded fixed number',
  );
  _expectStateError(
    () => verifyWorkflowYaml(
      validText.replaceFirst(r'"$REPEATS"', r'"${{ inputs.repeats }}"'),
    ),
    'fails when run: block interpolates inputs.repeats directly',
  );
}

void main(List<String> args) {
  final root = _locateRepoRoot(args);
  final workflowFile = File('$root/.github/workflows/perf-linux.yaml');
  _check(
    workflowFile.existsSync(),
    'perf-linux.yaml exists at ${workflowFile.path}',
  );
  final text = workflowFile.readAsStringSync();
  verifyWorkflowYaml(text);
  _testWorkflowMutations(text);
  stdout.writeln('All workflow tests passed.');
}
