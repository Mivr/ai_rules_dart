/// Spec execution: file mutation, Bazel invocation, expectation and
/// executed-test enforcement, and the staging lifecycle.
library;

import 'dart:io';

import 'package:e2e_runner/spec.dart';
import 'package:e2e_runner/test_count.dart';
import 'package:e2e_runner/workspace.dart';

/// Bazel's "no test/run targets found" exit code, always an error here.
const int bazelNoTargetsExitCode = 4;

/// The outcome of one command.
final class RunOutcome {
  /// Creates an outcome.
  const RunOutcome({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.testLog,
    required this.executedTests,
  });

  /// Process exit code.
  final int exitCode;

  /// Process stdout.
  final String stdout;

  /// Process stderr.
  final String stderr;

  /// Concatenated `test.log` contents named by the BEP (empty when none).
  final String testLog;

  /// Non-skipped executed test cases counted from the BEP / `test.xml`.
  final int executedTests;

  /// Combined stdout + stderr.
  String get output => '$stdout$stderr';
}

/// Whether [argv] names a `bazel` command (a placeholder the runner swaps
/// for the resolved client).
bool isBazelCommand(List<String> argv) => argv.isNotEmpty && argv[0] == 'bazel';

/// Returns the Bazel subcommand token (first non-flag argument after `bazel`),
/// or null when [argv] is not a `bazel` command.
String? bazelSubcommand(List<String> argv) {
  if (!isBazelCommand(argv)) return null;
  for (var i = 1; i < argv.length; i++) {
    if (!argv[i].startsWith('-')) return argv[i];
  }
  return null;
}

/// Whether [argv] names `bazel test ...`.
bool isBazelTestCommand(List<String> argv) => bazelSubcommand(argv) == 'test';

final RegExp _sandboxStrategyFlag = RegExp(
  r'^--(?:spawn_)?strategy=(?:[^=]+=)?sandboxed$',
);

/// Whether [argv] requests a POSIX-only Bazel sandbox flag (`--worker_sandboxing`
/// or a `sandboxed` strategy) that Bazel on Windows rejects.
bool requiresPosixSandbox(List<String> argv) => argv.any(
  (arg) => arg == '--worker_sandboxing' || _sandboxStrategyFlag.hasMatch(arg),
);

/// Expands `${WORKSPACE}` placeholders in [text] for [stagedDir].
String expandWorkspacePlaceholders(String text, String stagedDir) {
  final wsSlash = stagedDir.replaceAll(r'\', '/');
  final fileUrl = wsSlash.startsWith('/')
      ? 'file://$wsSlash'
      : 'file:///$wsSlash';
  return text
      .replaceAll(r'file://${WORKSPACE}', fileUrl)
      .replaceAll(r'${WORKSPACE}', wsSlash);
}

/// Builds the real argument vector for [command] (whose first token is the
/// `bazel` placeholder or another executable).
///
/// A `bazel` command becomes `<client> --output_base=<outputBase> <args...>`
/// and, for `bazel test`, gains `--build_event_json_file=<bepPath>` so the
/// executed-test count can be read. Non-`bazel` commands run as-is.
List<String> resolveArgv(
  List<String> command, {
  required String client,
  required String outputBase,
  required String bepPath,
}) {
  if (!isBazelCommand(command)) return command;
  final result = [client, '--output_base=$outputBase', ...command.sublist(1)];
  if (isBazelTestCommand(command)) {
    result.add('--build_event_json_file=$bepPath');
  }
  return result;
}

/// Asserts that [outcome] meets [expect], throwing [StateError] naming
/// [specPath] and [name] when it does not.
void checkExpectations(
  RunOutcome outcome,
  Expect? expect,
  String specPath,
  String name,
) {
  if (outcome.exitCode == bazelNoTargetsExitCode) {
    throw StateError(
      'spec $specPath: command "$name" exited '
      '$bazelNoTargetsExitCode (no test targets)',
    );
  }
  if (expect == null) {
    _requireExitZero(outcome, specPath, name);
    return;
  }
  if (expect.nonZero) {
    if (outcome.exitCode == 0) {
      throw StateError(
        'spec $specPath: command "$name" was expected to fail but exited 0',
      );
    }
  } else if (outcome.exitCode != (expect.exitCode ?? 0)) {
    throw StateError(
      'spec $specPath: command "$name" exited ${outcome.exitCode}, '
      'expected ${expect.exitCode ?? 0}',
    );
  }
  _requireAll(expect.stderrContains, outcome.stderr, 'stderr', specPath, name);
  _requireAll(expect.stdoutContains, outcome.stdout, 'stdout', specPath, name);
  _requireAll(expect.outputContains, outcome.output, 'output', specPath, name);
  _requireRegexAll(expect.outputRegex, outcome.output, specPath, name);
  _forbidAll(
    expect.stderrNotContains,
    outcome.stderr,
    'stderr',
    specPath,
    name,
  );
  _forbidAll(
    expect.outputNotContains,
    outcome.output,
    'output',
    specPath,
    name,
  );
  _requireAll(
    expect.testLogContains,
    outcome.testLog,
    'test.log',
    specPath,
    name,
  );
}

void _requireExitZero(RunOutcome outcome, String specPath, String name) {
  if (outcome.exitCode == 0) return;
  throw StateError(
    'spec $specPath: command "$name" exited ${outcome.exitCode}:\n'
    '${outcome.output}',
  );
}

void _requireAll(
  List<String> needles,
  String haystack,
  String what,
  String specPath,
  String name,
) {
  for (final needle in needles) {
    if (!haystack.contains(needle)) {
      throw StateError(
        'spec $specPath: command "$name" $what does not contain "$needle"',
      );
    }
  }
}

void _requireRegexAll(
  List<String> patterns,
  String haystack,
  String specPath,
  String name,
) {
  for (final pattern in patterns) {
    if (!RegExp(pattern, multiLine: true).hasMatch(haystack)) {
      throw StateError(
        'spec $specPath: command "$name" output does not match /$pattern/',
      );
    }
  }
}

void _forbidAll(
  List<String> needles,
  String haystack,
  String what,
  String specPath,
  String name,
) {
  for (final needle in needles) {
    if (haystack.contains(needle)) {
      throw StateError(
        'spec $specPath: command "$name" $what must not contain "$needle"',
      );
    }
  }
}

/// Asserts [executed] meets the spec's floor (default 1) for a `bazel test`.
void enforceTestFloor(
  int executed,
  int? minTestsExecuted,
  String specPath,
  String name,
) {
  final floor = minTestsExecuted ?? 1;
  if (floor < 1) {
    throw StateError(
      'spec $specPath: command "$name" min_tests_executed must be >= 1',
    );
  }
  if (executed >= floor) return;
  throw StateError(
    'spec $specPath: command "$name" executed $executed non-skipped test '
    'case(s), below the floor of $floor',
  );
}

/// Configuration for a full spec run.
final class RunnerConfig {
  /// Creates a config.
  const RunnerConfig({
    required this.workspaceDir,
    required this.repoRoot,
    required this.client,
    required this.specPath,
    required this.spec,
  });

  /// Absolute path to the workspace to stage.
  final String workspaceDir;

  /// Absolute repository root (the escaping override's target).
  final String repoRoot;

  /// Bazel client to invoke.
  final String client;

  /// Path of the spec file, used only in error messages.
  final String specPath;

  /// The parsed spec.
  final Spec spec;
}

Directory _createScratchDir() {
  if (!Platform.environment.containsKey('TEST_TMPDIR')) {
    final runnerTemp = Platform.environment['RUNNER_TEMP'];
    if (runnerTemp != null && runnerTemp.isNotEmpty) {
      final dir = Directory(runnerTemp);
      if (dir.existsSync()) return dir.createTempSync('e2e_');
    }
  }
  return Directory.systemTemp.createTempSync('e2e_');
}

/// Stages [config]'s workspace and runs its commands in order.
///
/// Returns 0 on success or 1 on failure; `bazel shutdown` runs on the staged
/// `--output_base` on every exit path.
int runSpec(RunnerConfig config) {
  final scratch = _createScratchDir();
  final stagedDir = normalizePath('${scratch.path}/ws');
  final outputBase = normalizePath('${scratch.path}/ob');
  try {
    stageWorkspace(config.workspaceDir, stagedDir, config.repoRoot);
    final commands = config.spec.commands;
    for (var i = 0; i < commands.length; i++) {
      _runOne(
        commands[i],
        bepPath: normalizePath('${scratch.path}/bep_$i.json'),
        stagedDir: stagedDir,
        outputBase: outputBase,
        config: config,
      );
    }
    return 0;
  } on StateError catch (e) {
    stderr.writeln(e.message);
    return 1;
  } finally {
    _shutdown(config.client, outputBase, stagedDir);
    _deleteScratch(scratch);
  }
}

void _runOne(
  Command command, {
  required String bepPath,
  required String stagedDir,
  required String outputBase,
  required RunnerConfig config,
}) {
  if (Platform.isWindows &&
      isBazelCommand(command.argv) &&
      requiresPosixSandbox(command.argv)) {
    stdout.writeln(
      'skipping command "${command.name}" on Windows '
      '(POSIX sandbox flag unsupported on Windows)',
    );
    return;
  }
  applyWriteFiles(command, stagedDir);
  applyReplaceInFiles(command, stagedDir, config.specPath);
  final argv = resolveArgv(
    command.argv,
    client: config.client,
    outputBase: outputBase,
    bepPath: bepPath,
  );
  final isTest = isBazelTestCommand(command.argv);
  final needTestLog =
      command.expect != null && command.expect!.testLogContains.isNotEmpty;
  final outcome = _runProcess(
    argv,
    stagedDir,
    bepPath: isTest ? bepPath : null,
    outputBase: outputBase,
    needTestLog: needTestLog,
  );
  checkExpectations(outcome, command.expect, config.specPath, command.name);
  if (isTest && outcome.exitCode == 0) {
    enforceTestFloor(
      outcome.executedTests,
      command.minTestsExecuted,
      config.specPath,
      command.name,
    );
  }
}

/// Writes [command]'s `write_files` entries into [stagedDir].
void applyWriteFiles(Command command, String stagedDir) {
  command.writeFiles.forEach((path, content) {
    final file = File('$stagedDir/$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(expandWorkspacePlaceholders(content, stagedDir));
  });
}

/// Applies [command]'s `replace_in_files` edits inside [stagedDir].
void applyReplaceInFiles(Command command, String stagedDir, String specPath) {
  command.replaceInFiles.forEach((path, replacements) {
    final file = File('$stagedDir/$path');
    if (!file.existsSync()) {
      throw StateError(
        'spec $specPath: command "${command.name}" cannot read "$path": '
        'file not found',
      );
    }
    final String text;
    try {
      text = file.readAsStringSync();
    } on FileSystemException catch (e) {
      throw StateError(
        'spec $specPath: command "${command.name}" cannot read "$path": '
        '${e.message}',
      );
    }
    var replaced = text;
    for (final r in replacements) {
      replaced = replaced.replaceAll(
        r.find,
        expandWorkspacePlaceholders(r.replace, stagedDir),
      );
    }
    file.writeAsStringSync(replaced);
  });
}

void _scanTestLogs(String dirPath, StringBuffer buffer) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return;
  try {
    for (final entry in dir.listSync(recursive: true, followLinks: false)) {
      if (entry is File && entry.path.endsWith('test.log')) {
        try {
          buffer.write(entry.readAsStringSync());
        } on FileSystemException {
          // Ignored: test log scan is best-effort.
        }
      }
    }
  } on FileSystemException {
    // Ignored: test log directory scan is best-effort.
  }
}

/// Reads `test.log` contents named by [bepText] (falling back to scanning
/// [outputBase] and [workingDir] when [needFallback] is set), and records a
/// timeout marker when BEP reports a `TIMEOUT` status on platforms whose test
/// wrapper does not write one into `test.log`.
String collectTestLogs(
  String bepText,
  String workingDir,
  String outputBase, {
  required bool needFallback,
}) {
  final buffer = StringBuffer();
  for (final path in outputPathsFromBep(bepText, 'test.log')) {
    final file = File(path);
    if (file.existsSync()) buffer.write(file.readAsStringSync());
  }
  if (buffer.isEmpty && needFallback) {
    _scanTestLogs(outputBase, buffer);
    _scanTestLogs(workingDir, buffer);
    final bazelLogs = Directory('$workingDir/bazel-testlogs');
    if (bazelLogs.existsSync()) {
      try {
        _scanTestLogs(bazelLogs.resolveSymbolicLinksSync(), buffer);
      } on FileSystemException {
        // Ignored: dangling bazel-testlogs link.
      }
    }
  }
  if (hasTimedOutTestInBep(bepText) &&
      !buffer.toString().contains('Test timed out')) {
    buffer.writeln('-- Test timed out --');
  }
  return buffer.toString();
}

RunOutcome _runProcess(
  List<String> argv,
  String workingDir, {
  required String? bepPath,
  required String outputBase,
  required bool needTestLog,
}) {
  final result = Process.runSync(
    argv.first,
    argv.sublist(1),
    workingDirectory: workingDir,
  );
  final bepText = bepPath != null && File(bepPath).existsSync()
      ? File(bepPath).readAsStringSync()
      : '';
  final testLog = bepPath == null && !needTestLog
      ? ''
      : collectTestLogs(
          bepText,
          workingDir,
          outputBase,
          needFallback: needTestLog,
        );
  final executedTests = bepPath == null
      ? 0
      : countNonSkippedTests(
          bepText,
          testLogsDir: outputBase,
          workspaceDir: workingDir,
        );
  return RunOutcome(
    exitCode: result.exitCode,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
    testLog: testLog,
    executedTests: executedTests,
  );
}

void _shutdown(String client, String outputBase, String stagedDir) {
  try {
    Process.runSync(client, [
      '--output_base=$outputBase',
      'shutdown',
    ], workingDirectory: Directory(stagedDir).existsSync() ? stagedDir : null);
  } on ProcessException catch (e) {
    stderr.writeln('bazel shutdown failed: ${e.message}');
  }
}

void _deleteScratch(Directory scratch) {
  try {
    deleteTree(scratch.path);
  } on FileSystemException catch (e) {
    stderr.writeln('scratch cleanup failed: ${e.message}');
  }
}
