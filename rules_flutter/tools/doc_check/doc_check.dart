/// Checks the Starlark documentation that `starlark_doc_extract` wrote.
///
/// Reads `ModuleInfo` binaryprotos, reports every gap as
/// `file:symbol[.attr]: rule` on stderr and exits non-zero when one remains.
library;

import 'dart:io';

import 'emit.dart';
import 'failure.dart';
import 'policy.dart';
import 'rules.dart';
import 'source_probe.dart';
import 'stardoc.dart';

const _usage = '''
usage: doc_check [--emit-rule-kinds | --emit-api]
                 [--allowlist=FILE] [--shared-phrasings=FILE]
                 --sources-root=DIR EXTRACT.binaryproto...
''';

/// The options parsed from the command line.
class Options {
  /// Parses [args]; [problem] holds the first mistake found, if any.
  factory parse(List<String> args) {
    final values = <String, String>{};
    final extracts = <String>[];
    final flags = <String>{};
    for (final arg in args) {
      if (!arg.startsWith('--')) {
        extracts.add(arg);
      } else if (arg.contains('=')) {
        values[arg.substring(2, arg.indexOf('='))] = arg.substring(
          arg.indexOf('=') + 1,
        );
      } else {
        flags.add(arg.substring(2));
      }
    }
    return Options._(extracts, values, flags);
  }

  const new _(this.extracts, this._values, this._flags);

  /// The extract files to read.
  final List<String> extracts;

  final Map<String, String> _values;
  final Set<String> _flags;

  /// Whether the bare `--name` flag was given.
  bool flag(String name) => _flags.contains(name);

  /// The `--name=value` option, or null.
  String? value(String name) => _values[name];

  /// The first problem with the arguments, or null when they are usable.
  String? get problem {
    final known = {'emit-rule-kinds', 'emit-api'};
    final Set<String> unknown = _flags.difference(known);
    if (unknown.isNotEmpty) return 'unknown flag --${unknown.first}';
    if (extracts.isEmpty) return 'no extract files given';
    if (flag('emit-rule-kinds') && flag('emit-api')) {
      return 'pick one of --emit-rule-kinds and --emit-api';
    }
    return null;
  }
}

/// Reads and decodes each extract, naming any that is missing or invalid.
List<ModuleDoc> readExtracts(List<String> paths) {
  final modules = <ModuleDoc>[];
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) throw DocCheckFailure('extract $path is missing');
    try {
      modules.add(ModuleDoc.parse(file.readAsBytesSync()));
    } on FormatException catch (e) {
      throw DocCheckFailure(
        'extract $path is not a ModuleInfo binaryproto: ${e.message}',
      );
    }
  }
  return modules;
}

Entries _readList(String? path, (String, String) Function(String) split) {
  if (path == null) return Entries.empty;
  final file = File(path);
  if (!file.existsSync()) throw DocCheckFailure('list $path is missing');
  return Entries.parse(file.readAsStringSync(), path, split);
}

/// Runs the checker; the exit code is 0 only when no blocking gap remains.
int run(List<String> args, StringSink out, StringSink err) {
  final options = Options.parse(args);
  final String? problem = options.problem;
  if (problem != null) {
    err.write('doc_check: $problem\n$_usage');
    return 2;
  }
  try {
    final List<ModuleDoc> modules = readExtracts(options.extracts);
    if (options.flag('emit-rule-kinds')) {
      out.write(emitRuleKinds(modules));
      return 0;
    }
    if (options.flag('emit-api')) {
      out.write(emitApi(modules));
      return 0;
    }
    return _check(options, modules, err);
  } on DocCheckFailure catch (e) {
    err.writeln('doc_check: ${e.message}');
    return 2;
  }
}

int _check(Options options, List<ModuleDoc> modules, StringSink err) {
  final String? root = options.value('sources-root');
  if (root == null) throw const DocCheckFailure('--sources-root is required');
  final Entries allowlist = _readList(
    options.value('allowlist'),
    splitAllowlistLine,
  );
  final Entries shared = _readList(
    options.value('shared-phrasings'),
    splitPhrasingLine,
  );
  final checker = DocChecker(
    returnsValue: SourceReturns(root).call,
    sharedPhrasings: shared.reasons.keys.toSet(),
  );
  final CheckReport report = checker.check(modules);
  final Verdict verdict = judge(report.findings, allowlist, [
    ...shared.problems,
    ...staleShared(shared, report.docUsage),
  ]);
  [...verdict.warnings, ...verdict.errors].forEach(err.writeln);
  return verdict.ok ? 0 : 1;
}

/// Entry point for `bazel run //tools/doc_check -- ...`.
void main(List<String> args) {
  exitCode = run(args, stdout, stderr);
}
