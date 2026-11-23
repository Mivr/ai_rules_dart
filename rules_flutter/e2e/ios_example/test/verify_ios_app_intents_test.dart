/// Verifies that `flutter_ios_app(runner_deps = [...], app_intents = [...])`
/// ships App Intents: the bundle carries the extracted metadata at its root and
/// it names the intent, and the runner binary links the library that declares
/// it.
library;

import 'dart:io';

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }
  final ipaPath = '$testSrcDir/$testWorkspace/app_intents.ipa';
  if (!File(ipaPath).existsSync()) {
    stderr.writeln('IPA not found at $ipaPath');
    exit(1);
  }

  final tmpDir = Directory.systemTemp.createTempSync('ios_intents_test');
  try {
    final unzip = Process.runSync('unzip', ['-q', ipaPath, '-d', tmpDir.path]);
    if (unzip.exitCode != 0) {
      stderr.writeln('Failed to extract ipa: ${unzip.stderr}');
      exit(1);
    }

    final apps = Directory('${tmpDir.path}/Payload')
        .listSync()
        .whereType<Directory>()
        .where((d) => d.path.endsWith('.app'))
        .toList();
    if (apps.length != 1) {
      stderr.writeln('FAIL: expected one .app in Payload, found $apps');
      exit(1);
    }
    final bundle = apps.single.path;

    final actions = File('$bundle/Metadata.appintents/extract.actionsdata');
    if (!actions.existsSync()) {
      stderr.writeln('FAIL: no extract.actionsdata in the bundle: $actions');
      exit(1);
    }
    if (!actions.readAsStringSync().contains('PingIntent')) {
      stderr.writeln('FAIL: extract.actionsdata does not name PingIntent');
      exit(1);
    }

    // The metadata alone is not the app: the runner has to carry the code. A
    // debug build may put it in a sibling `.debug.dylib`, so look in every
    // Mach-O file at the bundle root.
    final linked = Directory(bundle).listSync().whereType<File>().any((f) {
      final nm = Process.runSync('nm', [f.path]);
      return nm.exitCode == 0 && (nm.stdout as String).contains('PingIntent');
    });
    if (!linked) {
      stderr.writeln('FAIL: no binary in the bundle links PingIntent');
      exit(1);
    }
  } finally {
    tmpDir.deleteSync(recursive: true);
  }
}
