import 'package:perf/src/ledger.dart';
import 'package:perf/src/table.dart';
import 'package:test/test.dart';

Row _r(
  String id,
  List<double> runs, {
  bool noisy = false,
  Map<String, int> m = const {},
  String status = 'ok',
}) => Row(
  date: '',
  tool: 'rules_dart',
  sdk: '',
  corpus: '',
  flow: '',
  state: '',
  id: id,
  unit: id.startsWith('actions') ? 'actions' : 's',
  runs: runs,
  notes: '',
  noisy: noisy,
  mnemonics: m,
  status: status,
);

void main() {
  test('the table shows medians, ranges, ratios, exponents and noise', () {
    final md = planTable([
      _r('analysis.deep2000.rules', [2, 2, 2, 2, 2]),
      _r('analysis.deep2000.aspects', [4, 4, 4, 4, 4]),
      _r('analysis.deep5000.rules', [5, 5, 5, 5, 5]),
      _r('analysis.deep5000.aspects', [10, 10, 10, 10, 10], noisy: true),
      _r('dart.body.small.rules', [0.2, 0.1, 0.3, 0.15, 0.12]),
      _r(
        'android.dart.rules',
        [1],
        m: {'DartKernel': 1, 'RdfApk': 1, 'KotlinCompile (cached)': 3},
      ),
      _r('ios.sim_edit.rules', [], status: 'not_available'),
      _r('actions_per_source.test.rules', [0, 0, 0, 0, 0]),
    ]);
    expect(
      md,
      contains(
        '2.00 s (2.00–2.00, n=5) / 4.00 s (4.00–4.00, n=5); ratio 2.00x',
      ),
    );
    expect(md, contains('rules only 1.00, with aspects 1.00 *'));
    expect(md, contains('| 0.150 s (0.100–0.300, n=5) |'));
    expect(md, contains('none (ran: DartKernel, RdfApk)'));
    expect(md, isNot(contains('KotlinCompile')));
    expect(md, contains('0.000 actions'));
    expect(md, contains('not run'));
  });
}
