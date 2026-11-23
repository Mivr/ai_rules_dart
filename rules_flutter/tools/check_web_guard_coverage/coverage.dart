/// The web-guard hostile fixture coverage check, shared by the
/// `check_web_guard_coverage` binary (run by CI) and its unit test.
///
/// `_setup_web_fixtures` declares one hostile target per spelling and its
/// dart2js twin. Every one must be built by a CI step that requires the build
/// to fail with `is not a declared input`: a build that succeeds, or a failure
/// with another message (a compiler crash, say), must turn the job red. The
/// fixtures stay `manual`, so `//...` cannot build them and this check is what
/// keeps their must-fail coverage from silently disappearing.
library;

/// The refusal `web_guard` prints for an import outside the declared inputs.
const String guardRefusal = 'is not a declared input';

final RegExp _spellingLoop = RegExp(
  r'for\s+spelling\s+in\s*\[(.*?)\]',
  dotAll: true,
);
final RegExp _quoted = RegExp(r'''["']([^"']+)["']''');
final RegExp _literalHostile = RegExp(
  r'_web_guard_hostile_[A-Za-z0-9][A-Za-z0-9_.-]*',
);
final RegExp _bazelBuild = RegExp(r'\bbazel\s+build\b');
final RegExp _grepGuard = RegExp(
  r'\bgrep\b[^\n]*' + RegExp.escape(guardRefusal),
);
final RegExp _stepStart = RegExp(r'^(\s*)-\s+name:');
final RegExp _nextStep = RegExp(r'^(\s*)-\s+(?:name|uses):');
final RegExp _jobKey = RegExp(r'^(\s*)[A-Za-z0-9_-]+:\s*$');
final RegExp _nameChar = RegExp(r'[A-Za-z0-9_.-]');
final RegExp _continueOnError = RegExp(
  r'^\s*continue-on-error:\s*true\s*$',
  multiLine: true,
);
final RegExp _conditionalFalse = RegExp(
  r'^\s*if:\s*(?:false|\$\{\{\s*false\s*\}\})\s*$',
  multiLine: true,
);

/// Every hostile fixture declared by [source], a `flutter/tests/web_test.bzl`
/// string: both targets of each `for spelling in [...]` loop entry, plus any
/// target named literally. Comments are ignored, so a commented-out target is
/// not mistaken for a declared one.
Set<String> findHostileFixtures(String source) {
  final String text = _stripComments(source);
  final fixtures = <String>{};
  for (final RegExpMatch loop in _spellingLoop.allMatches(text)) {
    for (final RegExpMatch spelling in _quoted.allMatches(loop.group(1)!)) {
      final String name = spelling.group(1)!;
      fixtures.add('_web_guard_hostile_$name');
      fixtures.add('_web_guard_hostile_${name}_js');
    }
  }
  for (final RegExpMatch match in _literalHostile.allMatches(text)) {
    fixtures.add(match.group(0)!);
  }
  return fixtures;
}

/// Error strings for [fixtures] against CI [workflows] (file name to text).
/// A fixture is covered when a must-fail step in any workflow names it and
/// greps [guardRefusal]. Empty when every fixture has that coverage.
List<String> checkWebGuardCoverage({
  required Set<String> fixtures,
  required Map<String, String> workflows,
}) {
  final covered = <String>{};
  for (final String workflow in workflows.values) {
    for (final String step in _workflowSteps(_stripComments(workflow))) {
      if (!_isMustFailGuardStep(step)) {
        continue;
      }
      for (final fixture in fixtures) {
        if (_namesWholeTarget(step, fixture)) {
          covered.add(fixture);
        }
      }
    }
  }
  final errors = <String>[];
  for (final String fixture in fixtures.toList()..sort()) {
    if (!covered.contains(fixture)) {
      errors.add(
        "web-guard fixture '$fixture' is not named by a must-fail CI step "
        'that greps "$guardRefusal"',
      );
    }
  }
  return errors;
}

/// A step is must-fail when it runs `bazel build` and fails on success (an
/// `if` with the build, then `exit 1`), and it pins the guard message in a
/// `grep`. Merely mentioning the message in an echo does not count, and a
/// step that is skipped (`if: false`) or allowed to fail
/// (`continue-on-error: true`) cannot turn the job red.
bool _isMustFailGuardStep(String step) {
  if (_continueOnError.hasMatch(step) || _conditionalFalse.hasMatch(step)) {
    return false;
  }
  final List<String> lines = step.split('\n');
  final bool grepsGuard = lines.any(_grepGuard.hasMatch);
  final bool failsOnSuccess = lines.any((line) {
    final String trimmed = line.trimLeft();
    return trimmed.startsWith('if ') &&
        !trimmed.startsWith('if !') &&
        _bazelBuild.hasMatch(line);
  });
  return grepsGuard && failsOnSuccess && RegExp(r'\bexit\s+1\b').hasMatch(step);
}

/// Whether [step] names [fixture] as a whole target, so
/// `_web_guard_hostile_file_js` cannot cover `_web_guard_hostile_file`.
bool _namesWholeTarget(String step, String fixture) {
  int start = step.indexOf(fixture);
  while (start >= 0) {
    final String before = start == 0 ? '' : step[start - 1];
    final int afterIndex = start + fixture.length;
    final String after = afterIndex == step.length ? '' : step[afterIndex];
    if (!_nameChar.hasMatch(before) && !_nameChar.hasMatch(after)) {
      return true;
    }
    start = step.indexOf(fixture, start + 1);
  }
  return false;
}

/// The `- name:` blocks of [workflow], from each step's start to the next
/// step at the same or a shallower indent (or the next job key).
Iterable<String> _workflowSteps(String workflow) sync* {
  final List<String> lines = workflow.split('\n');
  var index = 0;
  while (index < lines.length) {
    final RegExpMatch? start = _stepStart.firstMatch(lines[index]);
    if (start == null) {
      index++;
      continue;
    }
    final int indent = start.group(1)!.length;
    final first = index;
    index++;
    while (index < lines.length) {
      final RegExpMatch? next = _nextStep.firstMatch(lines[index]);
      if (next != null && next.group(1)!.length <= indent) {
        break;
      }
      final RegExpMatch? key = _jobKey.firstMatch(lines[index]);
      if (key != null && key.group(1)!.length < indent) {
        break;
      }
      index++;
    }
    yield lines.sublist(first, index).join('\n');
  }
}

/// Drops blank and comment-only lines and `#` comments at the end of a line,
/// so a commented-out fixture or step can never satisfy the check.
String _stripComments(String text) => text
    .split('\n')
    .map((line) {
      if (line.trimLeft().startsWith('#')) {
        return '';
      }
      final int marker = line.indexOf(' #');
      return marker < 0 ? line : line.substring(0, marker);
    })
    .join('\n');
