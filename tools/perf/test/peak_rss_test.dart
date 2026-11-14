/// Tests for the peak resident-set sampler.
library;

import 'dart:io';

import 'package:perf/peak_rss.dart';
import 'package:perf/proc.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

ProcStat _proc(int pid, int ppid, int rssPages) => ProcStat(
  pid: pid,
  ppid: ppid,
  utime: 0,
  stime: 0,
  cutime: 0,
  cstime: 0,
  starttime: 1,
  rssPages: rssPages,
);

/// Server 100, workers 200 and 201, grandchild 300 and unrelated 999.
Map<int, ProcStat> _table({
  int server = 100,
  int workerA = 50,
  int workerB = 40,
  int grandchild = 10,
  bool workerBAlive = true,
}) => {
  100: _proc(100, 1, server),
  200: _proc(200, 100, workerA),
  if (workerBAlive) 201: _proc(201, 100, workerB),
  300: _proc(300, 200, grandchild),
  999: _proc(999, 1, 100000),
};

/// A reader whose table is replaced between samples.
final class _SequenceReader implements ProcReader {
  _SequenceReader(this.tables);

  final List<Map<int, ProcStat>> tables;
  int reads = 0;

  @override
  int get pageSizeBytes => 4096;

  @override
  int get clockTicksPerSecond => 100;

  @override
  Map<int, ProcStat> readAllProcesses() {
    final index = reads++;
    return tables[index < tables.length ? index : tables.length - 1];
  }
}

PeakRssSampler _sampler(ProcReader reader, {bool includeRoot = true}) =>
    PeakRssSampler(
      reader: reader,
      rootPid: 100,
      clock: () => Duration.zero,
      includeRoot: includeRoot,
    );

void _testPeakIsMaximumOfSums() {
  final sampler = _sampler(
    _SequenceReader([
      _table(),
      _table(server: 300, workerA: 200),
      _table(workerBAlive: false),
      _table(server: 20, workerA: 20, workerB: 20, grandchild: 20),
    ]),
  );
  _check(sampler.sample() == (100 + 50 + 40 + 10) * 4096, 'first sum');
  _check(sampler.sample() == (300 + 200 + 40 + 10) * 4096, 'second sum');
  _check(sampler.sample() == (100 + 50 + 10) * 4096, 'vanished worker adds 0');
  sampler.sample();
  _check(sampler.peakBytes == 550 * 4096, 'peak is the largest sum');
  _check(sampler.peakMib == 550 * 4096 / (1024 * 1024), 'peak in MiB');
  _check(sampler.sampleCount == 4, 'four samples');
}

void _testUnrelatedProcessExcluded() {
  final sampler = _sampler(FakeProcReader(_table()))..sample();
  _check(sampler.peakBytes == 200 * 4096, 'unrelated pid 999 is not summed');
  final withoutRoot = _sampler(FakeProcReader(_table()), includeRoot: false)
    ..sample();
  _check(withoutRoot.peakBytes == 100 * 4096, 'includeRoot false skips root');
  final scaled = _sampler(FakeProcReader(_table(), pageSizeBytes: 65536))
    ..sample();
  _check(scaled.peakBytes == 200 * 65536, 'page size scales the sum');
}

void _testIntervalLimit() {
  for (final bad in [
    const Duration(milliseconds: 600),
    Duration.zero,
    const Duration(milliseconds: 501),
  ]) {
    try {
      PeakRssSampler(
        reader: FakeProcReader(const {}),
        rootPid: 1,
        clock: () => Duration.zero,
        interval: bad,
      );
    } on ArgumentError {
      continue;
    }
    throw StateError('FAIL: interval $bad was accepted');
  }
  PeakRssSampler(
    reader: FakeProcReader(const {}),
    rootPid: 1,
    clock: () => Duration.zero,
    interval: const Duration(milliseconds: 500),
  );
}

void _testSamplingCadenceAndFinalSample() {
  var now = Duration.zero;
  final sampler = PeakRssSampler(
    reader: _SequenceReader([
      _table(),
      _table(server: 1000),
      _table(server: 5000),
    ]),
    rootPid: 100,
    clock: () => now,
    interval: const Duration(milliseconds: 200),
  );
  _check(sampler.sampleIfDue(), 'first call samples');
  now = const Duration(milliseconds: 100);
  _check(!sampler.sampleIfDue(), 'not due after 100 ms');
  now = const Duration(milliseconds: 200);
  _check(sampler.sampleIfDue(), 'due after 200 ms');
  _check(sampler.sampleCount == 2, 'two timed samples');
  sampler.stop();
  _check(sampler.sampleCount == 3, 'stop takes the final sample');
  _check(sampler.peakBytes == (5000 + 100) * 4096, 'final sample counts');
}

/// The sampler runs while the calling isolate blocks inside a synchronous call.
/// Needs a real `/proc`, so it runs on Linux only.
void _testSamplesWhileBlocked() {
  if (!Platform.isLinux) {
    stdout.writeln('skip _testSamplesWhileBlocked: needs /proc (Linux only)');
    return;
  }
  final result = measurePeakRss(
    () => Process.runSync('sh', ['-c', 'sleep 0.6']).exitCode,
    reader: const LinuxProcReader(),
    rootPid: pid,
    includeRoot: false,
  );
  _check(result.value == 0, 'body result is returned');
  final peak = result.peakMb;
  _check(peak != null && peak > 0, 'the blocked call was sampled: $peak');
}

/// Without `/proc` the peak is absent, never 0; the body still runs.
void _testAbsentWithoutProc() {
  final reason = peakRssUnavailableReason(const LinuxProcReader());
  _check(
    (reason == null) == Platform.isLinux,
    'unavailable reason matches the host: $reason',
  );
  _check(
    peakRssUnavailableReason(FakeProcReader(const {})) == null,
    'a fake table is always readable',
  );
  if (Platform.isLinux) return;
  final result = measurePeakRss(
    () => 7,
    reader: const LinuxProcReader(),
    rootPid: pid,
  );
  _check(result.value == 7, 'body runs without /proc');
  _check(result.peakMb == null, 'peak is null, not 0, without /proc');
}

void main() {
  _testPeakIsMaximumOfSums();
  _testUnrelatedProcessExcluded();
  _testIntervalLimit();
  _testSamplingCadenceAndFinalSample();
  _testSamplesWhileBlocked();
  _testAbsentWithoutProc();
  stdout.writeln('All peak_rss tests passed.');
}
