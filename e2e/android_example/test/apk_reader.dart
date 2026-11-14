/// Shared readers for the Android example's APK content tests.
///
/// The runfiles lookup, the APK entry extraction, the sha256 of a byte
/// string and the Dart VM features string are read here once, so the profile
/// and widget-tracking tests inspect an APK the same way. Every failure names
/// what was expected and what was found; a missing input fails, never skips.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'android_artifact_reader.dart';

/// Stops the test with [message]: a missing input fails, never skips.
Never abort(String message) {
  stderr.writeln(message);
  exit(1);
}

/// The runfile that the environment variable [name] points at.
///
/// The value is a `$(rootpath ...)` path, relative to the test workspace in
/// the runfiles tree.
File runfile(String name) {
  final value = Platform.environment[name];
  final srcDir = Platform.environment['TEST_SRCDIR'];
  final workspace = Platform.environment['TEST_WORKSPACE'];
  if (value == null || srcDir == null || workspace == null) {
    abort('FAIL: expected $name, TEST_SRCDIR and TEST_WORKSPACE to be set');
  }
  final file = File('$srcDir/$workspace/$value');
  if (!file.existsSync()) {
    abort('FAIL: expected $name to name an existing file; found ${file.path}');
  }
  return file;
}

/// The bytes of [entry] inside the zip [archive], or a failure naming it.
///
/// The archive is read by `readZipEntries`, so no host `unzip` is needed.
Uint8List zipEntry(File archive, String entry) {
  final Map<String, Uint8List> entries;
  try {
    entries = readZipEntries(archive.readAsBytesSync(), archive.path);
  } on FormatException catch (e) {
    abort('FAIL: expected ${archive.path} to be a zip; found ${e.message}');
  }
  final bytes = entries[entry];
  if (bytes == null || bytes.isEmpty) {
    abort('FAIL: expected $entry in ${archive.path}; found ${entries.keys}');
  }
  return bytes;
}

/// The lower-case hex sha256 of [bytes], through `sha256sum`.
String sha256Hex(Uint8List bytes) {
  final dir = Directory.systemTemp.createTempSync('android_sha256');
  try {
    final file = File('${dir.path}/input')..writeAsBytesSync(bytes);
    final result = Process.runSync('sha256sum', [file.path]);
    if (result.exitCode != 0) {
      abort('FAIL: expected sha256sum to succeed; found ${result.stderr}');
    }
    return (result.stdout as String).split(' ').first;
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// The first VM features string in [bytes], or empty when the binary has none.
///
/// The Dart VM embeds its features in an AOT snapshot as a space-separated
/// word list that starts with the build flavor (`product` in a release
/// build, `release` in a profile build) and runs through the `no-asan` word
/// to the target words (`arm64 android`). The string is stored glued to a
/// hash with no separator, so it is found by its flavor and `no-asan` words
/// rather than as a whole printable run, and read to the next non-printable
/// byte.
String snapshotFeatures(Uint8List bytes) {
  final text = latin1.decode(bytes);
  final match = RegExp('(product|release|debug) no-asan ').firstMatch(text);
  if (match == null) return '';
  var end = match.start;
  while (end < text.length) {
    final unit = text.codeUnitAt(end);
    if (unit < 0x20 || unit > 0x7e) break;
    end++;
  }
  return text.substring(match.start, end);
}
