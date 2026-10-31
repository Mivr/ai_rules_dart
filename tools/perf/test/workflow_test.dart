/// Unit test checking `.github/workflows/perf-linux.yaml` workflow file text.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

String? _sourceRootAbove(String? start) {
  var dir = start == null ? null : Directory(start);
  while (dir != null) {
    final module = File('${dir.path}/MODULE.bazel');
    if (module.existsSync()) {
      final root = File(module.resolveSymbolicLinksSync()).parent.path;
      if (FileSystemEntity.typeSync('$root/dart', followLinks: false) ==
          FileSystemEntityType.directory) {
        return root;
      }
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
  return null;
}

String? _anchorRoot(String arg) {
  try {
    final located = Runfiles.create().rlocation(arg);
    if (!File(located).existsSync()) return null;
    return _sourceRootAbove(Directory(located).parent.path);
  } catch (_) {
    return null;
  }
}

String _findRepoRoot(List<String> args) {
  if (args.isNotEmpty) {
    final root = _anchorRoot(args[0]);
    if (root != null) return root;
  }
  final bwd = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (bwd != null) {
    final root = _sourceRootAbove(bwd);
    if (root != null) return root;
  }
  final current = _sourceRootAbove(Directory.current.path);
  if (current != null) return current;
  throw StateError('Cannot locate repo root');
}

void _testWorkflowFile(String repoRoot) {
  final workflowFile = File('$repoRoot/.github/workflows/perf-linux.yaml');
  _check(
    workflowFile.existsSync(),
    'perf-linux.yaml exists at ${workflowFile.path}',
  );

  final text = workflowFile.readAsStringSync();

  // 1. workflow_dispatch only: no push, pull_request, schedule, workflow_run
  _check(text.contains('workflow_dispatch:'), 'has workflow_dispatch trigger');
  _check(!text.contains('push:'), 'no push trigger');
  _check(!text.contains('pull_request:'), 'no pull_request trigger');
  _check(!text.contains('schedule:'), 'no schedule trigger');
  _check(!text.contains('workflow_run:'), 'no workflow_run trigger');

  // 2. inputs with quoted defaults
  _check(text.contains('head_ref:'), 'has head_ref input');
  _check(
    text.contains('required: true') && text.contains('type: string'),
    'head_ref required: true, type: string',
  );
  _check(text.contains('target_loc:'), 'has target_loc input');
  _check(
    text.contains('default: "500000"'),
    'target_loc default is quoted "500000"',
  );
  _check(text.contains('repeats:'), 'has repeats input');
  _check(text.contains('default: "3"'), 'repeats default is quoted "3"');
  _check(text.contains('seed:'), 'has seed input');
  _check(text.contains('default: "1"'), 'seed default is quoted "1"');

  // 3. runner and cost rules
  _check(text.contains('contents: read'), 'permissions: contents: read');
  _check(text.contains('runs-on: ubuntu-latest'), 'runs-on: ubuntu-latest');

  final timeoutMatch = RegExp(r'timeout-minutes:\s*(\d+)').firstMatch(text);
  _check(timeoutMatch != null, 'timeout-minutes declared');
  final timeout = int.parse(timeoutMatch!.group(1)!);
  _check(timeout <= 300, 'timeout-minutes <= 300, got $timeout');

  // No caches
  _check(!text.contains('actions/cache'), 'no actions/cache step');
  _check(
    text.contains('disk-cache: false') || !text.contains('disk-cache: true'),
    'no disk-cache enabled',
  );
  _check(
    text.contains('repository-cache: false') ||
        !text.contains('repository-cache: true'),
    'no repository-cache enabled',
  );
  _check(
    text.contains('external-cache: false') ||
        !text.contains('external-cache: true'),
    'no external-cache enabled',
  );
  _check(
    text.contains('cache-save: false') || !text.contains('cache-save: true'),
    'no cache-save enabled',
  );

  // 4. checkouts
  _check(
    text.contains('path: tools-src'),
    'checkout tools-src for bench tooling',
  );
  _check(
    text.contains('path: rules-head'),
    'checkout rules-head for measured rules',
  );

  // 5. bazel run //perf:...
  _check(text.contains('//perf:generate'), 'runs //perf:generate');
  _check(text.contains('//perf:runner'), 'runs //perf:runner');
  _check(text.contains('//perf:summarize'), 'runs //perf:summarize');

  // 6. dart-sol upload
  _check(text.contains('name: dart-sol'), 'artifact name: dart-sol');
  _check(text.contains('path: dart-sol.json'), 'artifact path: dart-sol.json');
  _check(text.contains('retention-days: 3'), 'retention-days: 3');
  _check(text.contains('!cancelled()'), 'runs when !cancelled()');
}

void main(List<String> args) {
  final root = _findRepoRoot(args);
  _testWorkflowFile(root);
  stdout.writeln('All workflow tests passed.');
}
