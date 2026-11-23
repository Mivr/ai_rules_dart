import 'dart:io';

import 'package:test/test.dart';

import '../const_finder.dart' as cf;

void main() {
  group('parseConstFinderArgs', () {
    test('parses required and repeatable args', () {
      final cf.ConstFinderArgs parsed = cf.parseConstFinderArgs([
        '--output',
        'out.json',
        '--dart',
        'dart_bin',
        '--const-finder',
        'snap.snapshot',
        '--kernel-file',
        'a.dill',
        '--kernel-file',
        'b.dill',
      ]);
      expect(parsed.outputPath, equals('out.json'));
      expect(parsed.dartPath, equals('dart_bin'));
      expect(parsed.constFinderPath, equals('snap.snapshot'));
      expect(parsed.kernelFiles, equals(['a.dill', 'b.dill']));
    });
  });

  group('mergeConstFinderCodePoints', () {
    test('merges constant instances with and without package', () {
      final Map<String, Set<int>>? merged = cf.mergeConstFinderCodePoints([
        {
          'constantInstances': [
            {
              'fontFamily': 'MaterialIcons',
              'fontPackage': null,
              'codePoint': 58136,
            },
            {
              'fontFamily': 'CustomIcons',
              'fontPackage': 'my_pkg',
              'codePoint': 100,
            },
          ],
          'nonConstantLocations': <dynamic>[],
        },
      ]);
      expect(merged, isNotNull);
      expect(merged!['MaterialIcons'], equals({58136}));
      expect(merged['packages/my_pkg/CustomIcons'], equals({100}));
    });

    test('unions code points across multiple kernels', () {
      final Map<String, Set<int>>? merged = cf.mergeConstFinderCodePoints([
        {
          'constantInstances': [
            {
              'fontFamily': 'MaterialIcons',
              'fontPackage': '',
              'codePoint': 58136,
            },
          ],
          'nonConstantLocations': <dynamic>[],
        },
        {
          'constantInstances': [
            {
              'fontFamily': 'MaterialIcons',
              'fontPackage': null,
              'codePoint': 58137,
            },
          ],
          'nonConstantLocations': <dynamic>[],
        },
      ]);
      expect(merged, isNotNull);
      expect(merged!['MaterialIcons'], equals({58136, 58137}));
    });

    test('returns null when nonConstantLocations is not empty', () {
      final Map<String, Set<int>>? merged = cf.mergeConstFinderCodePoints([
        {
          'constantInstances': [
            {
              'fontFamily': 'MaterialIcons',
              'fontPackage': null,
              'codePoint': 58136,
            },
          ],
          'nonConstantLocations': [
            {'file': 'main.dart', 'line': 12},
          ],
        },
      ]);
      expect(merged, isNull);
    });
  });

  group('formatCodePointsJson', () {
    test(r'formats null as literal null\n', () {
      expect(cf.formatCodePointsJson(null), equals('null\n'));
    });

    test(r'formats empty map as {}\n', () {
      expect(cf.formatCodePointsJson({}), equals('{}\n'));
    });

    test('sorts families and code points deterministically', () {
      final map = <String, Set<int>>{
        'Zebra': {300, 100, 200},
        'Alpha': {50, 10},
      };
      final String formatted = cf.formatCodePointsJson(map);
      expect(
        formatted,
        equals('{"Alpha":[10,50],"Zebra":[100,200,300]}\n'),
      );
    });
  });

  group('main e2e with mock runner', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('const_finder_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test(
      'executes mock snapshot script and writes deterministic JSON',
      () async {
        final fakeScript = File('${tempDir.path}/mock_const_finder.sh');
        fakeScript.writeAsStringSync('''
#!/bin/sh
echo '{"constantInstances":[{"fontFamily":"MaterialIcons","fontPackage":null,"codePoint":58136}],"nonConstantLocations":[]}'
''');
        await Process.run('chmod', ['+x', fakeScript.path]);

        final outPath = '${tempDir.path}/output.json';
        await cf.main([
          '--output',
          outPath,
          '--dart',
          '/bin/sh',
          '--const-finder',
          fakeScript.path,
          '--kernel-file',
          '${tempDir.path}/fake.dill',
        ]);

        expect(File(outPath).existsSync(), isTrue);
        final String content = File(outPath).readAsStringSync();
        expect(content, equals('{"MaterialIcons":[58136]}\n'));
      },
    );
  });
}
