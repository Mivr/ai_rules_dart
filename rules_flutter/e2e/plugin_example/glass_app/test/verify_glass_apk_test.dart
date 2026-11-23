/// Verifies that `//glass_app:glass_android` packages `//glass_plugin` and
/// none of the unrelated pub-lock plugins (`record_android`, `jni`, etc.):
/// `//glass_plugin`'s boot receiver, permission and plugin class are in the
/// APK, while `record_android`'s `RECORD_AUDIO` permission and `jni`'s DEX
/// classes and `libdartjni.so` are absent.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

const _expectedManifest = [
  'com.example.glass_plugin.GlassBootReceiver',
  'android.intent.action.BOOT_COMPLETED',
  'android.permission.RECEIVE_BOOT_COMPLETED',
];

const _forbiddenManifest = ['android.permission.RECORD_AUDIO'];

const _expectedDex = ['Lcom/example/glass_plugin/GlassPlugin;'];

const _forbiddenDex = [
  'Lcom/github/dart_lang/jni/JniPlugin;',
  'Lcom/llfbandit/record/RecordPlugin;',
];

void main() {
  final base =
      '${Platform.environment['TEST_SRCDIR']}/'
      '${Platform.environment['TEST_WORKSPACE']}';
  final apk = '$base/glass_app/glass_android.apk';
  final tmp = Directory.systemTemp.createTempSync('glass_apk_');
  try {
    final unzip = Process.runSync('unzip', ['-q', apk, '-d', tmp.path]);
    if (unzip.exitCode != 0) {
      stderr.writeln('FAIL: could not extract $apk: ${unzip.stderr}');
      exit(1);
    }
    final manifest = File('${tmp.path}/AndroidManifest.xml').readAsBytesSync();
    final dexBytes = _readDexBytes(tmp);
    var failed = _checkStrings(
      label: 'merged manifest',
      haystack: manifest,
      expected: _expectedManifest,
      forbidden: _forbiddenManifest,
      encode: _utf16,
    );
    if (_checkStrings(
      label: 'classes.dex',
      haystack: dexBytes,
      expected: _expectedDex,
      forbidden: _forbiddenDex,
      encode: utf8.encode,
    )) {
      failed = true;
    }
    if (File('${tmp.path}/lib/arm64-v8a/libdartjni.so').existsSync()) {
      stderr.writeln('FAIL: unused lock plugin libdartjni.so packaged in APK');
      failed = true;
    } else {
      print('OK: unused lock plugin libdartjni.so absent');
    }
    if (failed) exit(1);
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

List<int> _readDexBytes(Directory dir) {
  final dexFiles =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => RegExp(r'/classes\d*\.dex$').hasMatch(f.path))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return [for (final file in dexFiles) ...file.readAsBytesSync()];
}

bool _checkStrings({
  required String label,
  required List<int> haystack,
  required List<String> expected,
  required List<String> forbidden,
  required List<int> Function(String) encode,
}) {
  var failed = false;
  for (final name in expected) {
    if (_contains(haystack, encode(name))) {
      print('OK: $label names $name');
    } else {
      stderr.writeln('FAIL: $label lacks $name');
      failed = true;
    }
  }
  for (final name in forbidden) {
    if (_contains(haystack, encode(name))) {
      stderr.writeln('FAIL: $label unexpectedly names $name');
      failed = true;
    } else {
      print('OK: $label excludes $name');
    }
  }
  return failed;
}

List<int> _utf16(String s) => [
  for (final unit in s.codeUnits) ...[unit & 0xff, unit >> 8],
];

bool _contains(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
