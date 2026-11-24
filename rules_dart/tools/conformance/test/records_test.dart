import 'dart:convert';

import 'package:conformance/records.dart';
import 'package:test/test.dart';

void main() {
  group('testsFromJsonReporter', () {
    test('pairs each testDone with its start and suite', () {
      final lines = [
        'Resolving dependencies...',
        jsonEncode({
          'type': 'suite',
          'suite': {'id': 0, 'path': '/p/test/a_test.dart'},
        }),
        jsonEncode({
          'type': 'testStart',
          'test': {
            'id': 1,
            'name': 'loading /p/test/a_test.dart',
            'suiteID': 0,
          },
        }),
        jsonEncode({
          'type': 'testDone',
          'testID': 1,
          'result': 'success',
          'hidden': true,
        }),
        jsonEncode({
          'type': 'testStart',
          'test': {'id': 2, 'name': 'g adds', 'suiteID': 0},
        }),
        jsonEncode({'type': 'testDone', 'testID': 2, 'result': 'failure'}),
        jsonEncode({
          'type': 'testStart',
          'test': {'id': 3, 'name': 'g skips', 'suiteID': 0},
        }),
        jsonEncode({
          'type': 'testDone',
          'testID': 3,
          'result': 'success',
          'skipped': true,
        }),
      ];
      final records = testsFromJsonReporter(lines);
      expect(
        [for (final r in records) '${r.suite}|${r.name}|${r.result}'],
        [
          '/p/test/a_test.dart|loading /p/test/a_test.dart|hidden:success',
          '/p/test/a_test.dart|g adds|failure',
          '/p/test/a_test.dart|g skips|skipped',
        ],
      );
    });
  });

  group('testsFromJunit', () {
    test('reads each testcase and its outcome', () {
      const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="test/a_test.dart" tests="4">
    <testcase name="adds &amp; &quot;subtracts&quot;" classname="test/a_test.dart" time="0.1"></testcase>
    <testcase name="fails" classname="test/a_test.dart" time="0.1"><failure message="x">boom</failure></testcase>
    <testcase name="errs" classname="test/a_test.dart" time="0.1"><error message="x">bad</error></testcase>
    <testcase name="skips" classname="test/a_test.dart" time="0.0"><skipped/></testcase>
  </testsuite>
</testsuites>''';
      final records = testsFromJunit(xml, fallbackSuite: '//:a_test');
      expect(
        [for (final r in records) '${r.suite}|${r.name}|${r.result}'],
        [
          'test/a_test.dart|adds & "subtracts"|success',
          'test/a_test.dart|fails|failure',
          'test/a_test.dart|errs|error',
          'test/a_test.dart|skips|skipped',
        ],
      );
    });

    test('a self-closing testcase without classname takes the fallback', () {
      final records = testsFromJunit(
        '<testsuite><testcase name="t" time="1"/></testsuite>',
        fallbackSuite: '//:t',
      );
      expect(records.single.suite, '//:t');
      expect(records.single.result, 'success');
    });
  });

  group('diagnosticsFromText', () {
    test('reads dart analyze lines and skips the rest', () {
      final found = diagnosticsFromText([
        'Analyzing p...',
        '  error - lib/a.dart:3:7 - Undefined name - x. Try - y - undefined_identifier',
        'warning - test/b_test.dart:10:1 - Unused import - unused_import',
        '   info - lib/c.dart:1:1 - Doc - public_member_api_docs',
        '3 issues found.',
      ]);
      expect(
        [for (final d in found) '${d.severity} ${d.file}:${d.line} ${d.code}'],
        [
          'error lib/a.dart:3 undefined_identifier',
          'warning test/b_test.dart:10 unused_import',
          'info lib/c.dart:1 public_member_api_docs',
        ],
      );
    });
  });

  test('records survive a JSON round trip', () {
    const t = TestRecord('s', 'n', 'success');
    expect(TestRecord.fromJson(t.toJson()).name, 'n');
    const d = Diagnostic(file: 'f', line: 2, severity: 'info', code: 'c');
    expect(Diagnostic.fromJson(d.toJson()).line, 2);
    const e = ExeRun(['a'], 'o', 'e', 3);
    expect(ExeRun.fromJson(e.toJson()).exitCode, 3);
  });
}
