/// Execution engine for `mivr-e2e-spec/1` workspaces.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:e2e_runner/junit.dart';
import 'package:e2e_runner/spec.dart';
import 'package:e2e_runner/staging.dart';
import 'package:path/path.dart' as p;

/// Environment variables leaked by an outer `bazel run` or `bazel test` that
/// must never be inherited by staged inner Bazel invocations.
const List<String> _outerBazelEnvVars = [
  'BUILD_WORKSPACE_DIRECTORY',
  'BUILD_WORKING_DIRECTORY',
  'BAZELISK_SKIP_WRAPPER',
  'RUNFILES_DIR',
  'RUNFILES_MANIFEST_FILE',
  'JAVA_RUNFILES',
  'TEST_SRCDIR',
  'TEST_TMPDIR',
  'TEST_UNDECLARED_OUTPUTS_DIR',
  'TEST_BINARY',
  'TEST_TARGET',
  'TEST_WORKSPACE',
  'XML_OUTPUT_FILE',
];

/// Optional runtime/environment overrides for [E2eRunnerOptions].
typedef RunnerRuntimeConfig = ({
  Map<String, String>? environment,
  Directory? tempParent,
  bool? isWindows,
  StringSink? stdoutSink,
  StringSink? stderrSink,
});

const RunnerRuntimeConfig _defaultRuntimeConfig = (
  environment: null,
  tempParent: null,
  isWindows: null,
  stdoutSink: null,
  stderrSink: null,
);

/// Configuration for a single [runE2e] execution.
class E2eRunnerOptions {
  /// Creates [E2eRunnerOptions].
  const new({
    required this.workspacePath,
    required this.bazelBinary,
    this.specPath,
    this.commandFilter,
    this.runtime = _defaultRuntimeConfig,
  });

  /// Source e2e workspace directory to stage and run.
  final String workspacePath;

  /// Resolved Bazel client binary or command name.
  final String bazelBinary;

  /// Optional explicit path to `e2e.yaml` (defaults to `<workspace>/e2e.yaml`).
  final String? specPath;

  /// Command names to execute (in spec order); `null` runs every command.
  ///
  /// An empty list, a blank name, or a name matching no spec command fails
  /// closed before any command runs.
  final List<String>? commandFilter;

  /// Environment, scratch parent, platform, and output stream overrides.
  final RunnerRuntimeConfig runtime;

  /// Base process environment (defaults to [Platform.environment]).
  Map<String, String>? get environment => runtime.environment;

  /// Optional parent directory for the isolated scratch tree.
  Directory? get tempParent => runtime.tempParent;

  /// Optional platform override for testing Windows client lookup on Unix.
  bool? get isWindows => runtime.isWindows;

  /// Optional sink receiving status and command `stdout` text.
  StringSink? get stdoutSink => runtime.stdoutSink;

  /// Optional sink receiving command `stderr` text.
  StringSink? get stderrSink => runtime.stderrSink;
}

typedef _PreparedCommand = ({
  String? subcommand,
  List<String> args,
  String? bepPath,
});

typedef _CommandOutput = ({
  int exitCode,
  String stdout,
  String stderr,
});

typedef _ScratchPaths = ({
  String stagedWorkspace,
  String outputBase,
  String bepDir,
});

class _RunState {
  const new({
    required this.options,
    required this.spec,
    required this.paths,
    required this.childEnv,
    required this.windowsMode,
  });

  final E2eRunnerOptions options;
  final E2eSpec spec;
  final _ScratchPaths paths;
  final Map<String, String> childEnv;
  final bool windowsMode;

  String get stagedWorkspace => paths.stagedWorkspace;
  String get outputBase => paths.outputBase;
  String get bepDir => paths.bepDir;
}

/// Resolves the workspace directory from `--workspace` ([flagWorkspace]) or
/// `BIT_WORKSPACE_DIR` in [environment], relative to [baseDirectory].
String resolveWorkspacePath({
  String? flagWorkspace,
  Map<String, String>? environment,
  String? baseDirectory,
}) {
  final Map<String, String> env = environment ?? Platform.environment;
  final String baseDir = baseDirectory ?? callerWorkingDirectory(env);
  final String? raw = (flagWorkspace != null && flagWorkspace.trim().isNotEmpty)
      ? flagWorkspace.trim()
      : env['BIT_WORKSPACE_DIR']?.trim();
  if (raw == null || raw.isEmpty) {
    throw const E2eRunnerException(
      specPath: '<cli>',
      commandName: '<cli>',
      message:
          'missing workspace: pass --workspace=<dir> or set BIT_WORKSPACE_DIR',
    );
  }
  return _resolveAgainstBase(raw, baseDir);
}

/// Resolves the Bazel client executable from `--bazel` ([flagBazel]) or
/// `BIT_BAZEL_BINARY` in [environment], handling Windows extensionless paths.
String resolveBazelBinary({
  String? flagBazel,
  Map<String, String>? environment,
  String? baseDirectory,
  bool? isWindows,
}) {
  final Map<String, String> env = environment ?? Platform.environment;
  final String baseDir = baseDirectory ?? callerWorkingDirectory(env);
  final bool win = isWindows ?? Platform.isWindows;
  final String? fromFlag = (flagBazel != null && flagBazel.trim().isNotEmpty)
      ? flagBazel.trim()
      : null;
  final String? fromEnv = env['BIT_BAZEL_BINARY']?.trim();
  final String raw =
      fromFlag ?? ((fromEnv != null && fromEnv.isNotEmpty) ? fromEnv : 'bazel');
  if (_containsPathSeparator(raw)) {
    final String candidate = _resolveAgainstBase(raw, baseDir);
    return _matchExecutableFile(candidate, env: env, isWindows: win) ??
        candidate;
  }
  final String? pathVar = env['PATH'] ?? env['Path'] ?? env['path'];
  if (pathVar == null || pathVar.isEmpty) return raw;
  final separator = win ? ';' : ':';
  for (final String entry in pathVar.split(separator)) {
    if (entry.isEmpty) continue;
    final String joined = p.join(entry, raw);
    final String? matched = _matchExecutableFile(
      joined,
      env: env,
      isWindows: win,
    );
    if (matched != null) return matched;
  }
  return raw;
}

/// Returns the caller's working directory, honouring `BUILD_WORKING_DIRECTORY`
/// when invoked via `bazel run`.
String callerWorkingDirectory([Map<String, String>? environment]) {
  final Map<String, String> env = environment ?? Platform.environment;
  final String? bwd = env['BUILD_WORKING_DIRECTORY'];
  if (bwd != null && bwd.isNotEmpty) return bwd;
  final String? bwsd = env['BUILD_WORKSPACE_DIRECTORY'];
  if (bwsd != null && bwsd.isNotEmpty) return bwsd;
  return Directory.current.path;
}

String _resolveAgainstBase(String rawPath, String baseDir) {
  if (p.isAbsolute(rawPath) || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(rawPath)) {
    return p.normalize(rawPath);
  }
  return p.normalize(p.join(baseDir, rawPath));
}

bool _containsPathSeparator(String value) =>
    value.contains('/') || value.contains(r'\');

String? _matchExecutableFile(
  String baseCandidate, {
  required Map<String, String> env,
  required bool isWindows,
}) {
  if (!isWindows) {
    return File(baseCandidate).existsSync()
        ? File(baseCandidate).absolute.path
        : null;
  }
  final List<String> extensions = _windowsCandidateExtensions(env);
  final String lowerBase = baseCandidate.toLowerCase();
  final bool hasKnownExt = extensions.any(
    (ext) => ext.isNotEmpty && lowerBase.endsWith(ext.toLowerCase()),
  );
  if (hasKnownExt && File(baseCandidate).existsSync()) {
    return File(baseCandidate).absolute.path;
  }
  for (final ext in extensions) {
    if (ext.isEmpty) continue;
    for (final String variant in {ext.toLowerCase(), ext.toUpperCase()}) {
      final candidate = '$baseCandidate$variant';
      if (File(candidate).existsSync()) {
        return File(candidate).absolute.path;
      }
    }
  }
  if (File(baseCandidate).existsSync()) {
    return File(baseCandidate).absolute.path;
  }
  return null;
}

List<String> _windowsCandidateExtensions(Map<String, String> env) {
  final result = <String>['.exe', '.cmd', '.bat', '.com'];
  final String? pathExt = env['PATHEXT'] ?? env['Pathext'] ?? env['pathext'];
  if (pathExt != null && pathExt.isNotEmpty) {
    for (final String raw in pathExt.split(';')) {
      final String trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      final normalized = trimmed.startsWith('.') ? trimmed : '.$trimmed';
      if (!result.any((e) => e.toLowerCase() == normalized.toLowerCase())) {
        result.add(normalized);
      }
    }
  }
  return result;
}

/// Stages the workspace in [options] into an isolated scratch directory, runs
/// all commands in its `e2e.yaml` against a dedicated `--output_base`, and runs
/// `bazel shutdown` on that `--output_base` on every exit path.
Future<void> runE2e(E2eRunnerOptions options) async {
  final Map<String, String> baseEnv =
      options.environment ?? Platform.environment;
  final bool win = options.isWindows ?? Platform.isWindows;
  final Directory scratchRoot = _selectScratchParent(
    options.tempParent,
    baseEnv,
  ).createTempSync('e2e_');
  final String stagedWorkspace = p.join(scratchRoot.path, 'ws');
  final String outputBase = p.join(scratchRoot.path, 'ob');
  final String bepDir = p.join(scratchRoot.path, 'bep');
  Directory(outputBase).createSync(recursive: true);
  Directory(bepDir).createSync(recursive: true);
  final Map<String, String> childEnv = buildSanitizedChildEnv(baseEnv);

  try {
    final String specFile =
        options.specPath ?? p.join(options.workspacePath, 'e2e.yaml');
    stageWorkspace(
      sourceWorkspace: options.workspacePath,
      stagedWorkspace: stagedWorkspace,
      context: (specPath: specFile, commandName: '<spec>'),
    );
    final E2eSpec spec = loadE2eSpec(specFile);
    final state = _RunState(
      options: options,
      spec: spec,
      paths: (
        stagedWorkspace: stagedWorkspace,
        outputBase: outputBase,
        bepDir: bepDir,
      ),
      childEnv: childEnv,
      windowsMode: win,
    );
    for (final int i in _selectCommandIndices(spec, options.commandFilter)) {
      await _executeStep(state, index: i);
    }
  } finally {
    await _shutdownScratchBazel(
      bazelBinary: options.bazelBinary,
      outputBase: outputBase,
      workingDirectory: stagedWorkspace,
      environment: childEnv,
      isWindows: win,
    );
    deleteScratchTree(scratchRoot);
  }
}

/// Returns the indices of [spec] commands selected by [filter], in spec order.
List<int> _selectCommandIndices(E2eSpec spec, List<String>? filter) {
  final all = List<int>.generate(spec.commands.length, (i) => i);
  if (filter == null) return all;
  final String shown = filter.map((name) => '"$name"').join(', ');
  if (filter.isEmpty || filter.any((name) => name.trim().isEmpty)) {
    throw E2eRunnerException(
      specPath: spec.specPath,
      commandName: '--command',
      message: '--command filter is empty ($shown)',
    );
  }
  final Set<String> known = spec.commands.map((c) => c.name).toSet();
  for (final String name in filter) {
    if (!known.contains(name)) {
      throw E2eRunnerException(
        specPath: spec.specPath,
        commandName: '--command',
        message:
            '--command filter "$name" matches no command; '
            'available: ${known.join(', ')}',
      );
    }
  }
  return all.where((i) => filter.contains(spec.commands[i].name)).toList();
}

Directory _selectScratchParent(
  Directory? explicitParent,
  Map<String, String> env,
) {
  if (explicitParent != null) {
    explicitParent.createSync(recursive: true);
    return explicitParent;
  }
  final String? runnerTemp = env['RUNNER_TEMP'];
  if (runnerTemp != null && runnerTemp.isNotEmpty) {
    final dir = Directory(runnerTemp);
    if (dir.existsSync()) return dir;
  }
  return Directory.systemTemp;
}

/// Returns a copy of [environment] with outer Bazel run/test variables removed.
Map<String, String> buildSanitizedChildEnv(Map<String, String> environment) {
  final sanitized = Map<String, String>.of(environment);
  _outerBazelEnvVars.forEach(sanitized.remove);
  return sanitized;
}

Future<void> _executeStep(_RunState state, {required int index}) async {
  final CommandSpec cmd = state.spec.commands[index];
  final SpecErrorContext ctx = (
    specPath: state.spec.specPath,
    commandName: cmd.name,
  );
  if (cmd.writeFiles.isNotEmpty) {
    applyWriteFiles(
      cmd.writeFiles,
      stagedWorkspace: state.stagedWorkspace,
      context: ctx,
    );
  }
  if (cmd.replaceInFiles.isNotEmpty) {
    applyReplaceInFiles(
      cmd.replaceInFiles,
      stagedWorkspace: state.stagedWorkspace,
      context: ctx,
    );
  }
  final _PreparedCommand prepared = _prepareBazelArgs(
    cmd.tokens,
    outputBase: state.outputBase,
    bepDir: state.bepDir,
    stepIndex: index,
  );
  state.options.stdoutSink?.writeln(
    '==> [${p.basename(state.options.workspacePath)}] ${cmd.name}',
  );
  final _CommandOutput output = await _spawnCommand(
    state,
    prepared.args,
    ctx,
  );
  _verifyCommandOutcome(
    state: state,
    command: cmd,
    prepared: prepared,
    output: output,
    context: ctx,
  );
}

_PreparedCommand _prepareBazelArgs(
  List<String> rawTokens, {
  required String outputBase,
  required String bepDir,
  required int stepIndex,
}) {
  final List<String> tokens = rawTokens.first == 'bazel'
      ? rawTokens.sublist(1)
      : List<String>.of(rawTokens);
  int? subIdx;
  for (var i = 0; i < tokens.length; i++) {
    if (!tokens[i].startsWith('-')) {
      subIdx = i;
      break;
    }
  }
  if (subIdx == null) {
    return (
      subcommand: null,
      args: <String>['--output_base=$outputBase', ...tokens],
      bepPath: null,
    );
  }
  final String subcommand = tokens[subIdx];
  final List<String> startup = tokens.sublist(0, subIdx);
  final List<String> rest = tokens.sublist(subIdx + 1);
  final bool hasOutputBase = startup.any(
    (arg) => arg == '--output_base' || arg.startsWith('--output_base='),
  );
  final fullArgs = <String>[
    if (!hasOutputBase) '--output_base=$outputBase',
    ...startup,
    subcommand,
  ];
  String? bepPath;
  if (subcommand == 'test') {
    final bool hasBep = rest.any(
      (arg) =>
          arg == '--build_event_json_file' ||
          arg.startsWith('--build_event_json_file='),
    );
    if (!hasBep) {
      bepPath = p.join(bepDir, 'bep_$stepIndex.json');
      fullArgs.add('--build_event_json_file=$bepPath');
    }
  }
  fullArgs.addAll(rest);
  return (subcommand: subcommand, args: fullArgs, bepPath: bepPath);
}

Future<_CommandOutput> _spawnCommand(
  _RunState state,
  List<String> args,
  SpecErrorContext context,
) async {
  final String executable = state.options.bazelBinary;
  final bool useShell = state.windowsMode && _isBatchScript(executable);
  final Process proc;
  try {
    proc = await Process.start(
      executable,
      args,
      workingDirectory: state.stagedWorkspace,
      environment: state.childEnv,
      runInShell: useShell,
    );
  } on ProcessException catch (error) {
    throw E2eRunnerException(
      specPath: context.specPath,
      commandName: context.commandName,
      message: 'failed to start "$executable": ${error.message}',
    );
  }
  final stdoutBuf = StringBuffer();
  final stderrBuf = StringBuffer();
  final Future<void> outDone = proc.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .forEach((chunk) {
        stdoutBuf.write(chunk);
        state.options.stdoutSink?.write(chunk);
      });
  final Future<void> errDone = proc.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .forEach((chunk) {
        stderrBuf.write(chunk);
        state.options.stderrSink?.write(chunk);
      });
  final int exitCode = await proc.exitCode;
  await Future.wait<void>([outDone, errDone]);
  return (
    exitCode: exitCode,
    stdout: stdoutBuf.toString(),
    stderr: stderrBuf.toString(),
  );
}

bool _isBatchScript(String executable) {
  final String lower = executable.toLowerCase();
  return lower.endsWith('.bat') || lower.endsWith('.cmd');
}

void _verifyCommandOutcome({
  required _RunState state,
  required CommandSpec command,
  required _PreparedCommand prepared,
  required _CommandOutput output,
  required SpecErrorContext context,
}) {
  if (output.exitCode == 4) {
    throw E2eRunnerException(
      specPath: context.specPath,
      commandName: context.commandName,
      message:
          'Bazel exited with code 4 (NO_TESTS_FOUND), which is rejected '
          'unconditionally',
    );
  }
  _verifyExitCode(command.expect, output, context);
  if (prepared.subcommand == 'test' &&
      (output.exitCode == 0 || command.minTestsExecuted != null)) {
    final int floor = command.minTestsExecuted ?? 1;
    final TestCaseCount counts = countCommandTestCases(
      bepJsonPath: prepared.bepPath,
      stagedWorkspace: state.stagedWorkspace,
      scratchOutputBase: state.outputBase,
    );
    if (counts.executed < floor) {
      throw E2eRunnerException(
        specPath: context.specPath,
        commandName: context.commandName,
        message:
            'executed ${counts.executed} non-skipped test(s) '
            '(${counts.total} total from ${counts.source}), '
            'below min_tests_executed=$floor',
      );
    }
  }
  _verifyOutputExpectations(
    state: state,
    expect: command.expect,
    prepared: prepared,
    output: output,
    context: context,
  );
}

void _verifyExitCode(
  ExpectSpec expect,
  _CommandOutput output,
  SpecErrorContext context,
) {
  final int actual = output.exitCode;
  if (expect.exitCode != null) {
    if (actual != expect.exitCode) {
      throw E2eRunnerException(
        specPath: context.specPath,
        commandName: context.commandName,
        message:
            'expected exit code ${expect.exitCode}, got $actual\n'
            '${_tailSnippet(output)}',
      );
    }
    return;
  }
  if (expect.nonZero) {
    if (actual == 0) {
      throw E2eRunnerException(
        specPath: context.specPath,
        commandName: context.commandName,
        message: 'expected non-zero exit code, got 0\n${_tailSnippet(output)}',
      );
    }
    return;
  }
  if (actual != 0) {
    throw E2eRunnerException(
      specPath: context.specPath,
      commandName: context.commandName,
      message: 'expected exit code 0, got $actual\n${_tailSnippet(output)}',
    );
  }
}

void _verifyOutputExpectations({
  required _RunState state,
  required ExpectSpec expect,
  required _PreparedCommand prepared,
  required _CommandOutput output,
  required SpecErrorContext context,
}) {
  final String combined = output.stdout.isEmpty
      ? output.stderr
      : (output.stderr.isEmpty
            ? output.stdout
            : '${output.stdout}\n${output.stderr}');
  _requireContainsAll(output.stdout, expect.stdoutContains, 'stdout', context);
  _requireContainsAll(output.stderr, expect.stderrContains, 'stderr', context);
  _requireContainsAll(combined, expect.outputContains, 'output', context);
  _requireNotContainsAny(
    output.stderr,
    expect.stderrNotContains,
    'stderr',
    context,
  );
  _requireNotContainsAny(
    combined,
    expect.outputNotContains,
    'output',
    context,
  );
  for (final RegExp regex in expect.outputRegex) {
    if (!regex.hasMatch(combined)) {
      throw E2eRunnerException(
        specPath: context.specPath,
        commandName: context.commandName,
        message:
            'output did not match regex /${regex.pattern}/\n'
            '${_tailSnippet(output)}',
      );
    }
  }
  if (expect.testLogContains.isNotEmpty) {
    final String logs = collectCommandTestLogs(
      bepJsonPath: prepared.bepPath,
      stagedWorkspace: state.stagedWorkspace,
      scratchOutputBase: state.outputBase,
    );
    _requireContainsAll(logs, expect.testLogContains, 'test.log', context);
  }
  if (expect.testXmlContains.isNotEmpty) {
    final String xml = collectCommandTestXml(
      bepJsonPath: prepared.bepPath,
      stagedWorkspace: state.stagedWorkspace,
      scratchOutputBase: state.outputBase,
    );
    _requireContainsAll(xml, expect.testXmlContains, 'test.xml', context);
  }
}

void _requireContainsAll(
  String haystack,
  List<String> needles,
  String streamName,
  SpecErrorContext context,
) {
  for (final needle in needles) {
    if (!haystack.contains(needle)) {
      throw E2eRunnerException(
        specPath: context.specPath,
        commandName: context.commandName,
        message: 'expected $streamName to contain "$needle"',
      );
    }
  }
}

void _requireNotContainsAny(
  String haystack,
  List<String> forbidden,
  String streamName,
  SpecErrorContext context,
) {
  for (final needle in forbidden) {
    if (haystack.contains(needle)) {
      throw E2eRunnerException(
        specPath: context.specPath,
        commandName: context.commandName,
        message: 'expected $streamName not to contain "$needle"',
      );
    }
  }
}

String _tailSnippet(_CommandOutput output) {
  final String combined = '${output.stdout}\n${output.stderr}'.trim();
  if (combined.isEmpty) return '(no command output)';
  const maxChars = 1200;
  return combined.length <= maxChars
      ? combined
      : '...${combined.substring(combined.length - maxChars)}';
}

Future<void> _shutdownScratchBazel({
  required String bazelBinary,
  required String outputBase,
  required String workingDirectory,
  required Map<String, String> environment,
  required bool isWindows,
}) async {
  final String runDir = Directory(workingDirectory).existsSync()
      ? workingDirectory
      : Directory.current.path;
  try {
    await Process.run(
      bazelBinary,
      <String>['--output_base=$outputBase', 'shutdown'],
      workingDirectory: runDir,
      environment: environment,
      runInShell: isWindows && _isBatchScript(bazelBinary),
    );
  } on ProcessException {
    // If the Bazel binary itself failed to launch, do not mask the primary
    // E2eRunnerException from the try block.
  }
}

/// Deletes [scratchRoot], the per-workspace scratch tree of one e2e run.
///
/// Bazel makes its output base read-only (external repositories, execroot), so
/// a plain recursive delete fails and would leak the whole tree, several GB per
/// workspace. The tree is made writable first, without following symlinks. A
/// delete that still fails is reported on stderr with the path and the error.
void deleteScratchTree(Directory scratchRoot) {
  if (!scratchRoot.existsSync()) {
    return;
  }
  try {
    _makeTreeWritable(scratchRoot);
    scratchRoot.deleteSync(recursive: true);
  } on FileSystemException catch (e) {
    stderr.writeln(
      'warning: e2e_runner could not delete scratch tree '
      '${scratchRoot.path}: $e',
    );
  } on ProcessException catch (e) {
    stderr.writeln(
      'warning: e2e_runner could not delete scratch tree '
      '${scratchRoot.path}: $e',
    );
  }
}

/// Adds owner read, write and search permission to every entry under [root]
/// (and [root] itself) so it can be deleted. `chmod -R` and `attrib /S /D` do
/// not follow symlinks.
void _makeTreeWritable(Directory root) {
  final ProcessResult result = Platform.isWindows
      ? Process.runSync('cmd', <String>[
          '/c',
          'attrib',
          '-r',
          p.join(root.path, '*'),
          '/s',
          '/d',
        ])
      : Process.runSync('chmod', <String>['-R', 'u+rwx', root.path]);
  if (result.exitCode != 0) {
    stderr.writeln(
      'warning: e2e_runner could not make ${root.path} writable '
      '(exit ${result.exitCode}): ${result.stderr}',
    );
  }
}
