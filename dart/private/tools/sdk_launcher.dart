// The executable behind `dart_sdk_binary`: runs the toolchain's Dart SDK
// binary with the caller's arguments.
//
// Caller-home policy (see `private_home.dart`): the child keeps the caller's
// environment, so the pub cache, hosted credentials and proxy configuration
// keep working, and command-form invocations gain the global
// `--suppress-analytics` flag so the run writes no telemetry under HOME.
// File-form executions pass through unchanged: they never touch HOME, and
// the flag is rejected there. Arguments and the exit code pass through
// untouched.
//
// The rule writes `<name>.sdk_config.json` beside the launcher (see
// `dart_sdk_binary.bzl`), so the SDK is found however the launcher starts:
// under `bazel run` it additionally carries `DART_SDK_CONFIG` through
// `RunEnvironmentInfo`, while another target that runs it straight from its
// runfiles as a data dependency — with no extra environment, as
// `e2e/smoke:dart_version_test` does — finds the config beside the
// executable. The SDK path itself resolves through the runfiles directory
// and through the manifest (`--noenable_runfiles`, Windows).
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

import 'private_home.dart';

Future<void> main(List<String> args) async {
  // `bazel run` starts the launcher in the runfiles tree; relative user
  // arguments mean what they meant in the shell the command was typed in.
  final cwd = Platform.environment['BUILD_WORKING_DIRECTORY'];
  if (cwd != null && cwd.isNotEmpty) {
    Directory.current = cwd;
  }
  final dart = _resolveDart();
  final child = await Process.start(
    dart,
    suppressAnalyticsArgv(args),
    mode: ProcessStartMode.inheritStdio,
  );
  exit(await child.exitCode);
}

/// The `<name>.sdk_config.json` file beside the launcher.
///
/// On Windows the launcher is invoked as `<name>.exe` while the rule writes
/// the config as `<name>.sdk_config.json` (no `.exe`), so the suffix is
/// stripped before the config name is appended. An empty [executable] falls
/// back to the current executable. Whether the file exists is for the caller
/// to check.
File? adjacentSdkConfigFile([String? executable]) {
  final exe = (executable == null || executable.isEmpty)
      ? Platform.executable
      : executable;
  if (exe.isEmpty) return null;
  var base = exe;
  if (base.toLowerCase().endsWith('.exe')) {
    base = base.substring(0, base.length - 4);
  }
  return File('$base.sdk_config.json');
}

/// This process's runfiles, or null when it runs outside runfiles.
///
/// A launcher copied out of its runfiles has no runfiles environment; the
/// config lookup below reports the missing config instead of crashing.
Runfiles? _currentRunfiles() {
  try {
    return Runfiles.create();
  } on StateError {
    // No runfiles directory or manifest; reported by the caller.
    return null;
  }
}

/// The toolchain `dart` binary this launcher passes through to.
String _resolveDart() {
  final config = _readSdkConfig();
  final dart = config['dart'] as String;
  if (File(dart).existsSync()) {
    return dart;
  }
  final runfiles = _currentRunfiles();
  if (runfiles == null) {
    stderr.writeln(
      'dart_sdk: could not resolve the SDK binary "$dart" outside runfiles.',
    );
    exit(1);
  }
  try {
    return runfiles.rlocation(dart);
  } on StateError catch (e) {
    stderr.writeln('dart_sdk: ${e.message}');
    exit(1);
  }
}

/// The parsed `<name>.sdk_config.json` for this launcher.
///
/// Beside the executable first (data-dependency use), then `DART_SDK_CONFIG`
/// from `RunEnvironmentInfo` (`bazel run` use), as a path and through
/// runfiles. Exits naming the lookup when nothing answers.
Map<String, dynamic> _readSdkConfig() {
  final adjacent = adjacentSdkConfigFile();
  if (adjacent != null && adjacent.existsSync()) {
    return _parseSdkConfig(adjacent);
  }
  final key = Platform.environment['DART_SDK_CONFIG'];
  if (key != null && key.isNotEmpty) {
    if (File(key).existsSync()) {
      return _parseSdkConfig(File(key));
    }
    final runfiles = _currentRunfiles();
    if (runfiles != null) {
      try {
        final file = File(runfiles.rlocation(key));
        if (file.existsSync()) {
          return _parseSdkConfig(file);
        }
      } on StateError catch (e) {
        stderr.writeln('dart_sdk: ${e.message}');
      }
      stderr.writeln('dart_sdk: no SDK config at "$key" in runfiles.');
      exit(1);
    }
  }
  stderr.writeln(
    'dart_sdk: could not locate dart.sdk_config.json beside '
    '${Platform.executable}. Run this with `bazel run` on its target or from '
    'its runfiles.',
  );
  exit(1);
}

/// Parses [file] as the SDK config JSON map.
Map<String, dynamic> _parseSdkConfig(File file) =>
    jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
