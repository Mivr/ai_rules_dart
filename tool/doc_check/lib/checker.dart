/// Runs the documentation check over extract files and prints its report.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:doc_check/doc_rules.dart';
import 'package:doc_check/policy.dart';
import 'package:doc_check/stardoc_model.dart';

/// Everything one check run reads.
class CheckInputs {
  /// Creates the inputs of a run.
  const new({
    required this.extracts,
    required this.readSource,
    required this.allowlist,
    required this.sharedPhrasings,
  });

  /// The `ModuleInfo` binaryprotos, in report order.
  final List<Uint8List> extracts;

  /// Reads the `.bzl` source of a label, null when it is not available.
  final SourceReader readSource;

  /// The allowlist file's text.
  final String allowlist;

  /// The approved shared-phrasings file's text.
  final String sharedPhrasings;
}

/// The result of a check run: report lines for stderr and a verdict.
class CheckReport {
  /// Creates a report.
  const new(this.lines, {required this.failed});

  /// Report lines, one problem or warning per line.
  final List<String> lines;

  /// Whether any blocking problem remains.
  final bool failed;
}

/// Checks [inputs] and reports every gap as `file:symbol[.attr]: rule`.
CheckReport runCheck(CheckInputs inputs) {
  final List<ModuleDoc> modules = decodeExtracts(inputs.extracts);
  final List<Gap> gaps = checkDocs(
    modules,
    inputs.readSource,
    parseSharedPhrasings(inputs.sharedPhrasings),
  );
  final Filtered filtered = applyAllowlist(
    gaps,
    parseAllowlist(inputs.allowlist),
  );
  final List<String> lines = [
    for (final gap in filtered.errors) gap.line,
    for (final key in filtered.staleEntries)
      'allowlist: $key: entry covers no violation; remove it',
    for (final gap in filtered.warnings) 'warning: ${gap.line}',
  ];
  return CheckReport(
    lines,
    failed: filtered.errors.isNotEmpty || filtered.staleEntries.isNotEmpty,
  );
}

/// Decodes each extract, failing with the offending index on bad input.
List<ModuleDoc> decodeExtracts(List<Uint8List> extracts) {
  return [for (var i = 0; i < extracts.length; i++) _decode(extracts[i], i)];
}

ModuleDoc _decode(Uint8List data, int index) {
  try {
    return ModuleDoc.decode(data);
  } on FormatException catch (e) {
    throw FormatException('extract #$index is not a ModuleInfo: ${e.message}');
  }
}

/// A [SourceReader] over files laid out as `<repo>/<package>/<file>`.
///
/// [locate] maps a runfiles-relative path to a file system path, or null.
SourceReader sourceReader(
  String? Function(String) locate, {
  String repo = '_main',
}) {
  return (label) {
    final RegExpMatch? match = RegExp(r'^//([^:]*):(.+)$').firstMatch(label);
    if (match == null) return null;
    final String package = match.group(1)!;
    final String? path = locate(
      '$repo/${package.isEmpty ? '' : '$package/'}${match.group(2)}',
    );
    if (path == null || !File(path).existsSync()) return null;
    return File(path).readAsStringSync();
  };
}
