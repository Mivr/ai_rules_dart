/// The result records both builders write: test results, diagnostics and
/// program runs, and the readers that turn each tool's report into them.
library;

import 'dart:convert';

/// One test case and how it ended: `success`, `failure`, `error` or
/// `skipped`.
class TestRecord {
  const TestRecord(this.suite, this.name, this.result);

  factory TestRecord.fromJson(Map<String, Object?> json) => TestRecord(
    json['suite'] as String,
    json['name'] as String,
    json['result'] as String,
  );

  /// The test file, as the runner names it.
  final String suite;
  final String name;
  final String result;

  Map<String, Object?> toJson() => {
    'suite': suite,
    'name': name,
    'result': result,
  };
}

/// Reads `package:test`'s JSON reporter (`dart test --reporter json`,
/// `flutter test --reporter json`), one event per line. Lines that are not
/// JSON objects (a tool's own banner) are skipped.
///
/// Hidden tests are kept, marked by a `hidden` result prefix, so a
/// normaliser can drop them by name.
List<TestRecord> testsFromJsonReporter(Iterable<String> lines) {
  final suites = <int, String>{};
  final names = <int, ({String name, int suite})>{};
  final records = <TestRecord>[];
  for (final line in lines) {
    final Object? event;
    try {
      event = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (event is! Map<String, Object?>) continue;
    switch (event['type']) {
      case 'suite':
        final suite = event['suite'] as Map<String, Object?>;
        suites[suite['id'] as int] = suite['path'] as String? ?? '';
      case 'testStart':
        final test = event['test'] as Map<String, Object?>;
        names[test['id'] as int] = (
          name: test['name'] as String,
          suite: test['suiteID'] as int,
        );
      case 'testDone':
        final started = names[event['testID'] as int];
        if (started == null) continue;
        final skipped = event['skipped'] as bool? ?? false;
        final hidden = event['hidden'] as bool? ?? false;
        final result = skipped ? 'skipped' : event['result'] as String;
        records.add(
          TestRecord(
            suites[started.suite] ?? '',
            started.name,
            hidden ? 'hidden:$result' : result,
          ),
        );
    }
  }
  return records;
}

/// Reads the JUnit report the rules' test runners write to
/// `XML_OUTPUT_FILE`: `testcase` elements with `name` and `classname`, each
/// holding at most one of `skipped`, `failure` or `error`.
///
/// This reads that one shape, which the rules write themselves (and Bazel's
/// fallback report, a single `testcase` named after the target); it is not a
/// general XML reader. Bazel offers no other per-case record of a test run.
List<TestRecord> testsFromJunit(String xml, {required String fallbackSuite}) {
  final records = <TestRecord>[];
  final caseStart = RegExp(r'<testcase\b([^>]*?)(/?)>');
  for (final RegExpMatch m in caseStart.allMatches(xml)) {
    final String attrs = m.group(1)!;
    final String name = _attr(attrs, 'name') ?? '';
    final String suite = _attr(attrs, 'classname') ?? fallbackSuite;
    var body = '';
    if (m.group(2) != '/') {
      final int end = xml.indexOf('</testcase>', m.end);
      body = xml.substring(m.end, end < 0 ? xml.length : end);
    }
    final String result = body.contains('<skipped')
        ? 'skipped'
        : body.contains('<failure')
        ? 'failure'
        : body.contains('<error')
        ? 'error'
        : 'success';
    records.add(TestRecord(suite, name, result));
  }
  return records;
}

String? _attr(String attrs, String name) {
  final RegExpMatch? m = RegExp('\\b$name="([^"]*)"').firstMatch(attrs);
  if (m == null) return null;
  return m
      .group(1)!
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&#10;', '\n')
      .replaceAll('&amp;', '&');
}

/// One analyzer diagnostic.
class Diagnostic {
  const Diagnostic({
    required this.file,
    required this.line,
    required this.severity,
    required this.code,
  });

  factory Diagnostic.fromJson(Map<String, Object?> json) => Diagnostic(
    file: json['file'] as String,
    line: json['line'] as int,
    severity: json['severity'] as String,
    code: json['code'] as String,
  );

  final String file;
  final int line;
  final String severity;
  final String code;

  Map<String, Object?> toJson() => {
    'file': file,
    'line': line,
    'severity': severity,
    'code': code,
  };
}

/// Reads the diagnostic lines of `dart analyze`'s default output, which is
/// also what the rules' analysis action prints:
///
///     warning - lib/a.dart:3:7 - The value ... - unused_local_variable
///
/// Every other line is ignored.
List<Diagnostic> diagnosticsFromText(Iterable<String> lines) {
  final line = RegExp(
    r'^\s*(error|warning|info) - (.+?):(\d+):\d+ - .* - ([a-z0-9_]+)\s*$',
  );
  return [
    for (final l in lines)
      if (line.firstMatch(l) case final m?)
        Diagnostic(
          file: m.group(2)!,
          line: int.parse(m.group(3)!),
          severity: m.group(1)!,
          code: m.group(4)!,
        ),
  ];
}

/// One run of a compiled program.
class ExeRun {
  const ExeRun(this.args, this.stdout, this.stderr, this.exitCode);

  factory ExeRun.fromJson(Map<String, Object?> json) => ExeRun(
    [for (final a in json['args'] as List) a as String],
    json['stdout'] as String,
    json['stderr'] as String,
    json['exit'] as int,
  );

  final List<String> args;
  final String stdout;
  final String stderr;
  final int exitCode;

  Map<String, Object?> toJson() => {
    'args': args,
    'stdout': stdout,
    'stderr': stderr,
    'exit': exitCode,
  };
}
