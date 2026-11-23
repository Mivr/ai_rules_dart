/// Unit tests for `package:e2e_runner/junit.dart`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:e2e_runner/junit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Entry point for BEP and JUnit XML unit tests.
void main() {
  _registerXmlParserTests();
  _registerBepAndFallbackTests();
}

void _registerXmlParserTests() {
  group('countExecutedTestsInXml', () {
    test('counts executed testcases and skips <skipped> children', () {
      const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <!-- <testcase name="commented_out"/> -->
  <testsuite name="pkg_test" tests="5" skipped="2">
    <testcase classname="s" name="self_closing_pass" time="0.01"/>
    <testcase classname="s" name="block_pass" info="a/>b">
      <system-out><![CDATA[<skipped/> </testcase>]]></system-out>
    </testcase>
    <testcase classname="s" name="failed_still_executed">
      <failure message="boom">trace</failure>
    </testcase>
    <testcase classname="s" name="skipped_empty">
      <skipped message="platform filter"/>
    </testcase>
    <testcase classname="s" name="skipped_block">
      <skipped>not applicable</skipped>
    </testcase>
  </testsuite>
</testsuites>
''';
      final ({int total, int executed}) result = countExecutedTestsInXml(xml);
      expect(result.total, 5);
      expect(result.executed, 3);
    });

    test('returns zero for empty testsuite', () {
      const xml =
          '<testsuites><testsuite name="empty" tests="0"/></testsuites>';
      final ({int total, int executed}) result = countExecutedTestsInXml(xml);
      expect(result.total, 0);
      expect(result.executed, 0);
    });
  });
}

void _registerBepAndFallbackTests() {
  group('countCommandTestCases and collectCommandTestLogs', () {
    test('prefers BEP test.xml and test.log URIs across shards', () {
      final Directory dir = Directory.systemTemp.createTempSync('junit_bep_');
      addTearDown(() => dir.deleteSync(recursive: true));

      final shard1Xml = File(p.join(dir.path, 's1', 'test.xml'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          '<testsuite><testcase name="a"/><testcase name="b"><skipped/></testcase></testsuite>',
        );
      final shard2Xml = File(p.join(dir.path, 's2', 'test.xml'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          '<testsuite><testcase name="c"/><testcase name="d"/></testsuite>',
        );
      final shard1Log = File(p.join(dir.path, 's1', 'test.log'))
        ..writeAsStringSync('SHARD_ONE_LOG_LINE');

      final bepFile = File(p.join(dir.path, 'bep.json'));
      final String event1 = jsonEncode({
        'testResult': {
          'testActionOutput': [
            {'name': 'test.xml', 'uri': Uri.file(shard1Xml.path).toString()},
            {'name': 'test.log', 'uri': Uri.file(shard1Log.path).toString()},
          ],
        },
      });
      final String event2 = jsonEncode({
        'testResult': {
          'testActionOutput': [
            {'name': 'test.xml', 'uri': Uri.file(shard2Xml.path).toString()},
          ],
        },
      });
      bepFile.writeAsStringSync('$event1\n$event2\n');

      final ws = Directory(p.join(dir.path, 'ws'))..createSync();
      final ob = Directory(p.join(dir.path, 'ob'))..createSync();

      final TestCaseCount counts = countCommandTestCases(
        bepJsonPath: bepFile.path,
        stagedWorkspace: ws.path,
        scratchOutputBase: ob.path,
      );
      expect(counts.source, 'BEP');
      expect(counts.total, 4);
      expect(counts.executed, 3);

      final String logs = collectCommandTestLogs(
        bepJsonPath: bepFile.path,
        stagedWorkspace: ws.path,
        scratchOutputBase: ob.path,
      );
      expect(logs, contains('SHARD_ONE_LOG_LINE'));

      final String xml = collectCommandTestXml(
        bepJsonPath: bepFile.path,
        stagedWorkspace: ws.path,
        scratchOutputBase: ob.path,
      );
      expect(xml, contains('<testcase name="a"/>'));
      expect(xml, contains('<testcase name="d"/>'));
    });

    test('falls back to workspace and execroot test.xml deduplicated', () {
      final Directory dir = Directory.systemTemp.createTempSync('junit_fb_');
      addTearDown(() => dir.deleteSync(recursive: true));

      final ws = Directory(p.join(dir.path, 'ws'))..createSync();
      final ob = Directory(p.join(dir.path, 'ob'))..createSync();
      final stTestlogs = Directory(
        p.join(
          ob.path,
          'execroot',
          '_main',
          'bazel-out',
          'k8-fastbuild-ST-1234',
          'testlogs',
          'pkg',
          'my_test',
        ),
      )..createSync(recursive: true);
      File(p.join(stTestlogs.path, 'test.xml')).writeAsStringSync(
        '<testsuite><testcase name="one"/><testcase name="two"/></testsuite>',
      );
      File(p.join(stTestlogs.path, 'test.log')).writeAsStringSync('FB_LOG_OK');
      Link(p.join(ws.path, 'bazel-testlogs')).createSync(
        p.join(
          ob.path,
          'execroot',
          '_main',
          'bazel-out',
          'k8-fastbuild-ST-1234',
          'testlogs',
        ),
      );
      final emptyBep = File(p.join(dir.path, 'empty_bep.json'))
        ..writeAsStringSync('{"started":{}}\n');

      final TestCaseCount counts = countCommandTestCases(
        bepJsonPath: emptyBep.path,
        stagedWorkspace: ws.path,
        scratchOutputBase: ob.path,
      );
      expect(counts.source, 'JUnit test.xml');
      expect(counts.total, 2);
      expect(counts.executed, 2);

      final String logs = collectCommandTestLogs(
        bepJsonPath: emptyBep.path,
        stagedWorkspace: ws.path,
        scratchOutputBase: ob.path,
      );
      expect(logs, contains('FB_LOG_OK'));

      final String xml = collectCommandTestXml(
        bepJsonPath: emptyBep.path,
        stagedWorkspace: ws.path,
        scratchOutputBase: ob.path,
      );
      expect(xml, contains('<testcase name="two"/>'));
    });
  });
}
