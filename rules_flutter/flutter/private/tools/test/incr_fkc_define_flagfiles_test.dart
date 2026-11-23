// Tagged `runfiles`: the worker imports `kernel_filter.dart`, which imports
// `package:rules_dart_guard`, supplied via the `@rules_dart//dart/guard`
// dep its `dart_test` declares. A bare `dart test` resolves only this
// package's pubspec, where that import does not exist.
// Coverage comes from //flutter/private/tools:incr_fkc_define_flagfiles_test.
@Tags(['runfiles'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../incr_fkc_server.dart';

void main() {
  group('expandWorkerFlagfiles', () {
    test('expands @ files in order and skips empty lines', () {
      final Directory dir = Directory.systemTemp.createTempSync(
        'incr_flagfile_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/args').writeAsStringSync('--a\n\n--b=1\n');
      expect(
        expandWorkerFlagfiles(['--x', '@${dir.path}/args', '--y']),
        ['--x', '--a', '--b=1', '--y'],
      );
    });

    test('unwraps single-quoted lines and leaves the rest literal', () {
      final Directory dir = Directory.systemTemp.createTempSync(
        'incr_flagfile_q_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      File(
        '${dir.path}/args',
      ).writeAsStringSync("'-Dname=a b'\n--c\n'a'b\n");
      expect(
        expandWorkerFlagfiles(['@${dir.path}/args']),
        ['-Dname=a b', '--c', "'a'b"],
      );
    });

    test('expands a define flagfile named by the parameter file', () {
      final Directory dir = Directory.systemTemp.createTempSync('incr_nested_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final inner = File('${dir.path}/inner.defines')
        ..writeAsStringSync('-DSECOND=two\n');
      final nested = File('${dir.path}/nested.defines')
        ..writeAsStringSync('-DFIRST=one\n@${inner.path}\n');
      File(
        '${dir.path}/args',
      ).writeAsStringSync('--sentinel\n@${nested.path}\n');
      expect(
        expandWorkerFlagfiles(['@${dir.path}/args']),
        ['--sentinel', '-DFIRST=one', '-DSECOND=two'],
      );
    });

    test('refuses a nested line that is not a define, with its number', () {
      final Directory dir = Directory.systemTemp.createTempSync(
        'incr_badline_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final bad = File('${dir.path}/bad.defines')
        ..writeAsStringSync('\n-DOK=1\nNOT_A_DEFINE\n');
      File('${dir.path}/args').writeAsStringSync('@${bad.path}\n');
      expect(
        () => expandWorkerFlagfiles(['@${dir.path}/args']),
        throwsA(
          predicate(
            (Object? error) =>
                error is FormatException &&
                error.message.contains(bad.path) &&
                error.message.contains('line 3'),
            'names the flagfile and the 1-based line',
          ),
        ),
      );
    });

    test('refuses a missing nested flagfile with the chain', () {
      final Directory dir = Directory.systemTemp.createTempSync(
        'incr_missing_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final missing = File('${dir.path}/missing.defines');
      final outer = File('${dir.path}/args')
        ..writeAsStringSync('@${missing.path}\n');
      expect(
        () => expandWorkerFlagfiles(['@${outer.path}']),
        throwsA(
          predicate(
            (Object? error) =>
                error is FormatException &&
                error.message.contains(outer.path) &&
                error.message.contains(missing.path),
            'names the chain of files',
          ),
        ),
      );
    });

    test('refuses an unreadable nested flagfile with the chain', () {
      final Directory dir = Directory.systemTemp.createTempSync(
        'incr_unreadable_',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final outer = '${dir.path}/args';
      final secret = '${dir.path}/secret.defines';
      expect(
        () => expandWorkerFlagfiles(
          ['@$outer'],
          readFile: (path) {
            if (path == secret) {
              throw FileSystemException('denied', path);
            }
            return ['@$secret'];
          },
        ),
        throwsA(
          predicate(
            (Object? error) =>
                error is FormatException &&
                error.message.contains(outer) &&
                error.message.contains(secret) &&
                error.message.contains('denied'),
            'names the chain of files',
          ),
        ),
      );
    });

    test('refuses a nested cycle with the chain', () {
      final Directory dir = Directory.systemTemp.createTempSync('incr_cycle_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final first = File('${dir.path}/first.defines')
        ..writeAsStringSync('@${dir.path}/second.defines\n');
      final second = File('${dir.path}/second.defines')
        ..writeAsStringSync('@${dir.path}/first.defines\n');
      File('${dir.path}/args').writeAsStringSync('@${first.path}\n');
      expect(
        () => expandWorkerFlagfiles(['@${dir.path}/args']),
        throwsA(
          predicate(
            (Object? error) =>
                error is FormatException &&
                error.message.contains('cycle') &&
                error.message.contains(first.path) &&
                error.message.contains(second.path),
            'names the cycle chain',
          ),
        ),
      );
    });
  });
}
