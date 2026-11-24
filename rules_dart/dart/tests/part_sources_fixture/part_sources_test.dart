import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:same_pkg/parent.dart';
import 'package:same_pkg/rev_parent.dart';
import 'package:same_pkg/sib_parent.dart';
import 'package:test/test.dart';

void main(List<String> args) {
  test('sandboxed modular binary and dart_test execute split part libraries and match whole-program output', () async {
    expect(
      '${parentBanner()}|${revParentBanner()}|${sibParentBanner()}',
      'parent(uri-part-v1,named-part-v1)|rev_parent(rev-part-v1)|sib_parent(sib-part-v1)',
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
      'parent(uri-part-v1,named-part-v1)|'
      'rev_parent(rev-part-v1)|'
      'sib_parent(sib-part-v1)\n',
    );
  });
}
