/// CLI entry point for `//tools/e2e_runner`.
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:e2e_runner/runner.dart';
import 'package:e2e_runner/spec.dart';
import 'package:path/path.dart' as p;

ArgParser _buildParser() => ArgParser()
  ..addOption(
    'workspace',
    abbr: 'w',
    help: 'Path to the e2e workspace (defaults to BIT_WORKSPACE_DIR).',
  )
  ..addOption(
    'bazel',
    abbr: 'b',
    help: 'Bazel client binary or name (defaults to BIT_BAZEL_BINARY/bazel).',
  )
  ..addOption(
    'spec',
    help: 'Optional explicit path to e2e.yaml.',
  )
  ..addMultiOption(
    'command',
    splitCommas: false,
    help:
        'Run only the named spec command (repeatable; spec order). Fails '
        'when empty or when a name matches no command.',
  )
  ..addFlag(
    'help',
    abbr: 'h',
    negatable: false,
    help: 'Print usage information.',
  );

/// Runs an e2e workspace spec in an isolated staged directory and output base.
Future<void> main(List<String> arguments) async {
  final ArgParser parser = _buildParser();
  final ArgResults parsed;
  try {
    parsed = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr
      ..writeln('e2e_runner: ${error.message}')
      ..writeln(parser.usage);
    exitCode = 2;
    return;
  }
  if (parsed['help'] as bool) {
    stdout.writeln(parser.usage);
    return;
  }
  if (parsed.rest.isNotEmpty) {
    stderr.writeln(
      'e2e_runner: unexpected positional arguments: ${parsed.rest}',
    );
    exitCode = 2;
    return;
  }
  try {
    final String baseDir = callerWorkingDirectory();
    final String workspacePath = resolveWorkspacePath(
      flagWorkspace: parsed['workspace'] as String?,
      baseDirectory: baseDir,
    );
    final String bazelBinary = resolveBazelBinary(
      flagBazel: parsed['bazel'] as String?,
      baseDirectory: baseDir,
    );
    final rawSpec = parsed['spec'] as String?;
    final String? resolvedSpec = (rawSpec != null && rawSpec.trim().isNotEmpty)
        ? (p.isAbsolute(rawSpec)
              ? p.normalize(rawSpec)
              : p.normalize(p.join(baseDir, rawSpec)))
        : null;
    await runE2e(
      E2eRunnerOptions(
        workspacePath: workspacePath,
        bazelBinary: bazelBinary,
        specPath: resolvedSpec,
        commandFilter: parsed.wasParsed('command')
            ? parsed['command'] as List<String>
            : null,
        runtime: (
          environment: Platform.environment,
          tempParent: null,
          isWindows: Platform.isWindows,
          stdoutSink: stdout,
          stderrSink: stderr,
        ),
      ),
    );
  } on E2eRunnerException catch (error) {
    stderr.writeln('ERROR: $error');
    exitCode = 1;
  }
}
