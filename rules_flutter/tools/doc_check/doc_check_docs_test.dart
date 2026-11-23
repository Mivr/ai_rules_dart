/// Runs the documentation checker over every extract in
/// `//docs:all_doc_extracts`: any gap fails `bazel test //...`.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import 'doc_check.dart';

/// The environment variable [key], failing the test when it is unset.
String _env(String key) {
  final String? value = Platform.environment[key];
  if (value == null || value.isEmpty) {
    fail('$key is not set; //docs:doc_check_test must pass it');
  }
  return value;
}

void main() {
  test('every extract is fully documented', () {
    final runfiles = Runfiles.create();
    final List<String> extracts = _env('DOC_CHECK_EXTRACTS_RLOCATIONS')
        .split(' ');
    final String anchor = _env('DOC_CHECK_ANCHOR_RLOCATION');
    // The anchor is `//flutter:providers.bzl`: its runfile path minus the
    // package path is the root of the main repository's source tree.
    final String root = runfiles
        .rlocation(anchor)
        .replaceFirst(RegExp(r'/flutter/providers\.bzl$'), '');
    final List<String> paths = [
      for (final e in extracts) runfiles.rlocation(e),
    ];
    final err = StringBuffer();
    final int code = run(
      [
        '--allowlist=${runfiles.rlocation(_env('DOC_CHECK_ALLOWLIST_RLOCATION'))}',
        '--shared-phrasings=${runfiles.rlocation(_env('DOC_CHECK_SHARED_RLOCATION'))}',
        '--sources-root=$root',
        ...paths,
      ],
      StringBuffer(),
      err,
    );
    expect(code, 0, reason: '\n$err');
  });
}
