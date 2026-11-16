/// Runs the CI Linux sandbox verifier against the live shared script and
/// workflow files.
library;

import 'dart:io';

import 'package:test/test.dart';

import 'ci_linux_sandbox_verifier.dart';

void main() {
  final String root = _resolveWorkspaceRoot();
  final workflows = WorkflowSet(<String, String>{
    for (final FileSystemEntity f in Directory(
      '$root/.github/workflows',
    ).listSync())
      if (f.path.endsWith('.yaml'))
        f.uri.pathSegments.last: File(f.path).readAsStringSync(),
  });
  final script = File('$root/$scriptPath');

  test('the shared script is executable', () {
    expect(script.existsSync(), isTrue);
    expect(script.statSync().mode & 0x49, isNonZero, reason: 'x bit');
  });
  test('the shared script sets up and proves user namespaces', () {
    expect(verifyScript(script.readAsStringSync()), isEmpty);
  });
  test('all 15 Linux Bazel jobs run the script before Bazel', () {
    final int count = linuxBazelJobs.values.fold(0, (a, j) => a + j.length);
    expect(count, 15);
    expect(verifyLinuxJobs(workflows), isEmpty);
    expect(verifyNoInlineSetup(workflows), isEmpty);
  });
  test('macOS, Windows and non-Bazel jobs are untouched', () {
    expect(verifyUntouchedJobs(workflows), isEmpty);
  });
  test('unit-tests proves linux-sandbox from the BEP runner counts', () {
    expect(verifyProofStep(workflows.files['ci.yaml']!), isEmpty);
  });
  test('reproducibility keeps its output bases under RUNNER_TEMP', () {
    expect(verifyReproducibility(workflows.files['ci.yaml']!), isEmpty);
  });
}

bool _isRoot(Directory dir) =>
    File('${dir.path}/MODULE.bazel').existsSync() &&
    File('${dir.path}/$scriptPath').existsSync();

/// The live checkout: `BUILD_WORKSPACE_DIRECTORY` under `bazel run`-style
/// invocations, else the directory above the test source's real path.
String _resolveWorkspaceRoot() {
  final String workspace =
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ?? '';
  if (workspace.isNotEmpty && _isRoot(Directory(workspace))) return workspace;
  final String anchor = Platform.environment['GUARD_ROOT_ANCHOR'] ?? '';
  final String runfiles = Platform.environment['TEST_SRCDIR'] ?? '';
  if (anchor.isEmpty || runfiles.isEmpty) {
    throw StateError('GUARD_ROOT_ANCHOR and TEST_SRCDIR must be set');
  }
  final String real = File('$runfiles/$anchor').resolveSymbolicLinksSync();
  Directory dir = File(real).parent;
  while (!_isRoot(dir)) {
    if (dir.parent.path == dir.path) throw StateError('no root above $anchor');
    dir = dir.parent;
  }
  return dir.path;
}
