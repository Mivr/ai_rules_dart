import 'dart:io';

import 'package:pkg_a/a_top.dart';
import 'package:pkg_b/b.dart';
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main(List<String> args) {
  test('sandboxed modular binary and dart_test execute cross-package cycle and match whole-program output', () async {
    expect(
      '${aTopValue()}|${bValue()}',
      'a_top(b(a_base(leaf-v1),a_top_tag),a_base(leaf-v1))|b(a_base(leaf-v1),a_top_tag)',
    );

    final runfiles = Runfiles.create();
    final String modularDill = runfiles.rlocation(args[0]);
    final String wholeDill = runfiles.rlocation(args[1]);

    final ProcessResult modularRes = await Process.run(
      Platform.resolvedExecutable,
      [modularDill],
    );
    expect(
      modularRes.exitCode,
      0,
      reason: 'modular binary failed: ${modularRes.stderr}',
    );

    final ProcessResult wholeRes = await Process.run(
      Platform.resolvedExecutable,
      [wholeDill],
    );
    expect(
      wholeRes.exitCode,
      0,
      reason: 'whole-program binary failed: ${wholeRes.stderr}',
    );

    final String modularOut = (modularRes.stdout as String).replaceAll(
      '\r\n',
      '\n',
    );
    final String wholeOut = (wholeRes.stdout as String).replaceAll(
      '\r\n',
      '\n',
    );
    expect(modularOut, equals(wholeOut));
    expect(
      modularOut,
      'a_top(b(a_base(leaf-v1),a_top_tag),a_base(leaf-v1))|'
      'b(a_base(leaf-v1),a_top_tag)\n',
    );
  });
}
