import 'dart:convert';
import 'dart:io';

import 'package:e2e_runner/test_count.dart';
import 'package:test/test.dart';

void main() {
  group('countNonSkippedTestcases', () {
    test('counts self-closing and explicit testcase elements', () {
      const xml = '''
<testsuites>
  <testsuite name="a" tests="3" failures="0" errors="0">
    <testcase name="one" classname="" status="run" duration="0" time="0"></testcase>
    <testcase name="two"/>
  </testsuite>
</testsuites>
''';
      expect(countNonSkippedTestcases(xml), 2);
    });

    test('excludes skipped testcases after self-closing passing ones', () {
      const xml = '''
<testsuites>
  <testsuite name="a" tests="3">
    <testcase name="self_closing_pass" classname="pkg/foo" />
    <testcase name="run"><system-out>log</system-out></testcase>
    <testcase name="skipped"><skipped/></testcase>
    <testcase name="skipped_attr" status="skipped"/>
  </testsuite>
</testsuites>
''';
      expect(countNonSkippedTestcases(xml), 2);
    });
  });

  group('outputPathsFromBep', () {
    test('collects the named output URIs across testResult events', () {
      final bep =
          _bepLine('//:a', [
            'test.xml',
            '/tmp/a/test.xml',
            'test.log',
            '/tmp/a/test.log',
          ]) +
          _bepLine('//:b', [
            'test.xml',
            '/tmp/b/test.xml',
            'test.log',
            '/tmp/b/test.log',
          ]);
      expect(testXmlPathsFromBep(bep), ['/tmp/a/test.xml', '/tmp/b/test.xml']);
      expect(outputPathsFromBep(bep, 'test.log'), [
        '/tmp/a/test.log',
        '/tmp/b/test.log',
      ]);
    });

    test('ignores non-testResult events', () {
      expect(testXmlPathsFromBep('{"id": {"x": 1}}\n'), isEmpty);
    });
  });

  group('countNonSkippedTests', () {
    test('counts from the BEP-named test.xml files', () {
      final dir = Directory.systemTemp.createTempSync('bep_xml_');
      try {
        final xmlPath = '${dir.path}/test.xml';
        const xml =
            '<testsuites><testsuite><testcase name="a"/></testsuite></testsuites>';
        File(xmlPath).writeAsStringSync(xml);
        final bep = _bepLine('//:a', ['test.xml', xmlPath]);
        expect(countNonSkippedTests(bep, testLogsDir: dir.path), 1);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('falls back to scanning testLogsDir when the BEP names no test', () {
      final dir = Directory.systemTemp.createTempSync('bep_fb_');
      try {
        File('${dir.path}/a/test.xml')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '<testsuites><testsuite><testcase name="a"/></testsuite></testsuites>',
          );
        expect(countNonSkippedTests('', testLogsDir: dir.path), 1);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}

String _bepLine(String label, List<String> outputs) {
  final files = <Map<String, String>>[];
  for (var i = 0; i < outputs.length; i += 2) {
    files.add({'name': outputs[i], 'uri': 'file://${outputs[i + 1]}'});
  }
  return '${jsonEncode({
    'id': {
      'testResult': {'label': label},
    },
    'testResult': {'testActionOutput': files},
  })}\n';
}
