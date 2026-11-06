import 'package:test/test.dart';

import 'ci_linux_sandbox_verifier.dart';

const String _goodScript = r'''
#!/usr/bin/env bash
set -euo pipefail
if [ -f /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]; then
  sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
fi
if [ -f /proc/sys/kernel/unprivileged_userns_clone ]; then
  sudo sysctl -w kernel.unprivileged_userns_clone=1
fi
unshare -U -r -m -p -f --mount-proc true
probe="${RUNNER_TEMP:-/tmp}/userns_probe"
trap 'rm -f "$probe"' EXIT
cp /usr/bin/unshare "$probe"
chmod +x "$probe"
"$probe" -U -r -m -p -f --mount-proc true
''';

const String _proofStep = r'''
      - name: Prove linux-sandbox runs root-workspace actions
        run: |
          base="${RUNNER_TEMP}/proof"
          trap 'bazel "--output_base=$base" shutdown' EXIT
          bazel "--output_base=$base" test --disk_cache= --nocache_test_results --build_event_json_file="$bep" //dart/tests/x:y
          echo processwrapper-sandbox
          if [ "$wrapper" -ne 0 ] || [ "$linux" -lt 1 ]; then exit 1; fi
''';

const String _reproJob = r'''
  reproducibility:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Enable and verify Linux user namespaces
        run: .github/scripts/enable_linux_sandbox.sh
      - run: |
          trap 'bazel "--output_base=${RUNNER_TEMP}/repro_canary_a" shutdown' EXIT
          bazel "--output_base=${RUNNER_TEMP}/repro_canary_a" build //:c
          bazel "--output_base=${RUNNER_TEMP}/repro_canary_b" build //:c
''';

/// The Linux Bazel jobs of the synthetic layout.
const List<LinuxBazelJob> _linuxJobs = [
  LinuxBazelJob('ci.yaml', 'test', gated: true),
  LinuxBazelJob('ci.yaml', 'format-hermeticity'),
  LinuxBazelJob('ci.yaml', 'run-home'),
  LinuxBazelJob('ci.yaml', 'expected-failure'),
  LinuxBazelJob('ci.yaml', 'dbg-mode'),
  LinuxBazelJob('ci.yaml', 'reproducibility'),
  LinuxBazelJob('ci.yaml', 'hermetic-strict'),
  LinuxBazelJob('buildifier.yaml', 'check'),
  LinuxBazelJob('perf-linux.yaml', 'bench', script: 'tools-src/$scriptPath'),
];

String _stepFor(LinuxBazelJob j) {
  final gate = j.gated ? "        if: matrix.os == 'ubuntu-latest'\n" : '';
  return '      - uses: actions/checkout@v7\n'
      '      - name: Enable and verify Linux user namespaces\n'
      '$gate        run: ${j.script}\n'
      '      - run: bazel build //...\n';
}

String _job(String name, String body) =>
    '  $name:\n    runs-on: ubuntu-latest\n    steps:\n$body';

/// A passing set of workflow files, with [override] replacing job bodies.
Map<String, String> _workflows({Map<String, String> override = const {}}) {
  final Map<String, StringBuffer> files = {};
  for (final LinuxBazelJob j in _linuxJobs) {
    final String body = override['${j.file}:${j.job}'] ?? _stepFor(j);
    final String text = j.job == 'reproducibility'
        ? (override['${j.file}:${j.job}'] ?? _reproJob)
        : _job(j.job, body);
    files.putIfAbsent(j.file, StringBuffer.new).write('$text\n');
  }
  for (final UnchangedJob j in unchangedJobs) {
    final String body = override['${j.file}:${j.job}'] ?? '      - run: true\n';
    files.putIfAbsent(j.file, StringBuffer.new).write(_job(j.job, body));
  }
  final Map<String, String> out = {
    for (final MapEntry<String, StringBuffer> e in files.entries)
      e.key: e.value.toString(),
  };
  out['ci.yaml'] =
      '${out['ci.yaml']}'
      '${'          - os: windows-latest\n' * 5}';
  return out;
}

void main() {
  group('script', () {
    test('accepts the shared script', () {
      expect(verifyScript(_goodScript), isEmpty);
    });
    test('rejects a missing sysctl', () {
      final String bad = _goodScript.replaceAll(
        'sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0',
        'true',
      );
      expect(verifyScript(bad), isNotEmpty);
    });
    test('rejects a sysctl gated on unshare', () {
      final String bad = _goodScript.replaceFirst(
        'if [ -f',
        'if ! unshare -U true; then\n  :\nfi\nif [ -f',
      );
      expect(verifyScript(bad).join(), contains('if ! unshare'));
    });
    test('rejects a missing direct unshare', () {
      final String bad = _goodScript.replaceFirst(
        RegExp(r'^unshare -U -r -m -p -f --mount-proc true$', multiLine: true),
        '',
      );
      expect(verifyScript(bad).join(), contains('directly'));
    });
    test('rejects a missing unprofiled probe', () {
      final String bad = _goodScript
          .replaceAll('userns_probe', 'p')
          .replaceAll('cp /usr/bin/unshare', 'true');
      expect(verifyScript(bad), isNotEmpty);
    });
  });

  group('workflows', () {
    test('accepts a sound layout', () {
      final List<String> v = verifyWorkflows(_workflows());
      expect(v.where((s) => !s.startsWith('proof:')), isEmpty);
    });
    test('rejects a Linux Bazel job without the shared step', () {
      final Map<String, String> w = _workflows(
        override: {'buildifier.yaml:check': '      - run: bazel build //...\n'},
      );
      expect(verifyJob(_linuxJobs[7], w['buildifier.yaml']), isNotEmpty);
    });
    test('reports an ubuntu job that calls bazel without the script', () {
      final Map<String, String> w = _workflows();
      w['new.yaml'] =
          'jobs:\n${_job('fresh', '      - run: bazel test //...\n')}';
      final List<String> v = verifyWorkflows(w);
      expect(v.join('\n'), contains('new.yaml:fresh: must run'));
    });
    test('does not require the script in an unchanged job', () {
      final Map<String, String> w = _workflows(
        override: {'ci.yaml:pre-commit': '      - run: bazel build //...\n'},
      );
      expect(
        discoverLinuxBazelJobs(w).map((j) => j.job),
        isNot(contains('pre-commit')),
      );
      expect(verifyWorkflows(w).join(), isNot(contains('pre-commit')));
    });
    test('accepts a new ubuntu job that runs the script', () {
      final Map<String, String> w = _workflows();
      w['new.yaml'] =
          'jobs:\n${_job('fresh', _stepFor(const LinuxBazelJob('new.yaml', 'fresh')))}';
      expect(discoverLinuxBazelJobs(w).map((j) => j.job), contains('fresh'));
      expect(verifyWorkflows(w).join(), isNot(contains('fresh')));
    });
    test('ignores bazel in names, uses lines and non-ubuntu jobs', () {
      final Map<String, String> w = _workflows();
      w['new.yaml'] =
          'jobs:\n'
          '  a:\n    runs-on: ubuntu-latest\n    steps:\n'
          '      - uses: bazel-contrib/setup-bazel@x\n'
          '      - name: bazel build\n        run: true\n'
          '  b:\n    runs-on: macos-latest\n    steps:\n'
          '      - run: bazel build //...\n';
      expect(discoverLinuxBazelJobs(w).map((j) => j.job), isNot(contains('a')));
      expect(discoverLinuxBazelJobs(w).map((j) => j.job), isNot(contains('b')));
    });
    test('rejects Bazel running before the shared step', () {
      final LinuxBazelJob j = _linuxJobs[2];
      final body =
          '      - run: bazel build //...\n'
          '      - run: ${j.script}\n';
      final String wf = _job(j.job, body);
      expect(verifyJob(j, wf).join(), contains('before'));
    });
    test('rejects an inline sysctl copy in a job', () {
      final LinuxBazelJob j = _linuxJobs[4];
      final String wf = _job(
        j.job,
        '${_stepFor(j)}      - run: sudo sysctl -w a=0\n',
      );
      expect(verifyJob(j, wf).join(), contains('inline'));
    });
    test('rejects a touched macOS, Windows or non-Bazel job', () {
      const j = UnchangedJob('ci.yaml', 'mac-smoke');
      final String wf = _job(
        j.job,
        '      - run: .github/scripts/enable_linux_sandbox.sh\n',
      );
      expect(verifyUnchanged(j, wf), isNotEmpty);
    });
    test('rejects a gated step missing its gate and a wrong Windows count', () {
      const j = LinuxBazelJob('ci.yaml', 'test', gated: true);
      final String wf = _job(
        j.job,
        _stepFor(const LinuxBazelJob('ci.yaml', 'test')),
      );
      expect(verifyJob(j, wf).join(), contains('gated'));
      expect(verifyWindowsLegs('os: windows-latest\n'), isNotEmpty);
    });
    test('rejects a working-directory on the setup step', () {
      final LinuxBazelJob j = _linuxJobs[1];
      final String wf = _job(
        j.job,
        '      - name: x\n        working-directory: e2e/a\n'
        '        run: ${j.script}\n',
      );
      expect(verifyJob(j, wf).join(), contains('working-directory'));
    });
  });

  group('reproducibility', () {
    test('accepts RUNNER_TEMP output bases', () {
      expect(verifyReproducibility(_reproJob), isEmpty);
    });
    test('rejects /tmp output bases', () {
      final String bad = _reproJob.replaceAll(
        r'"--output_base=${RUNNER_TEMP}/repro_canary_b"',
        '--output_base=/tmp/repro_canary_b',
      );
      expect(verifyReproducibility(bad), isNotEmpty);
    });
    test('rejects the word gates and a missing trap', () {
      final String bad = _reproJob.replaceAll(' EXIT', ' gates');
      expect(verifyReproducibility(bad).length, greaterThanOrEqualTo(2));
    });
  });

  group('proof step', () {
    String wf(String step) => '  hermetic-strict:\n    steps:\n$step';
    test('accepts the proof step', () {
      expect(verifyProof(wf(_proofStep)), isEmpty);
    });
    test('rejects a missing linux-sandbox >= 1 check', () {
      expect(
        verifyProof(wf(_proofStep.replaceAll('-lt 1', '-lt 0'))),
        isNotEmpty,
      );
    });
    test('rejects a missing processwrapper-sandbox == 0 check', () {
      expect(
        verifyProof(wf(_proofStep.replaceAll('-ne 0', '-ne 9'))),
        isNotEmpty,
      );
    });
    test('rejects a forced spawn strategy and a missing step', () {
      final String forced = _proofStep.replaceFirst(
        'test --disk_cache=',
        'test --spawn_strategy=linux-sandbox --disk_cache=',
      );
      expect(verifyProof(wf(forced)).join(), contains('default strategy'));
      expect(verifyProof(wf('      - run: true\n')), isNotEmpty);
    });
  });
}
