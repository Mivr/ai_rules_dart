/// Writes the fixture protos under `tool/doc_check/test/fixtures/`.
///
/// Run `bazel run //tool/doc_check:write_fixtures` after changing
/// `test/support/fixture_defs.dart`.
library;

import 'dart:io';

import 'support/fixture_defs.dart';

void main() {
  final String? root = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (root == null) {
    stderr.writeln(
      'run this through `bazel run //tool/doc_check:write_fixtures`',
    );
    exit(2);
  }
  final dir = Directory('$root/tool/doc_check/test/fixtures')
    ..createSync(recursive: true);
  fixtures.forEach((name, bytes) {
    File('${dir.path}/$name.binaryproto').writeAsBytesSync(bytes);
  });
  stdout.writeln('wrote ${fixtures.length} fixtures to ${dir.path}');
}
