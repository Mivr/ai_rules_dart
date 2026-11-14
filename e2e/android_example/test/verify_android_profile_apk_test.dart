/// Verifies the profile APK of the Android example is a profile build.
///
/// A profile APK must bundle the profile engine's `libflutter.so`, carry an
/// AOT snapshot in `libapp.so` that is not a product build, and take the
/// `profile` variant manifest's `INTERNET` grant that a release APK of the
/// same app does not. The test reads `:app_profile` and `:app_nopermissions`
/// through their zip entries; no device or emulator is involved.
library;

// This script's diagnostics are its product: it reports what it found in the
// built artifact to the bazel test log, so `print` is its output channel
// rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:io';

import 'apk_reader.dart';
import 'verify_android_permissions_test.dart' show usesPermissions;

const _libflutter = 'lib/arm64-v8a/libflutter.so';
const _libapp = 'lib/arm64-v8a/libapp.so';
const _internet = 'android.permission.INTERNET';

final _failures = <String>[];

/// Records a failure naming [expected] and [found] when [ok] is false.
void _check(String expected, {required bool ok, required String found}) {
  if (ok) {
    print('OK: $expected');
  } else {
    stderr.writeln('FAIL: expected $expected; found $found');
    _failures.add(expected);
  }
}

void main() {
  final profileApk = runfile('PROFILE_APK');
  final releaseApk = runfile('RELEASE_APK');
  final profileEngine = sha256Hex(
    zipEntry(runfile('PROFILE_ENGINE_JAR'), _libflutter),
  );
  final releaseEngine = sha256Hex(
    zipEntry(runfile('RELEASE_ENGINE_JAR'), _libflutter),
  );
  _check(
    'the profile and release engines to ship different libflutter.so',
    ok: profileEngine != releaseEngine,
    found: 'both $profileEngine',
  );

  final profileLib = sha256Hex(zipEntry(profileApk, _libflutter));
  _check(
    'the profile APK $_libflutter to be the profile engine ($profileEngine)',
    ok: profileLib == profileEngine,
    found: profileLib,
  );
  _check(
    'the profile APK $_libflutter to differ from the release engine '
    '($releaseEngine)',
    ok: profileLib != releaseEngine,
    found: profileLib,
  );

  final features = snapshotFeatures(zipEntry(profileApk, _libapp));
  final words = features.split(' ');
  _check(
    'the profile APK $_libapp to hold an AOT snapshot features string '
    'without the product word',
    ok: features.isNotEmpty && !words.contains('product'),
    found: features.isEmpty ? 'no features string' : features,
  );

  final profilePermissions = usesPermissions(
    zipEntry(profileApk, 'AndroidManifest.xml'),
  );
  _check(
    'the profile APK manifest to grant $_internet',
    ok: profilePermissions.contains(_internet),
    found: profilePermissions.join(', '),
  );
  final releasePermissions = usesPermissions(
    zipEntry(releaseApk, 'AndroidManifest.xml'),
  );
  _check(
    'the release APK manifest not to grant $_internet',
    ok: !releasePermissions.contains(_internet),
    found: releasePermissions.join(', '),
  );

  if (_failures.isNotEmpty) {
    stderr.writeln('\n${_failures.length} check(s) failed.');
    exit(1);
  }
  print('\nAll Android profile APK checks passed.');
}
