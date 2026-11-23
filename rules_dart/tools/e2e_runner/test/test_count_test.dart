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

  group('fileUriToPath', () {
    test('converts POSIX and Windows file URIs cleanly', () {
      expect(
        fileUriToPath('file:///tmp/a/test.xml', windows: false),
        '/tmp/a/test.xml',
      );
      expect(
        fileUriToPath('file:///D:/a/test.xml', windows: true),
        r'D:\a\test.xml',
      );
      expect(
        fileUriToPath('file://D:/a/test.xml', windows: true),
        r'D:\a\test.xml',
      );
      expect(
        fileUriToPath(r'file://C:\Users\RUNNER~1\test.xml', windows: true),
        r'C:\Users\RUNNER~1\test.xml',
      );
      expect(
        fileUriToPath('file://host/share/test.xml', windows: false),
        isNull,
      );
      expect(
        fileUriToPath('file://host/share/test.xml', windows: true),
        r'\\host\share\test.xml',
      );
      expect(fileUriToPath('https://example.com/test.xml'), isNull);
    });
  });

  group('hasTimedOutTestInBep', () {
    test('detects TIMEOUT testResult and ignores normal failures', () {
      const timedOut =
          '{"testResult":{"status":"TIMEOUT"}}\n'
          '{"testSummary":{"overallStatus":"TIMEOUT"}}\n';
      const failed = '{"testResult":{"status":"FAILED"}}\n';
      expect(hasTimedOutTestInBep(timedOut), isTrue);
      expect(hasTimedOutTestInBep(failed), isFalse);
    });
  });

  group('outputPathsFromBep', () {
    test('collects the named output URIs across testResult events', () {
      final sep = Platform.pathSeparator;
      final root = Platform.isWindows ? r'C:\tmp' : '/tmp';
      final xmlA = '$root${sep}a${sep}test.xml';
      final logA = '$root${sep}a${sep}test.log';
      final xmlB = '$root${sep}b${sep}test.xml';
      final logB = '$root${sep}b${sep}test.log';
      final bep =
          _bepLine('//:a', ['test.xml', xmlA, 'test.log', logA]) +
          _bepLine('//:b', ['test.xml', xmlB, 'test.log', logB]);
      expect(testXmlPathsFromBep(bep), [xmlA, xmlB]);
      expect(outputPathsFromBep(bep, 'test.log'), [logA, logB]);
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
    files.add({'name': outputs[i], 'uri': Uri.file(outputs[i + 1]).toString()});
  }
  return '${jsonEncode({
    'id': {
      'testResult': {'label': label},
    },
    'testResult': {'testActionOutput': files},
  })}\n';
}
