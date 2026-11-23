/// Runtime verification of Flutter profile mode: launches the profile-built
/// macOS .app and checks what a profile engine serves.
///
/// Requires a GUI session, so it is `manual`. Run explicitly:
/// `bazel test :verify_macos_profile_app_test --test_tag_filters=`
///
/// The app comes from `:app_profile`, which builds `:app` with
/// `-c opt --@rules_flutter//flutter:profile` whatever the command line says.
///
/// Like `verify_macos_app_test`, everything is addressed by the PID this test
/// launched, by running `Contents/MacOS/<exe>` directly.
///
/// Pass criteria:
/// - The app prints its Dart VM service URI (a release build prints none).
/// - The isolate's `extensionRPCs` include `ext.flutter.profileWidgetBuilds`
///   and exclude the debug-only `ext.flutter.reassemble`.
/// - Once a frame has rendered, `getVMTimeline` returns trace events.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const _overall = Duration(seconds: 60);
const _profileExtension = 'ext.flutter.profileWidgetBuilds';
const _debugOnlyExtension = 'ext.flutter.reassemble';

final _serviceLine = RegExp(
  r'The Dart VM service is listening on (http://\S+)',
);

Future<void> main() async {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  // Runfiles paths do not carry the configuration, so the transitioned zip is
  // at the same place `app.zip` is in an untransitioned build.
  final zipPath = '$testSrcDir/$testWorkspace/app.zip';
  if (!File(zipPath).existsSync()) {
    stderr.writeln('Bundle zip not found at $zipPath');
    exit(1);
  }

  final tmpDir = Directory.systemTemp.createTempSync('macos_profile_app_test');
  Process? process;
  final client = HttpClient();
  try {
    final unzip = Process.runSync('unzip', ['-q', zipPath, '-d', tmpDir.path]);
    if (unzip.exitCode != 0) {
      stderr.writeln('Failed to extract zip: ${unzip.stderr}');
      exit(1);
    }

    const bundleName = 'Flutter App';
    final executable =
        '${tmpDir.path}/$bundleName.app/Contents/MacOS/$bundleName';
    print('Launching $executable ...');
    final launched = process = await Process.start(executable, const []);
    print('PID: ${launched.pid}');

    // Drain both streams for the life of the process — an undrained pipe can
    // block the app on a write — and keep them for the failure report.
    final output = StringBuffer();
    final serviceUri = Completer<Uri>();
    for (final stream in [launched.stdout, launched.stderr]) {
      stream.transform(utf8.decoder).transform(const LineSplitter()).listen((
        line,
      ) {
        output.writeln(line);
        final match = _serviceLine.firstMatch(line);
        if (match != null && !serviceUri.isCompleted) {
          serviceUri.complete(Uri.parse(match.group(1)!));
        }
      });
    }

    int? exitCode;
    unawaited(launched.exitCode.then((code) => exitCode = code));
    final deadline = DateTime.now().add(_overall);

    Never fail(String message) {
      stderr
        ..writeln('FAIL: $message')
        ..writeln('--- app output ---')
        ..write(output);
      exit(1);
    }

    // A crash ends the wait at once rather than after the timeout.
    final uri = await Future.any<Uri?>([
      serviceUri.future,
      launched.exitCode.then((_) => null),
    ]).timeout(_overall, onTimeout: () => null);
    if (uri == null) {
      fail(
        'the app printed no "The Dart VM service is listening on" line '
        '(exit code: ${exitCode ?? 'still running'}); a profile build must '
        'serve a VM service',
      );
    }
    print('VM service: $uri');

    Future<Map<String, dynamic>> call(
      String method, [
      Map<String, String> params = const {},
    ]) async {
      final result = await _call(client, uri, method, params, deadline);
      if (result == null) fail('$method got no answer from the VM service');
      return result;
    }

    final vm = await call('getVM');
    final isolates = (vm['isolates'] as List?) ?? const [];
    if (isolates.isEmpty) fail('getVM listed no isolates');
    final isolateId = (isolates.first as Map)['id'] as String;

    // The service is up before the framework registers its extensions, so ask
    // until the profile one appears, the app dies, or the deadline passes.
    var extensions = <String>[];
    while (!extensions.contains(_profileExtension) &&
        !extensions.contains(_debugOnlyExtension)) {
      if (exitCode != null) {
        fail(
          'the app exited with code $exitCode before registering extensions',
        );
      }
      if (DateTime.now().isAfter(deadline)) {
        fail(
          'extensionRPCs lacks $_profileExtension after '
          '${_overall.inSeconds}s: the app is not a profile build. '
          'Found: $extensions',
        );
      }
      final isolate = await call('getIsolate', {'isolateId': isolateId});
      extensions = ((isolate['extensionRPCs'] as List?) ?? const [])
          .cast<String>();
    }
    print('Isolate $isolateId has ${extensions.length} extension RPCs.');
    print('Has $_profileExtension: ${extensions.contains(_profileExtension)}');
    print(
      'Has $_debugOnlyExtension: ${extensions.contains(_debugOnlyExtension)}',
    );
    if (extensions.contains(_debugOnlyExtension)) {
      fail(
        'extensionRPCs contains the debug-only $_debugOnlyExtension: the '
        'app is a debug build',
      );
    }

    // The timeline fills once the engine draws, so ask until it has an event,
    // the app dies, or the overall deadline passes.
    var events = 0;
    while (events == 0) {
      if (exitCode != null) {
        fail(
          'the app exited with code $exitCode before the timeline had any '
          'event',
        );
      }
      final timeline = await call('getVMTimeline');
      events = ((timeline['traceEvents'] as List?) ?? const []).length;
    }
    print('Timeline traceEvents: $events');
    print('PASS');
  } finally {
    client.close(force: true);
    if (process != null) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
    tmpDir.deleteSync(recursive: true);
  }
}

/// Calls the VM service's HTTP endpoint [method] and returns its `result`, or
/// null if [deadline] passes first.
///
/// The service can trail the printed URI slightly, and the timeline can be
/// empty at first, so a refused connection or an error reply is asked again
/// until the deadline. Each retry waits on a socket round trip, not a sleep.
Future<Map<String, dynamic>?> _call(
  HttpClient client,
  Uri base,
  String method,
  Map<String, String> params,
  DateTime deadline,
) async {
  final url = base.replace(
    path: '${base.path}$method',
    queryParameters: params.isEmpty ? null : params,
  );
  while (DateTime.now().isBefore(deadline)) {
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      final json =
          jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>;
      final result = json['result'];
      if (result is Map<String, dynamic>) return result;
    } on SocketException {
      // Not accepting connections yet; ask again.
    }
  }
  return null;
}
