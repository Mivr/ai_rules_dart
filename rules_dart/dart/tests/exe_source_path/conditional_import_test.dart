// An `exe` binary answers `dart.library.*` like `dart compile exe`, whether or
// not `modular_kernel` is on. The `dart:mirrors` refusal is tested through the
// rule in `//dart/tests/import_check_export:import_check_export_test`.
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
}
