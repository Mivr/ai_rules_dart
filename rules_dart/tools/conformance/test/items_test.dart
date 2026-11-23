import 'package:conformance/compare.dart';
import 'package:conformance/items.dart';
import 'package:conformance/normalise.dart';
import 'package:conformance/records.dart';
import 'package:test/test.dart';

void main() {
  group('testItems', () {
    test('drops passing hidden tests and makes suites relative', () {
      final applied = Applied();
      final Items items = testItems(
        const [
          TestRecord(
            '/w/stock/p/src/test/a_test.dart',
            'loading',
            'hidden:success',
          ),
          TestRecord('/w/stock/p/src/test/a_test.dart', 'adds', 'success'),
          TestRecord('test/b_test.dart', 'x', 'failure'),
        ],
        ['/w/stock/p/src'],
        applied,
      );
      expect(items.keys, [
        'test:test/a_test.dart :: adds',
        'test:test/b_test.dart :: x',
      ]);
      expect(items['test:test/b_test.dart :: x']!.digest, 'failure');
      expect(applied.counts, {'hidden-loading-tests': 1, 'relative-paths': 1});
    });

    test('keeps a failing hidden test, and numbers repeated names', () {
      final Items items = testItems(
        const [
          TestRecord('t.dart', 'loading t.dart', 'hidden:error'),
          TestRecord('t.dart', 'same', 'success'),
          TestRecord('t.dart', 'same', 'failure'),
        ],
        const [],
        Applied(),
      );
      expect(items.keys, [
        'test:t.dart :: loading t.dart',
        'test:t.dart :: same',
        'test:t.dart :: same #2',
      ]);
      expect(items['test:t.dart :: loading t.dart']!.digest, 'error');
    });
  });

  group('analysisItems', () {
    test('one item per analyzed file, clean or with its diagnostics', () {
      final Items items = analysisItems(
        ['/c/lib/a.dart', '/c/lib/b.dart'],
        const [
          Diagnostic(file: 'lib/b.dart', line: 3, severity: 'info', code: 'z'),
          Diagnostic(file: 'lib/b.dart', line: 1, severity: 'error', code: 'a'),
          Diagnostic(file: 'lib/c.dart', line: 1, severity: 'info', code: 'q'),
          Diagnostic(file: 'lib/c.dart', line: 1, severity: 'info', code: 'q'),
        ],
        ['/c'],
        Applied(),
      );
      expect(
        {for (final e in items.entries) e.key: e.value.digest},
        {
          'file:lib/a.dart': 'clean',
          'file:lib/b.dart': 'error a, info z',
          'file:lib/c.dart': 'info q',
        },
      );
    });
  });

  test('exeItems keys runs by their arguments', () {
    final Items items = exeItems(const [
      ExeRun(['1 + 2'], ' = 3\n', '', 0),
      ExeRun(['1 +'], '', 'bad\n', 1),
    ]);
    expect(items.keys, ['run:1 + 2', 'run:1 +']);
    expect(items['run:1 +']!.note, contains('exit 1'));
    expect(
      items['run:1 + 2']!.digest,
      isNot(
        exeItems(const [
          ExeRun(['1 + 2'], ' = 4\n', '', 0),
        ])['run:1 + 2']!.digest,
      ),
    );
  });
}
