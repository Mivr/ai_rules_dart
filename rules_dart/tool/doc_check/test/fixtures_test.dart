/// The checked-in fixture protos match their definitions and decode.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:doc_check/checker.dart';
import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'support/fixture_defs.dart';

void main() {
  final runfiles = Runfiles.create();
  for (final MapEntry<String, Uint8List> entry in fixtures.entries) {
    final path = 'tool/doc_check/test/fixtures/${entry.key}.binaryproto';
    test('${entry.key}.binaryproto is checked in and current', () {
      final String located = runfiles.rlocation('_main/$path');
      final file = File(located);
      expect(
        file.existsSync(),
        isTrue,
        reason:
            'missing $path; run `bazel run //tool/doc_check:write_fixtures`',
      );
      expect(
        file.readAsBytesSync(),
        entry.value,
        reason:
            '$path is stale; run `bazel run //tool/doc_check:write_fixtures`',
      );
      expect(decodeExtracts([file.readAsBytesSync()]).single.file, fixtureFile);
    });
  }
}
