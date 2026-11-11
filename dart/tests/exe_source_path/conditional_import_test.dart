// An `exe` binary answers `dart.library.*` like `dart compile exe`, whether or
// not `modular_kernel` is on, and a `dart:mirrors` import reports the front
// end's diagnostic with a line.
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main(List<String> args) {
  final runfiles = Runfiles.create();
  String run(String rlocation) {
    final ProcessResult res = Process.runSync(
      runfiles.rlocation(rlocation),
      [],
    );
    expect(res.exitCode, 0, reason: '${res.stdout}\n${res.stderr}');
    return (res.stdout as String).trim();
  }

  test('modular and source exe binaries both print the AOT answers', () {
    final String modular = run(args[0]);
    final String source = run(args[1]);
    expect(modular, source);
    expect(modular, 'stub false');
  });

  test('dart:mirrors is refused by the front end with a line', () {
    final ProcessResult res = Process.runSync(Platform.resolvedExecutable, [
      'compile',
      'exe',
      runfiles.rlocation(args[2]),
      '-o',
      '${Directory.systemTemp.path}/mirrors_probe.exe',
    ]);
    expect(res.exitCode, isNot(0));
    expect(
      '${res.stdout}${res.stderr}',
      matches(
        RegExp(
          r"mirrors_main\.dart:\d+:\d+: Error: Dart library 'dart:mirrors' "
          'is not available on this platform',
        ),
      ),
    );
  });
}
