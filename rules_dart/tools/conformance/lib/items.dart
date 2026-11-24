/// Items for the result kinds: test cases, analyzer diagnostics, program runs.
library;

import 'package:conformance/compare.dart';
import 'package:conformance/normalise.dart';
import 'package:conformance/records.dart';

/// One item per test case: `test:<suite> :: <name>`, valued by its result.
///
/// A name that repeats inside one suite gets ` #2`, ` #3` in run order.
Items testItems(List<TestRecord> records, List<String> roots, Applied applied) {
  final items = <String, Value>{};
  for (final r in records) {
    var result = r.result;
    if (result.startsWith('hidden:')) {
      result = result.substring('hidden:'.length);
      if (result == 'success') {
        applied.hit(hiddenLoadingTests);
        continue;
      }
    }
    final String suite = relativeTo(r.suite, roots, applied);
    final base = 'test:$suite :: ${r.name}';
    var key = base;
    for (var n = 2; items.containsKey(key); n++) {
      key = '$base #$n';
    }
    items[key] = Value(result, result);
  }
  return items;
}

/// One item per analyzed file: `file:<path>`, valued by its diagnostics as
/// a sorted list of `severity code`, or `clean`.
///
/// A diagnostic reported twice at the same line (two targets that share a
/// file each analyze it) counts once. [files] are the files the side
/// analyzed; a file with a diagnostic is
/// an item even when [files] does not list it.
Items analysisItems(
  List<String> files,
  List<Diagnostic> diagnostics,
  List<String> roots,
  Applied applied,
) {
  final byFile = <String, List<String>>{
    for (final f in files) relativeTo(f, roots, applied): [],
  };
  final seen = <String>{};
  for (final d in diagnostics) {
    final String file = relativeTo(d.file, roots, applied);
    if (!seen.add('$file:${d.line} ${d.severity} ${d.code}')) {
      applied.hit(repeatedDiagnostics);
      continue;
    }
    (byFile[file] ??= []).add('${d.severity} ${d.code}');
  }
  return {
    for (final MapEntry(:key, :value) in byFile.entries)
      'file:$key': _listValue(value..sort()),
  };
}

Value _listValue(List<String> found) {
  final text = found.isEmpty ? 'clean' : found.join(', ');
  return Value(text, text);
}

/// One item per run of the program: `run:<args>`, valued by its exit code,
/// stdout and stderr.
Items exeItems(List<ExeRun> runs) => {
  for (final r in runs)
    'run:${r.args.join(' ')}': Value(
      'exit=${r.exitCode}\n--stdout\n${r.stdout}\n--stderr\n${r.stderr}',
      'exit ${r.exitCode}, stdout ${_firstLine(r.stdout)}',
    ),
};

String _firstLine(String s) {
  final String line = s.trim().split('\n').first;
  return line.length > 60 ? '"${line.substring(0, 60)}..."' : '"$line"';
}
