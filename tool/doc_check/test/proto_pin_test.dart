/// The vendored `stardoc_output.proto` is Bazel 9.3.0's copy, byte for byte.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'support/sha256.dart';

/// The sha256 of `src/main/protobuf/stardoc_output.proto` at Bazel 9.3.0.
const _pinnedSha256 =
    '4bd566b8efae83ae84cc96467d682a7760d2a1b03e635642eaab9d5db76dd80c';

void main() {
  test('the sha256 implementation matches a known vector', () {
    expect(
      sha256Hex('abc'.codeUnits),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  test('the vendored proto matches the pinned sha256', () {
    final String path = Runfiles.create().rlocation(
      '_main/tool/doc_check/stardoc_output.proto',
    );
    final file = File(path);
    if (!file.existsSync()) {
      fail('the vendored stardoc_output.proto is missing at $path');
    }
    expect(sha256Hex(file.readAsBytesSync()), _pinnedSha256);
  });
}
