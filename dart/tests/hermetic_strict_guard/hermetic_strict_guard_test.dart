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
  final String workflow = File('$root/.github/workflows/ci.yaml')
      .readAsStringSync();
  _checkCanary(root);
  _checkStrictJob(workflow);
  _checkConclusion(workflow);
  _checkSelfTest(workflow);
  _checkSweep(root, workflow);
  _checkSlicing();
}

/// Checks the red-by-design canary workspace layout.
void _checkCanary(String root) {
  group('canary workspace', () {
    test('layout matches the red-by-design contract', () {
      final dir = Directory('$root/e2e/hermetic_canary');
      expect(dir.existsSync(), isTrue, reason: 'missing e2e/hermetic_canary');

      final build = File('${dir.path}/BUILD.bazel');
      _expectFile(build, 'e2e/hermetic_canary/BUILD.bazel');
      final String buildText = build.readAsStringSync();
      expect(buildText.trim(), isNotEmpty, reason: 'BUILD.bazel is empty');
      for (final String needle in _buildNeedles) {
        _expectContains(buildText, needle, 'BUILD.bazel must declare $needle');
      }

      final module = File('${dir.path}/MODULE.bazel');
      _expectFile(module, 'e2e/hermetic_canary/MODULE.bazel');
      final String moduleText = module.readAsStringSync();
      for (final String needle in _moduleNeedles) {
        _expectContains(
          moduleText,
          needle,
          'MODULE.bazel must contain $needle',
        );
      }

      final version = File('${dir.path}/.bazelversion');
      _expectFile(version, 'e2e/hermetic_canary/.bazelversion');
      expect(
        version.readAsStringSync().trim(),
        equals('9.3.0'),
        reason: '.bazelversion must pin 9.3.0',
      );

      final lock = File('${dir.path}/MODULE.bazel.lock');
      _expectFile(lock, 'e2e/hermetic_canary/MODULE.bazel.lock');
      expect(
        lock.readAsStringSync().trim(),
        isNotEmpty,
        reason: 'MODULE.bazel.lock must be generated, not empty',
      );

      final rule = File('${dir.path}/canary.bzl');
      _expectFile(rule, 'e2e/hermetic_canary/canary.bzl');
      final String ruleText = rule.readAsStringSync();
      for (final String needle in _ruleNeedles) {
        _expectContains(ruleText, needle, 'canary.bzl must contain $needle');
      }
      _expectNotContains(
        ruleText,
        '/usr/bin/env',
        'the rule must not declare the undeclared host path in inputs',
      );

      final tool = File('${dir.path}/tool.dart');
      _expectFile(tool, 'e2e/hermetic_canary/tool.dart');
      final String toolText = tool.readAsStringSync();
      for (final String needle in _toolNeedles) {
        _expectContains(toolText, needle, 'tool.dart must contain $needle');
      }
    });
  });
}

/// Every declaration the canary `BUILD.bazel` must keep.
const List<String> _buildNeedles = [
  'load("@rules_dart//dart:defs.bzl", "dart_binary")',
  'dart_binary(',
  'name = "tool"',
  'hermetic_canary(',
  'name = "canary"',
];

/// Every module declaration the canary `MODULE.bazel` must keep.
const List<String> _moduleNeedles = [
  'module(name = "hermetic_canary")',
  'bazel_dep(name = "ai_rules_dart", version = "0.0.0", repo_name = "rules_dart")',
  'local_path_override(',
  'path = "../..",',
  'dart_version = "3.13.5"',
  'use_repo(dart, "dart_toolchains")',
  'register_toolchains("@dart_toolchains//:all")',
];

/// Every action declaration the canary rule must keep.
const List<String> _ruleNeedles = [
  'ctx.actions.run(',
  'executable = ctx.executable._tool',
  'tools = [ctx.attr._tool[DefaultInfo].files_to_run]',
  'use_default_shell_env = False',
  'mnemonic =',
  'doc =',
  'attrs =',
];

/// Every step the canary Dart entry point must keep.
const List<String> _toolNeedles = [
  '/usr/bin/env',
  'readAsBytesSync()',
  'stderr',
  'exit(1)',
  'args[0]',
];

/// Checks the strict job keeps every H1 flag, mount, phase and BEP file.
void _checkStrictJob(String workflow) {
  group('strict job', () {
    test('block keeps every H1 flag, mount and BEP file', () {
      final String block = _jobBlock(workflow, 'hermetic-strict');
      _expectContains(block, 'runs-on: ubuntu-latest', 'strict job runner');
      _expectContains(block, 'timeout-minutes:', 'strict job timeout');
      _expectContains(block, 'actions/checkout@', 'strict job checkout');
      _expectContains(
        block,
        'for tool in curl python3 find cp tar unzip',
        'blocked-tool shim list',
      );
      _expectContains(
        block,
        r'test ! -e "$SHIM_DIR/git"',
        'git is not shimmed',
      );
      _expectContains(block, 'test -x /usr/bin/git', 'git stays in /usr/bin');
      _expectContains(
        block,
        r'--repo_env=PATH="$SHIM_DIR:/usr/bin:/bin"',
        'the shim directory comes first on the repository PATH',
      );
      for (final String flag in _strictFlags) {
        _expectContains(block, flag, 'hermetic-strict must keep $flag');
      }
      for (final String mount in _mounts) {
        _expectContains(block, mount, 'hermetic-strict must mount $mount');
      }
      _expectAtLeast(block, '--build_event_json_file=', 4, 'BEP files');
      _expectAtLeast(
        block,
        '--experimental_use_hermetic_linux_sandbox',
        2,
        'strict Phase 1 builds',
      );
      _expectContains(
        block,
        'working-directory: e2e/hello_world',
        'hello_world workspace',
      );
      _expectContains(
        block,
        'working-directory: e2e/codegen',
        'codegen workspace',
      );
      _expectContains(
        block,
        "bazel query '//... except attr(generator_function, build_test, //...)'",
        'codegen resolves the underlying build targets',
      );
      _expectContains(
        block,
        '--skip_incompatible_explicit_targets',
        'codegen skips incompatible explicit targets',
      );
      _expectContains(block, "bazel query 'tests(//...)'", 'test discovery');
      _expectContains(block, 'bazel test //...', 'Phase 2 test runs');
      _expectNotContains(block, '|| true', 'the strict job tolerates nothing');
      _expectNotContains(block, 'exit 4', 'the strict job tolerates no exit 4');
      _expectNotContains(
        block,
        'continue-on-error',
        'the strict job tolerates no failure',
      );
      _expectExactly(
        block,
        '--sandbox_add_mount_pair=',
        16,
        'the strict job mounts only the four minimal pairs in four phases',
      );
      _expectContains(block, 'canonical', 'BEP canonical command line');
      _expectContains(block, 'original', 'BEP original command line');
      _expectContains(block, '--action_env', 'BEP action-env assertion');

      final String helloBuild = _stepBlock(block, 'Phase 1 hello_world');
      final String codegenBuild = _stepBlock(block, 'Phase 1 codegen');
      final String helloTest = _stepBlock(block, 'Phase 2 hello_world');
      final String codegenTest = _stepBlock(block, 'Phase 2 codegen');
      _expectContains(
        helloBuild,
        '--experimental_use_hermetic_linux_sandbox',
        'hello_world Phase 1 is strict',
      );
      _expectContains(
        codegenBuild,
        '--experimental_use_hermetic_linux_sandbox',
        'codegen Phase 1 is strict',
      );
      _expectNotContains(
        helloTest,
        '--experimental_use_hermetic_linux_sandbox',
        'hello_world Phase 2 omits the hermetic sandbox flag',
      );
      _expectNotContains(
        codegenTest,
        '--experimental_use_hermetic_linux_sandbox',
        'codegen Phase 2 omits the hermetic sandbox flag',
      );
    });
  });
}

/// Every flag the strict phases must keep passing to Bazel.
const List<String> _strictFlags = [
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
const List<String> _mounts = [
  '/lib64',
  '/lib/x86_64-linux-gnu',
  '/usr/lib/x86_64-linux-gnu',
  '/etc/ld.so.cache',
];

/// Checks the conclusion job still gates on the strict job.
void _checkConclusion(String workflow) {
  group('conclusion', () {
    test('conclusion still gates on the strict job', () {
      final String block = _jobBlock(workflow, 'conclusion');
      expect(
        RegExp(r'^\s*-\s*hermetic-strict\s*$', multiLine: true).hasMatch(block),
        isTrue,
        reason: 'conclusion needs must list hermetic-strict',
      );
    });
  });
}

/// Checks the expected-failure canary self-test.
void _checkSelfTest(String workflow) {
  group('self-test', () {
    test('expected-failure proves the canary fails strict', () {
      final String block = _jobBlock(workflow, 'expected-failure');
      _expectNotContains(block, 'continue-on-error', 'no tolerated failure');
      final String step = _stepBlock(block, 'e2e/hermetic_canary');
      _expectNotContains(step, '|| true', 'no tolerated failure');
      _expectContains(
        step,
        'working-directory: e2e/hermetic_canary',
        'the canary step runs in its workspace',
      );
      _expectContains(
        step,
        'bazel build //:canary ||',
        'the default build must succeed first',
      );
      _expectContains(
        step,
        '--experimental_use_hermetic_linux_sandbox',
        'the self-test passes the hermetic flag',
      );
      _expectContains(
        step,
        '--output_base=',
        'the self-test isolates its base',
      );
      _expectContains(
        step,
        r'if out=$(bazel ',
        'the strict build must be expected to fail',
      );
      _expectContains(
        step,
        'grep -F -q "/usr/bin/env"',
        'the self-test greps the strict output',
      );
      for (final String mount in _mounts) {
        _expectContains(step, mount, 'the self-test must mount $mount');
      }
      _expectExactly(
        step,
        '--sandbox_add_mount_pair=',
        4,
        'the self-test uses only the four minimal mounts',
      );
    });
  });
}

/// Checks no positive sweep runs the canary.
void _checkSweep(String root, String workflow) {
  group('sweep', () {
    test('no positive sweep runs the canary', () {
      _expectNotContains(
        _jobBlock(workflow, 'test'),
        'e2e/hermetic_canary',
        'test matrices must not name the canary',
      );
      final String options = File('$root/tools/vm/run_e2e_options.dart')
          .readAsStringSync();
      _expectNotContains(
        options,
        'e2e/hermetic_canary',
        'ciFolders must not name the canary',
      );
      final String full = File('$root/.github/workflows/full.yaml')
          .readAsStringSync();
      _expectNotContains(
        full,
        'e2e/hermetic_canary',
        'full.yaml must not name the canary',
      );
    });
  });
}

/// Checks the job and step slicers used above.
void _checkSlicing() {
  group('checker self-checks', () {
    test('job slicing stops at the next job', () {
      const doc = '  alpha:\n    x: 1\n  beta:\n    y: 2\n';
      expect(_jobBlock(doc, 'alpha'), contains('x: 1'));
      expect(_jobBlock(doc, 'alpha'), isNot(contains('y: 2')));
    });

    test('step slicing stops at the next step', () {
      const doc =
          '      - name: first\n        run: one\n'
          '      - name: second\n        run: two\n';
      expect(_stepBlock(doc, 'first'), contains('one'));
      expect(_stepBlock(doc, 'first'), isNot(contains('two')));
    });

    test('missing job or step raises', () {
      expect(() => _jobBlock('  alpha:\n', 'beta'), throwsStateError);
      expect(
        () => _stepBlock('      - name: first\n', 'second'),
        throwsStateError,
      );
    });
  });
}

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

/// The YAML block of the step whose text contains [marker].
String _stepBlock(String text, String marker) {
  final List<String> lines = text.split('\n');
  final int at = lines.indexWhere((String line) => line.contains(marker));
  if (at < 0) {
    throw StateError('step $marker not found');
  }
  final stepStart = RegExp('^      - ');
  var start = at;
  while (start > 0 && !stepStart.hasMatch(lines[start])) {
    start--;
  }
  if (!stepStart.hasMatch(lines[start])) {
    throw StateError('step $marker has no step header');
  }
  int end = at + 1;
  while (end < lines.length && !stepStart.hasMatch(lines[end])) {
    end++;
  }
  return lines.sublist(start, end).join('\n');
}

/// Expects [path] to exist and to be a file.
void _expectFile(File path, String name) {
  expect(path.existsSync(), isTrue, reason: 'missing $name');
}

/// Expects [text] to contain [needle].
void _expectContains(String text, String needle, String reason) {
  expect(text.contains(needle), isTrue, reason: reason);
}

/// Expects [text] not to contain [needle].
void _expectNotContains(String text, String needle, String reason) {
  expect(text.contains(needle), isFalse, reason: reason);
}

/// Expects [text] to contain at least [count] occurrences of [needle].
void _expectAtLeast(String text, String needle, int count, String what) {
  expect(
    _countOf(text, needle),
    greaterThanOrEqualTo(count),
    reason: 'need at least $count $what',
  );
}

/// Expects [text] to contain exactly [count] occurrences of [needle].
void _expectExactly(String text, String needle, int count, String reason) {
  expect(_countOf(text, needle), equals(count), reason: reason);
}

/// Counts the occurrences of [needle] in [text].
int _countOf(String text, String needle) {
  return needle.isEmpty ? 0 : text.split(needle).length - 1;
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
