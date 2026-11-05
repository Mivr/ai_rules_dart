/// Verifies the Linux user-namespace setup in CI: the shared script, its
/// wiring at the start of every Linux Bazel job, the `linux-sandbox` proof step
/// and the `reproducibility` output bases. Every check returns violation
/// messages; an empty list means the input is sound.
library;

/// The shared setup script, as invoked from a job that checks out at `.`.
const String scriptPath = '.github/scripts/enable_linux_sandbox.sh';

/// A Linux job that runs Bazel and must run the setup script first.
class LinuxBazelJob {
  /// Creates the description of one job.
  const new(
    this.file,
    this.job, {
    this.script = scriptPath,
    this.gated = false,
  });

  /// Workflow file name under `.github/workflows`.
  final String file;

  /// Job key.
  final String job;

  /// Script path as written in the step's `run:`.
  final String script;

  /// Whether the step must be gated on the Linux matrix entries.
  final bool gated;
}

/// A job that must not run the setup script: macOS, Windows or non-Bazel.
class UnchangedJob {
  /// Creates the description of one job.
  const new(this.file, this.job);

  /// Workflow file name under `.github/workflows`.
  final String file;

  /// Job key.
  final String job;
}

/// The ten Linux jobs that run Bazel.
const List<LinuxBazelJob> linuxBazelJobs = [
  LinuxBazelJob('ci.yaml', 'test', gated: true),
  LinuxBazelJob('ci.yaml', 'format-hermeticity'),
  LinuxBazelJob('ci.yaml', 'run-home'),
  LinuxBazelJob('ci.yaml', 'expected-failure'),
  LinuxBazelJob('ci.yaml', 'dbg-mode'),
  LinuxBazelJob('ci.yaml', 'reproducibility'),
  LinuxBazelJob('ci.yaml', 'hermetic-strict'),
  LinuxBazelJob('commit-messages.yaml', 'check'),
  LinuxBazelJob('perf-linux.yaml', 'bench', script: 'tools-src/$scriptPath'),
];

/// The jobs that stay untouched.
const List<UnchangedJob> unchangedJobs = [
  UnchangedJob('ci.yaml', 'mac-smoke'),
  UnchangedJob('ci.yaml', 'pre-commit'),
  UnchangedJob('ci.yaml', 'conclusion'),
  UnchangedJob('full.yaml', 'test-macos'),
  UnchangedJob('publish.yaml', 'publish'),
  UnchangedJob('release.yaml', 'gate'),
  UnchangedJob('release.yaml', 'release'),
  UnchangedJob('tag.yaml', 'tag'),
  UnchangedJob('tag.yaml', 'release'),
];

const String _sysctl =
    'sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0';
const String _unshare = 'unshare -U -r -m -p -f --mount-proc true';

/// Checks the setup script text.
List<String> verifyScript(String text) {
  final List<String> out = [];
  void need(String needle, String why) {
    if (!text.contains(needle)) out.add('script: $why (missing `$needle`)');
  }

  need('#!/usr/bin/env bash', 'bash shebang');
  need('set -euo pipefail', 'strict mode');
  need(_sysctl, 'disables the AppArmor userns restriction');
  need(
    'sudo sysctl -w kernel.unprivileged_userns_clone=1',
    'enables userns clone',
  );
  need(
    '/proc/sys/kernel/apparmor_restrict_unprivileged_userns',
    'sysctl guard',
  );
  need('cp /usr/bin/unshare', 'copies unshare to an unprofiled path');
  need('userns_probe', 'names the unprofiled probe');
  need('RUNNER_TEMP:-/tmp', 'puts the probe under RUNNER_TEMP');
  need('chmod +x', 'makes the probe executable');
  need(r'"$probe" -U -r -m -p -f --mount-proc true', 'runs the probe');
  need('rm -f', 'removes the probe');
  need('EXIT', 'removes the probe on exit');
  if (RegExp(
    r'^unshare -U -r -m -p -f --mount-proc true$',
    multiLine: true,
  ).allMatches(text).isEmpty) {
    out.add('script: must run `$_unshare` directly');
  }
  if (RegExp(r'if\s+!\s+unshare').hasMatch(text)) {
    out.add('script: sysctl must not be gated on `if ! unshare`');
  }
  if (text.contains('|| true')) out.add('script: must not tolerate failure');
  final int sysctl = text.indexOf(_sysctl);
  if (sysctl >= 0 && sysctl > text.indexOf(_unshare)) {
    out.add('script: sysctl must run before the first unshare');
  }
  return out;
}

/// Returns the block of job [job] in workflow [text], or null.
String? jobBlock(String text, String job) {
  final RegExpMatch? start = RegExp(
    '^  ${RegExp.escape(job)}:\\s*\$',
    multiLine: true,
  ).firstMatch(text);
  if (start == null) return null;
  final RegExpMatch? next = RegExp(r'^  [a-zA-Z0-9_-]+:\s*$', multiLine: true)
      .allMatches(text)
      .where((RegExpMatch m) => m.start > start.start)
      .firstOrNull;
  return text.substring(start.start, next?.start ?? text.length);
}

/// Splits a job block into its steps.
List<String> stepBlocks(String block) {
  final List<int> starts = RegExp(
    '^      - ',
    multiLine: true,
  ).allMatches(block).map((RegExpMatch m) => m.start).toList();
  return [
    for (int i = 0; i < starts.length; i++)
      block.substring(
        starts[i],
        i + 1 < starts.length ? starts[i + 1] : block.length,
      ),
  ];
}

String _withoutComments(String text) =>
    text.split('\n').where((l) => !l.trimLeft().startsWith('#')).join('\n');

/// Checks that [job] runs the setup script before any Bazel use.
List<String> verifyJob(LinuxBazelJob job, String? workflow) {
  final label = '${job.file}:${job.job}';
  final String? raw = workflow == null ? null : jobBlock(workflow, job.job);
  if (raw == null) return ['$label: job not found'];
  final String block = _withoutComments(raw);
  final List<String> out = [];
  final int script = block.indexOf('run: ${job.script}');
  if (script < 0) return ['$label: must run `${job.script}`'];
  final RegExpMatch? bazel = RegExp(r'\bbazel\b').firstMatch(block);
  if (bazel != null && bazel.start < script) {
    out.add('$label: starts Bazel before the setup script');
  }
  final String step = stepBlocks(block)
      .firstWhere((s) => s.contains('run: ${job.script}'));
  out.addAll(_stepViolations(label, step, job));
  if (RegExp(r'\b(sysctl|unshare)\b').hasMatch(block)) {
    out.add('$label: carries an inline sysctl or unshare copy');
  }
  return out;
}

List<String> _stepViolations(String label, String step, LinuxBazelJob job) {
  final List<String> out = [];
  if (job.gated && !step.contains("if: matrix.os == 'ubuntu-latest'")) {
    out.add('$label: setup step must be gated to ubuntu-latest');
  }
  if (!job.gated && step.contains('if:')) {
    out.add('$label: setup step must not be conditional');
  }
  if (step.contains('working-directory:')) {
    out.add('$label: setup step must not set working-directory');
  }
  if (step.contains('|| true') || step.contains('continue-on-error')) {
    out.add('$label: setup step must not tolerate failure');
  }
  return out;
}

/// Checks that [job] does not run the setup script.
List<String> verifyUnchanged(UnchangedJob job, String? workflow) {
  final label = '${job.file}:${job.job}';
  final String? block = workflow == null ? null : jobBlock(workflow, job.job);
  if (block == null) return ['$label: job not found'];
  if (block.contains('enable_linux_sandbox')) {
    return ['$label: must stay unchanged (no setup script)'];
  }
  return [];
}

/// Checks the `reproducibility` job's output bases.
List<String> verifyReproducibility(String? workflow) {
  final String? block = workflow == null
      ? null
      : jobBlock(workflow, 'reproducibility');
  if (block == null) return ['reproducibility: job not found'];
  final List<String> out = [];
  for (final side in ['a', 'b']) {
    if (!block.contains('"--output_base=\${RUNNER_TEMP}/repro_canary_$side"')) {
      out.add('reproducibility: output base $side must sit under RUNNER_TEMP');
    }
  }
  if (block.contains('--output_base=/tmp')) {
    out.add('reproducibility: output base must not sit under /tmp');
  }
  if (!RegExp(r"trap '[^\n]*shutdown[^\n]*' EXIT").hasMatch(block)) {
    out.add('reproducibility: must shut the scratch servers down in a trap');
  }
  if (RegExp(r'\bgates\b', caseSensitive: false).hasMatch(block)) {
    out.add('reproducibility: block must not contain the word gates');
  }
  return out;
}

/// Checks the root-workspace `linux-sandbox` proof step in [workflow].
List<String> verifyProof(String? workflow) {
  final String? raw = workflow == null
      ? null
      : jobBlock(workflow, 'hermetic-strict');
  final String? step = raw == null
      ? null
      : stepBlocks(raw)
            .where(
              (s) =>
                  s.contains('--build_event_json_file=') &&
                  s.contains('linux-sandbox'),
            )
            .firstOrNull;
  if (step == null) return ['proof: no root-workspace linux-sandbox step'];
  final needs = {
    '--output_base=': 'dedicated output base',
    'RUNNER_TEMP': 'output base under RUNNER_TEMP',
    '--disk_cache= ': 'disabled disk cache',
    '--nocache_test_results': 'uncached test results',
    'EXIT': 'shutdown trap',
    'shutdown': 'shutdown trap',
    'processwrapper-sandbox': 'processwrapper-sandbox count',
    '-ne 0': 'processwrapper-sandbox == 0',
    '-lt 1': 'linux-sandbox >= 1',
    ' //dart/': 'root-workspace target',
  };
  final List<String> out = [
    for (final MapEntry<String, String> e in needs.entries)
      if (!step.contains(e.key)) 'proof: missing ${e.value} (`${e.key}`)',
  ];
  if (step.contains('--spawn_strategy') || step.contains('working-directory')) {
    out.add('proof: must use default strategy selection in the root workspace');
  }
  if (step.contains('|| true') || step.contains('continue-on-error')) {
    out.add('proof: must not tolerate failure');
  }
  return out;
}

/// Checks that the `test` job keeps its five Windows matrix legs.
List<String> verifyWindowsLegs(String? workflow) {
  final int legs = RegExp('os: windows-latest')
      .allMatches(workflow ?? '')
      .length;
  return legs == 5 ? [] : ['ci.yaml:test: expected 5 Windows legs, got $legs'];
}

/// Runs every workflow check; [files] maps workflow file names to text.
List<String> verifyWorkflows(Map<String, String> files) {
  return [
    for (final LinuxBazelJob j in linuxBazelJobs)
      ...verifyJob(j, files[j.file]),
    for (final UnchangedJob j in unchangedJobs)
      ...verifyUnchanged(j, files[j.file]),
    ...verifyReproducibility(files['ci.yaml']),
    ...verifyProof(files['ci.yaml']),
    ...verifyWindowsLegs(files['ci.yaml']),
  ];
}
