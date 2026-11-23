import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Fail-closed guard for the strict-layering check (`dart_layering_check`).
///
/// The check is on by default and the feature turns it off, so three facts
/// must stay true together: the aspect names the feature it honours; the red
/// workspace `e2e/layering_check` is exercised by the `expected-failure` job
/// (a failing default build and a passing `--features=-dart_layering_check`
/// build); and that workspace is in no shard folder matrix, no `ciFolders`
/// entry and no `full.yaml` matrix, where its red build would fail a green
/// sweep. The test runs unsandboxed so it reads the live tree.
void main(List<String> args) {
  final String root = _workspaceRoot(args);

  test('the aspect names the dart_layering_check feature', () {
    final bzl = File('$root/dart/private/dart_import_check.bzl');
    expect(
      bzl.existsSync(),
      isTrue,
      reason: 'dart_import_check.bzl must exist',
    );
    expect(bzl.readAsStringSync(), contains('dart_layering_check'));
  });

  test('expected-failure builds the red workspace and the opt-out', () {
    final String job = _expectedFailureJob(root);
    final String? step = _stepNaming(
      job,
      'working-directory: e2e/layering_check',
    );
    expect(step, isNotNull, reason: 'no expected-failure step names it');
    expect(step, contains('bazel build //:user'));
    expect(step, contains('if '));
    expect(step, contains('--features=-dart_layering_check'));
  });

  test('no shard folder, ciFolders entry or full.yaml names the workspace', () {
    final findings = <String>[];
    final List<String> ci = File('$root/.github/workflows/ci.yaml')
        .readAsLinesSync();
    var inExpectedFailure = false;
    for (var i = 0; i < ci.length; i++) {
      final String line = ci[i];
      if (RegExp('^  [A-Za-z0-9_-]+:').hasMatch(line)) {
        inExpectedFailure = line.startsWith('  expected-failure:');
      }
      if (line.contains('layering_check') &&
          !line.trimLeft().startsWith('#') &&
          !inExpectedFailure) {
        findings.add('.github/workflows/ci.yaml:${i + 1}: $line');
      }
    }
    for (final path in [
      '.github/workflows/full.yaml',
      'tools/vm/run_e2e_options.dart',
    ]) {
      final file = File('$root/$path');
      if (file.existsSync() &&
          file.readAsStringSync().contains('e2e/layering_check')) {
        findings.add('$path names e2e/layering_check');
      }
    }
    expect(findings, isEmpty, reason: '\n${findings.join('\n')}');
  });
}

/// The text of ci.yaml's `expected-failure` job.
String _expectedFailureJob(String root) {
  final List<String> lines = File('$root/.github/workflows/ci.yaml')
      .readAsLinesSync();
  final int start = lines.indexWhere(
    (l) => l.startsWith('  expected-failure:'),
  );
  expect(start, isNot(-1), reason: 'ci.yaml has no expected-failure job');
  int end = start + 1;
  while (end < lines.length &&
      !RegExp('^  [A-Za-z0-9_-]+:').hasMatch(lines[end])) {
    end++;
  }
  return lines.sublist(start, end).join('\n');
}

/// The `- name:` step of [job] whose text names [needle], or null.
String? _stepNaming(String job, String needle) {
  for (final String step in job.split(RegExp(r'\n(?=      - name:)'))) {
    if (step.contains(needle)) return step;
  }
  return null;
}

/// The source-tree workspace root: from the runfiles anchor (this test's own
/// source, resolved through its link), else by walking up from the working
/// directory to a `MODULE.bazel` beside a real `dart/` directory.
String _workspaceRoot(List<String> args) {
  if (args.isNotEmpty) {
    try {
      final String located = Runfiles.create().rlocation(args.first);
      if (File(located).existsSync()) {
        final String real = File(located).resolveSymbolicLinksSync();
        return File(real).parent.parent.parent.path;
      }
    } on Exception {
      // No runfiles manifest (a direct `dart test` run): walk up instead.
    }
  }
  Directory dir = Directory.current;
  while (!File('${dir.path}/MODULE.bazel').existsSync() ||
      !Directory('${dir.path}/dart').existsSync()) {
    if (dir.parent.path == dir.path) fail('cannot locate the workspace root');
    dir = dir.parent;
  }
  return dir.path;
}
