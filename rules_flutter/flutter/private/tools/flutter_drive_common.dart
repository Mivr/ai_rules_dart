/// Pieces `flutter_drive_test`'s Android and iOS runners share: the VM service
/// announcement parser, the named-step timeout, the driver command read from
/// the test environment and the driver process itself.
library;

import 'dart:async';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

import 'run_home.dart';

/// Environment variable naming the VM service URI the driver connects to.
const String vmServiceEnv = 'VM_SERVICE_URL';

/// Host command and arguments used to execute the user's driver.
typedef DriverCommand = ({String executable, List<String> args});

final RegExp _vmServiceLine = RegExp(
  r'(?:Dart VM service|Observatory) is listening on http://127\.0\.0\.1:(\d+)(/[^\s]*)?',
);

/// Extracts `(port, path)` from a log line announcing the VM service, or
/// `null` when [line] is not that announcement.
({int port, String path})? parseVmServiceLine(String line) {
  final RegExpMatch? m = _vmServiceLine.firstMatch(line);
  if (m == null) return null;
  return (port: int.parse(m.group(1)!), path: m.group(2) ?? '/');
}

/// Raised when a named launch step exceeds its time budget.
class StepTimeout implements Exception {
  /// Creates a timeout error for [step] after [limit].
  const new(this.step, this.limit, {this.detail = ''});

  /// The step that ran out of time.
  final String step;

  /// The budget the step had.
  final Duration limit;

  /// Extra diagnostics appended to the message, or empty.
  final String detail;

  @override
  String toString() =>
      'flutter_drive_test: timed out after ${limit.inSeconds}s during step '
      '"$step"${detail.isEmpty ? '' : '\n$detail'}';
}

/// Runs [body] within [limit]; a timeout throws a [StepTimeout] naming [step].
Future<T> runStep<T>(String step, Duration limit, Future<T> Function() body) =>
    body().timeout(limit, onTimeout: () => throw StepTimeout(step, limit));

/// The value of [key] in [env], or a [FormatException] naming it when unset.
String requiredEnv(Map<String, String> env, String key) {
  final String? v = env[key];
  if (v == null || v.isEmpty) {
    throw FormatException('$key must be set for flutter_drive_test.');
  }
  return v;
}

/// Reads the driver command from the test [env]: a `.dill` run by the pinned
/// Dart VM when `FLUTTER_DRIVE_DART` is set, else a prebuilt executable.
DriverCommand driverCommandFromEnv(Map<String, String> env, Runfiles r) {
  final String driverPath = r.rlocation(
    requiredEnv(env, 'FLUTTER_DRIVE_DRIVER'),
  );
  final String? dartKey = env['FLUTTER_DRIVE_DART'];
  if (dartKey != null && dartKey.isNotEmpty) {
    return (
      executable: r.rlocation(dartKey),
      args: <String>['--enable-asserts', driverPath],
    );
  }
  return (executable: driverPath, args: const <String>[]);
}

/// Runs the driver on the host in a private home under [scratch], with [extra]
/// layered on the sandboxed environment; returns its exit code.
Future<int> runDriverProcess(
  DriverCommand command,
  String scratch,
  Map<String, String> extra,
) async {
  final driverHome = Directory('$scratch/driver_home')
    ..createSync(recursive: true);
  final Process p = await Process.start(
    command.executable,
    command.args,
    environment: <String, String>{
      ...privateHomeEnv(driverHome.path),
      'TMPDIR': scratch,
      'DART_SUPPRESS_ANALYTICS': 'true',
      ...extra,
    },
    mode: ProcessStartMode.inheritStdio,
  );
  return await p.exitCode;
}
