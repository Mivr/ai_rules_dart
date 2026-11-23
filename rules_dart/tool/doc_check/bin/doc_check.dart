/// Command-line entry of the Starlark documentation checker.
///
/// ```text
/// doc_check [--allowlist=FILE] [--shared-phrasings=FILE] EXTRACT...
/// doc_check --emit-rule-kinds EXTRACT...
/// doc_check --emit-api EXTRACT...
/// ```
///
/// `EXTRACT` is a `ModuleInfo` binaryproto written by `starlark_doc_extract`.
/// Paths resolve through Bazel runfiles when run under Bazel. The check
/// reports every gap on stderr and exits 1 when one remains; it reads the
/// `.bzl` sources of the load closure through runfiles, so it needs a Bazel
/// run. The two `--emit-*` flags need only the extracts.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:doc_check/checker.dart';
import 'package:doc_check/emit.dart';
import 'package:doc_check/runfiles_paths.dart';

void main(List<String> args) {
  final List<String> flags = args.where((a) => a.startsWith('--')).toList();
  final List<Uint8List> extracts = [
    for (final path in args.where((a) => !a.startsWith('--')))
      File(resolveRunfile(path)).readAsBytesSync(),
  ];
  if (flags.contains('--emit-rule-kinds')) {
    stdout.writeln(emitRuleKinds(decodeExtracts(extracts)));
  } else if (flags.contains('--emit-api')) {
    stdout.writeln(emitApi(decodeExtracts(extracts)));
  } else {
    _check(extracts, flags);
  }
}

void _check(List<Uint8List> extracts, List<String> flags) {
  final CheckReport report = runCheck(
    CheckInputs(
      extracts: extracts,
      readSource: sourceReader(locateRunfile),
      allowlist: _flagFile(flags, 'allowlist'),
      sharedPhrasings: _flagFile(flags, 'shared-phrasings'),
    ),
  );
  report.lines.forEach(stderr.writeln);
  if (report.failed) exit(1);
}

String _flagFile(List<String> flags, String name) {
  final prefix = '--$name=';
  for (final flag in flags) {
    if (flag.startsWith(prefix)) {
      return File(resolveRunfile(flag.substring(prefix.length)))
          .readAsStringSync();
    }
  }
  return '';
}
