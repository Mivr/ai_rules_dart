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

void _verifyTriggersAndInputs(String text) {
  _check(text.contains('workflow_dispatch:'), 'has workflow_dispatch trigger');
  _check(!text.contains('push:'), 'no push trigger');
  _check(!text.contains('pull_request:'), 'no pull_request trigger');
  _check(!text.contains('schedule:'), 'no schedule trigger');
  _check(!text.contains('workflow_run:'), 'no workflow_run trigger');

  _check(text.contains('head_ref:'), 'has head_ref input');
  _check(text.contains('required: true'), 'head_ref is required');
  _check(text.contains('type: string'), 'inputs use type: string');
  _check(text.contains('target_loc:'), 'has target_loc input');
  _check(text.contains('default: "500000"'), 'quoted default "500000"');
  _check(text.contains('repeats:'), 'has repeats input');
  _check(text.contains('default: "3"'), 'quoted default "3"');
  _check(text.contains('seed:'), 'has seed input');
  _check(text.contains('default: "1"'), 'quoted default "1"');
  _check(
    RegExp(r'required:\s*true').allMatches(text).length == 1,
    'Only head_ref is required: true',
  );
}

void _verifyRunnerCachesAndSteps(String text) {
  _check(text.contains('contents: read'), 'permissions: contents: read');
  _check(text.contains('runs-on: ubuntu-latest'), 'runs-on: ubuntu-latest');

  final timeoutMatch = RegExp(r'timeout-minutes:\s*(\d+)').firstMatch(text);
  _check(timeoutMatch != null, 'timeout-minutes declared');
  final timeout = int.parse(timeoutMatch!.group(1)!);
  _check(timeout > 0 && timeout <= 300, 'timeout-minutes <= 300, got $timeout');

  _check(!text.contains('actions/cache'), 'no actions/cache step');
  for (final cacheKey in [
    'disk-cache',
    'repository-cache',
    'external-cache',
    'cache-save',
  ]) {
    _check(
      !RegExp('$cacheKey:\\s*true').hasMatch(text),
      '$cacheKey must not be enabled',
    );
  }

  _check(text.contains('path: tools-src'), 'checks out tools-src');
  _check(text.contains('path: rules-head'), 'checks out rules-head');
  _check(text.contains('//perf:generate'), 'invokes //perf:generate');
  _check(text.contains('//perf:runner'), 'invokes //perf:runner');
  _check(text.contains('//perf:summarize'), 'invokes //perf:summarize');
  _check(text.contains('--nobuild'), 'runs unmeasured --nobuild lockfile pass');
  _check(text.contains('MODULE.bazel.lock'), 'verifies MODULE.bazel.lock');
  _check(text.contains('GITHUB_STEP_SUMMARY'), 'writes GITHUB_STEP_SUMMARY');

  _check(text.contains('name: dart-sol'), 'uploads artifact dart-sol');
  _check(text.contains('path: dart-sol.json'), 'uploads path dart-sol.json');
  _check(text.contains('retention-days: 3'), 'retention-days: 3');
  _check(text.contains('!cancelled()'), 'summarize/upload guarded !cancelled');
}

void main(List<String> args) {
  final root = _locateRepoRoot(args);
  final workflowFile = File('$root/.github/workflows/perf-linux.yaml');
  _check(
    workflowFile.existsSync(),
    'perf-linux.yaml exists at ${workflowFile.path}',
  );
  final text = workflowFile.readAsStringSync();
  _verifyTriggersAndInputs(text);
  _verifyRunnerCachesAndSteps(text);
  stdout.writeln('All workflow tests passed.');
}
