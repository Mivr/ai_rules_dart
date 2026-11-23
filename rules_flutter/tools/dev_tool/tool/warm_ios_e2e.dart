/// Builds iOS simulator e2e targets into the shared disk cache before tests run.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/bazel.dart';
import 'package:flutter_bazel_dev_tool/device_ios_sim.dart';
import 'package:path/path.dart' as p;

/// A target to pre-build in a specific workspace.
class WarmTarget {
  /// Workspace directory relative to repository root.
  final String workspace;

  /// Target label within the workspace.
  final String target;

  const new({required this.workspace, required this.target});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WarmTarget &&
          runtimeType == other.runtimeType &&
          workspace == other.workspace &&
          target == other.target;

  @override
  int get hashCode => Object.hash(workspace, target);
}

/// The default targets pre-warmed for iOS simulator e2e tests.
///
/// Each workspace's simulator bundle and its `flutter_application` dev inputs
/// are both listed: the bundle compiles its dev inputs inside a split
/// transition, so warming the bundle alone leaves the host-configured dev
/// build that `run` and `attach` read cold for the timed e2e run.
const defaultWarmTargets = <WarmTarget>[
  WarmTarget(workspace: 'e2e/ios_example', target: ':app'),
  WarmTarget(workspace: 'e2e/ios_example', target: ':app_flutter'),
  WarmTarget(workspace: 'e2e/plugin_example', target: ':plugin_ios'),
  WarmTarget(workspace: 'e2e/plugin_example', target: ':plugin_app'),
];

/// Thrown when warming fails.
class WarmFailure implements Exception {
  /// The reason explaining the failure.
  final String reason;

  const new(this.reason);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WarmFailure &&
          runtimeType == other.runtimeType &&
          reason == other.reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => reason;
}

/// A running child process spawned by [WarmBazelSpawner].
class WarmChild {
  /// Completes with the exit code when the process exits.
  final Future<int> exitCode;

  /// The collected stdout text.
  final Future<String> stdoutText;

  /// The collected stderr text.
  final Future<String> stderrText;

  /// Terminates the process.
  final void Function() kill;

  const new({
    required this.exitCode,
    required this.stdoutText,
    required this.stderrText,
    required this.kill,
  });
}

/// Spawns a Bazel child process in [workingDirectory] with [args].
typedef WarmBazelSpawner = Future<WarmChild> Function(
  List<String> args, {
  required String workingDirectory,
});

/// Configuration options for warming iOS e2e builds.
class WarmOptions {
  /// The spawner used to invoke Bazel.
  final WarmBazelSpawner bazel;

  /// Repository root directory.
  final String repoRoot;

  /// Environment variables map.
  final Map<String, String> environment;

  /// Maximum duration allowed for each target build.
  final Duration buildTimeout;

  /// Maximum duration allowed for `bazel shutdown`.
  final Duration shutdownTimeout;

  /// Callback for logging progress messages.
  final void Function(String line) log;

  const new({
    required this.bazel,
    required this.repoRoot,
    required this.environment,
    this.buildTimeout = const Duration(minutes: 60),
    this.shutdownTimeout = const Duration(seconds: 60),
    required this.log,
  });
}

/// Resolves the shared disk cache path from [environment].
///
/// Reads `USERPROFILE` when [isWindows] or `Platform.isWindows` is true and
/// `HOME` otherwise. Throws [WarmFailure] when unset or empty, joins
/// `.cache/rules_flutter_e2e_disk`, and normalizes backslashes to forward slashes.
String resolveWarmDiskCache(
  Map<String, String> environment, {
  bool? isWindows,
}) {
  final bool windows = isWindows ?? Platform.isWindows;
  final varName = windows ? 'USERPROFILE' : 'HOME';
  final String? home = environment[varName];
  if (home == null || home.trim().isEmpty) {
    throw WarmFailure('$varName environment variable is unset or empty');
  }
  final String joined = windows
      ? p.windows.join(home, '.cache', 'rules_flutter_e2e_disk')
      : p.posix.join(home, '.cache', 'rules_flutter_e2e_disk');
  return joined.replaceAll(r'\', '/');
}

/// Parses the optional `--timeout=<seconds>` argument from [args].
///
/// Defaults to 60 minutes when [args] is empty. Throws [WarmFailure] with a
/// one-line usage message on any other or malformed argument.
Duration parseWarmTimeout(List<String> args) {
  const usage =
      'Usage: dart run tools/dev_tool/tool/warm_ios_e2e.dart [--timeout=<seconds>]';
  if (args.isEmpty) {
    return const Duration(minutes: 60);
  }
  if (args.length != 1) {
    throw const WarmFailure(usage);
  }
  final String arg = args.single;
  if (!arg.startsWith('--timeout=')) {
    throw const WarmFailure(usage);
  }
  final String rawSeconds = arg.substring('--timeout='.length);
  if (!RegExp(r'^[1-9]\d*$').hasMatch(rawSeconds)) {
    throw const WarmFailure(usage);
  }
  final int seconds = int.parse(rawSeconds);
  return Duration(seconds: seconds);
}

/// Builds [targets] into the shared disk cache and shuts down Bazel per workspace.
///
/// Contiguous targets that share a workspace build one after another on the
/// same Bazel server, and that server is shut down once when the group ends —
/// whether every target built or one of them failed. A failure stops the run,
/// so the groups after it are not started.
Future<void> warmIosE2eBuilds(
  WarmOptions options, {
  List<WarmTarget> targets = defaultWarmTargets,
}) async {
  final String diskCache = resolveWarmDiskCache(options.environment);
  for (final List<WarmTarget> group in _groupByWorkspace(targets)) {
    final String workspaceDir = p.join(options.repoRoot, group.first.workspace);
    final moduleFile = File(p.join(workspaceDir, 'MODULE.bazel'));
    if (!moduleFile.existsSync()) {
      throw WarmFailure('missing ${moduleFile.path}');
    }
    try {
      for (final targetSpec in group) {
        await _warmTarget(options, targetSpec, workspaceDir, diskCache);
      }
    } finally {
      await _shutdownWorkspace(options, workspaceDir);
    }
  }
}

/// Splits [targets] into runs of contiguous entries that share a workspace,
/// keeping their order.
List<List<WarmTarget>> _groupByWorkspace(List<WarmTarget> targets) {
  final groups = <List<WarmTarget>>[];
  for (final target in targets) {
    if (groups.isNotEmpty && groups.last.first.workspace == target.workspace) {
      groups.last.add(target);
    } else {
      groups.add([target]);
    }
  }
  return groups;
}

/// Builds one [targetSpec] into the disk cache at [diskCache].
Future<void> _warmTarget(
  WarmOptions options,
  WarmTarget targetSpec,
  String workspaceDir,
  String diskCache,
) async {
  final List<String> argv = bazelBuildArgs(
    targetSpec.target,
    compilationMode: 'dbg',
    extraArgs: [
      ...IOSSimulatorDevice(udid: 'warm').buildArgs,
      '--disk_cache=$diskCache',
      '--experimental_disk_cache_gc_max_size=50G',
      '--experimental_disk_cache_gc_max_age=30d',
    ],
  );
  options.log('warming ${targetSpec.workspace} (${targetSpec.target}) ...');
  await _runBuildAttempt(
    options: options,
    argv: argv,
    workspaceDir: workspaceDir,
    targetSpec: targetSpec,
  );
}

String _formatElapsed(Duration elapsed) => elapsed.inSeconds >= 1
    ? '${elapsed.inSeconds}s'
    : '${elapsed.inMilliseconds}ms';

Future<void> _runBuildAttempt({
  required WarmOptions options,
  required List<String> argv,
  required String workspaceDir,
  required WarmTarget targetSpec,
}) async {
  final stopwatch = Stopwatch()..start();
  final WarmChild child;
  try {
    child = await options.bazel(argv, workingDirectory: workspaceDir);
  } on ProcessException catch (error) {
    throw WarmFailure(
      'build of ${targetSpec.workspace} (${targetSpec.target}) failed to spawn bazel: $error',
    );
  }

  final int exitCode;
  try {
    exitCode = await child.exitCode.timeout(options.buildTimeout);
  } on TimeoutException {
    child.kill();
    final Duration elapsed = stopwatch.elapsed >= options.buildTimeout
        ? stopwatch.elapsed
        : options.buildTimeout;
    final String elapsedText = _formatElapsed(elapsed);
    try {
      final String stdoutText = await child.stdoutText.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () => '',
      );
      final String stderrText = await child.stderrText.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () => '',
      );
      if (stdoutText.isNotEmpty) {
        options.log(stdoutText);
      }
      if (stderrText.isNotEmpty) {
        options.log(stderrText);
      }
    } on TimeoutException {
      // Best-effort drain of child output on timeout failure.
    }
    throw WarmFailure(
      'build of ${targetSpec.workspace} (${targetSpec.target}) timed out after $elapsedText',
    );
  }

  if (exitCode != 0) {
    final String stdoutText = await child.stdoutText;
    final String stderrText = await child.stderrText;
    if (stdoutText.isNotEmpty) {
      options.log(stdoutText);
    }
    if (stderrText.isNotEmpty) {
      options.log(stderrText);
    }
    throw WarmFailure(
      'build of ${targetSpec.workspace} (${targetSpec.target}) exited with code $exitCode',
    );
  }
}

Future<void> _shutdownWorkspace(
  WarmOptions options,
  String workspaceDir,
) async {
  try {
    final WarmChild shutdownChild = await options.bazel(
      const ['shutdown'],
      workingDirectory: workspaceDir,
    );
    try {
      await shutdownChild.exitCode.timeout(options.shutdownTimeout);
    } on TimeoutException {
      // Kill shutdown child when shutdownTimeout expires.
      shutdownChild.kill();
    }
  } on ProcessException catch (error) {
    // If Bazel cannot be spawned for shutdown, log without masking build failure.
    options.log('bazel shutdown failed in $workspaceDir: $error');
  }
}

/// The repository root for this script at [scriptPath]
/// (`<root>/tools/dev_tool/tool/warm_ios_e2e.dart`).
String warmRepoRootFor(String scriptPath) =>
    p.dirname(p.dirname(p.dirname(p.dirname(scriptPath))));

String _findRepoRoot() {
  final String repoRoot = warmRepoRootFor(Platform.script.toFilePath());
  final marker = File(p.join(repoRoot, 'tools', 'dev_tool', 'pubspec.yaml'));
  if (!marker.existsSync()) {
    throw WarmFailure('missing pubspec.yaml at ${marker.path}');
  }
  return repoRoot;
}

Future<WarmChild> _streamingProcessSpawner(
  List<String> args, {
  required String workingDirectory,
}) async {
  final Process process = await Process.start(
    'bazel',
    args,
    workingDirectory: workingDirectory,
  );

  final stdoutBuf = StringBuffer();
  final stderrBuf = StringBuffer();
  final stdoutCompleter = Completer<String>();
  final stderrCompleter = Completer<String>();

  process.stdout
      .transform(utf8.decoder)
      .listen(
        (data) {
          stdout.write(data);
          stdoutBuf.write(data);
        },
        onError: (Object _) {
          if (!stdoutCompleter.isCompleted) {
            stdoutCompleter.complete(stdoutBuf.toString());
          }
        },
        onDone: () {
          if (!stdoutCompleter.isCompleted) {
            stdoutCompleter.complete(stdoutBuf.toString());
          }
        },
      );

  process.stderr
      .transform(utf8.decoder)
      .listen(
        (data) {
          stderr.write(data);
          stderrBuf.write(data);
        },
        onError: (Object _) {
          if (!stderrCompleter.isCompleted) {
            stderrCompleter.complete(stderrBuf.toString());
          }
        },
        onDone: () {
          if (!stderrCompleter.isCompleted) {
            stderrCompleter.complete(stderrBuf.toString());
          }
        },
      );

  return WarmChild(
    exitCode: process.exitCode,
    stdoutText: stdoutCompleter.future,
    stderrText: stderrCompleter.future,
    kill: () {
      try {
        process.kill(ProcessSignal.sigkill);
      } on Exception {
        // Fall back to parameterless kill on platforms that do not support SIGKILL.
        process.kill();
      }
    },
  );
}

/// CLI entry point.
Future<void> main(List<String> args) async {
  final Duration timeout;
  try {
    timeout = parseWarmTimeout(args);
  } on WarmFailure catch (failure) {
    stderr.writeln(failure.reason);
    exit(2);
  }

  try {
    final String repoRoot = _findRepoRoot();
    final options = WarmOptions(
      bazel: _streamingProcessSpawner,
      repoRoot: repoRoot,
      environment: Platform.environment,
      buildTimeout: timeout,
      log: stdout.writeln,
    );
    await warmIosE2eBuilds(options);
    exit(0);
  } on WarmFailure catch (failure) {
    stderr.writeln(failure.reason);
    exit(1);
  }
}
