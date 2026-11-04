import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main() {
  final runfiles = Runfiles.create();
  final String dillPath = runfiles.rlocation(
    Platform.environment['DILL_PATH']!,
  );
  final ProcessResult result = Process.runSync(Platform.resolvedExecutable, [
    dillPath,
  ]);
  if (result.exitCode != 0) {
    throw StateError(
      'Running modular kernel $dillPath failed (exit ${result.exitCode}):\n'
      '${result.stdout}\n${result.stderr}',
    );
  }
}
