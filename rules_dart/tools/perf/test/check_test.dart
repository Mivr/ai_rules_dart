import 'package:perf/src/check.dart';
import 'package:perf/src/ledger.dart';
import 'package:test/test.dart';

Row _row(
  String id,
  List<double> runs, {
  bool noisy = false,
  Map<String, int> m = const {},
  String unit = 's',
  String status = 'ok',
}) => Row(
  date: '2026-11-23T00:00:00+02:00',
  tool: 'rules_dart',
  sdk: 'x',
  corpus: 'c',
  flow: 'f',
  state: 's',
  id: id,
  unit: unit,
  runs: runs,
  notes: '',
  noisy: noisy,
  status: status,
  mnemonics: m,
);

void main() {
  final base = [
    _row(
      'a',
      [1.0, 1.1, 0.9, 1.0, 1.0],
      m: {'DartKernel': 1, 'DartKernelLink': 1},
    ),
    _row('n', [9, 9, 9, 9, 9], unit: 'actions'),
  ];

  test('an unchanged flow passes, a cache hit of a known action too', () {
    final v = compareRows([
      _row(
        'a',
        [1.05, 1.0, 1.1, 1.0, 1.0],
        m: {'DartKernel (cached)': 1, 'DartKernelLink': 1},
      ),
    ], base);
    expect(v.single.pass, isTrue, reason: v.single.failures.join());
  });

  test('a flow slower than the margin fails', () {
    final v = compareRows([
      _row('a', [1.4, 1.5, 1.4, 1.3, 1.6], m: {'DartKernel': 1}),
    ], base);
    expect(v.single.pass, isFalse);
    expect(v.single.failures.single, contains('slower'));
  });

  test('a slowdown under the floor in seconds passes', () {
    final v = compareRows(
      [
        _row('t', [0.13]),
      ],
      [
        _row('t', [0.1]),
      ],
    );
    expect(v.single.pass, isTrue);
  });

  test('a new mnemonic fails', () {
    final v = compareRows([
      _row('a', [1.0], m: {'DartKernel': 1, 'DartKernelLink': 1, 'Genrule': 1}),
    ], base);
    expect(v.single.failures.single, contains('Genrule'));
  });

  test('a count that grows fails', () {
    expect(
      compareRows([
        _row('n', [10], unit: 'actions'),
      ], base).single.pass,
      isFalse,
    );
    expect(
      compareRows([
        _row('n', [9], unit: 'actions'),
      ], base).single.pass,
      isTrue,
    );
  });

  test('a noisy row is never a baseline', () {
    final v = compareRows(
      [
        _row('a', [1.0]),
      ],
      [
        _row('a', [1.0], noisy: true),
      ],
    );
    expect(v.single.failures.single, contains('no baseline'));
  });

  test('a flow that failed fails the check', () {
    expect(
      compareRows([_row('a', [], status: 'failed')], base).single.pass,
      isFalse,
    );
  });
}
