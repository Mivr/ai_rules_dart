// Runs the kernel `dart_binary` whose `main` is `lib/main.dart` of the library
// in its `deps`: the program's `main` is that library's, under the library's
// `package:` URI, as `dart run` names it.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main() {
  final runfiles = Runfiles.create();
  final String dill = runfiles.rlocation(
    '_main/dart/tests/entry_in_library_fixture/app.dill',
  );
  final ProcessResult result = Process.runSync(Platform.resolvedExecutable, [
    dill,
  ]);
  if (result.exitCode != 0) {
    throw StateError('app exited ${result.exitCode}: ${result.stderr}');
  }
  final List<String> lines = (result.stdout as String).trim().split('\n');
  if (lines.length != 2 || lines[0] != 'hello from layout') {
    throw StateError('unexpected output:\n${result.stdout}');
  }
  if (!lines[1].contains(
    'main (package:entry_in_library_fixture/main.dart:8:',
  )) {
    throw StateError(
      "the frame of `main` must name the library's URI and line, "
      'package:entry_in_library_fixture/main.dart:8. Output:\n${result.stdout}',
    );
  }
}
