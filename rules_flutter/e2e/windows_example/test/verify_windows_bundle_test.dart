/// Verifies the Windows bundle produced by flutter_windows_app has the expected
/// directory structure.
///
/// Runs as a Bazel dart_test with the bundle as data dependency.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main() {
  // Resolved through the runfiles library, not by joining TEST_SRCDIR: the
  // windows-latest job runs with --noenable_runfiles, so no runfiles directory
  // exists there and only the manifest knows where the bundle is.
  final String bundlePath;
  try {
    bundlePath = Runfiles.create().rlocation('_main/app');
  } on Object catch (e) {
    stderr.writeln('The runfiles of this test cannot be read: $e');
    exit(1);
  }
  final bundle = Directory(bundlePath);

  if (!bundle.existsSync()) {
    stderr.writeln('Bundle directory not found at $bundlePath');
    exit(1);
  }

  var failed = false;

  void check(String description, String path, {bool nonEmpty = false}) {
    final file = File(path);
    final isDir = FileSystemEntity.isDirectorySync(path);
    final exists = isDir || file.existsSync();
    if (!exists) {
      stderr.writeln('FAIL: $description — not found: $path');
      failed = true;
    } else if (nonEmpty && !isDir && file.lengthSync() == 0) {
      stderr.writeln('FAIL: $description — file is empty: $path');
      failed = true;
    } else {
      final size = !isDir ? ' (${file.lengthSync()} bytes)' : '';
      print('OK: $description$size');
    }
  }

  // Runner executable.
  check('Runner binary', '$bundlePath/app.exe', nonEmpty: true);

  // Engine DLL.
  check(
    'flutter_windows.dll',
    '$bundlePath/flutter_windows.dll',
    nonEmpty: true,
  );

  // In release mode data/app.so exists; in debug mode data/flutter_assets/kernel_blob.bin exists.
  final hasAotLib = File('$bundlePath/data/app.so').existsSync();
  final hasKernelBlob = File(
    '$bundlePath/data/flutter_assets/kernel_blob.bin',
  ).existsSync();
  if (hasAotLib) {
    check('AOT snapshot (release)', '$bundlePath/data/app.so', nonEmpty: true);
  } else if (hasKernelBlob) {
    check(
      'Kernel blob (debug)',
      '$bundlePath/data/flutter_assets/kernel_blob.bin',
      nonEmpty: true,
    );
  } else {
    stderr.writeln(
      'FAIL: Neither data/app.so nor data/flutter_assets/kernel_blob.bin found',
    );
    failed = true;
  }

  // Flutter assets.
  check('flutter_assets directory', '$bundlePath/data/flutter_assets');
  check(
    'AssetManifest.bin',
    '$bundlePath/data/flutter_assets/AssetManifest.bin',
  );
  check(
    'FontManifest.json',
    '$bundlePath/data/flutter_assets/FontManifest.json',
  );
  check('NOTICES.Z', '$bundlePath/data/flutter_assets/NOTICES.Z');

  // ICU data.
  check('icudtl.dat', '$bundlePath/data/icudtl.dat', nonEmpty: true);

  if (failed) {
    stderr
      ..writeln()
      ..writeln('Actual bundle contents:');
    _listTree(bundle, '');
    exit(1);
  }

  print('');
  print('All Windows bundle verification checks passed.');
}

void _listTree(Directory dir, String indent) {
  if (!dir.existsSync()) return;
  final entries = dir.listSync()..sort((a, b) => a.path.compareTo(b.path));
  for (final entry in entries) {
    final name = entry.path.split('/').last;
    if (entry is Directory) {
      stderr.writeln('$indent$name/');
      _listTree(entry, '$indent  ');
    } else if (entry is File) {
      stderr.writeln('$indent$name (${entry.lengthSync()} bytes)');
    }
  }
}
