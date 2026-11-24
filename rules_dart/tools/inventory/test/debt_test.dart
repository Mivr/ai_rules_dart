import 'package:inventory/debt.dart';
import 'package:inventory/finding.dart';
import 'package:test/test.dart';

Finding _finding(String file, String key, [int line = 1]) =>
    Finding(rule: 'r', file: file, line: line, message: 'm', key: key);

void main() {
  test('the rendered list parses back and is sorted', () {
    final List<DebtEntry> entries = debtFor([
      _finding('b.bzl', 'x'),
      _finding('a.bzl', 'y'),
      _finding('a.bzl', 'y', 5),
    ]);
    final String json = renderDebt(entries);
    expect(json.indexOf('a.bzl'), lessThan(json.indexOf('b.bzl')));
    expect(parseDebt(json).toSet(), entries.toSet());
    expect(parseDebt(json).firstWhere((e) => e.file == 'a.bzl').count, 2);
  });

  test('a moved violation is still covered, an added one is new', () {
    final List<DebtEntry> debt = debtFor([_finding('a.bzl', 'x', 3)]);
    final DebtReport report = applyDebt([
      _finding('a.bzl', 'x', 40),
      _finding('a.bzl', 'z', 41),
    ], debt);
    expect(report.covered, 1);
    expect(report.fresh.single.key, 'z');
    expect(report.stale, isEmpty);
  });

  test('an entry that matches nothing is reported as stale', () {
    final List<DebtEntry> debt = debtFor([
      _finding('a.bzl', 'x'),
      _finding('a.bzl', 'x'),
    ]);
    final DebtReport report = applyDebt([_finding('a.bzl', 'x')], debt);
    expect(report.fresh, isEmpty);
    expect(report.stale.single.count, 1);
  });

  test('an empty file is an empty list, a malformed one is refused', () {
    expect(parseDebt(''), isEmpty);
    expect(() => parseDebt('{}'), throwsFormatException);
  });
}
