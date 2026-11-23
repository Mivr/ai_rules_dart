/// Tests for the paired `link_modules` off/on summary of `summarize`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:perf/result_writer.dart';
import 'package:perf/summarize_cli.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

FlowResult _flow(String key, double peak, FlowExtras extras) => FlowResult(
  method: key == 'dart-app-clean' ? 'batch' : 'warm-server',
  bazelCpu: 10,
  solCpu: 2,
  identical: true,
  reason: 'ok',
  chain: buildChainObject(identical: true, solCpu: 2, reason: 'ok'),
  workerSteps: const {},
).withMeasure(peak, extras);

/// One repeat; [check] set means the arm opted in to link_modules.
RepeatResult _repeat(
  int index, {
  required double wall,
  required double peak,
  double? check,
  String out = 'Result: 3\n',
}) => RepeatResult(
  repeatIndex: index,
  flows: {
    for (final key in expectedFlowKeys)
      key: _flow(
        key,
        peak,
        FlowExtras(
          wallSeconds: wall,
          linkCheckWallSeconds: check,
          linked: check == null ? null : key != 'dart-test-leaf',
          appStdout: key == 'dart-app-clean' ? out : null,
        ),
      ),
  },
);

void _testPairedRatios() {
  final off = [
    _repeat(1, wall: 10, peak: 1000),
    _repeat(2, wall: 20, peak: 1000),
  ];
  final on = [
    _repeat(1, wall: 5, peak: 1200, check: 0.5),
    _repeat(2, wall: 20, peak: 1400, check: 0.7),
  ];
  final clean = pairArms(off, on).first;
  _check(clean.key == 'dart-app-clean', 'pairs follow expectedFlowKeys');
  // Geomean of 0.5 and 1.0 is sqrt(0.5); the median of 1.2 and 1.4 is 1.3.
  _check((clean.wallRatio! - 0.7071067811865476).abs() < 1e-9, 'geomean wall');
  _check((clean.peakRatio! - 1.3).abs() < 1e-9, 'median peak ratio');
  _check(clean.off.wall == 15 && clean.on.wall == 12.5, 'arm medians');
  _check((clean.on.linkCheck! - 0.6).abs() < 1e-9, 'link check median');
  final swapped = pairArms(off.reversed.toList(), on);
  _check(swapped.first.wallRatio == clean.wallRatio, 'pairs by repeat index');
  _check(abFailures(off, on).isEmpty, 'a clean pair has no failures');
  final table = formatAbTable(pairArms(off, on));
  _check(table.contains('| dart-app-clean | 0.707 | 1.300 |'), 'table row');
}

void _testPairRejections() {
  final off = [_repeat(1, wall: 10, peak: 1000)];
  final on = [_repeat(1, wall: 5, peak: 1200, check: 0.5)];
  _check(
    abFailures(off, [
      _repeat(2, wall: 5, peak: 1, check: 0.5),
    ]).any((f) => f.contains('different repeats')),
    'different repeat sets are rejected',
  );
  _check(
    abFailures(off, [
      _repeat(1, wall: 5, peak: 1, check: 0.5, out: 'x'),
    ]).any((f) => f.contains('stdout differs')),
    'differing stdout is rejected',
  );
  _check(
    abFailures(on, off).length == 2,
    'swapped arms are rejected (off carries link data, on has none)',
  );
}

void _writeRepeats(String dir, List<RepeatResult> repeats) {
  Directory(dir).createSync(recursive: true);
  for (final r in repeats) {
    File('$dir/repeat-${r.repeatIndex}.json')
        .writeAsStringSync(jsonEncode(r.toJson()));
  }
}

int _summarize(Directory root, List<String> extra) => runSummarizeCli([
  '--results-dir=${root.path}/off',
  '--sha=0123456789abcdef0123456789abcdef01234567',
  '--target-loc=1000',
  '--seed=1',
  '--repeats=2',
  '--out=${root.path}/dart-sol-off.json',
  '--on-results-dir=${root.path}/on',
  '--on-out=${root.path}/dart-sol-on.json',
  '--ab-report=${root.path}/ab.md',
  ...extra,
]);

void _testSummarizeAb() {
  final root = Directory.systemTemp.createTempSync('rd_ab_summary_');
  try {
    _writeRepeats('${root.path}/off', [
      _repeat(1, wall: 10, peak: 1000),
      _repeat(2, wall: 20, peak: 1000),
    ]);
    _writeRepeats('${root.path}/on', [
      _repeat(1, wall: 5, peak: 1200, check: 0.5),
      _repeat(2, wall: 20, peak: 1400, check: 0.7),
    ]);
    _check(_summarize(root, []) == 0, 'a paired run exits 0');
    for (final name in ['dart-sol-off.json', 'dart-sol-on.json', 'ab.md']) {
      _check(File('${root.path}/$name').existsSync(), '$name is written');
    }
    _check(
      File('${root.path}/ab.md').readAsStringSync().contains('| 0.707 |'),
      'the report carries the paired ratio',
    );
    _writeRepeats('${root.path}/on', [
      _repeat(1, wall: 5, peak: 1200, check: 0.5, out: 'Result: 4\n'),
      _repeat(2, wall: 20, peak: 1400, check: 0.7),
    ]);
    _check(_summarize(root, []) == 1, 'differing app stdout exits 1');
    _check(
      _summarize(root, ['--on-out=']) == 1,
      'an incomplete A/B flag set exits 1',
    );
  } finally {
    root.deleteSync(recursive: true);
  }
}

void main() {
  _testPairedRatios();
  _testPairRejections();
  _testSummarizeAb();
  stdout.writeln('All ab_summary tests passed.');
}
