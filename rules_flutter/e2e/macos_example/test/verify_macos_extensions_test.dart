/// Verifies the extensions `flutter_macos_app(extensions = [...])` embeds:
/// each `.appex` sits in `Contents/PlugIns/`, declares the extension point it
/// is for, is sandboxed, and shares the app's App Group; the widget extension
/// carries the App Intents metadata its control runs; and the signature over
/// the whole bundle is valid.
///
/// macOS loads a widget or share extension only if it is sandboxed, and an
/// extension the app's signature does not seal is one codesign rejects and
/// the system will not load.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

const _appGroup = 'group.com.example.flutterapp';

/// Each extension bundle and the extension point its Info.plist must name.
const _extensions = <String, String>{
  'share.appex': 'com.apple.share-services',
  'widgets.appex': 'com.apple.widgetkit-extension',
};

var _failed = false;

void _fail(String message) {
  stderr.writeln('FAIL: $message');
  _failed = true;
}

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }
  final zipPath = '$testSrcDir/$testWorkspace/app_extensions.zip';
  if (!File(zipPath).existsSync()) {
    stderr.writeln('Bundle zip not found at $zipPath');
    exit(1);
  }

  final tmpDir = Directory.systemTemp.createTempSync('macos_extensions_');
  try {
    // ditto, not unzip: a signed bundle's symlinks and extended attributes
    // have to survive for codesign to verify it.
    final unzip = Process.runSync('ditto', ['-x', '-k', zipPath, tmpDir.path]);
    if (unzip.exitCode != 0) {
      stderr.writeln('Failed to extract zip: ${unzip.stderr}');
      exit(1);
    }
    final app = '${tmpDir.path}/Extensions App.app';

    final verify = Process.runSync('codesign', [
      '--verify',
      '--deep',
      '--strict',
      app,
    ]);
    if (verify.exitCode == 0) {
      print('OK: codesign --verify --deep --strict');
    } else {
      _fail('codesign --verify --deep --strict: ${verify.stderr}');
    }

    final embedded = Directory('$app/Contents/PlugIns')
        .listSync()
        .map((e) => e.uri.pathSegments.lastWhere((s) => s.isNotEmpty))
        .toSet();
    if (!embedded.containsAll(_extensions.keys) ||
        embedded.length != _extensions.length) {
      _fail('Contents/PlugIns/ holds $embedded, expected ${_extensions.keys}');
    }

    for (final MapEntry(key: appex, value: point) in _extensions.entries) {
      final bundle = '$app/Contents/PlugIns/$appex';
      final info = _plist('$bundle/Contents/Info.plist');
      final actual =
          (info['NSExtension'] as Map?)?['NSExtensionPointIdentifier'];
      if (actual == point) {
        print('OK: $appex is a $point extension');
      } else {
        _fail('$appex names extension point $actual, expected $point');
      }
      final entitlements = _entitlements(bundle);
      if (entitlements['com.apple.security.app-sandbox'] == true) {
        print('OK: $appex is sandboxed');
      } else {
        _fail('$appex is not sandboxed, so macOS will not load it');
      }
      _checkGroup(appex, entitlements);
    }
    _checkGroup('Extensions App.app', _entitlements(app));

    final actions = File(
      '$app/Contents/PlugIns/widgets.appex/Contents/Resources/'
      'Metadata.appintents/extract.actionsdata',
    );
    if (actions.existsSync() &&
        actions.readAsStringSync().contains('PingIntent')) {
      print('OK: widgets.appex carries App Intents metadata naming PingIntent');
    } else {
      _fail('widgets.appex has no App Intents metadata naming PingIntent');
    }

    if (_failed) exit(1);
    print('\nAll macOS extension checks passed.');
  } finally {
    tmpDir.deleteSync(recursive: true);
  }
}

void _checkGroup(String name, Map<String, Object?> entitlements) {
  final groups = entitlements['com.apple.security.application-groups'];
  if (groups is List && groups.contains(_appGroup)) {
    print('OK: $name is in $_appGroup');
  } else {
    _fail('$name has App Groups $groups, expected $_appGroup');
  }
}

/// The entitlements codesign embedded in [bundle]'s signature.
Map<String, Object?> _entitlements(String bundle) {
  final out = File('${Directory.systemTemp.path}/entitlements.plist');
  final result = Process.runSync('codesign', [
    '-d',
    '--entitlements',
    ':${out.path}',
    bundle,
  ]);
  if (result.exitCode != 0) {
    stderr.writeln('codesign -d failed on $bundle: ${result.stderr}');
    exit(1);
  }
  try {
    return _plist(out.path);
  } finally {
    out.deleteSync();
  }
}

Map<String, Object?> _plist(String path) {
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
