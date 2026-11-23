import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Runs the `dart_binary` consumer and checks its exit code and output.
void main() {
  test('dart_binary runs and prints the fixed line', () {
    final r = Runfiles.create();
    final exeName = Platform.isWindows ? 'app.exe' : 'app';
    final exe = r.rlocation('_main/$exeName');
    final result = Process.runSync(exe, []);
    expect(
      result.exitCode,
      0,
      reason: 'stdout=${result.stdout}\nstderr=${result.stderr}',
    );
    expect(result.stdout, contains('smoke: hello from rules_dart'));
  });
}
