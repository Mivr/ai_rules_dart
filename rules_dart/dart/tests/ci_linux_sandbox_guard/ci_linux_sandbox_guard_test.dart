import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'ci_linux_sandbox_verifier.dart';

/// Runs the verifier over the live setup script and workflow files. Runs
/// unsandboxed over the live tree, resolving the root from its runfiles anchor.
void main(List<String> args) {
  final String root = _workspaceRoot(args);
  test('the shared script enables and verifies user namespaces', () {
    final script = File('$root/$scriptPath');
    expect(script.existsSync(), isTrue, reason: 'missing $scriptPath');
    expect(verifyScript(script.readAsStringSync()), isEmpty);
    if (!Platform.isWindows) {
      // Windows filesystems carry no execute bits.
      expect(
        script.statSync().mode & 0x49,
        isNot(0),
        reason: '$scriptPath must be executable',
      );
    }
  });
  test('every Linux Bazel job, unchanged job and proof step is sound', () {
    final Map<String, String> files = {
      for (final FileSystemEntity f in Directory(
        '$root/.github/workflows',
      ).listSync())
        if (f is File && f.path.endsWith('.yaml'))
          f.uri.pathSegments.last: f.readAsStringSync(),
    };
    expect(verifyWorkflows(files), isEmpty);
  });
}

/// Resolves the repository root via the runfiles anchor.
String _workspaceRoot(List<String> args) {
  if (args.isNotEmpty) {
    try {
      final String located = Runfiles.create().rlocation(args.first);
      Directory dir = Directory(File(located).resolveSymbolicLinksSync())
          .parent;
      while (dir.path != dir.parent.path) {
        if (File('${dir.path}/MODULE.bazel').existsSync() &&
            Directory('${dir.path}/dart').existsSync()) {
          return dir.path;
        }
        dir = dir.parent;
      }
    } on Object catch (_) {
      // Fall through to environment lookup.
    }
  }
  for (final key in ['BUILD_WORKSPACE_DIRECTORY', 'BUILD_WORKING_DIRECTORY']) {
    final String? candidate = Platform.environment[key];
    if (candidate != null && Directory(candidate).existsSync()) {
      return candidate;
    }
  }
  return Directory.current.path;
}
