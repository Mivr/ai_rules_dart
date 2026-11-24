/// Verifies that `flutter_macos_app(runner_deps = [...], app_intents = [...])`
/// ships App Intents: the bundle carries the extracted metadata and it names
/// the intent, and the runner binary links the library that declares it.
library;

import 'dart:io';

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }
  final zipPath = '$testSrcDir/$testWorkspace/app_intents.zip';
  if (!File(zipPath).existsSync()) {
    stderr.writeln('Bundle zip not found at $zipPath');
    exit(1);
  }

  final tmpDir = Directory.systemTemp.createTempSync('macos_intents_test');
  try {
    final unzip = Process.runSync('unzip', ['-q', zipPath, '-d', tmpDir.path]);
    if (unzip.exitCode != 0) {
      stderr.writeln('Failed to extract zip: ${unzip.stderr}');
      exit(1);
    }

    final bundle = '${tmpDir.path}/Intents App.app';
    final actions = File(
      '$bundle/Contents/Resources/Metadata.appintents/extract.actionsdata',
    );
    if (!actions.existsSync()) {
      stderr.writeln('FAIL: no extract.actionsdata in the bundle: $actions');
      exit(1);
    }
    if (!actions.readAsStringSync().contains('PingIntent')) {
      stderr.writeln('FAIL: extract.actionsdata does not name PingIntent');
      exit(1);
    }

    // The metadata alone is not the app: the runner has to carry the code.
    final nm = Process.runSync('nm', ['$bundle/Contents/MacOS/Intents App']);
    if (nm.exitCode != 0 || !(nm.stdout as String).contains('PingIntent')) {
      stderr.writeln('FAIL: the runner binary does not link PingIntent');
      exit(1);
    }
  } finally {
    tmpDir.deleteSync(recursive: true);
  }
}
