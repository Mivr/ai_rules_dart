/// Peak resident set of a process tree, sampled while a Bazel command runs.
library;

import 'dart:io';
import 'dart:isolate';

import 'proc.dart';

/// The longest sampling interval; a larger one could miss a short peak.
const Duration maxPeakRssInterval = Duration(milliseconds: 500);

/// The interval the benches sample at.
const Duration defaultPeakRssInterval = Duration(milliseconds: 200);

const double _bytesPerMib = 1024 * 1024;

/// A monotonic clock, as the time elapsed since some fixed start.
typedef PeakClock = Duration Function();

/// Sums the resident set of a root process and its descendants per sample.
///
/// [sample] reads `/proc` once; [sampleIfDue] does so only when the interval
/// has passed on the clock. [peakBytes] is the largest sum seen. A process
/// that is absent from a sample adds nothing to that sample's sum.
final class PeakRssSampler {
  /// Creates a sampler of the tree under [rootPid].
  ///
  /// Throws [ArgumentError] when [interval] is not positive or exceeds
  /// [maxPeakRssInterval]. With [includeRoot] false only the descendants of
  /// [rootPid] are summed (use it when the root is the sampling process).
  PeakRssSampler({
    required this.reader,
    required this.rootPid,
    required this.clock,
    this.interval = defaultPeakRssInterval,
    this.includeRoot = true,
  }) {
    if (interval <= Duration.zero || interval > maxPeakRssInterval) {
      throw ArgumentError.value(
        interval,
        'interval',
        'must be positive and at most $maxPeakRssInterval',
      );
    }
  }

  /// Source of process statistics.
  final ProcReader reader;

  /// Root of the sampled tree.
  final int rootPid;

  /// Clock deciding when [sampleIfDue] samples.
  final PeakClock clock;

  /// Time between samples taken by [sampleIfDue].
  final Duration interval;

  /// Whether the root's own resident set counts.
  final bool includeRoot;

  int _peakBytes = 0;
  int _samples = 0;
  Duration? _lastSample;

  /// The largest summed resident set seen, in bytes.
  int get peakBytes => _peakBytes;

  /// The largest summed resident set seen, in MiB.
  double get peakMib => _peakBytes / _bytesPerMib;

  /// How many samples were taken.
  int get sampleCount => _samples;

  /// Takes one sample and returns the summed resident bytes.
  int sample() {
    final procs = reader.readAllProcesses();
    var pages = 0;
    for (final pid in _treeOf(procs)) {
      pages += procs[pid]?.rssPages ?? 0;
    }
    final bytes = pages * reader.pageSizeBytes;
    if (bytes > _peakBytes) _peakBytes = bytes;
    _samples++;
    _lastSample = clock();
    return bytes;
  }

  /// Takes a sample when none was taken in the last [interval]; returns
  /// whether it did.
  bool sampleIfDue() {
    final last = _lastSample;
    if (last != null && clock() - last < interval) return false;
    sample();
    return true;
  }

  /// Takes the final sample.
  void stop() {
    sample();
  }

  Set<int> _treeOf(Map<int, ProcStat> procs) {
    final children = <int, List<int>>{};
    for (final p in procs.values) {
      children.putIfAbsent(p.ppid, () => <int>[]).add(p.pid);
    }
    final tree = <int>{if (includeRoot) rootPid};
    final queue = <int>[rootPid];
    while (queue.isNotEmpty) {
      for (final child in children[queue.removeLast()] ?? const <int>[]) {
        if (child != rootPid && tree.add(child)) queue.add(child);
      }
    }
    return tree;
  }
}

/// What the sampling isolate needs; all of it can cross an isolate boundary.
final class _SamplerJob {
  const _SamplerJob({
    required this.reader,
    required this.rootPid,
    required this.interval,
    required this.includeRoot,
    required this.directory,
  });

  final ProcReader reader;
  final int rootPid;
  final Duration interval;
  final bool includeRoot;
  final String directory;

  String get stopFile => '$directory/stop';
  String get resultFile => '$directory/result';
}

void _writeResult(_SamplerJob job, String content) {
  final tmp = File('${job.resultFile}.tmp')..writeAsStringSync(content);
  tmp.renameSync(job.resultFile);
}

/// Isolate entry: samples until the stop file appears, then writes the peak.
void _sampleUntilStopped(_SamplerJob job) {
  final watch = Stopwatch()..start();
  try {
    final sampler = PeakRssSampler(
      reader: job.reader,
      rootPid: job.rootPid,
      clock: () => watch.elapsed,
      interval: job.interval,
      includeRoot: job.includeRoot,
    );
    while (!File(job.stopFile).existsSync()) {
      sampler.sampleIfDue();
      sleep(const Duration(milliseconds: 10));
    }
    sampler.stop();
    _writeResult(job, 'ok ${sampler.peakBytes}');
  } on Object catch (e) {
    _writeResult(job, 'error $e');
  }
}

/// A sampler running beside a blocking call, in its own isolate.
///
/// The caller stays synchronous: [start] returns at once, the isolate samples
/// until [stop], which waits for the final sample and returns the peak. The
/// sampling never depends on the blocking call returning.
final class PeakRssRun {
  PeakRssRun._(this._job);

  final _SamplerJob _job;
  Object? _spawnError;

  /// Starts sampling the tree under [rootPid].
  static PeakRssRun start({
    required ProcReader reader,
    required int rootPid,
    Duration interval = defaultPeakRssInterval,
    bool includeRoot = true,
  }) {
    // Validates the interval before an isolate is spawned.
    PeakRssSampler(
      reader: reader,
      rootPid: rootPid,
      clock: () => Duration.zero,
      interval: interval,
    );
    final dir = Directory.systemTemp.createTempSync('peak_rss_');
    final run = PeakRssRun._(
      _SamplerJob(
        reader: reader,
        rootPid: rootPid,
        interval: interval,
        includeRoot: includeRoot,
        directory: dir.path,
      ),
    );
    Isolate.spawn(_sampleUntilStopped, run._job).then<void>(
      (_) {},
      onError: (Object e) {
        run._spawnError = e;
      },
    );
    return run;
  }

  /// Stops sampling and returns the peak summed resident set in MiB.
  ///
  /// Throws [StateError] when the sampler did not start, failed or did not
  /// report within [timeout].
  double stop({Duration timeout = const Duration(seconds: 30)}) {
    File(_job.stopFile).writeAsStringSync('');
    final result = File(_job.resultFile);
    final watch = Stopwatch()..start();
    try {
      while (!result.existsSync()) {
        final spawnError = _spawnError;
        if (spawnError != null) {
          throw StateError('peak RSS sampler failed to start: $spawnError');
        }
        if (watch.elapsed > timeout) {
          throw StateError('peak RSS sampler did not report in $timeout');
        }
        sleep(const Duration(milliseconds: 5));
      }
      final fields = result.readAsStringSync().split(' ');
      if (fields.first != 'ok') {
        throw StateError(
          'peak RSS sampler failed: ${fields.skip(1).join(' ')}',
        );
      }
      return int.parse(fields[1]) / _bytesPerMib;
    } finally {
      Directory(_job.directory).deleteSync(recursive: true);
    }
  }
}

/// Runs [body] while sampling the tree under [rootPid]; returns its value and
/// the peak summed resident set in MiB.
///
/// A body that throws still stops the sampler; its error is rethrown.
({T value, double peakMb}) measurePeakRss<T>(
  T Function() body, {
  required ProcReader reader,
  required int rootPid,
  bool includeRoot = true,
}) {
  final run = PeakRssRun.start(
    reader: reader,
    rootPid: rootPid,
    includeRoot: includeRoot,
  );
  final T value;
  try {
    value = body();
  } on Object {
    try {
      run.stop();
    } on StateError catch (e) {
      stderr.writeln('peak RSS sampler stop after a failed command: $e');
    }
    rethrow;
  }
  return (value: value, peakMb: run.stop());
}
