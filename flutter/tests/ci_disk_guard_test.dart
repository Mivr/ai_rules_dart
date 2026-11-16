/// Static guard for the hosted-Linux disk headroom in `ci.yaml` and `full.yaml`.
///
/// Hosted ubuntu-latest runners now start with about 86 GB free on a 145 GB
/// disk (2026-11-16), far more than a cached push job uses, so the push jobs
/// spend no time freeing disk: removing the preinstalled toolchains cost 40 to
/// 120 s per job. They still log `df -h /` before the first workspace and after
/// each one, so a shortfall shows in the log before it fails a job. The cold
/// nightly in `full.yaml` keeps the cleanup as headroom for uncached builds.
library;

import 'dart:io';

import 'package:test/test.dart';

/// The ci.yaml jobs that run e2e workspaces on a hosted Linux runner, with the
/// workspaces each runs in order.
const Map<String, List<String>> _e2eJobs = {
  'e2e-linux-app': ['hello_world', 'codegen'],
  'e2e-linux-small': [
    'smoke',
    'dual_hub',
    'ffi_example',
    'ffi_plugin_example',
    'web_example',
  ],
  'e2e-linux-integration': [
    'integration_web',
    'integration_linux',
    'integration_android',
    'min_versions',
    'android_no_go_sdk',
  ],
  'e2e-linux-examples': ['linux_example', 'cross_compile_example'],
  'e2e-linux-pub-scc': ['pub_scc'],
};

/// Hosted-Linux jobs that run Bazel against workspaces without a `Run e2e/`
/// step: they need no per-workspace report.
const List<String> _otherLinuxJobs = ['unit-tests', 'web-smoke'];

/// Finds the rules_flutter repository root directory.
String _locateRepoRoot() {
  final String? buildDir = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (buildDir != null && buildDir.isNotEmpty && _hasRepoMarkers(buildDir)) {
    return buildDir;
  }
  final String? anchor = Platform.environment['GUARD_ROOT_ANCHOR'];
  final String? srcdir = Platform.environment['TEST_SRCDIR'];
  if (anchor != null && anchor.isNotEmpty && srcdir != null) {
    try {
      Directory candidate = File(
        File('$srcdir/$anchor').resolveSymbolicLinksSync(),
      ).parent;
      for (var depth = 0; depth < 8; depth++) {
        if (_hasRepoMarkers(candidate.path)) {
          return candidate.path;
        }
        candidate = candidate.parent;
      }
    } on FileSystemException {
      // Fall through to Directory.current resolution below.
    }
  }
  Directory currentDir = Directory.current;
  for (var depth = 0; depth < 8; depth++) {
    if (_hasRepoMarkers(currentDir.path)) {
      return currentDir.path;
    }
    currentDir = currentDir.parent;
  }
  throw StateError('Failed to discover rules_flutter repository root');
}

/// Returns true if [path] looks like the repository root.
bool _hasRepoMarkers(String path) =>
    File('$path/MODULE.bazel').existsSync() &&
    Directory('$path/flutter').existsSync() &&
    Directory('$path/e2e').existsSync();

/// The text of the top-level job [name] in [workflow].
String _job(String workflow, String name) {
  final RegExpMatch? m = RegExp(
    '^  $name:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|(?![\\s\\S]))',
    multiLine: true,
    dotAll: true,
  ).firstMatch(workflow);
  if (m == null) {
    fail('no `$name` job');
  }
  return m.group(1)!;
}

/// The steps of [job], each as its own text block.
List<String> _steps(String job) => job
    .substring(job.indexOf('\n    steps:\n'))
    .split(RegExp('^      - ', multiLine: true))
    .skip(1)
    .toList();

void main() {
  late final String root;
  late final String ci;
  late final String free;
  late final String report;
  setUpAll(() {
    root = _locateRepoRoot();
    ci = File('$root/.github/workflows/ci.yaml').readAsStringSync();
    free = File('$root/.github/actions/free-disk/action.yaml')
        .readAsStringSync();
    report = File('$root/.github/actions/disk-report/action.yaml')
        .readAsStringSync();
  });

  group('free-disk action', () {
    test('removes the unused toolchains and says what it skips', () {
      for (final p in const [
        '/usr/share/dotnet',
        '/opt/ghc',
        '/opt/hostedtoolcache/CodeQL',
        '/usr/share/swift',
      ]) {
        expect(free, contains(p));
      }
      expect(free, contains('skip: '));
      expect(free, contains('cannot remove'));
      expect(free, contains(r'exit "$status"'));
      expect(free, contains('df -h /'));
    });
    test('keeps the Android SDK the rules discover through ANDROID_HOME', () {
      // The removal list is the `for p in ...; do` line.
      final String list = RegExp(r'for p in ([^;\n]*);').firstMatch(free)![1]!;
      expect(list, isNot(contains('android')));
      expect(list, isNot(contains('hostedtoolcache/Python')));
      expect(list, isNot(contains('hostedtoolcache/node')));
    });
  });

  group('disk-report action', () {
    test('logs df -h / under a label and names missing directories', () {
      expect(report, contains('df -h /'));
      expect(report, contains('inputs.label'));
      expect(report, contains('missing: '));
    });
  });

  group('ci.yaml e2e jobs', () {
    _e2eJobs.forEach((String name, List<String> workspaces) {
      test('$name spends no time freeing disk', () {
        final List<String> steps = _steps(_job(ci, name));
        expect(steps.first, contains('actions/checkout'));
        expect(_job(ci, name), isNot(contains('actions/free-disk')));
      });
      test('$name reports disk before and after every workspace', () {
        final List<String> steps = _steps(_job(ci, name));
        int at(String label) => steps.indexWhere(
          (s) =>
              s.contains('uses: ./.github/actions/disk-report') &&
              s.contains('label: $label\n') &&
              s.contains('if: always()\n'),
        );
        int previous = at('before first workspace');
        expect(previous, greaterThan(1), reason: 'no report before workspaces');
        for (final w in workspaces) {
          final int run = steps.indexWhere(
            (s) => s.startsWith('name: Run e2e/$w\n'),
          );
          expect(run, greaterThan(previous), reason: 'Run e2e/$w misplaced');
          final int after = at('after e2e/$w');
          expect(after, greaterThan(run), reason: 'no report after $w');
          previous = after;
        }
      });
      test('$name keeps its job name', () {
        expect(_job(ci, name), startsWith('    name: E2E Linux'));
      });
    });
    for (final String name in _otherLinuxJobs) {
      test('$name spends no time freeing disk', () {
        expect(_job(ci, name), isNot(contains('actions/free-disk')));
      });
    }
    test('no ci.yaml job frees disk', () {
      expect(ci, isNot(contains('actions/free-disk')));
    });
  });

  test('full.yaml nightly Linux job frees disk right after checkout', () {
    final String full = File('$root/.github/workflows/full.yaml')
        .readAsStringSync();
    final List<String> steps = _steps(_job(full, 'e2e-linux-nightly'));
    expect(steps[1], contains('uses: ./.github/actions/free-disk\n'));
  });
}
