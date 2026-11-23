import 'dart:io';

import 'package:test/test.dart';

import 'defines_files.dart';

/// Unit tests for the defines_files tool.
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('defines_files_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  File createFile(String name, String content) {
    final file = File('${tempDir.path}/$name');
    file.writeAsStringSync(content);
    return file;
  }

  group('defines_files format parsing', () {
    test('parses JSON with string, number, and boolean values in order', () {
      final File jsonFile = createFile('config.json', '''
{
  "API_URL": "https://example.com/api",
  "TIMEOUT_MS": 5000,
  "RATIO": 3.14,
  "ENABLE_LOGS": true,
  "DRY_RUN": false
}
''');
      final outFile = File('${tempDir.path}/out.defines');
      final err = StringBuffer();
      final int code = run(<String>[
        '--output',
        outFile.path,
        jsonFile.path,
      ], errSink: err);

      expect(code, 0, reason: err.toString());
      expect(outFile.existsSync(), isTrue);
      final List<String> lines = outFile.readAsLinesSync();
      expect(lines, <String>[
        '-DAPI_URL=https://example.com/api',
        '-DTIMEOUT_MS=5000',
        '-DRATIO=3.14',
        '-DENABLE_LOGS=true',
        '-DDRY_RUN=false',
      ]);
    });

    test(
      'parses .env with trimming, no quote processing, comments and blanks',
      () {
        final File envFile = createFile(
          'config.env',
          '# This is a comment\n'
              '   # Another indented comment\n'
              '\n'
              'HOST=  example.com  \n'
              'PORT=8080\n'
              'QUOTED="hello world"\n'
              'EXTRA_EQ=foo=bar=baz\n'
              'EMPTY_VAL=\n',
        );
        final outFile = File('${tempDir.path}/out.defines');
        final err = StringBuffer();
        final int code = run(<String>[
          '--output',
          outFile.path,
          envFile.path,
        ], errSink: err);

        expect(code, 0, reason: err.toString());
        expect(outFile.existsSync(), isTrue);
        final List<String> lines = outFile.readAsLinesSync();
        expect(lines, <String>[
          '-DHOST=example.com',
          '-DPORT=8080',
          '-DQUOTED="hello world"',
          '-DEXTRA_EQ=foo=bar=baz',
          '-DEMPTY_VAL=',
        ]);
      },
    );

    test('preserves file order and list order across multiple files', () {
      final File f1 = createFile(
        'a.json',
        '{"A_KEY": "val_a", "B_KEY": "val_b"}',
      );
      final File f2 = createFile('b.env', 'C_KEY=val_c\nD_KEY=val_d\n');
      final File f3 = createFile('c.json', '{"E_KEY": 100}');

      final outFile = File('${tempDir.path}/out.defines');
      final err = StringBuffer();
      final int code = run(<String>[
        '--output',
        outFile.path,
        f1.path,
        f2.path,
        f3.path,
      ], errSink: err);

      expect(code, 0, reason: err.toString());
      expect(outFile.readAsLinesSync(), <String>[
        '-DA_KEY=val_a',
        '-DB_KEY=val_b',
        '-DC_KEY=val_c',
        '-DD_KEY=val_d',
        '-DE_KEY=100',
      ]);
    });

    test('drops excluded defines overridden by higher precedence', () {
      final File f1 = createFile(
        'first.json',
        '{"OVERRIDDEN": "val1", "KEEP_ME": "keep"}',
      );
      final File f2 = createFile(
        'second.env',
        'ALSO_OVERRIDDEN=val2\nSTAY=stay_val\n',
      );

      final outFile = File('${tempDir.path}/out.defines');
      final err = StringBuffer();
      final int code = run(<String>[
        '--output',
        outFile.path,
        '--exclude-define',
        'OVERRIDDEN=new_value',
        '--exclude-key',
        'ALSO_OVERRIDDEN',
        f1.path,
        f2.path,
      ], errSink: err);

      expect(code, 0, reason: err.toString());
      expect(outFile.readAsLinesSync(), <String>[
        '-DKEEP_ME=keep',
        '-DSTAY=stay_val',
      ]);
    });
  });

  group('defines_files refusals', () {
    test('refuses malformed JSON naming file and problem', () {
      final File jsonFile = createFile('bad.json', '{ unquoted_key: 123 }');
      final outFile = File('${tempDir.path}/out.defines');
      final err = StringBuffer();
      final int code = run(<String>[
        '--output',
        outFile.path,
        jsonFile.path,
      ], errSink: err);

      expect(code, isNot(0));
      expect(err.toString(), contains(jsonFile.path));
      expect(err.toString(), contains('malformed JSON'));
      expect(outFile.existsSync(), isFalse);
    });

    test('refuses non-object root in JSON naming file and problem', () {
      final File jsonFile = createFile('array.json', '[1, 2, 3]');
      final outFile = File('${tempDir.path}/out.defines');
      final err = StringBuffer();
      final int code = run(<String>[
        '--output',
        outFile.path,
        jsonFile.path,
      ], errSink: err);

      expect(code, isNot(0));
      expect(err.toString(), contains(jsonFile.path));
      expect(err.toString(), contains('top-level'));
      expect(outFile.existsSync(), isFalse);
    });

    test('refuses JSON value that is null, array, or object', () {
      final File nullJson = createFile('null.json', '{"KEY": null}');
      final File arrayJson = createFile('array_val.json', '{"KEY": [1, 2]}');
      final File mapJson = createFile(
        'map_val.json',
        '{"KEY": {"nested": true}}',
      );

      for (final file in <File>[nullJson, arrayJson, mapJson]) {
        final outFile = File('${tempDir.path}/out.defines');
        final err = StringBuffer();
        final int code = run(<String>[
          '--output',
          outFile.path,
          file.path,
        ], errSink: err);

        expect(code, isNot(0));
        expect(err.toString(), contains(file.path));
        expect(err.toString(), contains('KEY'));
        expect(outFile.existsSync(), isFalse);
      }
    });

    test('refuses .env line with no = naming file and problem', () {
      final File envFile = createFile(
        'missing_eq.env',
        'VALID=1\nNO_EQUALS_HERE\n',
      );
      final outFile = File('${tempDir.path}/out.defines');
      final err = StringBuffer();
      final int code = run(<String>[
        '--output',
        outFile.path,
        envFile.path,
      ], errSink: err);

      expect(code, isNot(0));
      expect(err.toString(), contains(envFile.path));
      expect(err.toString(), contains("no '='"));
      expect(outFile.existsSync(), isFalse);
    });

    test(
      'refuses key appearing twice in the same JSON file naming file and key',
      () {
        final File jsonFile = createFile(
          'dup.json',
          '{"DUPE": "first", "DUPE": "second"}',
        );
        final outFile = File('${tempDir.path}/out.defines');
        final err = StringBuffer();
        final int code = run(<String>[
          '--output',
          outFile.path,
          jsonFile.path,
        ], errSink: err);

        expect(code, isNot(0));
        expect(err.toString(), contains(jsonFile.path));
        expect(err.toString(), contains('DUPE'));
        expect(err.toString(), contains('twice'));
        expect(outFile.existsSync(), isFalse);
      },
    );

    test(
      'refuses key appearing twice in the same .env file naming file and key',
      () {
        final File envFile = createFile('dup.env', 'DUPE=first\nDUPE=second\n');
        final outFile = File('${tempDir.path}/out.defines');
        final err = StringBuffer();
        final int code = run(<String>[
          '--output',
          outFile.path,
          envFile.path,
        ], errSink: err);

        expect(code, isNot(0));
        expect(err.toString(), contains(envFile.path));
        expect(err.toString(), contains('DUPE'));
        expect(err.toString(), contains('twice'));
        expect(outFile.existsSync(), isFalse);
      },
    );

    test(
      'refuses key appearing across two files naming both files and key',
      () {
        final File f1 = createFile('f1.json', '{"SHARED_KEY": "val1"}');
        final File f2 = createFile('f2.env', 'SHARED_KEY=val2\n');
        final outFile = File('${tempDir.path}/out.defines');
        final err = StringBuffer();
        final int code = run(<String>[
          '--output',
          outFile.path,
          f1.path,
          f2.path,
        ], errSink: err);

        expect(code, isNot(0));
        expect(err.toString(), contains(f1.path));
        expect(err.toString(), contains(f2.path));
        expect(err.toString(), contains('SHARED_KEY'));
        expect(outFile.existsSync(), isFalse);
      },
    );

    test('refuses empty key naming file', () {
      final File emptyJsonKey = createFile('empty_key.json', '{"": "val"}');
      final File emptyEnvKey = createFile('empty_key.env', '=val\n');

      for (final file in <File>[emptyJsonKey, emptyEnvKey]) {
        final outFile = File('${tempDir.path}/out.defines');
        final err = StringBuffer();
        final int code = run(<String>[
          '--output',
          outFile.path,
          file.path,
        ], errSink: err);

        expect(code, isNot(0));
        expect(err.toString(), contains(file.path));
        expect(err.toString(), contains('empty'));
        expect(outFile.existsSync(), isFalse);
      }
    });

    test(
      'refuses key with characters outside [A-Za-z0-9_.] naming file and key',
      () {
        final File badJson = createFile(
          'bad_key.json',
          '{"INVALID-KEY": "val"}',
        );
        final File badEnv = createFile('bad_key.env', 'BAD KEY=val\n');

        for (final file in <File>[badJson, badEnv]) {
          final outFile = File('${tempDir.path}/out.defines');
          final err = StringBuffer();
          final int code = run(<String>[
            '--output',
            outFile.path,
            file.path,
          ], errSink: err);

          expect(code, isNot(0));
          expect(err.toString(), contains(file.path));
          expect(err.toString(), contains('invalid characters'));
          expect(outFile.existsSync(), isFalse);
        }
      },
    );

    test('refuses reserved keys naming file and key', () {
      final reserved = <String>[
        'dart.vm.product',
        'dart.vm',
        'dart.library.io',
        'dart.tool.runner',
        'flutter.inspector',
      ];

      for (final key in reserved) {
        final File file = createFile('reserved_$key.json', '{"$key": "val"}');
        final outFile = File('${tempDir.path}/out.defines');
        final err = StringBuffer();
        final int code = run(<String>[
          '--output',
          outFile.path,
          file.path,
        ], errSink: err);

        expect(code, isNot(0));
        expect(err.toString(), contains(file.path));
        expect(err.toString(), contains(key));
        expect(err.toString(), contains('reserved'));
        expect(outFile.existsSync(), isFalse);
      }
    });

    test('refuses value containing newline naming file and key', () {
      final File file = createFile(
        'newline.json',
        r'{"MULTILINE": "first\nsecond"}',
      );
      final outFile = File('${tempDir.path}/out.defines');
      final err = StringBuffer();
      final int code = run(<String>[
        '--output',
        outFile.path,
        file.path,
      ], errSink: err);

      expect(code, isNot(0));
      expect(err.toString(), contains(file.path));
      expect(err.toString(), contains('MULTILINE'));
      expect(err.toString(), contains('newline'));
      expect(outFile.existsSync(), isFalse);
    });

    test(
      'leaves no partial output if failure occurs after partial processing',
      () {
        final File good = createFile('1_good.json', '{"GOOD": "val"}');
        final File bad = createFile('2_bad.json', '{bad_json}');
        final outFile = File('${tempDir.path}/out.defines');
        outFile.writeAsStringSync('previous-content');

        final err = StringBuffer();
        final int code = run(<String>[
          '--output',
          outFile.path,
          good.path,
          bad.path,
        ], errSink: err);

        expect(code, isNot(0));
        expect(outFile.existsSync(), isFalse);
      },
    );
  });
}
