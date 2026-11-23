/// Pins the vendored `stardoc_output.proto` to Bazel 9.3.0's copy, and checks
/// the pure-Dart SHA-256 it is pinned with.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import '../sha256.dart';

/// The sha256 of `src/main/protobuf/stardoc_output.proto` in Bazel 9.3.0.
const _pinned =
    '4bd566b8efae83ae84cc96467d682a7760d2a1b03e635642eaab9d5db76dd80c';

void main() {
  test('the vendored stardoc_output.proto is the pinned file', () {
    const key = 'DOC_CHECK_PROTO_RLOCATION';
    final String? rlocation = Platform.environment[key];
    if (rlocation == null || rlocation.isEmpty) {
      fail('$key is not set; the test needs stardoc_output.proto in `data`');
    }
    final String path = Runfiles.create().rlocation(rlocation);
    final file = File(path);
    if (!file.existsSync()) fail('stardoc_output.proto is missing: $path');
    expect(
      sha256Hex(file.readAsBytesSync()),
      _pinned,
      reason: 'stardoc_output.proto differs from Bazel 9.3.0; re-vendor it',
    );
  });

  test('sha256Hex matches the FIPS 180 test vectors', () {
    expect(
      sha256Hex(utf8.encode('abc')),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(
      sha256Hex(const []),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    );
    expect(
      sha256Hex(
        utf8.encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
      ),
      '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    );
  });
}
