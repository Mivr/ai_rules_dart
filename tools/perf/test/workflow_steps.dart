/// Step-scoped checks of `.github/workflows/perf-linux.yaml`.
library;

import 'dart:io';

/// Throws a [StateError] named `FAIL: ...` unless [condition] holds.
void check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

/// One workflow step: its raw [block] text and the extracted `run:` [script].
final class WorkflowStep {
  /// Creates a step record.
  const WorkflowStep(this.name, this.block, this.script);

  /// The `name:` of the step.
  final String name;

  /// Every line belonging to the step.
  final String block;

  /// The dedented `run: |` script, or empty for `uses:` steps.
  final String script;
}

String _extractScript(List<String> lines) {
  final start = lines.indexWhere(
    (l) => RegExp(r'^\s*run:\s*\|\s*$').hasMatch(l),
  );
  if (start == -1) return '';
  final out = <String>[];
  for (final line in lines.skip(start + 1)) {
    if (line.trim().isEmpty) {
      out.add('');
      continue;
    }
    if (!line.startsWith('          ')) break;
    out.add(line.substring(10));
  }
  return '${out.join('\n').trimRight()}\n';
}

/// Splits [text] into its job steps, keyed by step name.
Map<String, WorkflowStep> parseSteps(String text) {
  final steps = <String, WorkflowStep>{};
  final lines = text.split('\n');
  final starts = <int>[
    for (var i = 0; i < lines.length; i++)
      if (RegExp(r'^      - name: ').hasMatch(lines[i])) i,
  ];
  for (var s = 0; s < starts.length; s++) {
    final end = s + 1 < starts.length ? starts[s + 1] : lines.length;
    final block = lines.sublist(starts[s], end);
    final name = block.first
        .replaceFirst(RegExp(r'^      - name: '), '')
        .trim();
    steps[name] = WorkflowStep(name, block.join('\n'), _extractScript(block));
  }
  return steps;
}

/// Returns the step called [name] or throws.
WorkflowStep requireStep(String text, String name) {
  final step = parseSteps(text)[name];
  check(step != null, 'step "$name" exists');
  return step!;
}

/// Name of the step that runs the repeats.
const String repeatsStepName = 'Run speed-of-light runner repeats';

/// Name of the step that summarizes results.
const String summarizeStepName = 'Summarize speed-of-light results';

void _verifyRepeatsGuard(WorkflowStep step) {
  check(
    RegExp(
      r'case "\$REPEATS" in\s*\n\s*\x27\x27 \| \*\[!0-9\]\* \| 0\*\)[\s\S]*?exit 1',
    ).hasMatch(step.script),
    '${step.name}: validates REPEATS is a positive integer >= 1',
  );
}

void _verifyGenerateStep(String text) {
  final step = requireStep(text, 'Generate pristine monorepo');
  check(
    step.script.contains(r'--rules-dart="$GITHUB_WORKSPACE/rules-head"'),
    'generate passes --rules-dart="\$GITHUB_WORKSPACE/rules-head"',
  );
  check(
    !step.script.contains('tools-src"'),
    'generate never points at tools-src',
  );
}

void _verifyRepeatsStep(String text) {
  final step = requireStep(text, repeatsStepName);
  final script = step.script;
  check(!script.contains('|| true'), 'repeats step has no "|| true"');
  _verifyRepeatsGuard(step);
  check(script.contains('failed=0'), 'repeats step starts with failed=0');
  check(script.contains('|| failed=1'), 'repeats step records "|| failed=1"');
  check(
    script.trimRight().split('\n').last.trim() == r'exit "$failed"',
    'repeats step ends with exit "\$failed"',
  );
}

void _verifySummarizeStep(String text) {
  final step = requireStep(text, summarizeStepName);
  final script = step.script;
  check(
    step.block.contains(r'if: ${{ !cancelled() }}'),
    'summarize step runs on !cancelled()',
  );
  _verifyRepeatsGuard(step);
  check(
    script.contains(r'git -C "$GITHUB_WORKSPACE/rules-head" rev-parse HEAD'),
    'summarize resolves sha from rules-head',
  );
  check(!script.contains('tools-src" rev-parse'), 'sha never from tools-src');
  check(script.contains('summary_rc=0'), 'summarize initializes summary_rc');
  check(
    script.contains(r'|| summary_rc=$?'),
    'summarize captures //perf:summarize exit status',
  );
  check(
    RegExp(
      r'-f "\$GITHUB_WORKSPACE/dart-sol\.json" \]'
      r'[^\n]*GITHUB_STEP_SUMMARY[\s\S]*?cat "\$GITHUB_WORKSPACE/dart-sol\.json"'
      r' >> "\$GITHUB_STEP_SUMMARY"',
    ).hasMatch(script),
    'summarize appends dart-sol.json to the step summary when it exists',
  );
  check(
    script.trimRight().split('\n').last.trim() == r'exit "$summary_rc"',
    'summarize step ends with exit "\$summary_rc"',
  );
}

void _verifyTailSteps(String text) {
  check(
    requireStep(
      text,
      'Shut down tooling Bazel server',
    ).block.contains(r'if: ${{ always() }}'),
    'shutdown step runs on always()',
  );
  check(
    requireStep(
      text,
      'Upload dart-sol artifact',
    ).block.contains(r"if: ${{ !cancelled() && inputs.head_ref != '' }}"),
    'upload step runs on !cancelled() && head_ref set',
  );
}

/// Verifies per-step failure-propagation invariants of [text].
void verifyWorkflowSteps(String text) {
  check(
    !text.contains('continue-on-error'),
    'no job or step may set continue-on-error',
  );
  _verifyGenerateStep(text);
  _verifyRepeatsStep(text);
  _verifySummarizeStep(text);
  _verifyTailSteps(text);
}

/// Result of running a step script under bash.
typedef ShellOutcome = ({int exitCode, String log, String summary});

const String _stubBazel = r'''#!/bin/bash
echo "$*" >> "$STUB_LOG"
case "$*" in
  *//perf:runner*)
    for a in "$@"; do
      case "$a" in --repeat=*) n="${a#--repeat=}" ;; esac
    done
    if [ "$n" = "${STUB_FAIL_REPEAT:-}" ]; then exit 7; fi
    ;;
  *//perf:summarize*)
    for a in "$@"; do
      case "$a" in --out=*) echo '{"flows":{}}' > "${a#--out=}" ;; esac
    done
    exit "${STUB_SUMMARY_RC:-0}"
    ;;
esac
''';

/// Runs [script] under `bash -eo pipefail` with a stub `bazel` on PATH.
ShellOutcome runStepScript(String script, {required Map<String, String> env}) {
  final root = Directory.systemTemp.createTempSync('rd_wf_');
  try {
    Directory('${root.path}/tools-src/tools').createSync(recursive: true);
    Directory('${root.path}/bin').createSync();
    final stub = File('${root.path}/bin/bazel')..writeAsStringSync(_stubBazel);
    Process.runSync('chmod', ['+x', stub.path]);
    final logFile = File('${root.path}/stub.log')..writeAsStringSync('');
    final summaryFile = File('${root.path}/step_summary.md')
      ..writeAsStringSync('');
    final res = Process.runSync(
      'bash',
      ['-eo', 'pipefail', '-c', script],
      workingDirectory: root.path,
      environment: {
        'PATH': '${root.path}/bin:${Platform.environment['PATH']}',
        'RUNNER_TEMP': '${root.path}/tmp',
        'GITHUB_WORKSPACE': root.path,
        'GITHUB_STEP_SUMMARY': summaryFile.path,
        'STUB_LOG': logFile.path,
        'HEAD_REF': 'main',
        'TARGET_LOC': '1000',
        'SEED': '1',
        ...env,
      },
    );
    return (
      exitCode: res.exitCode,
      log: logFile.readAsStringSync(),
      summary: summaryFile.readAsStringSync(),
    );
  } finally {
    root.deleteSync(recursive: true);
  }
}

/// Executes the repeats and summarize scripts of [text] against a stub bazel.
void verifyStepScriptsExecute(String text) {
  final repeats = requireStep(text, repeatsStepName).script;
  for (final bad in ['0', '-1', 'abc', '00', '']) {
    final out = runStepScript(repeats, env: {'REPEATS': bad});
    check(out.exitCode != 0, 'REPEATS="$bad" exits non-zero');
    check(
      !out.log.contains('//perf:runner'),
      'REPEATS="$bad" must not invoke //perf:runner',
    );
  }
  final ok = runStepScript(repeats, env: {'REPEATS': '2'});
  check(ok.exitCode == 0, 'REPEATS=2 with healthy runner exits 0');

  final failing = runStepScript(
    repeats,
    env: {'REPEATS': '2', 'STUB_FAIL_REPEAT': '1'},
  );
  check(failing.exitCode != 0, 'a failed repeat 1 makes the step fail');
  check(
    failing.log.contains('--repeat=2'),
    'repeat 2 still runs after repeat 1 failed',
  );

  final summarize = requireStep(text, summarizeStepName).script;
  for (final bad in ['0', '-1', 'abc']) {
    final out = runStepScript(summarize, env: {'REPEATS': bad});
    check(out.exitCode != 0, 'summarize REPEATS="$bad" exits non-zero');
    check(
      !out.log.contains('//perf:summarize'),
      'summarize REPEATS="$bad" must not invoke //perf:summarize',
    );
  }
  final red = runStepScript(
    summarize,
    env: {'REPEATS': '2', 'STUB_SUMMARY_RC': '1'},
  );
  check(red.exitCode == 1, 'failed //perf:summarize exits 1');
  check(
    red.summary.contains('"flows"'),
    'dart-sol.json is appended to GITHUB_STEP_SUMMARY on failure',
  );
  final green = runStepScript(summarize, env: {'REPEATS': '2'});
  check(green.exitCode == 0, 'successful //perf:summarize exits 0');
}
