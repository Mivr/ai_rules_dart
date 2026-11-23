/// The built `flutter_bazel` binary, run as a user runs it.
///
/// The binary's own imports decide which copy of `DevToolException` its `catch`
/// names: a relative import of a `lib/` file and a `package:` import of it are
/// two libraries, so a binary that mixed them let every failing command end in
/// an unhandled exception instead of its `Error:` line and exit code.
///
/// Tagged `runfiles`: the binary is a `data` dependency.
@TestOn('!windows')
@Tags(['runfiles'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/runfiles_helper.dart';
import 'package:test/test.dart';

const _binaryKey = 'rules_flutter/tools/dev_tool/flutter_bazel';

void main() {
  test('a stray positional argument reports Error and exits 1', () async {
    final String? binary = resolveRunfile(_binaryKey);
    if (binary == null) {
      throw StateError(
        'Could not resolve $_binaryKey from runfiles. Run this with '
        '`bazel test //tools/dev_tool:flutter_bazel_binary_test`.',
      );
    }
    final ProcessResult result = await Process.run(
      binary,
      ['build', 'stray'],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    final output = '${result.stdout}\n${result.stderr}';

    expect(output, isNot(contains('Unhandled exception')));
    expect(result.stderr, contains('Error: Unexpected argument(s): stray'));
    expect(result.exitCode, 1);
  });
}
