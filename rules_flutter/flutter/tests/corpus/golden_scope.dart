/// Validates that the corpus golden covers every fixture the Linux-x64 host
/// can build and that every other fixture is listed with a reason.
///
/// The inputs are the checked-in `BUILD.bazel`, `golden_targets.txt`,
/// `uncovered_golden.txt` and `actions.golden.json`. Nothing here touches the
/// file system, so the unit tests feed it plain strings.
library;

import 'dart:convert';

/// The label prefix every corpus target shares.
const String corpusPackage = '//flutter/tests/corpus:';

final RegExp _toolingKind = RegExp(
  r'^(dart_binary|dart_test|test_suite|cc_\w+)$',
);
final RegExp _labelName = RegExp(r'^[A-Za-z0-9_.+-]+$');
final RegExp _callStart = RegExp(r'^([A-Za-z_]\w*)\($');
final RegExp _callName = RegExp(r'^    name = "([^"]+)",$');
final RegExp _generatedDeps = RegExp(r'^(\w+?)_\d+__\w+$');

/// The text of the four checked-in files the validator compares.
class CorpusScopeInput {
  /// Creates an input from the file contents.
  const new({
    required this.build,
    required this.goldenTargets,
    required this.uncovered,
    required this.goldenJson,
  });

  /// `BUILD.bazel`.
  final String build;

  /// `golden_targets.txt`.
  final String goldenTargets;

  /// `uncovered_golden.txt`.
  final String uncovered;

  /// `actions.golden.json`.
  final String goldenJson;
}

/// The targets `BUILD.bazel` declares, split into fixtures and corpus tooling.
class DeclaredTargets {
  /// Creates the split from the two name sets.
  const new({required this.fixtures, required this.tooling});

  /// Names of the public rule, macro and aspect fixtures.
  final Set<String> fixtures;

  /// Names of the golden updater, tests, suites and `cc_*` helpers.
  final Set<String> tooling;
}

/// The targets declared by a top-level `name = "<target>"` in [build].
DeclaredTargets declaredTargets(String build) {
  final fixtures = <String>{};
  final tooling = <String>{};
  String? kind;
  for (final String line in build.split('\n')) {
    final RegExpMatch? start = _callStart.firstMatch(line);
    if (start != null) {
      kind = start.group(1);
      continue;
    }
    if (line.startsWith(')')) {
      kind = null;
      continue;
    }
    final RegExpMatch? name = _callName.firstMatch(line);
    if (name == null || kind == null) continue;
    (_toolingKind.hasMatch(kind) ? tooling : fixtures).add(name.group(1)!);
  }
  return DeclaredTargets(fixtures: fixtures, tooling: tooling);
}

/// The non-blank, non-comment lines of [text], trimmed.
List<String> dataRows(String text) => <String>[
  for (final String raw in text.split('\n'))
    if (raw.trim().isNotEmpty && !raw.trim().startsWith('#')) raw.trim(),
];

/// Whether [name] is a macro-generated sub-target of a fixture in [fixtures].
bool isSubTarget(String name, Set<String> fixtures) {
  final String bare = name.replaceFirst(RegExp('^_+'), '');
  return fixtures.any((String f) => bare.startsWith('${f}_'));
}

/// Problems with `golden_targets.txt`, plus the label set it names.
List<String> checkGoldenTargets(
  List<String> rows,
  DeclaredTargets declared,
) {
  final problems = <String>[];
  final seen = <String>{};
  for (final row in rows) {
    final String name = row.startsWith(corpusPackage)
        ? row.substring(corpusPackage.length)
        : '';
    if (name.isEmpty || !_labelName.hasMatch(name)) {
      problems.add('golden_targets.txt: malformed label "$row"');
    } else if (!seen.add(row)) {
      problems.add('golden_targets.txt: duplicate label $row');
    } else if (declared.tooling.contains(name)) {
      problems.add('golden_targets.txt: corpus tooling or helper $row');
    } else if (!declared.fixtures.contains(name) &&
        !isSubTarget(name, declared.fixtures)) {
      problems.add('golden_targets.txt: $row is not a fixture or sub-target');
    }
  }
  final sorted = List<String>.of(rows)..sort();
  if (rows.join('\n') != sorted.join('\n')) {
    problems.add('golden_targets.txt: lines are not sorted');
  }
  return problems;
}

/// Parses `uncovered_golden.txt` rows into `target -> reason`, appending any
/// problem to [problems].
Map<String, String> parseUncovered(
  List<String> rows,
  DeclaredTargets declared,
  List<String> problems,
) {
  final result = <String, String>{};
  for (final row in rows) {
    final int colon = row.indexOf(':');
    if (colon < 0) {
      problems.add('uncovered_golden.txt: missing ":" in "$row"');
      continue;
    }
    final String target = row.substring(0, colon).trim();
    final String reason = row.substring(colon + 1).trim();
    if (target.isEmpty || reason.isEmpty) {
      problems.add('uncovered_golden.txt: empty target or reason in "$row"');
    } else if (result.containsKey(target)) {
      problems.add('uncovered_golden.txt: duplicate target $target');
    } else if (declared.tooling.contains(target)) {
      problems.add('uncovered_golden.txt: corpus tooling or helper $target');
    } else if (!declared.fixtures.contains(target) &&
        !_isGeneratedDeps(target, declared.fixtures)) {
      problems.add('uncovered_golden.txt: $target is not a declared fixture');
    } else {
      result[target] = reason;
    }
  }
  return result;
}

bool _isGeneratedDeps(String target, Set<String> fixtures) {
  final RegExpMatch? match = _generatedDeps.firstMatch(target);
  return match != null && fixtures.contains(match.group(1));
}

/// Problems with the targets that own actions in the golden JSON.
List<String> checkGoldenActions(
  String goldenJson,
  Set<String> listed,
  DeclaredTargets declared,
) {
  final problems = <String>[];
  final Object? doc = jsonDecode(goldenJson);
  final Object? actions = doc is Map<String, Object?> ? doc['actions'] : null;
  if (actions is! List<Object?>) {
    return <String>['actions.golden.json: no "actions" list'];
  }
  final targets = <String>{};
  for (final Object? entry in actions) {
    final Object? action = entry is String ? jsonDecode(entry) : entry;
    if (action is Map<String, Object?> && action['target'] is String) {
      targets.add(action['target']! as String);
    }
  }
  for (final String target in targets.toList()..sort()) {
    final String name = target.startsWith(corpusPackage)
        ? target.substring(corpusPackage.length)
        : target;
    if (declared.tooling.contains(name)) {
      problems.add('actions.golden.json: corpus tooling or helper $target');
    } else if (!listed.contains(target)) {
      problems.add('actions.golden.json: $target is not in golden_targets.txt');
    }
  }
  return problems;
}

/// Every problem in the corpus golden scope; empty when consistent.
List<String> validateGoldenScope(CorpusScopeInput input) {
  final DeclaredTargets declared = declaredTargets(input.build);
  final List<String> goldenRows = dataRows(input.goldenTargets);
  final List<String> problems = checkGoldenTargets(goldenRows, declared);
  final Map<String, String> uncovered = parseUncovered(
    dataRows(input.uncovered),
    declared,
    problems,
  );
  final Set<String> listed = goldenRows.toSet();
  for (final String fixture in declared.fixtures.toList()..sort()) {
    final bool covered = listed.contains('$corpusPackage$fixture');
    final bool tracked = uncovered.containsKey(fixture);
    if (covered == tracked) {
      problems.add(
        '$fixture: must be in exactly one of golden_targets.txt and '
        'uncovered_golden.txt (${covered ? 'both' : 'neither'})',
      );
    }
  }
  problems.addAll(checkGoldenActions(input.goldenJson, listed, declared));
  return problems;
}
