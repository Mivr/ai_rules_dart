/// Hermetic regression test for `check_android_fail_closed.sh`.
///
/// The script is staged into a scratch directory beside a copy of the
/// fixture's `lazy_plugin/android/build.gradle` and run with a stub `bazel`
/// first on `PATH`. Each scenario scripts what the stub prints and returns,
/// then pins the script's exit code, its output, and the `bazel` commands it
/// issued. The failure the script must catch: an aggregator fetch that fails
/// for an unrelated reason being papered over by a direct fetch of the
/// plugin's Android repository.
library;

// The test's diagnostics are its product, reported to the bazel test log.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:runfiles/runfiles.dart';

const _aggregator = '@deps//android:all_android_plugin_libs';
const _direct = '@deps-android-lazy_plugin//android:lib';

/// The five diagnostics a genuine fail-closed aggregator fetch prints.
const _refusalLines = [
  'ERROR: deps__lazy_plugin//android:lib',
  'lazy_plugin',
  'android/build.gradle',
  'declares Android dependencies rules_flutter cannot translate to Bazel '
      'labels',
  'com.example:lazy-unmapped',
];

/// What the stub `bazel` does for one scenario.
class Scenario {
  /// Creates a scenario; [fetchOut] is the aggregator fetch's output.
  const Scenario({
    required this.name,
    required this.buildExit,
    required this.fetchExit,
    required this.fetchOut,
    required this.expectExit0,
    required this.expectText,
    this.forbidDirectFetch = true,
    this.forbidFetch = false,
  });

  /// Human-readable scenario name.
  final String name;

  /// Exit code of `bazel build //:app`.
  final int buildExit;

  /// Exit code of any `bazel fetch`.
  final int fetchExit;

  /// Text any `bazel fetch` of the aggregator prints.
  final String fetchOut;

  /// Whether the script must exit 0.
  final bool expectExit0;

  /// Text the script must print.
  final String expectText;

  /// Whether a fetch of the direct Android repository is a failure.
  final bool forbidDirectFetch;

  /// Whether any `bazel fetch` at all is a failure.
  final bool forbidFetch;
}

/// A stub `bazel` that logs argv and replays the scenario from env vars.
const _stub = r'''#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$1" in
  build) exit "$STUB_BUILD_EXIT" ;;
  fetch)
    if [ "$2" = "@deps-android-lazy_plugin//android:lib" ]; then
      printf '%s\n' "$STUB_DIRECT_OUT"
      exit 1
    fi
    printf '%s\n' "$STUB_FETCH_OUT"
    exit "$STUB_FETCH_EXIT" ;;
esac
exit 0
''';

/// Runs the staged script for [s]; returns null on success, else a failure.
String? _run(Scenario s, String script, String gradle, String scratch) {
  final dir = Directory('$scratch/${s.name.replaceAll(' ', '_')}')
    ..createSync(recursive: true);
  File('${dir.path}/check_android_fail_closed.sh')
      .writeAsStringSync(File(script).readAsStringSync());
  Directory('${dir.path}/lazy_plugin/android').createSync(recursive: true);
  File('${dir.path}/lazy_plugin/android/build.gradle')
      .writeAsStringSync(File(gradle).readAsStringSync());
  final bin = Directory('${dir.path}/bin')..createSync();
  File('${bin.path}/bazel').writeAsStringSync(_stub);
  Process.runSync('chmod', ['+x', '${bin.path}/bazel']);
  final log = File('${dir.path}/stub.log')..writeAsStringSync('');
  final result = Process.runSync(
    'bash',
    ['check_android_fail_closed.sh'],
    workingDirectory: dir.path,
    environment: {
      'PATH': '${bin.path}:${Platform.environment['PATH']}',
      'STUB_LOG': log.path,
      'STUB_BUILD_EXIT': '${s.buildExit}',
      'STUB_FETCH_EXIT': '${s.fetchExit}',
      'STUB_FETCH_OUT': s.fetchOut,
      'STUB_DIRECT_OUT': _refusalLines.join('\n'),
    },
  );
  return _verify(s, result, log.readAsLinesSync());
}

/// Compares [result] and the stub's [calls] with what [s] expects.
String? _verify(Scenario s, ProcessResult result, List<String> calls) {
  final text = '${result.stdout}${result.stderr}';
  if ((result.exitCode == 0) != s.expectExit0) {
    return 'exit code ${result.exitCode}, expected '
        '${s.expectExit0 ? 'zero' : 'non-zero'}:\n$text';
  }
  if (!text.contains(s.expectText)) {
    return 'output lacks "${s.expectText}":\n$text';
  }
  if (s.forbidDirectFetch && calls.any((c) => c.contains(_direct))) {
    return 'fetched the direct Android repository: $calls';
  }
  if (s.forbidFetch && calls.any((c) => c.startsWith('fetch'))) {
    return 'ran bazel fetch after a failed build: $calls';
  }
  if (s.expectExit0 && !calls.contains('fetch $_aggregator --keep_going')) {
    return 'aggregator fetch lacked --keep_going: $calls';
  }
  return null;
}

/// Refusal output with [omit] left out.
String _refusalWithout(String omit) =>
    _refusalLines.where((l) => !l.contains(omit)).join('\n');

void main() {
  final runfiles = Runfiles.create();
  final script = runfiles.rlocation(Platform.environment['CHECK_SCRIPT']!);
  final gradle = runfiles.rlocation(Platform.environment['GRADLE_FILE']!);
  final scratch = Directory(
    '${Platform.environment['TEST_TMPDIR'] ?? Directory.systemTemp.path}'
    '/check_android',
  )..createSync(recursive: true);

  final scenarios = [
    Scenario(
      name: 'unrelated aggregator failure',
      buildExit: 0,
      fetchExit: 1,
      fetchOut: "ERROR: no such package '@@deps-android-wrong//android'",
      expectExit0: false,
      expectText: 'Android fetch failed without the expected diagnostic',
    ),
    Scenario(
      name: 'aggregator succeeds',
      buildExit: 0,
      fetchExit: 0,
      fetchOut: _refusalLines.join('\n'),
      expectExit0: false,
      expectText: 'expected the Android plugin fetch to fail',
    ),
    Scenario(
      name: 'missing spoke alias',
      buildExit: 0,
      fetchExit: 1,
      fetchOut: _refusalWithout('deps__lazy_plugin'),
      expectExit0: false,
      expectText: 'deps__lazy_plugin//android:lib',
    ),
    const Scenario(
      name: 'positive build fails',
      buildExit: 1,
      fetchExit: 1,
      fetchOut: '',
      expectExit0: false,
      expectText: '',
      forbidFetch: true,
    ),
    Scenario(
      name: 'valid fail closed',
      buildExit: 0,
      fetchExit: 1,
      fetchOut: _refusalLines.join('\n'),
      expectExit0: true,
      expectText: 'ok:',
    ),
  ];

  var failed = false;
  for (final s in scenarios) {
    final problem = _run(s, script, gradle, scratch.path);
    if (problem == null) {
      print('OK: ${s.name}');
    } else {
      stderr.writeln('FAIL: ${s.name}: $problem');
      failed = true;
    }
  }
  if (failed) exit(1);
}
