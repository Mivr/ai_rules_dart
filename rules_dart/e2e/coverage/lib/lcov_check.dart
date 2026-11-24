/// Checks one source file's records in a combined LCOV report.
///
/// "Collected nothing, reported 100%" is the failure this exists to catch, so
/// every expectation demands a record: an absent one is a failure, never a
/// skip. [checkLcov] returns one message per failed assertion, each naming the
/// assertion and what it expected; an empty list means the report passed.
library;

/// What a report must say about one source file.
class LcovExpectation {
  LcovExpectation({
    required this.file,
    required this.executed,
    required this.unexecuted,
    required this.uncalled,
  });

  /// Parses `--file=`, `--executed=`, `--unexecuted=` and `--uncalled=`
  /// arguments; the last three repeat. Throws [FormatException] on anything
  /// else or when no file is named.
  factory LcovExpectation.parse(Iterable<String> args) {
    String? file;
    final List<int> executed = <int>[];
    final List<int> unexecuted = <int>[];
    final List<String> uncalled = <String>[];
    for (final String arg in args) {
      final int eq = arg.indexOf('=');
      final String key = eq < 0 ? arg : arg.substring(0, eq);
      final String value = eq < 0 ? '' : arg.substring(eq + 1);
      switch (key) {
        case '--file':
          file = value;
        case '--executed':
          executed.add(int.parse(value));
        case '--unexecuted':
          unexecuted.add(int.parse(value));
        case '--uncalled':
          uncalled.add(value);
        default:
          throw FormatException('unknown argument `$arg`');
      }
    }
    if (file == null || file.isEmpty) {
      throw const FormatException(
        '--file=<workspace-relative path> is required',
      );
    }
    return LcovExpectation(
      file: file,
      executed: executed,
      unexecuted: unexecuted,
      uncalled: uncalled,
    );
  }

  /// The workspace-relative path the report's `SF:` record must carry.
  final String file;

  /// Lines that must appear as `DA:<line>,<n>` with `n > 0`.
  final List<int> executed;

  /// Lines that must appear as `DA:<line>,0`.
  final List<int> unexecuted;

  /// Functions that must appear as `FNDA:0,<name>`.
  final List<String> uncalled;
}

/// The failed assertions of [report] against [expect]; empty when it passes.
List<String> checkLcov(String report, LcovExpectation expect) {
  final List<String> failures = <String>[];
  final List<String> record = _recordFor(report, expect.file, failures);
  if (record.isEmpty) return failures;
  final Map<int, int> hits = <int, int>{};
  final Set<String> uncalled = <String>{};
  int branches = 0;
  for (final String line in record) {
    if (line.startsWith('DA:')) {
      final List<String> parts = line.substring(3).split(',');
      if (parts.length >= 2) {
        final int? number = int.tryParse(parts[0]);
        final int? count = int.tryParse(parts[1]);
        if (number != null && count != null) hits[number] = count;
      }
    } else if (line.startsWith('FNDA:0,')) {
      uncalled.add(line.substring('FNDA:0,'.length));
    } else if (line.startsWith('BRDA:')) {
      branches++;
    }
  }
  for (final int n in expect.executed) {
    final int? count = hits[n];
    if (count == null || count <= 0) {
      failures.add(
        'executed line: expected `DA:$n,<n>` with n > 0 for ${expect.file}, '
        'found ${count == null ? 'no DA record' : 'DA:$n,$count'}',
      );
    }
  }
  for (final int n in expect.unexecuted) {
    if (hits[n] != 0) {
      failures.add(
        'unexecuted line: expected `DA:$n,0` for ${expect.file}, '
        'found ${hits[n] == null ? 'no DA record' : 'DA:$n,${hits[n]}'}',
      );
    }
  }
  for (final String name in expect.uncalled) {
    if (!uncalled.contains(name)) {
      failures.add(
        'uncalled function: expected `FNDA:0,$name` for ${expect.file}, '
        'found none',
      );
    }
  }
  if (branches == 0) {
    failures.add(
      'branch data: expected at least one `BRDA:` record for ${expect.file}, '
      'found none',
    );
  }
  return failures;
}

/// The record lines of the `SF:` record for [file], or an empty list after
/// adding the reason to [failures].
List<String> _recordFor(String report, String file, List<String> failures) {
  final List<String> record = <String>[];
  bool inside = false;
  bool found = false;
  final List<String> others = <String>[];
  for (final String raw in report.split('\n')) {
    final String line = raw.trimRight();
    if (line.startsWith('SF:')) {
      final String path = line.substring(3);
      inside = path == file;
      found = found || inside;
      if (!inside) others.add(path);
    } else if (line == 'end_of_record') {
      inside = false;
    } else if (inside) {
      record.add(line);
    }
  }
  if (found) return record;
  final String? absolute = others
      .where((String p) => p.endsWith('/$file') || p.endsWith('\\$file'))
      .firstOrNull;
  failures.add(
    absolute != null
        ? 'workspace-relative SF: expected `SF:$file`, found `SF:$absolute`'
        : 'SF record: expected `SF:$file` (workspace-relative), found '
              '${others.isEmpty ? 'no SF record at all' : 'only ${others.join(', ')}'}',
  );
  return <String>[];
}
