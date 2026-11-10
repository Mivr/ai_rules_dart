/// Exit-code tests for the `runner` and `summarize` CLI entrypoints.
library;

import 'dart:convert';
import 'dart:io';

import 'package:perf/result_writer.dart';
import 'package:perf/runner_cli.dart';
import 'package:perf/summarize_cli.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

const _sha = '0123456789abcdef0123456789abcdef01234567';

FlowResult _flow({
  bool identical = true,
  double? sol = 1.0,
  double? bazel = 2.0,
  String reason = 'ok',
}) => FlowResult(
  method: 'warm-server',
  bazelCpu: bazel,
  solCpu: sol,
  identical: identical,
  reason: reason,
  chain: buildChainObject(identical: identical, solCpu: sol, reason: reason),
  workerSteps: const {},
);

RepeatResult _repeat(
  int index, {
  Map<String, FlowResult> override = const {},
}) => RepeatResult(
  repeatIndex: index,
  flows: {for (final k in expectedFlowKeys) k: _flow(), ...override},
);

void _writeRepeat(Directory dir, RepeatResult r) =>
    File('${dir.path}/repeat-${r.repeatIndex}.json')
        .writeAsStringSync(jsonEncode(r.toJson()));

/// Runs summarize over [repeats] files for `--repeats=[expected]`.
({int code, bool wrote}) _summarize(
  List<RepeatResult> repeats,
  String expected,
) {
  final dir = Directory.systemTemp.createTempSync('rd_sum_');
  try {
    final results = Directory('${dir.path}/results')..createSync();
    repeats.forEach((r) => _writeRepeat(results, r));
    final out = File('${dir.path}/out/dart-sol.json');
    final code = runSummarizeCli([
      '--results-dir=${results.path}',
      '--sha=$_sha',
      '--repeats=$expected',
      '--out=${out.path}',
    ]);
    return (code: code, wrote: out.existsSync());
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void _testHealthHelpers() {
  _check(isRepeatHealthy(_repeat(1)), 'all-ok repeat is healthy');
  for (final bad in [
    _flow(identical: false),
    _flow(sol: null),
    _flow(bazel: null),
    _flow(reason: 'boom'),
    _flow(reason: ''),
  ]) {
    _check(
      !isRepeatHealthy(_repeat(1, override: {'dart-app-api': bad})),
      'repeat with a bad flow is unhealthy',
    );
  }
  _check(
    !isRepeatHealthy(const RepeatResult(repeatIndex: 1, flows: {})),
    'repeat with missing flows is unhealthy',
  );
  Map<String, dynamic> summary(
    Map<String, dynamic> flow, {
    Object? repeats = 1,
  }) => {
    'meta': {'repeats': repeats},
    'flows': {for (final k in expectedFlowKeys) k: flow},
  };
  final okFlow = {'identical': true, 'sol': 1.0, 'reason': 'ok'};
  _check(isSummaryHealthy(summary(okFlow)), 'ok summary is healthy');
  _check(!isSummaryHealthy(summary(okFlow, repeats: 0)), 'repeats 0 fails');
  _check(
    !isSummaryHealthy({
      'meta': {'repeats': 1},
      'flows': {},
    }),
    'missing flows fail',
  );
  for (final bad in [
    {...okFlow, 'identical': false},
    {...okFlow, 'sol': null},
    {...okFlow, 'reason': 'x'},
    {...okFlow, 'reason': ''},
    {...okFlow, 'reason': null},
  ]) {
    _check(summaryFailures(summary(bad)).length == 4, 'bad flow reported');
  }
}

void _testSummarizeExit() {
  var r = _summarize([_repeat(1), _repeat(2)], '2');
  _check(r.code == 0 && r.wrote, 'healthy summarize writes and exits 0');
  r = _summarize([
    _repeat(1, override: {'dart-app-body': _flow(identical: false)}),
  ], '1');
  _check(r.code == 1 && r.wrote, 'identical:false writes then exits 1');
  r = _summarize([
    _repeat(1, override: {'dart-test-leaf': _flow(reason: 'bazel failed')}),
  ], '1');
  _check(r.code == 1 && r.wrote, 'non-ok reason writes then exits 1');
  r = _summarize([
    _repeat(1, override: {'dart-app-api': _flow(sol: null)}),
  ], '1');
  _check(r.code == 1 && r.wrote, 'sol:null writes then exits 1');
  r = _summarize([_repeat(1)], '3');
  _check(r.code == 1 && r.wrote, 'missing repeat files write then exit 1');
  r = _summarize([], '3');
  _check(r.code == 1 && r.wrote, 'zero repeat files write then exit 1');
  for (final bad in ['0', '-1', 'abc']) {
    r = _summarize([_repeat(1)], bad);
    _check(r.code == 1 && !r.wrote, '--repeats=$bad is refused');
  }
}

/// Runs the runner CLI with a fake executor; returns exit code and files.
({int code, List<int> written}) _runner(
  List<String> flags,
  RepeatResult Function(int index) make,
) {
  final dir = Directory.systemTemp.createTempSync('rd_run_');
  try {
    final code = runRunnerCli(
      [
        '--workspace=${dir.path}',
        ...flags.map((f) => f.replaceAll('OUT', dir.path)),
      ],
      executor: ({
        required pristineWorkspace,
        required repeatIndex,
        required tempRoot,
      }) => make(repeatIndex),
    );
    final written = [
      for (final f in dir.listSync().whereType<File>())
        if (RegExp(r'repeat-(\d+)\.json$').firstMatch(f.path) case final m?)
          int.parse(m.group(1)!),
    ]..sort();
    return (code: code, written: written);
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void _testRunnerExit() {
  var r = _runner(['--repeats=2', '--out=OUT'], _repeat);
  _check(r.code == 0 && r.written.length == 2, 'healthy runner exits 0');
  r = _runner(
    ['--repeats=3', '--out=OUT'],
    (i) => i == 1
        ? _repeat(i, override: {'dart-app-clean': _flow(identical: false)})
        : _repeat(i),
  );
  _check(r.code == 1, 'unhealthy repeat 1 exits 1');
  _check(r.written.length == 3, 'all repeats still written after a failure');
  r = _runner([
    '--repeats=2',
    '--out=OUT',
  ], (i) => _repeat(i, override: {'dart-app-body': _flow(reason: 'bad')}));
  _check(r.code == 1, 'non-ok reason exits 1');
  r = _runner(['--repeats=2', '--out=OUT'], (i) {
    if (i == 1) throw StateError('crash');
    return _repeat(i);
  });
  _check(r.code == 1 && r.written.length == 2, 'crashed repeat exits 1');
  for (final flag in [
    '--repeats=0',
    '--repeats=-1',
    '--repeat=0',
    '--repeat=-1',
  ]) {
    r = _runner([flag, '--out=OUT'], _repeat);
    _check(r.code == 1 && r.written.isEmpty, '$flag is refused');
  }
  r = _runner(['--repeat=abc', '--out=OUT'], _repeat);
  _check(r.code == 1 && r.written.isEmpty, 'non-integer repeat is refused');
  r = _runner(['--repeats=1', '--out=OUT', '--floor=on'], _repeat);
  _check(r.code == 0 && r.written.length == 1, '--floor=on exits 0');
  r = _runner(['--repeats=1', '--out=OUT', '--floor=off'], _repeat);
  _check(r.code == 0 && r.written.length == 1, '--floor=off exits 0');
  r = _runner(['--repeats=1', '--out=OUT', '--floor=maybe'], _repeat);
  _check(r.code == 1 && r.written.isEmpty, '--floor=maybe is refused');
}

void main() {
  _testHealthHelpers();
  _testSummarizeExit();
  _testRunnerExit();
  stdout.writeln('All CLI exit-code tests passed.');
}
