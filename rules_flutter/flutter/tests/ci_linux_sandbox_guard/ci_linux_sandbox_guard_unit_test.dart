/// Unit tests for the CI Linux sandbox verifier over synthetic inputs.
library;

import 'package:test/test.dart';

import 'ci_linux_sandbox_verifier.dart';

const String _goodScript = r'''
#!/usr/bin/env bash
set -euo pipefail
if [[ -e /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]]; then
  sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
fi
if [[ -e /proc/sys/kernel/unprivileged_userns_clone ]]; then
  sudo sysctl -w kernel.unprivileged_userns_clone=1
fi
unshare -U -r -m -p -f --mount-proc true
probe="${RUNNER_TEMP:-/tmp}/userns_probe"
trap 'rm -f "$probe"' EXIT
cp /usr/bin/unshare "$probe"
chmod +x "$probe"
"$probe" -U -r -m -p -f --mount-proc true
''';

const String _reproBody = r'''
        run: |
          trap 'bazel shutdown' EXIT
          bazel "--output_base=${RUNNER_TEMP}/repro_canary_a" build //:canary
          bazel "--output_base=${RUNNER_TEMP}/repro_canary_b" build //:canary
''';

const String _proofBody = r'''
      - name: Prove sandboxed actions run under linux-sandbox
        run: |
          trap 'bazel "--output_base=${base}" shutdown' EXIT
          bazel "--output_base=${base}" test //x --disk_cache= --nocache_test_results "--build_event_json_file=${bep}"
          python3 - "$bep" <<'PY'
          runnerCount = 1
          if counts.get("processwrapper-sandbox", 0) != 0:
              pass
          if counts.get("linux-sandbox", 0) < 1:
              pass
          PY
''';

String _job(String file, String name) {
  final String script = scriptPathFor(file);
  final String extra = switch ((file, name)) {
    ('ci.yaml', 'reproducibility') => '      - name: canary\n$_reproBody',
    ('ci.yaml', 'unit-tests') => _proofBody,
    _ => '',
  };
  return '''
  $name:
    steps:
      - uses: actions/checkout@v7
      - name: Enable Linux sandbox user namespaces
        run: $script
      - uses: bazel-contrib/setup-bazel@abc
$extra''';
}

String _plainJob(String name) =>
    '''
  $name:
    steps:
      - uses: actions/checkout@v7
      - run: echo hi
''';

Map<String, String> _goodFiles() {
  final names = <String>{
    ...linuxBazelJobs.keys,
    ...untouchedJobs.keys,
  };
  return <String, String>{
    for (final String file in names)
      file:
          'jobs:\n'
          '${[for (final String j in linuxBazelJobs[file] ?? <String>[]) _job(file, j)].join()}'
          '${[for (final String j in untouchedJobs[file] ?? <String>[]) _plainJob(j)].join()}',
  };
}

List<String> _verifyWith(
  String Function(String file, String text) mutate,
) {
  final Map<String, String> files = _goodFiles();
  return verifyAll(
    _goodScript,
    WorkflowSet(<String, String>{
      for (final MapEntry<String, String> e in files.entries)
        e.key: mutate(e.key, e.value),
    }),
  );
}

void main() {
  test('good synthetic inputs have no violations', () {
    expect(_verifyWith((f, t) => t), isEmpty);
  });

  group('script', () {
    final breaks = <String, String Function(String)>{
      'missing apparmor sysctl': (s) => s.replaceAll(
        'sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0',
        'true',
      ),
      'sysctl gated on if ! unshare': (s) => s.replaceFirst(
        'if [[ -e /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]]',
        'if ! unshare -U true',
      ),
      'missing unshare check': (s) =>
          s.replaceFirst('\nunshare -U -r -m -p -f --mount-proc true', ''),
      'missing unprofiled probe': (s) =>
          s.replaceFirst(r'"$probe" -U -r -m -p -f --mount-proc true', ''),
      'missing chmod': (s) => s.replaceFirst(r'chmod +x "$probe"', ''),
      'missing cleanup trap': (s) =>
          s.replaceFirst('trap \'rm -f "\$probe"\' EXIT', ''),
      'swallowed failure': (s) => '$s|| true\n',
    };
    for (final MapEntry<String, String Function(String)> b in breaks.entries) {
      test(b.key, () => expect(verifyScript(b.value(_goodScript)), isNotEmpty));
    }
    test(
      'good script passes',
      () => expect(verifyScript(_goodScript), isEmpty),
    );
  });

  group('workflows', () {
    test('job missing the shared step', () {
      final List<String> bad = _verifyWith(
        (f, t) => f == 'full.yaml'
            ? t.replaceAll('run: ${scriptPathFor(f)}', 'run: echo')
            : t,
      );
      expect(
        bad,
        contains('full.yaml: job e2e-linux-nightly does not run $scriptPath'),
      );
    });
    test('bazel runs before the shared step', () {
      final List<String> bad = _verifyWith(
        (f, t) => f == 'commit-messages.yaml'
            ? t.replaceFirst(
                'actions/checkout@v7',
                'bazel-contrib/setup-bazel@x',
              )
            : t,
      );
      expect(bad.single, contains('uses bazel before'));
    });
    test('perf-linux must use the tools-src path', () {
      final List<String> bad = _verifyWith(
        (f, t) => f == 'perf-linux.yaml'
            ? t.replaceAll('tools-src/$scriptPath', scriptPath)
            : t,
      );
      expect(bad.single, contains('perf-linux.yaml: job bench'));
    });
    test('inline sysctl copy in a job', () {
      final List<String> bad = _verifyWith(
        (f, t) => f == 'ci.yaml'
            ? t.replaceFirst(
                '      - run: echo hi',
                '      - run: sudo sysctl -w a=0',
              )
            : t,
      );
      expect(bad.single, contains('inline sysctl/unshare'));
    });
    test('touched macOS job', () {
      final List<String> bad = _verifyWith(
        (f, t) => f == 'ci.yaml'
            ? t.replaceFirst('      - run: echo hi', '      - run: $scriptPath')
            : t,
      );
      expect(bad.single, contains('e2e-macos-apple must not run'));
    });
    test('touched non-Bazel job in another workflow', () {
      final List<String> bad = _verifyWith(
        (f, t) => f == 'tag.yaml'
            ? t.replaceFirst('      - run: echo hi', '      - run: $scriptPath')
            : t,
      );
      expect(bad.single, contains('tag.yaml: job tag must not run'));
    });
  });

  group('reproducibility', () {
    String ci(String Function(String) f) => f(_goodFiles()['ci.yaml']!);
    test('/tmp output base', () {
      final List<String> bad = verifyReproducibility(
        ci(
          (t) => t.replaceFirst(
            r'${RUNNER_TEMP}/repro_canary_a',
            '/tmp/repro_canary_a',
          ),
        ),
      );
      expect(bad.single, contains('not under RUNNER_TEMP'));
    });
    test('single output base', () {
      final List<String> bad = verifyReproducibility(
        ci((t) => t.replaceAll('repro_canary_b', 'repro_canary_a')),
      );
      expect(bad, contains('reproducibility: need two distinct bases'));
    });
    test('no shutdown trap', () {
      final List<String> bad = verifyReproducibility(
        ci((t) => t.replaceFirst("trap 'bazel shutdown' EXIT", 'true')),
      );
      expect(bad.single, contains('not shut down'));
    });
  });

  group('proof step', () {
    String ci(String Function(String) f) => f(_goodFiles()['ci.yaml']!);
    test('missing linux-sandbox >= 1', () {
      final List<String> bad = verifyProofStep(
        ci((t) => t.replaceFirst('counts.get("linux-sandbox", 0) < 1', 'True')),
      );
      expect(bad.single, contains('linux-sandbox >= 1'));
    });
    test('missing processwrapper-sandbox == 0', () {
      final List<String> bad = verifyProofStep(
        ci(
          (t) => t.replaceFirst(
            'counts.get("processwrapper-sandbox", 0) != 0',
            'True',
          ),
        ),
      );
      expect(bad.single, contains('processwrapper-sandbox == 0'));
    });
    test('pinned strategy', () {
      final List<String> bad = verifyProofStep(
        ci(
          (t) => t.replaceFirst(
            ' test //x',
            ' test --spawn_strategy=linux-sandbox //x',
          ),
        ),
      );
      expect(bad.single, contains('must not pin a strategy'));
    });
    test('missing step entirely', () {
      final List<String> bad = verifyProofStep(
        ci((t) => t.replaceAll('--build_event_json_file', '--other')),
      );
      expect(bad, contains('unit-tests: no BEP proof step'));
    });
  });
}
