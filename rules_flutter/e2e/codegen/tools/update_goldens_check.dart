/// Proves that `bazel run <flutter_test> -- --update-goldens` rewrites a stale
/// golden PNG in the workspace and that the test passes afterwards.
///
/// Run with `bazel run //:update_goldens_check -- --bazel=bazel` from
/// `e2e/codegen`. The check works on a scratch copy of the workspace under a
/// temporary directory it creates and removes, so no PNG is ever written into
/// the checked-out tree:
///
/// 1. add a golden test of a text-free, fixed-size widget with a committed PNG
///    that differs from what the widget renders;
/// 2. `bazel test` must FAIL, so the stale PNG is detected;
/// 3. `bazel run -- --update-goldens` must change the PNG into a non-empty PNG;
/// 4. `bazel test` must PASS.
///
/// Any failed step exits non-zero with a message naming the step.
library;

import 'dart:convert';
import 'dart:io';

const _target = '//:scratch_golden_test';
const _testFile = 'test/scratch_golden_test.dart';
const _goldenFile = 'test/goldens/scratch_only.png';
const _pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// Bazel's exit code for a build that succeeded but whose tests failed.
const _testFailureExit = 3;

/// The subject of `test/golden_test.dart`: no text, so no font, and a fixed
/// size, so no window geometry.
const _scratchTest = '''
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the box matches its golden', (tester) async {
    await tester.pumpWidget(
      const Center(
        child: SizedBox(
          width: 64,
          height: 64,
          child: ColoredBox(color: Color(0xFF2196F3)),
        ),
      ),
    );
    await expectLater(
      find.byType(ColoredBox),
      matchesGoldenFile('goldens/scratch_only.png'),
    );
  });
}
''';

const _scratchBuild = '''

load("@rules_flutter//flutter:defs.bzl", "flutter_test")

flutter_test(
    name = "scratch_golden_test",
    package_name = "codegen_e2e",
    size = "medium",
    data = glob(["test/goldens/**"]),
    main = "test/scratch_golden_test.dart",
    deps = [
        "@deps//:flutter",
        "@deps//:flutter_test",
    ],
)
''';

/// A failed step of the check.
class _StepFailure implements Exception {
  _StepFailure(this.step, this.message);

  final String step;
  final String message;

  @override
  String toString() => 'FAIL [$step]: $message';
}

/// The outcome of one Bazel invocation.
class _Run {
  _Run(this.exitCode, this.output);

  final int exitCode;
  final String output;
}

/// Runs Bazel in [workspace] and echoes its output.
class _Bazel {
  _Bazel(this.executable, this.workspace);

  final String executable;
  final Directory workspace;

  Future<_Run> run(List<String> args) async {
    stdout.writeln('+ $executable ${args.join(' ')}');
    final process = await Process.start(
      executable,
      args,
      workingDirectory: workspace.path,
      // A `bazel run` parent exports these; the nested invocation targets a
      // different workspace and must not inherit them.
      environment: {
        'BUILD_WORKSPACE_DIRECTORY': workspace.path,
        'BUILD_WORKING_DIRECTORY': workspace.path,
      },
    );
    final buffer = StringBuffer();
    Future<void> pump(Stream<List<int>> bytes, IOSink sink) async {
      await for (final line
          in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
        buffer.writeln(line);
        sink.writeln(line);
      }
    }

    await Future.wait([
      pump(process.stdout, stdout),
      pump(process.stderr, stderr),
    ]);
    return _Run(await process.exitCode, buffer.toString());
  }
}

String? _bazelArg(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('--bazel=')) return arg.substring('--bazel='.length);
  }
  return null;
}

/// Copies [source] to [dest] without Bazel's convenience symlinks or any
/// developer-local state.
Future<void> _copyWorkspace(Directory source, Directory dest) async {
  await for (final entity in source.list(followLinks: false)) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (name.startsWith('bazel-') || name == '.bazelrc.user') continue;
    await _copyEntity(entity, '${dest.path}/$name');
  }
}

Future<void> _copyEntity(FileSystemEntity entity, String target) async {
  if (entity is Directory) {
    await Directory(target).create(recursive: true);
    await for (final child in entity.list(followLinks: false)) {
      final name = child.uri.pathSegments.where((s) => s.isNotEmpty).last;
      await _copyEntity(child, '$target/$name');
    }
  } else if (entity is File) {
    await entity.copy(target);
  } else if (entity is Link) {
    await Link(target).create(await entity.target());
  }
}

/// Points the scratch copy's `local_path_override` at the real repository and
/// adds the scratch test, its source and the stale golden.
Future<void> _prepare(Directory workspace, Directory source) async {
  final module = File('${workspace.path}/MODULE.bazel');
  final repoRoot = source.parent.parent.absolute.path;
  final text = await module.readAsString();
  if (!text.contains('path = "../.."')) {
    throw _StepFailure('prepare', 'MODULE.bazel has no `path = "../.."`');
  }
  await module.writeAsString(
    text.replaceFirst('path = "../.."', 'path = "$repoRoot"'),
  );
  final build = File('${workspace.path}/BUILD.bazel');
  await build.writeAsString((await build.readAsString()) + _scratchBuild);
  await File('${workspace.path}/$_testFile').writeAsString(_scratchTest);
  // The committed 1x1 transparent stand-in: a valid PNG that cannot equal a
  // 64x64 blue box.
  await File('${workspace.path}/test/goldens/stand_in.png')
      .copy('${workspace.path}/$_goldenFile');
}

void _expect(bool condition, String step, String message) {
  if (!condition) throw _StepFailure(step, message);
}

bool _isPng(List<int> bytes) {
  if (bytes.length <= _pngMagic.length) return false;
  for (var i = 0; i < _pngMagic.length; i++) {
    if (bytes[i] != _pngMagic[i]) return false;
  }
  return true;
}

Future<void> _check(_Bazel bazel) async {
  final golden = File('${bazel.workspace.path}/$_goldenFile');
  final stale = await golden.readAsBytes();

  const step1 = 'step 1: stale golden fails the test';
  final failing = await bazel.run(['test', _target, '--test_output=errors']);
  _expect(
    failing.exitCode == _testFailureExit,
    step1,
    'expected the test to fail (exit $_testFailureExit), got exit '
    '${failing.exitCode}',
  );
  _expect(
    failing.output.contains('Pixel test failed'),
    step1,
    'the test failed, but not with a golden mismatch ("Pixel test failed")',
  );

  const step2 = 'step 2: bazel run -- --update-goldens rewrites the PNG';
  final update = await bazel.run(['run', _target, '--', '--update-goldens']);
  _expect(update.exitCode == 0, step2, 'exit ${update.exitCode}');
  final updated = await golden.readAsBytes();
  _expect(updated.isNotEmpty, step2, 'the golden is empty');
  _expect(_isPng(updated), step2, 'the golden is not a PNG');
  _expect(
    !_sameBytes(stale, updated),
    step2,
    'the golden bytes did not change',
  );

  const step3 = 'step 3: the test passes after the update';
  final passing = await bazel.run(['test', _target, '--test_output=errors']);
  _expect(passing.exitCode == 0, step3, 'exit ${passing.exitCode}');
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Future<void> main(List<String> args) async {
  final source = Directory(
    Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ?? Directory.current.path,
  ).absolute;
  final scratchRoot = await Directory.systemTemp.createTemp('update_goldens_');
  final workspace = Directory('${scratchRoot.path}/codegen');
  final bazel = _Bazel(_bazelArg(args) ?? 'bazel', workspace);
  var code = 0;
  try {
    await workspace.create();
    await _copyWorkspace(source, workspace);
    await _prepare(workspace, source);
    await _check(bazel);
    stdout.writeln(
      'OK: --update-goldens rewrote the stale golden and the '
      'test then passed.',
    );
  } on _StepFailure catch (failure) {
    stderr.writeln(failure);
    code = 1;
  } finally {
    await bazel.run(['shutdown']);
    await scratchRoot.delete(recursive: true);
  }
  exit(code);
}
