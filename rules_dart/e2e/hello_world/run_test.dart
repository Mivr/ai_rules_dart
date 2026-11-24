import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Runs both snapshot-mode binaries through their launchers with arguments.
///
/// A `.aot` or `.jit` file is not an executable: before the snapshot launcher
/// existed `bazel run` segfaulted on the AOT file and failed with `Exec format
/// error` on the JIT file. This test starts the same entry `bazel run` uses,
/// forwards arguments, and asserts the program's stdout and exit code.
Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: run_test.dart <aot-launcher> <jit-launcher>');
    exit(64);
  }
  final runfiles = Runfiles.create();
  await _run(runfiles, args[0], 'aot-snapshot', <String>['alpha', 'beta']);
  await _run(runfiles, args[1], 'jit-snapshot', <String>['gamma']);
  stdout.writeln('PASS: both snapshot launchers forwarded their arguments');
}

/// Runs one launcher and fails unless it exits 0 with the expected output.
Future<void> _run(
  Runfiles runfiles,
  String rlocation,
  String mode,
  List<String> arguments,
) async {
  final launcher = runfiles.rlocation(rlocation);
  final ProcessResult result;
  try {
    result = await Process.run(launcher, arguments);
  } on ProcessException catch (error) {
    stderr.writeln('FAIL: $mode launcher did not start: ${error.message}');
    exit(1);
  }
  final output = '${result.stdout}${result.stderr}';
  if (result.exitCode != 0) {
    stderr.writeln('FAIL: $mode exited ${result.exitCode}:\n$output');
    exit(1);
  }
  if (!output.contains('Hello, World!')) {
    stderr.writeln('FAIL: $mode did not print the program stdout:\n$output');
    exit(1);
  }
  final expected = 'arguments: ${arguments.join(' ')}';
  if (!output.contains(expected)) {
    stderr.writeln('FAIL: $mode did not receive "$expected":\n$output');
    exit(1);
  }
}
