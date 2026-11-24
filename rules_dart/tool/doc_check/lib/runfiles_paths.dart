/// Resolution of runfiles-relative paths, with a plain-path fallback.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';

Runfiles? _runfiles;

bool _underBazel() {
  final Map<String, String> env = Platform.environment;
  return env.containsKey('TEST_SRCDIR') ||
      env.containsKey('RUNFILES_MANIFEST_FILE') ||
      env.containsKey('RUNFILES_DIR');
}

/// The file system path for the runfiles path [path], null when absent.
String? locateRunfile(String path) {
  if (!_underBazel()) return null;
  final String located = (_runfiles ??= Runfiles.create()).rlocation(path);
  return File(located).existsSync() ? located : null;
}

/// [path] as a runfiles entry when one exists, else [path] itself.
String resolveRunfile(String path) => locateRunfile(path) ?? path;
