import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Locks the hermetic-strict CI signal in place.
///
/// The canary workspace stays red by design, the strict job keeps the H1
/// flag set with its shimmed repository environment and its BEP check, the
/// expected-failure job keeps the canary self-test, and no positive sweep
/// picks the canary up. Runs unsandboxed over the live tree, resolving the
/// root from its own runfiles anchor with an ancestor-walk fallback.
void main(List<String> args) {
  final String root = _repoRoot(args);
  _checkCanary(root);
  _checkStrict(root);
  _checkConclusion(root);
  _checkSelfTest(root);
  _checkSweep(root);
  _checkSlicing();
}

/// Checks the red-by-design canary workspace layout.
void _checkCanary(String root) {
  group('canary workspace', () {
    test('layout matches the red-by-design contract', () {
      final dir = Directory('$root/e2e/hermetic_canary');
      expect(dir.existsSync(), isTrue, reason: 'missing e2e/hermetic_canary');
      final build = File('${dir.path}/BUILD.bazel');
      expect(build.existsSync(), isTrue, reason: 'missing BUILD.bazel');
      expect(
        build.readAsStringSync().trim().isNotEmpty,
        isTrue,
        reason: 'BUILD.bazel must declare targets',
      );
      expect(
        File('${dir.path}/MODULE.bazel').existsSync(),
        isTrue,
        reason: 'missing MODULE.bazel',
      );
      expect(
        File('${dir.path}/.bazelversion').readAsStringSync().trim(),
        equals('9.3.0'),
        reason: '.bazelversion must pin 9.3.0',
      );
      final lock = File('${dir.path}/MODULE.bazel.lock');
      expect(lock.existsSync(), isTrue, reason: 'missing MODULE.bazel.lock');
      expect(
        lock.readAsStringSync().trim().isNotEmpty,
        isTrue,
        reason: 'MODULE.bazel.lock must be generated, not empty',
      );
    });
  });
}

/// Checks the strict job keeps every H1 flag, mount and BEP file.
void _checkStrict(String root) {
  group('strict job', () {
    test('block keeps every H1 flag, mount and BEP file', () {
      final String text = File('$root/.github/workflows/ci.yaml')
          .readAsStringSync();
      final String block = _jobBlock(text, 'hermetic-strict');
      for (final String flag in _requiredFlags) {
        expect(
          block.contains(flag),
          isTrue,
          reason: 'hermetic-strict block must contain $flag',
        );
      }
      for (final String mount in _requiredMounts) {
        expect(
          block.contains(mount),
          isTrue,
          reason: 'hermetic-strict block must mount $mount',
        );
      }
      final int beps = RegExp('--build_event_json_file=')
          .allMatches(block)
          .length;
      expect(beps, greaterThanOrEqualTo(2), reason: 'need two BEP files');
    });
  });
}

/// Checks the conclusion job still gates on the strict job.
void _checkConclusion(String root) {
  group('conclusion', () {
    test('conclusion still gates on the strict job', () {
      final String text = File('$root/.github/workflows/ci.yaml')
          .readAsStringSync();
      final String block = _jobBlock(text, 'conclusion');
      expect(
        RegExp(r'^\s*-\s*hermetic-strict\s*$', multiLine: true).hasMatch(block),
        isTrue,
        reason: 'conclusion needs must list hermetic-strict',
      );
    });
  });
}

/// Checks the expected-failure canary self-test.
void _checkSelfTest(String root) {
  group('self-test', () {
    test('expected-failure proves the canary fails strict', () {
      final String text = File('$root/.github/workflows/ci.yaml')
          .readAsStringSync();
      final String block = _jobBlock(text, 'expected-failure');
      expect(
        block.contains('e2e/hermetic_canary'),
        isTrue,
        reason: 'expected-failure must name e2e/hermetic_canary',
      );
      expect(
        block.contains('--experimental_use_hermetic_linux_sandbox'),
        isTrue,
        reason: 'self-test must pass the hermetic flag',
      );
      expect(
        block.contains('--output_base='),
        isTrue,
        reason: 'self-test must isolate the strict base',
      );
      expect(
        block.contains('continue-on-error'),
        isFalse,
        reason: 'self-test must not tolerate success',
      );
    });
  });
}

/// Checks no positive sweep runs the canary.
void _checkSweep(String root) {
  group('sweep', () {
    test('no positive sweep runs the canary', () {
      final String text = File('$root/.github/workflows/ci.yaml')
          .readAsStringSync();
      expect(
        _jobBlock(text, 'test').contains('e2e/hermetic_canary'),
        isFalse,
        reason: 'test matrices must not name the canary',
      );
      final String options = File('$root/tools/vm/run_e2e_options.dart')
          .readAsStringSync();
      expect(
        options.contains('e2e/hermetic_canary'),
        isFalse,
        reason: 'ciFolders must not name the canary',
      );
    });
  });
}

/// Checks the job slicer used above.
void _checkSlicing() {
  group('checker self-checks', () {
    test('job slicing stops at the next job', () {
      const doc = '  alpha:\n    x: 1\n  beta:\n    y: 2\n';
      expect(_jobBlock(doc, 'alpha'), contains('x: 1'));
      expect(_jobBlock(doc, 'alpha'), isNot(contains('y: 2')));
    });

    test('missing job raises', () {
      expect(() => _jobBlock('  alpha:\n', 'beta'), throwsStateError);
    });
  });
}

/// Every flag the strict phases must keep passing to Bazel.
const List<String> _requiredFlags = [
  '--worker_sandboxing',
  '--experimental_worker_sandbox_hardening',
  '--experimental_worker_strict_flagfiles',
  '--experimental_use_hermetic_linux_sandbox',
  '--sandbox_add_mount_pair',
  '--nosandbox_default_allow_network',
  '--sandbox_fake_username',
  '--sandbox_fake_hostname',
  '--experimental_strict_repo_env',
  '--repo_env=PATH=',
  '--build_event_json_file=',
  '--skip_incompatible_explicit_targets',
];

/// Minimal mount set the hermetic sandbox must keep.
const List<String> _requiredMounts = [
  '/lib64',
  '/lib/x86_64-linux-gnu',
  '/usr/lib/x86_64-linux-gnu',
  '/etc/ld.so.cache',
];

/// The YAML block of a two-space-indented top-level job.
String _jobBlock(String text, String job) {
  final RegExpMatch? start = RegExp(
    '^  $job:\\s*\$',
    multiLine: true,
  ).firstMatch(text);
  if (start == null) {
    throw StateError('job $job not found');
  }
  final Iterable<RegExpMatch> later = RegExp(
    r'^  [A-Za-z0-9_-]+:\s*$',
    multiLine: true,
  ).allMatches(text).where((RegExpMatch m) => m.start > start.start);
  final int end = later.isEmpty ? text.length : later.first.start;
  return text.substring(start.start, end);
}

/// Source-tree root from the runfiles anchor or an ancestor walk.
String _repoRoot(List<String> args) {
  if (args.isNotEmpty) {
    try {
      final String located = Runfiles.create().rlocation(args.first);
      if (File(located).existsSync()) {
        final String? found = _climb(Directory(located).parent);
        if (found != null) {
          return found;
        }
      }
    } on Object catch (_) {
      // Fall through to the environment walk below.
    }
  }
  for (final candidate in <String?>[
    Platform.environment['BUILD_WORKSPACE_DIRECTORY'],
    Platform.environment['BUILD_WORKING_DIRECTORY'],
    Directory.current.path,
  ]) {
    if (candidate == null) {
      continue;
    }
    final String? found = _climb(Directory(candidate));
    if (found != null) {
      return found;
    }
  }
  throw StateError('cannot locate the workspace root');
}

/// Nearest ancestor holding both MODULE.bazel and a dart/ tree.
String? _climb(Directory? here) {
  var dir = here;
  while (dir != null) {
    final bool module = File('${dir.path}/MODULE.bazel').existsSync();
    final bool dart = Directory('${dir.path}/dart').existsSync();
    if (module && dart) {
      return dir.path;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) {
      return null;
    }
    dir = parent;
  }
  return null;
}
