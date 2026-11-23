/// Verifies the extensions `flutter_ios_app(extensions = [...])` embeds: each
/// `.appex` sits in the app's `PlugIns/`, declares the extension point it is
/// for, and the app and every extension carry the same App Group. The widget
/// extension also carries the App Intents metadata its control runs.
///
/// A simulator build is ad-hoc signed, so the entitlements are not in the
/// code signature. rules_apple links them into each binary's
/// `__TEXT,__entitlements` section instead, which is where the simulator reads
/// them, and where this test reads them too.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

const _appGroup = 'group.com.rulesflutter.ios.example';

/// Each extension bundle and the extension point its Info.plist must name.
const _extensions = <String, String>{
  'share.appex': 'com.apple.share-services',
  'widgets.appex': 'com.apple.widgetkit-extension',
};

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }
  final ipaPath = '$testSrcDir/$testWorkspace/app_extensions.ipa';
  if (!File(ipaPath).existsSync()) {
    stderr.writeln('IPA not found at $ipaPath');
    exit(1);
  }

  final tmpDir = Directory.systemTemp.createTempSync('ios_extensions_test');
  try {
    final unzip = Process.runSync('unzip', ['-q', ipaPath, '-d', tmpDir.path]);
    if (unzip.exitCode != 0) {
      stderr.writeln('Failed to extract ipa: ${unzip.stderr}');
      exit(1);
    }
    final app = '${tmpDir.path}/Payload/app_extensions.app';

    final embedded = Directory('$app/PlugIns')
        .listSync()
        .map((e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty))
        .toSet();
    if (!embedded.containsAll(_extensions.keys) ||
        embedded.length != _extensions.length) {
      stderr.writeln(
        'FAIL: PlugIns/ holds $embedded, expected '
        '${_extensions.keys}',
      );
      exit(1);
    }

    var failed = false;
    for (final MapEntry(key: appex, value: point) in _extensions.entries) {
      final bundle = '$app/PlugIns/$appex';
      final info = _plist('$bundle/Info.plist', tmpDir);
      final actual =
          (info['NSExtension'] as Map?)?['NSExtensionPointIdentifier'];
      if (actual == point) {
        print('OK: $appex is a $point extension');
      } else {
        stderr.writeln(
          'FAIL: $appex names extension point $actual, '
          'expected $point',
        );
        failed = true;
      }
      failed |= !_hasGroup('$bundle/${info['CFBundleExecutable']}', tmpDir);
    }
    final actions = File(
      '$app/PlugIns/widgets.appex/Metadata.appintents/extract.actionsdata',
    );
    if (actions.existsSync() &&
        actions.readAsStringSync().contains('PingIntent')) {
      print('OK: widgets.appex carries App Intents metadata naming PingIntent');
    } else {
      stderr.writeln(
        'FAIL: widgets.appex has no App Intents metadata naming PingIntent',
      );
      failed = true;
    }
    final appInfo = _plist('$app/Info.plist', tmpDir);
    failed |= !_hasGroup('$app/${appInfo['CFBundleExecutable']}', tmpDir);

    if (failed) exit(1);
    print('\nAll iOS extension checks passed.');
  } finally {
    tmpDir.deleteSync(recursive: true);
  }
}

/// Whether [binary]'s embedded entitlements name the App Group.
bool _hasGroup(String binary, Directory tmpDir) {
  final out = '${tmpDir.path}/entitlements.plist';
  final segedit = Process.runSync('segedit', [
    binary,
    '-extract',
    '__TEXT',
    '__entitlements',
    out,
  ]);
  if (segedit.exitCode != 0) {
    stderr.writeln(
      'FAIL: no entitlements section in $binary: '
      '${segedit.stderr}',
    );
    return false;
  }
  final groups = _plist(out, tmpDir)['com.apple.security.application-groups'];
  final name = binary.split('/').last;
  if (groups is List && groups.contains(_appGroup)) {
    print('OK: $name is in $_appGroup');
    return true;
  }
  stderr.writeln('FAIL: $name has App Groups $groups, expected $_appGroup');
  return false;
}

Map<String, Object?> _plist(String path, Directory tmpDir) {
  final result = Process.runSync('plutil', [
    '-convert',
    'json',
    '-o',
    '-',
    path,
  ], stdoutEncoding: utf8);
  if (result.exitCode != 0) {
    stderr.writeln('plutil failed on $path: ${result.stderr}');
    exit(1);
  }
  return jsonDecode(result.stdout as String) as Map<String, Object?>;
}
