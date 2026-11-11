import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Builds `dev/import_check_export` as a consumer would.
///
/// `dev/` is a nested module that depends on rules_dart as an external
/// repository, so its rule (`defs.bzl`) loads `@rules_dart//dart:import_check.bzl`
/// and defaults `_import_check` to `//dart:import_check` from outside
/// `//dart`. A clean executable must build; one that imports a package its
/// `deps` do not provide must fail with the check's usual line. The nested
/// Bazel uses its own output base, so it never waits on the outer server.
void main(List<String> args) {
  final String root = _workspaceRoot(args.first);

  test('a clean executable passes the check', () {
    final ProcessResult result = _bazel(root, 'bazel', [
      '//import_check_export:clean',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  });

  test('an executable importing a package its deps lack fails the check', () {
    final ProcessResult result = _bazel(root, 'bazel', [
      '//import_check_export:bad',
    ]);
    final output = '${result.stdout}${result.stderr}';
    expect(result.exitCode, isNot(0), reason: output);
    expect(
      output,
      contains(
        "imports 'package:hidden/hidden.dart', but package 'hidden' is not a direct dependency",
      ),
    );
    expect(output, contains("Add the target that provides package 'hidden'"));
  });
}

/// Runs `bazel build` for [targets] in the nested `dev` module.
ProcessResult _bazel(String root, String bazel, List<String> targets) {
  final String base = p.join(_scratch(), 'output_base');
  final env = <String, String>{'HOME': _home()};
  final startup = ['--output_base=$base', '--max_idle_secs=30'];
  final ProcessResult result = Process.runSync(
    bazel,
    [...startup, 'build', '--lockfile_mode=off', ...targets],
    workingDirectory: p.join(root, 'dev'),
    environment: env,
  );
  Process.runSync(
    bazel,
    [...startup, 'shutdown'],
    workingDirectory: p.join(root, 'dev'),
    environment: env,
  );
  return result;
}

String _scratch() =>
    Platform.environment['TEST_TMPDIR'] ?? Directory.systemTemp.path;

/// The home directory the outer Bazel runs under, whose `.bazelrc` names the
/// shared caches: `HOME` when set, else the prefix of the test's own path
/// before Bazel's default `.cache/bazel` output root.
String _home() {
  final String? home = Platform.environment['HOME'];
  if (home != null && home.isNotEmpty) return home;
  final String tmp = _scratch();
  final int cut = tmp.indexOf('/.cache/bazel/');
  return cut < 0 ? tmp : tmp.substring(0, cut);
}

/// The source-tree workspace root, from the runfiles path of this test's source.
String _workspaceRoot(String rlocationPath) {
  final String located = Runfiles.create().rlocation(rlocationPath);
  final String real = File(located).resolveSymbolicLinksSync();
  return File(real).parent.parent.parent.parent.path;
}
