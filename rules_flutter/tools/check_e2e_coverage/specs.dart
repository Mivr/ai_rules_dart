/// Parses every checked-in `e2e.yaml` so a malformed spec fails CI even when
/// no workflow runs it.
library;

import 'dart:io';

import 'package:e2e_runner/spec.dart';

/// Paths of every `e2e.yaml` under [e2eDir], sorted. Symlinks are never
/// followed and `bazel-*` convenience directories are skipped, as in
/// `findE2eModules`.
List<String> findE2eSpecFiles(Directory e2eDir) {
  final found = <String>[];
  void walk(Directory dir) {
    for (final FileSystemEntity entity in dir.listSync(followLinks: false)) {
      final String name = entity.path.split(Platform.pathSeparator).last;
      if (entity is File && name == 'e2e.yaml') {
        found.add(entity.path);
      } else if (entity is Directory && !name.startsWith('bazel-')) {
        walk(entity);
      }
    }
  }

  walk(e2eDir);
  return found..sort();
}

/// One error line per spec under [e2eDir] that `loadE2eSpec` rejects; each
/// names the spec path.
List<String> checkSpecs(Directory e2eDir) {
  final errors = <String>[];
  for (final String path in findE2eSpecFiles(e2eDir)) {
    try {
      loadE2eSpec(path);
    } on E2eRunnerException catch (error) {
      errors.add('invalid e2e spec $error');
    }
  }
  return errors;
}
