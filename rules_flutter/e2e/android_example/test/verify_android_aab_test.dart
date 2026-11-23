/// Inspects the Android App Bundle `flutter_android_aab` produces.
///
/// Runs the pinned bundletool (`validate`, `dump manifest`) on `app_aab.aab`
/// and asserts that `validate` exits 0 and that the base module's manifest
/// names the expected package. Linux only: the bundletool wrapper is a shell
/// script around the JDK.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log.
// ignore_for_file: avoid_print

import 'dart:io';

String _runfile(String envVar) {
  final srcDir = Platform.environment['TEST_SRCDIR']!;
  final workspace = Platform.environment['TEST_WORKSPACE']!;
  return '$srcDir/$workspace/${Platform.environment[envVar]!}';
}

Future<ProcessResult> _bundletool(String bundletool, List<String> args) {
  return Process.run(bundletool, args);
}

Future<void> main() async {
  final aab = _runfile('AAB');
  final bundletool = _runfile('BUNDLETOOL');
  final expectedPackage = Platform.environment['EXPECTED_PACKAGE']!;

  if (!aab.endsWith('.aab') || !File(aab).existsSync()) {
    stderr.writeln('App bundle not found at $aab');
    exit(1);
  }

  final validate = await _bundletool(bundletool, ['validate', '--bundle=$aab']);
  print(validate.stdout);
  if (validate.exitCode != 0) {
    stderr.writeln(
      'bundletool validate exited ${validate.exitCode}: '
      '${validate.stderr}',
    );
    exit(1);
  }

  final manifest = await _bundletool(bundletool, [
    'dump',
    'manifest',
    '--bundle=$aab',
    '--module=base',
  ]);
  if (manifest.exitCode != 0) {
    stderr.writeln(
      'bundletool dump manifest exited ${manifest.exitCode}: '
      '${manifest.stderr}',
    );
    exit(1);
  }
  final text = manifest.stdout as String;
  if (!text.contains('package="$expectedPackage"')) {
    stderr.writeln('Manifest does not name package $expectedPackage:\n$text');
    exit(1);
  }
  if (!text.contains('versionCode=')) {
    stderr.writeln('Manifest does not carry a versionCode:\n$text');
    exit(1);
  }
  print('OK: $aab validates and names package $expectedPackage');
}
