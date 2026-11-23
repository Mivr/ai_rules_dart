/// Tagged `runfiles`: the e2e source is a `data` dependency, so this needs the
/// Bazel runfiles tree.
@Tags(['runfiles'])
library;

import 'dart:io';

import 'package:flutter_bazel_dev_tool/runfiles_helper.dart';
import 'package:test/test.dart';

/// The attach e2e must wait for the attached app's first frame before it reads
/// a label: `waitForHttpControl` only says the tool is up. This reads the e2e
/// source as text, because the cases themselves need a device.
const _key = 'rules_flutter/tools/dev_tool/test/e2e/attach_e2e_test.dart';

String _source() {
  final String? path = resolveRunfile(_key);
  if (path == null) {
    throw StateError(
      'Could not resolve $_key from runfiles: run this with '
      '`bazel test //tools/dev_tool:attach_e2e_first_read_test`.',
    );
  }
  return File(path).readAsStringSync();
}

/// The text of the case whose title contains [title], up to its `timeout:`.
String _caseBody(String source, String title) {
  final int start = source.indexOf(title);
  expect(start, isNonNegative, reason: 'case "$title" exists');
  final int end = source.indexOf('timeout: const Timeout', start);
  expect(end, isNonNegative, reason: 'case "$title" has a timeout');
  return source.substring(start, end);
}

void _expectWaitBeforeRead(String body, String marker) {
  final RegExpMatch? wait = RegExp(
    r"'app\.waitFor'[^;]*?'text':\s*'"
    '${RegExp.escape(marker)}'
    r"'[^;]*?'timeoutMs':\s*'30000'",
    dotAll: true,
  ).firstMatch(body);
  expect(wait, isNotNull, reason: 'a bounded app.waitFor for "$marker"');
  final int read = body.indexOf("'app.getText'");
  if (read >= 0) {
    expect(
      wait!.start,
      lessThan(read),
      reason: 'app.waitFor must come before the first app.getText',
    );
  }
}

void main() {
  late String source;
  setUpAll(() => source = _source());

  test('iOS simulator case waits for the first frame before reading', () {
    final String body = _caseBody(source, 'iOS simulator: attaches');
    _expectWaitBeforeRead(body, 'iOS attach marker v1');
    expect(
      body,
      contains('reason:'),
      reason: 'the first check reports the reply',
    );
    expect(body, contains(r': $before'));
  });

  test('desktop defines case waits for the first frame before reading', () {
    final String body = _caseBody(source, 'keeps the app’s own dart defines');
    _expectWaitBeforeRead(body, 'defines,live v1');
  });
}
