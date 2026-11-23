import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Guards the strict incompatible-flag gate.
///
/// `.bazelrc` imports `tools/strict.bazelrc`, whose `common:strict` config
/// names exactly the Bazel flags the repository passes and neither flag a
/// dependency blocks. Every action call under `dart/` names its `toolchain`,
/// which `--incompatible_auto_exec_groups` requires, and `dart/toolchain.bzl`
/// reads its SDK attributes through `[DefaultInfo].files`. CI runs the
/// `strict`, `last_rc` and `mod-tidy` jobs, of which only `mod-tidy` blocks,
/// and the BCR presubmit runs the `rolling` Bazel release.
///
/// Runs unsandboxed over the live tree. The workspace root is the real path of
/// this test's own source, passed as an `rlocationpath` argument and declared
/// in `data`, minus that source's workspace-relative path; it never walks up
/// the ancestors.
void main(List<String> args) {
  _bazelrcTests(args);
  _toolchainFileTests(args);
  _actionTests(args);
  _workflowTests(args);
  _presubmitTests(args);
  _parserTests();
}

/// The flags `common:strict` names, one per line.
const List<String> _strictFlags = [
  '--incompatible_auto_exec_groups',
  '--incompatible_check_external_repo_source_dir_package_boundary',
  '--incompatible_check_testonly_for_output_files',
  '--incompatible_config_setting_private_default_visibility',
  '--incompatible_default_to_explicit_init_py',
  '--incompatible_disable_native_android_rules',
  '--incompatible_disable_native_apple_binary_rule',
  '--incompatible_disable_non_executable_java_binary',
  '--incompatible_disable_starlark_host_transitions',
  '--incompatible_disallow_sdk_frameworks_attributes',
  '--incompatible_enable_apple_toolchain_resolution',
  '--incompatible_no_implicit_file_export',
  '--incompatible_objc_alwayslink_by_default',
  '--incompatible_python_disallow_native_rules',
  '--incompatible_remote_local_fallback_for_remote_cache',
  '--incompatible_resolve_select_keys_eagerly',
  '--incompatible_stop_exporting_build_file_path',
  '--incompatible_stop_exporting_language_modules',
  '--incompatible_strip_executable_safely',
  '--incompatible_use_cc_configure_from_rules_cc',
];

/// The flags a dependency fails under, which no config may set.
const List<String> _blockedFlags = [
  '--incompatible_no_rule_outputs_param',
  '--incompatible_disable_target_default_provider_fields',
];

/// The dependencies that block [_blockedFlags], named in the comments.
const List<String> _blockers = ['rules_cc', 'rules_go'];

/// The `.bazelrc` line importing the generated preset.
const String _presetImport = 'import %workspace%/tools/preset.bazelrc';

/// The `.bazelrc` line importing the strict config.
const String _strictImport = 'import %workspace%/tools/strict.bazelrc';

/// The `dart_toolchain` attributes whose targets' files the toolchain reads.
const List<String> _sdkAttrs = [
  'sdk_root',
  'compile_files',
  'runtime_files',
  'analyze_files',
];

/// The fewest action calls a scan of `dart/` can find and still be complete.
const int _minActionCalls = 24;

/// The pinned checkout action every new CI job uses.
const String _checkout =
    'actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd';

/// The pinned Bazel setup action every new CI job uses.
const String _setupBazel =
    'bazel-contrib/setup-bazel@c5acdfb288317d0b5c0bbd7a396a3dc868bb0f86';

/// The `mod-tidy` job's commands, in the order it must run them.
const List<String> _modTidyCommands = [
  'bazel mod tidy --lockfile_mode=refresh',
  'bazel build --nobuild --lockfile_mode=update //...',
  'bazel build --nobuild --lockfile_mode=error //...',
  'git diff --exit-code MODULE.bazel MODULE.bazel.lock',
];

/// One action call found by the scan: where it is, and what is wrong with
/// it, or null.
typedef _Call = ({String where, String? problem});

/// Checks the `.bazelrc` import and the `common:strict` flag set.
void _bazelrcTests(List<String> args) {
  group('bazelrc', () {
    test('.bazelrc imports tools/strict.bazelrc after the preset', () {
      final String root = _workspaceRoot(args);
      final List<String> lines = _rcLines(_read(root, '.bazelrc'));
      final int strict = lines.indexOf(_strictImport);
      expect(strict, isNonNegative, reason: '.bazelrc needs $_strictImport');
      expect(
        lines.indexOf(_presetImport),
        inInclusiveRange(0, strict - 1),
        reason: 'the strict import comes after $_presetImport',
      );
      expect(File('$root/tools/strict.bazelrc').existsSync(), isTrue);
    });

    test('common:strict names exactly the strict flags, one per line', () {
      final String root = _workspaceRoot(args);
      final List<String> lines = _rcLines(_read(root, 'tools/strict.bazelrc'));
      expect(_configProblems(lines), isEmpty);
      expect(_strictConfigFlags(lines), unorderedEquals(_strictFlags));
    });

    test('no config sets a blocked flag', () {
      final String root = _workspaceRoot(args);
      for (final rel in ['.bazelrc', 'tools/strict.bazelrc']) {
        final List<String> lines = _rcLines(_read(root, rel));
        expect(_blockedFlagLines(lines), isEmpty, reason: rel);
      }
    });

    test('only tools/strict.bazelrc defines the strict config', () {
      final String root = _workspaceRoot(args);
      for (final rel in ['.bazelrc', 'tools/preset.bazelrc']) {
        final List<String> lines = _rcLines(_read(root, rel));
        expect(_strictConfigLines(lines), isEmpty, reason: rel);
      }
    });

    test('the comments name both blocked flags and their blockers', () {
      final String root = _workspaceRoot(args);
      final String comments = _rcComments(_read(root, 'tools/strict.bazelrc'));
      for (final String needle in [..._blockedFlags, ..._blockers]) {
        expect(comments, contains(needle));
      }
    });
  });
}

/// Checks that `dart/toolchain.bzl` reads no target's legacy `.files`.
void _toolchainFileTests(List<String> args) {
  group('dart/toolchain.bzl', () {
    test('reads the SDK attributes through DefaultInfo', () {
      final String root = _workspaceRoot(args);
      final String code = _stripStarlark(_read(root, 'dart/toolchain.bzl'));
      expect(_legacyFilesReads(code), isEmpty);
      for (final String attr in _sdkAttrs) {
        expect(
          _defaultInfoRead(attr).hasMatch(code),
          isTrue,
          reason: 'expected ctx.attr.$attr[DefaultInfo].files',
        );
      }
    });
  });
}

/// Checks that every action call under `dart/` names its toolchain.
void _actionTests(List<String> args) {
  group('action toolchains', () {
    test('every action call under dart/ names its toolchain', () {
      final String root = _workspaceRoot(args);
      final List<_Call> calls = [
        for (final String rel in _bzlFiles(root, 'dart'))
          ..._actionCalls(rel, _read(root, rel)),
      ];
      expect(
        calls.length,
        greaterThanOrEqualTo(_minActionCalls),
        reason: 'the scan of dart/**/*.bzl found too few action calls',
      );
      expect([
        for (final call in calls)
          if (call.problem != null) '${call.where}: ${call.problem}',
      ], isEmpty);
    });
  });
}

/// Checks the `strict`, `last_rc` and `mod-tidy` jobs and the conclusion.
void _workflowTests(List<String> args) {
  String workflow() => _read(_workspaceRoot(args), '.github/workflows/ci.yaml');

  group('ci.yaml', () {
    test('strict tests under --config=strict without blocking', () {
      final List<String> job = _job(workflow(), 'strict');
      _expectSetup(job, 'strict');
      expect(_jobLevel(job, 'continue-on-error'), 'true');
      expect(_runText(job), contains('bazel test --config=strict //...'));
      expect(_commentAbove(workflow(), 'strict'), contains('2026-11-14'));
    });

    test('last_rc tests the last release candidate without blocking', () {
      final List<String> job = _job(workflow(), 'last_rc');
      _expectSetup(job, 'last_rc');
      expect(_jobLevel(job, 'continue-on-error'), 'true');
      expect(job.any(_lastRcVersion.hasMatch), isTrue);
      expect(_runText(job), contains('bazel test --lockfile_mode=off //...'));
    });

    test('mod-tidy runs the lockfile steps in order and may not fail', () {
      final List<String> job = _job(workflow(), 'mod-tidy');
      _expectSetup(job, 'mod-tidy');
      expect(job.where((line) => line.contains('continue-on-error')), isEmpty);
      expect(_firstMissing(_runText(job), _modTidyCommands), isNull);
    });

    test('conclusion needs mod-tidy but neither strict nor last_rc', () {
      final Set<String> needs = _needs(_job(workflow(), 'conclusion'));
      expect(needs, contains('mod-tidy'));
      expect(needs, isNot(contains('strict')));
      expect(needs, isNot(contains('last_rc')));
    });
  });
}

/// Checks the BCR presubmit matrix.
void _presubmitTests(List<String> args) {
  group('.bcr/presubmit.yml', () {
    test('the test module runs Bazel 9.x and rolling', () {
      final String yaml = _read(_workspaceRoot(args), '.bcr/presubmit.yml');
      expect(_bcrBazelVersions(yaml), containsAll(['9.x', 'rolling']));
    });
  });
}

/// Checks the parsers the checks above rely on, on small inputs.
void _parserTests() {
  group('guard self-checks', () {
    _starlarkParserTests();
    _bazelrcParserTests();
    _yamlParserTests();
  });
}

/// Checks comment and string removal and the action-call scan.
void _starlarkParserTests() {
  test('comments and strings are blanked with offsets kept', () {
    const source = 'a = "x(#" # y)\nb = """\nq)\n"""\nc = r"\\"("\nd()\n';
    final String code = _stripStarlark(source);
    expect(code.length, source.length);
    expect(code, isNot(contains('#')));
    expect(code, isNot(contains('q')));
    expect(code.split('\n')[5], 'd()');
  });

  test('a call with a top-level toolchain passes', () {
    const source =
        'ctx.actions.run(\n    outputs = [o],\n    toolchain = None,\n)\n';
    expect(_actionCalls('a.bzl', source).single.problem, isNull);
  });

  test('a toolchain only nested, commented or quoted is missing', () {
    const source =
        'ctx.actions.run(env = f(toolchain = None))\n'
        'ctx.actions.run_shell(\n    # toolchain = None,\n    command = "x",\n)\n'
        'ctx.actions.run(arguments = ["toolchain = None"])\n';
    final List<_Call> calls = _actionCalls('a.bzl', source);
    expect(
      [for (final call in calls) call.where],
      ['a.bzl:1', 'a.bzl:2', 'a.bzl:6'],
    );
    expect(calls.every((call) => call.problem != null), isTrue);
  });

  test('a docstring mention is not a call, an alias is a problem', () {
    const source = '"""Wraps `ctx.actions.run(`."""\nrun = ctx.actions.run\n';
    final List<_Call> calls = _actionCalls('a.bzl', source);
    expect(calls.single.where, 'a.bzl:2');
    expect(calls.single.problem, contains('without a call'));
  });

  test('a legacy files read is caught, a DefaultInfo read is not', () {
    expect(_legacyFilesReads('x = ctx.attr.sdk_root.files\n'), hasLength(1));
    expect(_legacyFilesReads('x = sdk_root.files\n'), hasLength(1));
    const fixed = 'x = ctx.attr.sdk_root[DefaultInfo].files\n';
    expect(_legacyFilesReads(fixed), isEmpty);
    expect(_defaultInfoRead('sdk_root').hasMatch(fixed), isTrue);
  });
}

/// Checks the bazelrc line and flag parsing.
void _bazelrcParserTests() {
  test('a commented-out flag is not set', () {
    final List<String> lines = _rcLines(
      '# common:strict --a\ncommon:strict --b # note\n',
    );
    expect(_strictConfigFlags(lines), ['--b']);
    expect(_configProblems(lines), isEmpty);
  });

  test('two flags on a line or another config are problems', () {
    final List<String> lines = _rcLines(
      'common:strict --a --b\nbuild:strict --c\ncommon --d\n',
    );
    expect(_configProblems(lines), hasLength(3));
    expect(_strictConfigLines(lines), hasLength(2));
  });

  test('a blocked flag is caught in any spelling', () {
    final List<String> lines = _rcLines(
      'common:strict --incompatible_no_rule_outputs_param=true\n'
      'build --noincompatible_disable_target_default_provider_fields\n'
      'common:strict --incompatible_no_rule_outputs_param_x\n',
    );
    expect(_blockedFlagLines(lines), hasLength(2));
  });
}

/// Checks the workflow and presubmit YAML slicing.
void _yamlParserTests() {
  const workflow =
      'on:\n  strict:\n    x: on\njobs:\n  # strict note\n  strict:\n'
      '    continue-on-error: true\n    steps:\n      - run: |\n'
      '          one\n          two\n      - run: three # c\n'
      '  # continue-on-error: true\n  conclusion:\n    needs: [strict, b]\n'
      '  other:\n    needs:\n      - c\n      - "d"\n    runs-on: x\n';

  test('job slicing stops at the next job and drops comments', () {
    final List<String> job = _job(workflow, 'strict');
    expect(job.first, '    continue-on-error: true');
    expect(_jobLevel(job, 'continue-on-error'), 'true');
    expect(job.where((line) => line.contains('continue')), hasLength(1));
    expect(_runText(job), 'one\ntwo\nthree');
    expect(_commentAbove(workflow, 'strict'), contains('strict note'));
  });

  test('needs parse in flow and block form', () {
    expect(_needs(_job(workflow, 'conclusion')), {'strict', 'b'});
    expect(_needs(_job(workflow, 'other')), {'c', 'd'});
  });

  test('commands must appear in order', () {
    expect(_firstMissing('a\nb\nc', ['a', 'c']), isNull);
    expect(_firstMissing('a\nb\nc', ['c', 'a']), 'a');
  });

  test('the BCR matrix versions parse in flow and block form', () {
    const flow =
        'bcr_test_module:\n  matrix:\n    bazel: ["9.x", "rolling"]\n'
        '  tasks:\n    bazel: other\n';
    const block =
        'bcr_test_module:\n  matrix:\n    bazel:\n      - 9.x\n'
        "      - 'rolling'\n  tasks: {}\n";
    expect(_bcrBazelVersions(flow), ['9.x', 'rolling']);
    expect(_bcrBazelVersions(block), ['9.x', 'rolling']);
  });
}

// Workspace access.

/// The workspace root: the real path of this test's own source minus the
/// source's workspace-relative path, as the `rlocationpath` in [args] names
/// it.
String _workspaceRoot(List<String> args) {
  if (args.isEmpty) {
    fail('pass the rlocationpath of strict_config_guard_test.dart');
  }
  final String rlocation = args.first;
  final String relative = rlocation.substring(rlocation.indexOf('/') + 1);
  final String located = Runfiles.create().rlocation(rlocation);
  final String real = _slashes(File(located).resolveSymbolicLinksSync());
  if (!real.endsWith('/$relative')) {
    fail('the anchor $real does not end in $relative');
  }
  final String root = real.substring(0, real.length - relative.length - 1);
  if (!File('$root/MODULE.bazel').existsSync()) {
    fail('$root, above the anchor, holds no MODULE.bazel');
  }
  return root;
}

/// The text of the workspace-relative file [rel].
String _read(String root, String rel) => File('$root/$rel').readAsStringSync();

/// [path] with forward slashes.
String _slashes(String path) => path.replaceAll(r'\', '/');

/// Workspace-relative paths of every `.bzl` file under [dir], sorted.
List<String> _bzlFiles(String root, String dir) {
  final Iterable<FileSystemEntity> entries = Directory('$root/$dir')
      .listSync(recursive: true, followLinks: false);
  return [
    for (final entry in entries)
      if (entry is File && entry.path.endsWith('.bzl'))
        _slashes(entry.path).substring(root.length + 1),
  ]..sort();
}

// Bazelrc parsing.

/// The lines of a bazelrc that set something, with comments cut off.
List<String> _rcLines(String text) => [
  for (final String line in text.split('\n'))
    if (_cutComment(line).isNotEmpty) _cutComment(line),
];

/// [line] up to any `#` comment, trimmed.
String _cutComment(String line) {
  final int at = line.indexOf('#');
  return (at < 0 ? line : line.substring(0, at)).trim();
}

/// The whitespace-separated words of a bazelrc [line].
List<String> _words(String line) => line.split(RegExp(r'\s+'));

/// The flags of every `common:strict` line, in file order.
List<String> _strictConfigFlags(List<String> lines) => [
  for (final String line in lines)
    if (_words(line).first == 'common:strict') ..._words(line).skip(1),
];

/// The lines that are not a single `common:strict` flag.
List<String> _configProblems(List<String> lines) => [
  for (final String line in lines)
    if (_words(line).length != 2 || _words(line).first != 'common:strict') line,
];

/// The lines that define any `<command>:strict` config.
List<String> _strictConfigLines(List<String> lines) => [
  for (final String line in lines)
    if (_words(line).first.endsWith(':strict')) line,
];

/// The lines that set a blocked flag, in any spelling Bazel accepts.
List<String> _blockedFlagLines(List<String> lines) => [
  for (final String line in lines)
    if (_words(line).any(_isBlockedFlag)) line,
];

/// Whether [word] sets a blocked flag: `--flag`, `--noflag` or `--flag=…`.
bool _isBlockedFlag(String word) => _blockedFlags.any((flag) {
  final String name = RegExp.escape(flag.substring(2));
  return RegExp('^--(no)?$name(=.*)?\$').hasMatch(word);
});

/// The text of every `#` comment in a bazelrc.
String _rcComments(String text) => [
  for (final String line in text.split('\n'))
    if (line.contains('#')) line.substring(line.indexOf('#') + 1),
].join('\n');

// Starlark scanning.

/// The callee of an action call, `ctx.actions.run` or `ctx.actions.run_shell`.
final RegExp _actionCallee = RegExp(
  r'\bctx\s*\.\s*actions\s*\.\s*(?:run|run_shell)\b',
);

/// A `toolchain =` keyword argument.
final RegExp _toolchainArg = RegExp(r'(?:^|[\s,])toolchain\s*=(?!=)');

/// [source] with every `#` comment and string literal blanked to spaces.
///
/// Newlines stay, so offsets and line numbers still match [source].
String _stripStarlark(String source) {
  final out = StringBuffer();
  var i = 0;
  while (i < source.length) {
    final String c = source[i];
    final bool quoted = c == '"' || c == "'";
    final int end = c == '#'
        ? _lineEnd(source, i)
        : (quoted ? _stringEnd(source, i) : i + 1);
    final String piece = source.substring(i, end);
    out.write(c == '#' || quoted ? _blank(piece) : piece);
    i = end;
  }
  return out.toString();
}

/// [text] with every character but newlines replaced by a space.
String _blank(String text) => text.replaceAll(RegExp('[^\n]'), ' ');

/// The offset of the newline ending the line at [from], or the text's end.
int _lineEnd(String text, int from) {
  final int newline = text.indexOf('\n', from);
  return newline < 0 ? text.length : newline;
}

/// The offset just past the string literal that opens at [start].
///
/// A backslash always skips the next character, as in Starlark's raw strings
/// too, and an unclosed one-line string ends at its line's end.
int _stringEnd(String text, int start) {
  final String quote = text[start];
  final String close = text.startsWith(quote * 3, start) ? quote * 3 : quote;
  int i = start + close.length;
  while (i < text.length) {
    if (text[i] == r'\') {
      i += 2;
    } else if (text.startsWith(close, i)) {
      return i + close.length;
    } else if (close.length == 1 && text[i] == '\n') {
      return i;
    } else {
      i++;
    }
  }
  return text.length;
}

/// The action calls in the Starlark [source] of [rel], with their problems.
List<_Call> _actionCalls(String rel, String source) {
  final String code = _stripStarlark(source);
  return [
    for (final RegExpMatch callee in _actionCallee.allMatches(code))
      (
        where: '$rel:${_lineOf(code, callee.start)}',
        problem: _callProblem(code, callee.end),
      ),
  ];
}

/// What is wrong with the action call whose callee ends at [calleeEnd] in
/// stripped [code], or null when it passes a top-level `toolchain =`.
String? _callProblem(String code, int calleeEnd) {
  final int open = code.indexOf(RegExp(r'\S'), calleeEnd);
  if (open < 0 || code[open] != '(') {
    return 'used without a call, so its arguments cannot be checked';
  }
  final int close = _closingParen(code, open);
  if (close < 0) {
    return 'its parentheses never close';
  }
  final String arguments = _topLevel(code.substring(open + 1, close));
  return _toolchainArg.hasMatch(arguments) ? null : 'passes no `toolchain =`';
}

/// The offset of the `)` that closes the `(` at [open], or -1.
int _closingParen(String code, int open) {
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    depth += switch (code[i]) {
      '(' => 1,
      ')' => -1,
      _ => 0,
    };
    if (depth == 0) {
      return i;
    }
  }
  return -1;
}

/// [arguments] with everything inside a nested bracket blanked out.
String _topLevel(String arguments) {
  final out = StringBuffer();
  var depth = 0;
  for (var i = 0; i < arguments.length; i++) {
    final String c = arguments[i];
    if ('([{'.contains(c)) {
      depth++;
    }
    out.write(depth == 0 ? c : ' ');
    if (')]}'.contains(c)) {
      depth--;
    }
  }
  return out.toString();
}

/// The 1-based line of [offset] in [text].
int _lineOf(String text, int offset) =>
    '\n'.allMatches(text.substring(0, offset)).length + 1;

/// Every `.files` read on an SDK attribute's target, directly through
/// `ctx.attr` or through a local of the same name.
List<String> _legacyFilesReads(String code) {
  final legacy = RegExp('\\b(?:${_sdkAttrs.join('|')})\\s*\\.\\s*files\\b');
  return [
    for (final RegExpMatch read in legacy.allMatches(code))
      'line ${_lineOf(code, read.start)}: ${read.group(0)}',
  ];
}

/// Matches `ctx.attr.<attr>[DefaultInfo].files`.
RegExp _defaultInfoRead(String attr) => RegExp(
  '\\bctx\\s*\\.\\s*attr\\s*\\.\\s*$attr\\s*\\[\\s*DefaultInfo\\s*\\]'
  r'\s*\.\s*files\b',
);

// Workflow and presubmit parsing.

/// A two-space-indented mapping key: a job header inside `jobs:`.
final RegExp _jobHeader = RegExp(r'^  ([A-Za-z0-9_-]+):\s*$');

/// A `run:` key, with the text before it and its value.
final RegExp _runKey = RegExp(r'^(\s*(?:-\s+)?)run:(.*)$');

/// The job-level `USE_BAZEL_VERSION` that selects the last release candidate.
final RegExp _lastRcVersion = RegExp(
  r'''^\s+USE_BAZEL_VERSION:\s*["']?last_rc["']?$''',
);

/// [line] without its YAML comment, right-trimmed; empty for a comment line.
String _yamlCode(String line) {
  if (line.trimLeft().startsWith('#')) {
    return '';
  }
  return line.replaceFirst(RegExp(r'\s#.*$'), '').trimRight();
}

/// The lines of the workflow's `jobs:` section.
List<String> _jobsSection(String workflow) {
  final List<String> lines = workflow.split('\n');
  final int start = lines.indexOf('jobs:');
  if (start < 0) {
    fail('the workflow has no jobs: section');
  }
  final int end = lines.indexWhere(
    (line) => RegExp(r'^[^\s#]').hasMatch(line),
    start + 1,
  );
  return lines.sublist(start + 1, end < 0 ? lines.length : end);
}

/// The index of job [id]'s header in the `jobs:` section [jobs].
int _jobStart(List<String> jobs, String id) {
  final int start = jobs.indexWhere(
    (line) => _jobHeader.firstMatch(line)?.group(1) == id,
  );
  if (start < 0) {
    fail('ci.yaml has no `$id` job');
  }
  return start;
}

/// The lines of job [id], without its header, blank lines or comments.
List<String> _job(String workflow, String id) {
  final List<String> jobs = _jobsSection(workflow);
  final job = <String>[];
  for (final String line in jobs.skip(_jobStart(jobs, id) + 1)) {
    if (_jobHeader.hasMatch(line)) {
      break;
    }
    final String code = _yamlCode(line);
    if (code.trim().isNotEmpty) {
      job.add(code);
    }
  }
  return job;
}

/// The comment lines directly above job [id]'s header, joined.
String _commentAbove(String workflow, String id) {
  final List<String> jobs = _jobsSection(workflow);
  final comments = <String>[];
  for (int i = _jobStart(jobs, id) - 1; i >= 0; i--) {
    if (!jobs[i].trimLeft().startsWith('#')) {
      break;
    }
    comments.insert(0, jobs[i].trim());
  }
  return comments.join('\n');
}

/// The value of the job-level [key] in [job], or null.
String? _jobLevel(List<String> job, String key) {
  final at = RegExp('^    ${RegExp.escape(key)}:(.*)\$');
  for (final line in job) {
    final RegExpMatch? match = at.firstMatch(line);
    if (match != null) {
      return _unquote(match.group(1)!.trim());
    }
  }
  return null;
}

/// Expects job [id] on `ubuntu-latest` with the pinned checkout and setup.
void _expectSetup(List<String> job, String id) {
  expect(_jobLevel(job, 'runs-on'), 'ubuntu-latest', reason: id);
  for (final String action in [_checkout, _setupBazel]) {
    final uses = RegExp('^\\s+(?:-\\s+)?uses:\\s*${RegExp.escape(action)}\$');
    expect(job.any(uses.hasMatch), isTrue, reason: '$id must use $action');
  }
}

/// Every `run:` command of [job], one per line, block scalars unfolded.
String _runText(List<String> job) {
  final commands = <String>[];
  for (var i = 0; i < job.length; i++) {
    final RegExpMatch? run = _runKey.firstMatch(job[i]);
    if (run == null) {
      continue;
    }
    final String value = run.group(2)!.trim();
    if (!value.startsWith('|') && !value.startsWith('>')) {
      commands.add(_unquote(value));
      continue;
    }
    final int column = run.group(1)!.length;
    for (int j = i + 1; j < job.length && _indent(job[j]) > column; j++) {
      commands.add(job[j].trim());
    }
  }
  return commands.join('\n');
}

/// The first of [commands] that does not follow the ones before it in
/// [text], or null when all appear in order.
String? _firstMissing(String text, List<String> commands) {
  var from = 0;
  for (final command in commands) {
    final int at = text.indexOf(command, from);
    if (at < 0) {
      return command;
    }
    from = at + command.length;
  }
  return null;
}

/// The job ids [job] lists under `needs:`, in flow or block form.
Set<String> _needs(List<String> job) {
  final int at = job.indexWhere((line) => line.startsWith('    needs:'));
  if (at < 0) {
    return {};
  }
  final String inline = job[at].substring('    needs:'.length).trim();
  if (inline.isNotEmpty) {
    return _flowItems(inline).toSet();
  }
  return _blockItems(job.skip(at + 1)).toSet();
}

/// The Bazel versions the `bcr_test_module` matrix lists.
List<String> _bcrBazelVersions(String yaml) {
  final List<String> lines = [
    for (final String line in yaml.split('\n'))
      if (_yamlCode(line).trim().isNotEmpty) _yamlCode(line),
  ];
  final int module = lines.indexOf('bcr_test_module:');
  final int matrix = module < 0
      ? -1
      : lines.indexWhere((line) => line.trim() == 'matrix:', module + 1);
  if (matrix < 0) {
    return [];
  }
  for (int i = matrix + 1; i < lines.length; i++) {
    if (_indent(lines[i]) <= _indent(lines[matrix])) {
      break;
    }
    final RegExpMatch? key = RegExp(r'^\s+bazel:(.*)$').firstMatch(lines[i]);
    if (key != null) {
      final String value = key.group(1)!.trim();
      return value.isEmpty ? _blockItems(lines.skip(i + 1)) : _flowItems(value);
    }
  }
  return [];
}

/// The items of a YAML flow sequence such as `[a, "b"]`, or of one scalar.
List<String> _flowItems(String value) {
  final bool bracketed = value.startsWith('[') && value.endsWith(']');
  final String inner = bracketed ? value.substring(1, value.length - 1) : value;
  return [
    for (final String item in inner.split(','))
      if (item.trim().isNotEmpty) _unquote(item.trim()),
  ];
}

/// The items of the YAML block sequence that starts [lines].
List<String> _blockItems(Iterable<String> lines) {
  final items = <String>[];
  for (final line in lines) {
    final RegExpMatch? item = RegExp(r'^\s*-\s+(.+)$').firstMatch(line);
    if (item == null) {
      break;
    }
    items.add(_unquote(item.group(1)!.trim()));
  }
  return items;
}

/// [value] without one pair of surrounding YAML quotes.
String _unquote(String value) {
  final bool quoted =
      value.length >= 2 &&
      (value.startsWith('"') && value.endsWith('"') ||
          value.startsWith("'") && value.endsWith("'"));
  return quoted ? value.substring(1, value.length - 1) : value;
}

/// The number of leading spaces of [line].
int _indent(String line) => line.length - line.trimLeft().length;
