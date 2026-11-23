/// Verifies the team-signed `:app_extensions_team`: the app and every
/// extension are signed by one team, none ad hoc, every App Group is that
/// team's prefixed form, and the signature over the whole bundle is valid.
///
/// rules_apple signs each extension in its own target, so the app's profile
/// does not reach its extensions. An extension without a profile of its own
/// is signed ad hoc inside an otherwise team-signed app, has no team, and
/// macOS refuses it the team's App Group.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

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
  final zipPath = '$testSrcDir/$testWorkspace/app_extensions_team.zip';
  if (!File(zipPath).existsSync()) {
    stderr.writeln('Bundle zip not found at $zipPath');
    exit(1);
  }

  final tmpDir = Directory.systemTemp.createTempSync('macos_team_signing_');
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

    final bundles = [
      app,
      ...Directory('$app/Contents/PlugIns')
          .listSync()
          .whereType<Directory>()
          .map((d) => d.path)
          .where((p) => p.endsWith('.appex')),
    ];
    if (bundles.length != 3) {
      _fail('expected the app and two extensions, found $bundles');
    }

    final teams = <String>{};
    for (final bundle in bundles) {
      final name = bundle.split('/').last;
      final team = _teamIdentifier(bundle);
      if (team == null) {
        _fail('$name is signed ad hoc, with no TeamIdentifier');
        continue;
      }
      teams.add(team);
      print('OK: $name is signed by team $team');

      final groups = _entitlements(
        bundle,
        tmpDir,
      )['com.apple.security.application-groups'];
      if (groups is List &&
          groups.isNotEmpty &&
          groups.every((g) => g is String && g.startsWith('$team.'))) {
        print('OK: $name is in $groups');
      } else {
        _fail('$name has App Groups $groups, expected ones prefixed $team.');
      }
    }
    if (teams.length > 1) {
      _fail('the bundles are signed by different teams: $teams');
    }

    if (_failed) exit(1);
    print('\nAll macOS team signing checks passed.');
  } finally {
    tmpDir.deleteSync(recursive: true);
  }
}

/// [bundle]'s TeamIdentifier, or null if it is signed ad hoc.
String? _teamIdentifier(String bundle) {
  // codesign -d writes its report to stderr.
  final result = Process.runSync('codesign', [
    '-dv',
    bundle,
  ], stderrEncoding: utf8);
  final match = RegExp(
    r'^TeamIdentifier=(.+)$',
    multiLine: true,
  ).firstMatch(result.stderr as String);
  final team = match?.group(1);
  return team == null || team == 'not set' ? null : team;
}

/// The entitlements codesign embedded in [bundle]'s signature.
Map<String, Object?> _entitlements(String bundle, Directory tmpDir) {
  final out = '${tmpDir.path}/entitlements.plist';
  final result = Process.runSync('codesign', [
    '-d',
    '--entitlements',
    ':$out',
    bundle,
  ]);
  if (result.exitCode != 0) {
    stderr.writeln('codesign -d failed on $bundle: ${result.stderr}');
    exit(1);
  }
  final json = Process.runSync('plutil', [
    '-convert',
    'json',
    '-o',
    '-',
    out,
  ], stdoutEncoding: utf8);
  if (json.exitCode != 0) {
    stderr.writeln('plutil failed on $out: ${json.stderr}');
    exit(1);
  }
  return jsonDecode(json.stdout as String) as Map<String, Object?>;
}
