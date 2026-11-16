/// Verifier for the CI Linux sandbox setup: the shared user-namespace script
/// and the workflow steps that run it before Bazel starts.
library;

/// Repo-relative path of the shared script.
const String scriptPath = '.github/scripts/enable_linux_sandbox.sh';

const String _unshareProbe = '-U -r -m -p -f --mount-proc true';

/// Linux jobs that run Bazel, keyed by workflow file name.
///
/// `perf-linux.yaml` checks the repository out under `tools-src`, so its
/// script path carries that prefix.
const Map<String, List<String>> linuxBazelJobs = <String, List<String>>{
  'ci.yaml': <String>[
    'unit-tests',
    'e2e-linux-app',
    'e2e-linux-small',
    'e2e-linux-integration',
    'e2e-linux-android',
    'e2e-linux-examples',
    'e2e-linux-pub-scc',
    'web-smoke',
    'flake-sweep',
    'repo-checks',
    'reproducibility',
  ],
  'full.yaml': <String>['e2e-linux-nightly'],
  'commit-messages.yaml': <String>['check'],
  'perf-linux.yaml': <String>['bench'],
};

/// Jobs that must not run the script: macOS, Windows and non-Bazel jobs.
const Map<String, List<String>> untouchedJobs = <String, List<String>>{
  'ci.yaml': <String>[
    'e2e-macos-apple',
    'e2e-macos-toolchain',
    'e2e-windows',
    'pre-commit',
    'dart-tool-tests',
    'conclusion',
  ],
  'full.yaml': <String>['e2e-macos', 'dev-tool-ios', 'conclusion'],
  'perf-ios.yaml': <String>['bench'],
  'publish.yaml': <String>['publish'],
  'release.yaml': <String>['gate-tag-matrix', 'release'],
  'tag.yaml': <String>['tag', 'release'],
};

/// Workflow file contents keyed by file name.
class WorkflowSet {
  const new(this.files);

  final Map<String, String> files;
}

/// Script path a job in [file] must run.
String scriptPathFor(String file) =>
    file == 'perf-linux.yaml' ? 'tools-src/$scriptPath' : scriptPath;

/// Drops whole-line comments and trailing ` # ` comments.
String stripComments(String yaml) => yaml
    .split('\n')
    .where((String l) => !l.trimLeft().startsWith('#'))
    .map((String l) => l.replaceFirst(RegExp(r'\s#(\s.*)?$'), ''))
    .join('\n');

/// The text of job [name] under `jobs:` in [yaml], or null when absent.
String? jobBlock(String yaml, String name) {
  final List<String> lines = stripComments(yaml).split('\n');
  final int jobsAt = lines.indexOf('jobs:');
  if (jobsAt < 0) return null;
  final header = RegExp(r'^  ([A-Za-z0-9_-]+):\s*$');
  int? start;
  for (int i = jobsAt + 1; i < lines.length; i++) {
    final RegExpMatch? m = header.firstMatch(lines[i]);
    if (m == null) continue;
    if (start != null) return lines.sublist(start, i).join('\n');
    if (m.group(1) == name) start = i;
  }
  return start == null ? null : lines.sublist(start).join('\n');
}

/// Splits a job block into its `      - ` steps.
List<String> steps(String block) {
  final out = <String>[];
  for (final String line in block.split('\n')) {
    if (line.startsWith('      - ')) {
      out.add(line);
    } else if (out.isNotEmpty) {
      out[out.length - 1] += '\n$line';
    }
  }
  return out;
}

/// Violations in the shared setup script's text.
List<String> verifyScript(String script) {
  final bad = <String>[];
  final List<String> lines = script.split('\n');
  if (lines.first != '#!/usr/bin/env bash') bad.add('script: bad shebang');
  if (!lines.contains('set -euo pipefail')) {
    bad.add('script: missing set -euo pipefail');
  }
  if (!RegExp(
    r'^\s*sudo sysctl -w kernel\.apparmor_restrict_unprivileged_userns=0$',
    multiLine: true,
  ).hasMatch(script)) {
    bad.add('script: missing apparmor_restrict_unprivileged_userns=0 sysctl');
  }
  if (RegExp(r'if\s+!\s*[^\n]*unshare').hasMatch(script)) {
    bad.add('script: sysctl gated on `if ! unshare`');
  }
  if (!script.contains('sudo sysctl -w kernel.unprivileged_userns_clone=1')) {
    bad.add('script: missing unprivileged_userns_clone sysctl');
  }
  if (!lines.contains('unshare $_unshareProbe')) {
    bad.add('script: missing `unshare $_unshareProbe`');
  }
  bad.addAll(_verifyProbe(script));
  if (script.contains('|| true')) bad.add('script: contains `|| true`');
  return bad;
}

List<String> _verifyProbe(String script) {
  final needs = <String, String>{
    'userns_probe': 'userns_probe path',
    'RUNNER_TEMP:-/tmp': 'RUNNER_TEMP-based probe path',
    r'cp /usr/bin/unshare "$probe"': 'copy of /usr/bin/unshare',
    r'chmod +x "$probe"': 'chmod +x of the probe',
    '"\$probe" $_unshareProbe': 'unprofiled probe run',
    'trap \'rm -f "\$probe"\' EXIT': 'probe removal on exit',
  };
  return <String>[
    for (final MapEntry<String, String> e in needs.entries)
      if (!script.contains(e.key)) 'script: missing ${e.value}',
  ];
}

/// Violations for every Linux Bazel job: the shared step exists and comes
/// before any Bazel use, with no inline copy of the setup.
List<String> verifyLinuxJobs(WorkflowSet set) {
  final bad = <String>[];
  for (final MapEntry<String, List<String>> e in linuxBazelJobs.entries) {
    final String? yaml = set.files[e.key];
    for (final String job in e.value) {
      final String? block = yaml == null ? null : jobBlock(yaml, job);
      if (block == null) {
        bad.add('${e.key}: job $job missing');
        continue;
      }
      bad.addAll(_verifyJobOrder(e.key, job, block));
    }
  }
  return bad;
}

List<String> _verifyJobOrder(String file, String job, String block) {
  final String want = scriptPathFor(file);
  final List<String> all = steps(block);
  final int at = all.indexWhere(
    (String s) =>
        RegExp('run:\\s*${RegExp.escape(want)}\\s*(\\n|\$)').hasMatch(s),
  );
  if (at < 0) return <String>['$file: job $job does not run $want'];
  final bad = <String>[];
  for (var i = 0; i < at; i++) {
    if (RegExp(r'\bbazel\b').hasMatch(all[i])) {
      bad.add('$file: job $job uses bazel before $want');
    }
  }
  return bad;
}

/// Violations for inline `sysctl`/`unshare` copies in any workflow.
List<String> verifyNoInlineSetup(WorkflowSet set) => <String>[
  for (final MapEntry<String, String> e in set.files.entries)
    if (RegExp(r'\b(sysctl|unshare)\b').hasMatch(stripComments(e.value)))
      '${e.key}: inline sysctl/unshare instead of the shared script',
];

/// Violations for jobs that must stay untouched.
List<String> verifyUntouchedJobs(WorkflowSet set) {
  final bad = <String>[];
  for (final MapEntry<String, List<String>> e in untouchedJobs.entries) {
    final String? yaml = set.files[e.key];
    for (final String job in e.value) {
      final String? block = yaml == null ? null : jobBlock(yaml, job);
      if (block == null) {
        bad.add('${e.key}: job $job missing');
      } else if (block.contains('enable_linux_sandbox')) {
        bad.add('${e.key}: job $job must not run the Linux sandbox script');
      }
    }
  }
  return bad;
}

/// Violations in the `reproducibility` job's output bases.
List<String> verifyReproducibility(String ci) {
  final String? block = jobBlock(ci, 'reproducibility');
  if (block == null) return <String>['ci.yaml: job reproducibility missing'];
  final Set<String> bases = RegExp(
    r"""--output_base=([^\s"'`]+)""",
  ).allMatches(block).map((RegExpMatch m) => m.group(1)!).toSet();
  final bad = <String>[];
  if (bases.length < 2) bad.add('reproducibility: need two distinct bases');
  for (final b in bases) {
    if (!b.startsWith(r'${RUNNER_TEMP}/')) {
      bad.add('reproducibility: --output_base=$b is not under RUNNER_TEMP');
    }
  }
  if (!RegExp(r'trap\s[^\n]*shutdown[^\n]*\sEXIT').hasMatch(block)) {
    bad.add('reproducibility: scratch servers are not shut down in a trap');
  }
  return bad;
}

/// Violations in the root-workspace `linux-sandbox` proof step of
/// `unit-tests`.
List<String> verifyProofStep(String ci) {
  final String? block = jobBlock(ci, 'unit-tests');
  if (block == null) return <String>['ci.yaml: job unit-tests missing'];
  final String? step = steps(block).cast<String?>().firstWhere(
    (String? s) => s!.contains('--build_event_json_file'),
    orElse: () => null,
  );
  if (step == null) return <String>['unit-tests: no BEP proof step'];
  final needs = <String, RegExp>{
    'a dedicated --output_base under RUNNER_TEMP': RegExp(
      r'--output_base=\$\{',
    ),
    'an EXIT trap that shuts the base down': RegExp(
      r'trap\s[^\n]*shutdown[^\n]*\sEXIT',
    ),
    '--disk_cache=': RegExp(r'--disk_cache=(\s|$)'),
    '--nocache_test_results': RegExp('--nocache_test_results'),
    'a python3 BEP parser': RegExp(r'python3[\s\S]*runnerCount'),
    'processwrapper-sandbox == 0 assertion': RegExp(
      r'processwrapper-sandbox[^\n]*(!=|>)\s*0',
    ),
    'linux-sandbox >= 1 assertion': RegExp(r'linux-sandbox[^\n]*<\s*1'),
  };
  return <String>[
    for (final MapEntry<String, RegExp> e in needs.entries)
      if (!e.value.hasMatch(step)) 'unit-tests proof step lacks ${e.key}',
    if (RegExp(r'--spawn_strategy|--strategy|\bgrep\b').hasMatch(step))
      'unit-tests proof step must not pin a strategy or use grep',
  ];
}

/// Every violation across the script and the workflow set.
List<String> verifyAll(String script, WorkflowSet set) => <String>[
  ...verifyScript(script),
  ...verifyLinuxJobs(set),
  ...verifyNoInlineSetup(set),
  ...verifyUntouchedJobs(set),
  ...verifyReproducibility(set.files['ci.yaml'] ?? ''),
  ...verifyProofStep(set.files['ci.yaml'] ?? ''),
];
