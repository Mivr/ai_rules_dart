import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

void main(List<String> args) {
  group('reproducibility canary guard', () {
    test('e2e/repro_canary workspace structure and non-deterministic rule', () {
      final String root = _findWorkspaceRoot(args);
      final canaryDir = Directory('$root/e2e/repro_canary');
      expect(
        canaryDir.existsSync(),
        isTrue,
        reason: 'e2e/repro_canary must exist',
      );

      final buildFile = File('${canaryDir.path}/BUILD.bazel');
      expect(
        buildFile.existsSync(),
        isTrue,
        reason: 'e2e/repro_canary/BUILD.bazel must exist',
      );
      expect(
        buildFile.readAsStringSync().trim().isNotEmpty,
        isTrue,
        reason: 'e2e/repro_canary/BUILD.bazel must not be empty',
      );

      final moduleFile = File('${canaryDir.path}/MODULE.bazel');
      expect(
        moduleFile.existsSync(),
        isTrue,
        reason: 'e2e/repro_canary/MODULE.bazel must exist',
      );

      final bazelVersion = File('${canaryDir.path}/.bazelversion');
      expect(
        bazelVersion.existsSync(),
        isTrue,
        reason: 'e2e/repro_canary/.bazelversion must exist',
      );
      expect(
        bazelVersion.readAsStringSync().trim(),
        equals('9.3.0'),
        reason: 'e2e/repro_canary/.bazelversion must contain 9.3.0',
      );

      final lockFile = File('${canaryDir.path}/MODULE.bazel.lock');
      expect(
        lockFile.existsSync(),
        isTrue,
        reason: 'e2e/repro_canary/MODULE.bazel.lock must exist',
      );
      expect(
        lockFile.readAsStringSync().trim().isNotEmpty,
        isTrue,
        reason: 'e2e/repro_canary/MODULE.bazel.lock must not be empty',
      );

      final bzlFile = File('${canaryDir.path}/nondet.bzl');
      expect(
        bzlFile.existsSync(),
        isTrue,
        reason: 'e2e/repro_canary/nondet.bzl must exist',
      );
      final String bzlContent = bzlFile.readAsStringSync();
      expect(
        bzlContent.contains('rule('),
        isTrue,
        reason: 'e2e/repro_canary/nondet.bzl must declare a rule',
      );
      expect(
        bzlContent.contains('/dev/urandom'),
        isTrue,
        reason: 'e2e/repro_canary/nondet.bzl action must read /dev/urandom',
      );
    });

    test(
      'ci.yaml has reproducibility job with distinct output bases and no gates',
      () {
        final String root = _findWorkspaceRoot(args);
        final ciFile = File('$root/.github/workflows/ci.yaml');
        expect(
          ciFile.existsSync(),
          isTrue,
          reason: '.github/workflows/ci.yaml must exist',
        );
        final String text = ciFile.readAsStringSync();

        final RegExpMatch? jobMatch = RegExp(
          r'^  reproducibility:\s*$',
          multiLine: true,
        ).firstMatch(text);
        expect(
          jobMatch,
          isNotNull,
          reason:
              'ci.yaml must declare a two-space indented reproducibility: job',
        );

        final int startIndex = jobMatch!.start;
        final Iterable<RegExpMatch> nextJobMatches = RegExp(
          r'^  [a-zA-Z0-9_-]+:\s*$',
          multiLine: true,
        ).allMatches(text).where((RegExpMatch m) => m.start > startIndex);
        final int endIndex = nextJobMatches.isNotEmpty
            ? nextJobMatches.first.start
            : text.length;
        final String jobBlock = text.substring(startIndex, endIndex);

        expect(
          jobBlock.contains('e2e/repro_canary'),
          isTrue,
          reason: 'reproducibility job block must name e2e/repro_canary',
        );

        final Iterable<RegExpMatch> outputBaseMatches = RegExp(
          r'--output_base=([^\s]+)',
        ).allMatches(jobBlock);
        final Set<String> bases = outputBaseMatches
            .map((RegExpMatch m) => m.group(1)!)
            .toSet();
        expect(
          bases.length,
          greaterThanOrEqualTo(2),
          reason: 'reproducibility job block must contain at least two distinct --output_base= values',
        );

        expect(
          RegExp(r'\bgates\b', caseSensitive: false).hasMatch(jobBlock),
          isFalse,
          reason: 'reproducibility job block must not contain gates',
        );
      },
    );

    test('conclusion job requires reproducibility', () {
      final String root = _findWorkspaceRoot(args);
      final ciFile = File('$root/.github/workflows/ci.yaml');
      final String text = ciFile.readAsStringSync();

      final RegExpMatch? conclusionMatch = RegExp(
        r'^  conclusion:\s*$',
        multiLine: true,
      ).firstMatch(text);
      expect(
        conclusionMatch,
        isNotNull,
        reason: 'ci.yaml must have conclusion job',
      );

      final int startIndex = conclusionMatch!.start;
      final Iterable<RegExpMatch> nextJobMatches = RegExp(
        r'^  [a-zA-Z0-9_-]+:\s*$',
        multiLine: true,
      ).allMatches(text).where((RegExpMatch m) => m.start > startIndex);
      final int endIndex = nextJobMatches.isNotEmpty
          ? nextJobMatches.first.start
          : text.length;
      final String conclusionBlock = text.substring(startIndex, endIndex);

      expect(
        RegExp(
          r'^\s*-\s*reproducibility\s*$',
          multiLine: true,
        ).hasMatch(conclusionBlock),
        isTrue,
        reason: "conclusion job's needs list must contain reproducibility",
      );
    });

    test('e2e/repro_canary is not part of positive sweep', () {
      final String root = _findWorkspaceRoot(args);
      final ciFile = File('$root/.github/workflows/ci.yaml');
      final String text = ciFile.readAsStringSync();

      final RegExpMatch? testMatch = RegExp(
        r'^  test:\s*$',
        multiLine: true,
      ).firstMatch(text);
      expect(testMatch, isNotNull, reason: 'ci.yaml must have test job');
      final int startIndex = testMatch!.start;
      final Iterable<RegExpMatch> nextJobMatches = RegExp(
        r'^  [a-zA-Z0-9_-]+:\s*$',
        multiLine: true,
      ).allMatches(text).where((RegExpMatch m) => m.start > startIndex);
      final int endIndex = nextJobMatches.isNotEmpty
          ? nextJobMatches.first.start
          : text.length;
      final String testBlock = text.substring(startIndex, endIndex);

      expect(
        testBlock.contains('e2e/repro_canary'),
        isFalse,
        reason: 'test job folder matrices must not name e2e/repro_canary',
      );

      final optionsFile = File('$root/tools/vm/run_e2e_options.dart');
      expect(optionsFile.existsSync(), isTrue);
      final String optionsText = optionsFile.readAsStringSync();
      expect(
        optionsText.contains("'e2e/repro_canary'"),
        isFalse,
        reason: 'ciFolders must not name e2e/repro_canary',
      );
    });

    test('ai-docs/performance/README.md names reproducibility job', () {
      final String root = _findWorkspaceRoot(args);
      final perfReadme = File('$root/ai-docs/performance/README.md');
      expect(perfReadme.existsSync(), isTrue);
      final String text = perfReadme.readAsStringSync();
      expect(
        text.contains('reproducibility'),
        isTrue,
        reason: 'ai-docs/performance/README.md must name reproducibility job',
      );
    });
  });
}

String _findWorkspaceRoot(List<String> args) {
  if (args.isNotEmpty) {
    try {
      final String loc = Runfiles.create().rlocation(args.first);
      if (File(loc).existsSync()) {
        final String? r = _climbRoot(File(loc).parent);
        if (r != null) return r;
      }
    } on Object catch (_) {
      // Fall back to environment search when runfiles lookup fails.
    }
  }
  for (final String? candidate in [
    Platform.environment['BUILD_WORKSPACE_DIRECTORY'],
    Platform.environment['BUILD_WORKING_DIRECTORY'],
    Directory.current.path,
  ]) {
    if (candidate == null) continue;
    final String? r = _climbRoot(Directory(candidate));
    if (r != null) return r;
  }
  fail('Could not resolve workspace root directory');
}

String? _climbRoot(Directory? start) {
  var dir = start;
  while (dir != null) {
    if (File('${dir.path}/MODULE.bazel').existsSync() &&
        Directory('${dir.path}/dart').existsSync()) {
      return dir.path;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}
