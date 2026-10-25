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

/// The toolchain `dart` binary, from the config this rule's runfiles carry.
String _resolveDart() {
  final key = Platform.environment['DART_SDK_CONFIG'];
  if (key == null || key.isEmpty) {
    stderr.writeln(
      'dart_sdk: DART_SDK_CONFIG is not set. Run this with `bazel run` on '
      'the target.',
    );
    exit(1);
  }
  final configFile = File(key).existsSync()
      ? File(key)
      : File(Runfiles.create().rlocation(key));
  final json =
      jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
  final dart = json['dart'] as String;
  return File(dart).existsSync() ? dart : Runfiles.create().rlocation(dart);
}
