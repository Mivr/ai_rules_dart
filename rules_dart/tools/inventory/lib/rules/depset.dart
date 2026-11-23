/// `depset-flatten`: production Starlark that expands a depset at analysis.
library;

import 'package:inventory/finding.dart';
import 'package:inventory/source_tree.dart';
import 'package:inventory/starlark.dart';

/// The rule's name in debt files and allow comments.
const String depsetFlattenRule = 'depset-flatten';

final RegExp _toList = RegExp(r'\.to_list\s*\(');

/// Every `.to_list()` in the Starlark files [isProduction] accepts.
///
/// Flattening a depset at analysis time makes the cost of a target grow with
/// its whole dependency closure instead of its direct dependencies. A site
/// that must flatten (a terminal rule, say) carries
/// `# lint-allow: depset-flatten <reason>` on its line or the line above.
List<Finding> checkDepsetFlatten(
  SourceTree tree,
  bool Function(String path) isProduction,
) {
  final findings = <Finding>[];
  for (final String path in tree.paths) {
    if (!(path.endsWith('.bzl') || path.endsWith('.bazel')) ||
        !isProduction(path)) {
      continue;
    }
    final String text = tree.read(path);
    final lines = Lines(text);
    for (final RegExpMatch m in _toList.allMatches(blank(text))) {
      final Finding? finding = findingAt(
        rule: depsetFlattenRule,
        file: path,
        lines: lines,
        offset: m.start,
        message:
            'depset flattened with .to_list() in production Starlark; '
            'expand it at execution through Args, or allow it with a reason',
      );
      if (finding != null) findings.add(finding);
    }
  }
  return findings;
}
