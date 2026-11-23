/// The compile-api negative target coverage check, shared by the
/// `check_compile_api_coverage` binary (run by CI) and its unit test.
///
/// `flutter/tests/compile_api_test.bzl` declares negative targets whose whole
/// point is that the build must fail. They are `manual` so `//...` stays
/// green, which also means `bazel test //flutter/tests/...` never builds
/// them. Every one must therefore be built by a CI step that requires the
/// build to fail with `is not a declared input`: a build that succeeds, or a
/// failure with another message (a compiler crash, `File not found`), must
/// turn the job red. This check keeps that must-fail coverage from silently
/// disappearing.
library;

/// The refusal the directive guard and the read-set check print for an input
/// outside the declared inputs.
const String refusal = 'is not a declared input';

/// The name prefix of the compile-api negative targets this check covers.
const String negativePrefix = '_compile_api_build_negative_';

final RegExp _declaration = RegExp(
  '\\bname\\s*=\\s*(["\'])(${RegExp.escape(negativePrefix)}[^"\']*)\\1',
);
final RegExp _tagsClause = RegExp(r'\btags\s*=\s*(\[[^\]]*\]|[^\s,)]+)');
final RegExp _manualTag = RegExp('["\']manual["\']');
final RegExp _buildIf = RegExp(
  r'^\s*if\s+(?![\s!])[^\n]*\bbazel\s+(?:-\S+\s+)*build\b',
);
final RegExp _failExit = RegExp(r'\bexit\s+1\b');
final RegExp _grepRefusal = RegExp(
  r'\bgrep\b[^|]*' + RegExp.escape(refusal) + r'[^|]*$',
);
final RegExp _shellVariable = RegExp(r'\$(?:\{\w+\}|\w+)');
final RegExp _disabledStep = RegExp(
  r'^\s*(?:continue-on-error:\s*true|'
  r'if:\s*(?:false|\$\{\{\s*false\s*\}\}))\s*$',
  multiLine: true,
);

/// The `manual` negative targets declared by [source], a
/// `flutter/tests/compile_api_test.bzl` string: every
/// `name = "_compile_api_build_negative_<suffix>"` whose call is tagged
/// `manual`. Comments are ignored, so a commented-out target is not mistaken
/// for a declared one. A name built at load time (`"..._negative_" + x`)
/// cannot be resolved, so its literal prefix is returned as-is: no step can
/// name it, and the check reports it instead of passing vacuously.
Set<String> findNegativeTargets(String source) {
  final String text = _stripComments(source);
  final List<(int, int)> spans = _callSpans(text);
  final targets = <String>{};
  for (final RegExpMatch match in _declaration.allMatches(text)) {
    final (int, int)? call = _innermostCall(spans, match.start);
    final String body = call == null ? '' : text.substring(call.$1, call.$2);
    if (_isManual(body)) {
      targets.add(match.group(2)!);
    }
  }
  return targets;
}

/// Error strings for [targets] against CI [workflows] (file name to text).
/// A target is covered when a must-fail build in any workflow names it as a
/// whole target and greps [refusal]. Empty when every target has that
/// coverage; a check with no targets at all is an error, never a pass.
List<String> checkCompileApiCoverage({
  required Set<String> targets,
  required Map<String, String> workflows,
}) {
  if (targets.isEmpty) {
    return [_vacuousError];
  }
  final List<String> builds = [
    for (final workflow in workflows.values)
      ..._mustFailBuilds(_stripComments(workflow)),
  ];
  return [
    for (final target in targets.toList()..sort())
      if (!builds.any((build) => _namesWholeTarget(build, target)))
        _uncoveredError(target),
  ];
}

/// The error for a check that found no target to cover.
const String _vacuousError =
    'found no manual $negativePrefix* targets; the coverage check would '
    'be vacuous';

/// The error that names a [target] no must-fail CI step builds.
String _uncoveredError(String target) =>
    "compile-api negative target '$target' is not named by a must-fail "
    'CI step that greps "$refusal"';

/// Whether the call text [body] tags its target `manual`. A `tags` value that
/// is not a list literal cannot be read, so it counts as manual: the check
/// asks for coverage rather than skipping a target it cannot prove built.
bool _isManual(String body) {
  final RegExpMatch? tags = _tagsClause.firstMatch(body);
  if (tags == null) {
    return false;
  }
  return _manualTag.hasMatch(body) || !tags.group(1)!.startsWith('[');
}

/// For each build in [workflow] that must fail, the text that names its
/// targets. A build is must-fail when its `if` runs `bazel build` and the
/// block then fails on success (`exit 1`) and greps [refusal]. Steps that are
/// skipped (`if: false`) or allowed to fail (`continue-on-error: true`)
/// cannot turn the job red and yield nothing.
Iterable<String> _mustFailBuilds(String workflow) sync* {
  for (final List<String> step in _workflowSteps(_logicalLines(workflow))) {
    if (_disabledStep.hasMatch(step.join('\n'))) {
      continue;
    }
    final List<int> starts = [
      for (var i = 0; i < step.length; i++)
        if (_buildIf.hasMatch(step[i])) i,
    ];
    for (var n = 0; n < starts.length; n++) {
      final int end = n + 1 < starts.length ? starts[n + 1] : step.length;
      final List<String> block = step.sublist(starts[n], end);
      if (block.any(_failExit.hasMatch) && block.any(_grepRefusal.hasMatch)) {
        yield _namingText(step, starts[n]);
      }
    }
  }
}

/// The text that names the targets of the build at line [at] of [step]: the
/// build line itself, plus the `for` lines before it when the build takes its
/// target from a shell variable (`bazel build "$target"`).
String _namingText(List<String> step, int at) {
  final String build = step[at];
  if (!_shellVariable.hasMatch(build.replaceAll(r'$(', ''))) {
    return build;
  }
  final Iterable<String> loops = step
      .take(at)
      .where((line) => line.trimLeft().startsWith('for '));
  return [...loops, build].join('\n');
}

/// Whether [text] names [target] as a whole target, so
/// `_compile_api_build_negative_pkg_extra` cannot cover
/// `_compile_api_build_negative_pkg`.
bool _namesWholeTarget(String text, String target) {
  return RegExp(
    '(?<![A-Za-z0-9_.-])${RegExp.escape(target)}(?![A-Za-z0-9_.-])',
  ).hasMatch(text);
}

/// The steps of [lines]: each `- ` list item up to the next line at the same
/// or a shallower indent. Items that are not steps hold no build and are
/// harmless.
List<List<String>> _workflowSteps(List<String> lines) {
  final steps = <List<String>>[];
  List<String>? current;
  var itemIndent = 0;
  for (final line in lines) {
    final String content = line.trimLeft();
    final int indent = line.length - content.length;
    if (current != null && indent <= itemIndent) {
      current = null;
    }
    if (current == null && content.startsWith('- ')) {
      current = [line];
      itemIndent = indent;
      steps.add(current);
    } else {
      current?.add(line);
    }
  }
  return steps;
}

/// The non-blank lines of [text], with each `\` continuation joined to the
/// line it continues, as the shell reads them.
List<String> _logicalLines(String text) {
  final lines = <String>[];
  var pending = '';
  for (final String raw in text.split(RegExp(r'\r?\n'))) {
    final joined = pending.isEmpty ? raw : '$pending ${raw.trimLeft()}';
    if (joined.endsWith(r'\')) {
      pending = joined.substring(0, joined.length - 1).trimRight();
    } else {
      pending = '';
      if (joined.trim().isNotEmpty) {
        lines.add(joined);
      }
    }
  }
  return lines;
}

/// The `(start, end)` index pairs of every parenthesised group in [text],
/// skipping string contents so a `(` inside a flag value is not a call.
List<(int, int)> _callSpans(String text) {
  final spans = <(int, int)>[];
  final open = <int>[];
  var index = 0;
  while (index < text.length) {
    final String char = text[index];
    if (char == '"' || char == "'") {
      index = _stringEnd(text, index);
    } else if (char == '(') {
      open.add(index);
    } else if (char == ')' && open.isNotEmpty) {
      spans.add((open.removeLast(), index));
    }
    index++;
  }
  return spans;
}

/// The index of the closing quote of the string that opens at [start],
/// honouring backslash escapes and triple quotes. A string that never closes
/// ends at the end of [text].
int _stringEnd(String text, int start) {
  final String quote = text[start];
  final bool triple = text.startsWith(quote * 3, start);
  final String closer = triple ? quote * 3 : quote;
  int index = start + closer.length;
  while (index < text.length && !text.startsWith(closer, index)) {
    index += text[index] == r'\' ? 2 : 1;
  }
  return index + closer.length - 1;
}

/// The innermost span of [spans] that contains [index], or null.
(int, int)? _innermostCall(List<(int, int)> spans, int index) {
  (int, int)? best;
  for (final span in spans) {
    if (span.$1 < index &&
        index < span.$2 &&
        (best == null || span.$1 > best.$1)) {
      best = span;
    }
  }
  return best;
}

/// Drops `#` comments (whole-line, or after whitespace outside a string), so
/// a commented-out target or step can never satisfy the check.
String _stripComments(String text) =>
    text.split('\n').map(_stripLineComment).join('\n');

String _stripLineComment(String line) {
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final String char = line[i];
    if (quote != null) {
      if (char == quote) {
        quote = null;
      }
    } else if (char == '"' || char == "'") {
      quote = char;
    } else if (char == '#' && (i == 0 || line[i - 1].trim().isEmpty)) {
      return line.substring(0, i);
    }
  }
  return line;
}
