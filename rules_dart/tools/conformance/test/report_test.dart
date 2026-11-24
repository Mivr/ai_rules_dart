import 'dart:convert';
import 'dart:io';

import 'package:conformance/by_design.dart';
import 'package:conformance/compare.dart';
import 'package:conformance/layout.dart';
import 'package:conformance/records.dart';
import 'package:conformance/report.dart';
import 'package:test/test.dart';

void main() {
  late Directory work;
  setUp(() => work = Directory.systemTemp.createTempSync('report_test'));
  tearDown(() => work.deleteSync(recursive: true));

  void writeTests(Side side, List<TestRecord> records, {bool built = true}) {
    final dir = KindDir(work.path, side, 'p', Kind.tests)..reset();
    dir.writeStatus(Status(built: built, reason: built ? null : 'no build'));
    writeJson(dir.tests, [for (final r in records) r.toJson()]);
  }

  List<TestRecord> cases(String Function(int) result) => [
    for (var i = 0; i < 20; i++)
      TestRecord(
        '${work.path}/stock/p/src/test/a_test.dart',
        'case $i',
        result(i),
      ),
  ];

  KindResult compare(List<ByDesignEntry> list, Set<ByDesignEntry> used) =>
      compareKind(
        work: work.path,
        project: 'p',
        kind: Kind.tests,
        byDesign: list,
        used: used,
      );

  test('a flipped result on one side is exactly one difference', () {
    writeTests(Side.stock, cases((_) => 'success'));
    writeTests(Side.rules, [
      for (final r in cases((i) => i == 4 ? 'failure' : 'success'))
        TestRecord('test/a_test.dart', r.name, r.result),
    ]);
    final KindResult r = compare(const [], {});
    expect(r.compared, 20);
    expect(r.equal, 19);
    expect(
      [for (final d in r.differences) d.item],
      ['test:test/a_test.dart :: case 4'],
    );
    expect(r.differences.single.detail, 'stock success, rules failure');
    expect(r.applied['relative-paths'], 20);
  });

  test('the same layout compares the same twice', () {
    writeTests(Side.stock, cases((i) => i.isEven ? 'success' : 'failure'));
    writeTests(Side.rules, cases((i) => i % 3 == 0 ? 'success' : 'failure'));
    String render() {
      final r = compare(const [], {});
      return '${scoreTable([r])}\n${jsonEncode(jsonReport([r]))}';
    }

    expect(render(), render());
  });

  test('a side that did not build is not compared, with its reason', () {
    writeTests(Side.stock, cases((_) => 'success'));
    writeTests(Side.rules, const [], built: false);
    final KindResult r = compare(const [], {});
    expect(r.notCompared, 'rules: no build');
    expect(r.score, isNull);
    final List<Map<String, Object?>> rows = ledgerRows(
      [r],
      date: '2026-11-23',
      commit: 'abc',
      next: 'def',
    );
    expect(rows.single, containsPair('built_rules', false));
    expect(rows.single, containsPair('parity', null));
    expect(rows.single, containsPair('not_compared', 'rules: no build'));
  });

  test('by-design differences count as matching in the score', () {
    writeTests(Side.stock, cases((_) => 'success'));
    writeTests(Side.rules, [
      for (final r in cases((i) => i < 2 ? 'skipped' : 'success'))
        TestRecord('test/a_test.dart', r.name, r.result),
    ]);
    final List<ByDesignEntry> list = parseByDesign(
      '{"entries": [{"kinds": ["tests"], "item": "test:*case 0", '
      '"reason": "skipped under Bazel"}]}',
    );
    final used = <ByDesignEntry>{};
    final KindResult r = compare(list, used);
    expect(r.byDesign, 1);
    expect(r.counted, 1);
    expect(r.score, closeTo(19 / 20, 1e-9));
    expect(used, hasLength(1));
    final String text = textReport([r], const []);
    expect(text, contains('1 x test: differs'));
    expect(text, contains('1 x by design: test: differs'));
  });

  test('scoreTable aligns its columns', () {
    final String table = scoreTable([
      KindResult(
        project: 'counter',
        kind: Kind.web,
        stock: Status(built: true),
        rules: Status(built: true),
        compared: 40,
        equal: 30,
      ),
      KindResult(
        project: 'large',
        kind: Kind.linux,
        stock: Status(built: false),
        rules: null,
        notCompared: 'x',
      ),
    ]);
    final List<String> lines = table.split('\n');
    expect(lines, hasLength(3));
    expect(lines[1], startsWith('counter  web    yes    yes    40'));
    expect(lines[1], endsWith('75.0%'));
    expect(lines[2], endsWith('n/a'));
  });
}
