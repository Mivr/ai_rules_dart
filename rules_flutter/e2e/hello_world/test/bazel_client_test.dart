/// Unit tests for the nested-tool resolver the macOS stage-clean test uses.
///
/// These run on every host: each test creates a temporary directory and a
/// fake executable, and none runs a real Bazel. They cover the `BAZEL`
/// override, the supplied `PATH` lookup (including files that are present but
/// not executable) and the failure that names the tool and value tried, for
/// both `bazel` and `unzip`. The real rebuild assertion is macOS-only and runs
/// in `E2E full (hello_world, macos-latest)` in `full.yaml`.
library;

import 'dart:io';

import 'package:test/test.dart';

import 'bazel_client.dart';

/// Creates a temporary directory removed when the test ends.
Directory _tempDir() {
  final dir = Directory.systemTemp.createTempSync('bazel_client_');
  addTearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });
  return dir;
}

/// Writes a shell script named [name] in [directory] and returns it.
File _fakeFile(Directory directory, String name) =>
    File('${directory.path}${Platform.pathSeparator}$name')
      ..writeAsStringSync('#!/bin/sh\nexit 0\n');

/// Writes an empty executable named [name] in [directory] and returns it.
File _fakeExecutable(Directory directory, String name) {
  final file = _fakeFile(directory, name);
  if (!Platform.isWindows) {
    final result = Process.runSync('chmod', ['+x', file.path]);
    if (result.exitCode != 0) {
      throw StateError(
        'chmod +x ${file.path} failed with exit ${result.exitCode}: '
        '${result.stderr}',
      );
    }
  }
  return file;
}

void main() {
  test('BAZEL absolute path wins over bazel on PATH', () {
    final overrideDir = _tempDir();
    final pathDir = _tempDir();
    final override = _fakeExecutable(overrideDir, 'custom_bazel');
    _fakeExecutable(pathDir, 'bazel');
    final resolved = resolveBazelClient(
      environment: {'BAZEL': override.path, 'PATH': pathDir.path},
      step: 'unit test',
    );
    expect(resolved, override.path);
  });

  test('bazel is found on the supplied PATH when BAZEL is unset', () {
    final dir = _tempDir();
    final bazel = _fakeExecutable(dir, 'bazel');
    final resolved = resolveBazelClient(
      environment: {'PATH': dir.path},
      step: 'unit test',
    );
    expect(resolved, bazel.path);
  });

  test('an empty BAZEL falls back to bazel on PATH', () {
    final dir = _tempDir();
    final bazel = _fakeExecutable(dir, 'bazel');
    final resolved = resolveBazelClient(
      environment: {'BAZEL': '', 'PATH': dir.path},
      step: 'unit test',
    );
    expect(resolved, bazel.path);
  });

  test('a bare BAZEL name is resolved on the supplied PATH', () {
    final dir = _tempDir();
    final bazel = _fakeExecutable(dir, 'bazel');
    final resolved = resolveBazelClient(
      environment: {'BAZEL': 'bazel', 'PATH': dir.path},
      step: 'unit test',
    );
    expect(resolved, bazel.path);
  });

  test('a bare BAZEL name not on PATH fails with the value it tried', () {
    final dir = _tempDir();
    expect(
      () => resolveBazelClient(
        environment: {'BAZEL': 'bazel', 'PATH': dir.path},
        step: 'nested build',
      ),
      throwsA(
        isA<ToolUnavailable>()
            .having((error) => error.tool, 'tool', 'bazel')
            .having((error) => error.tried, 'tried', 'BAZEL=bazel')
            .having((error) => error.step, 'step', 'nested build'),
      ),
    );
  });

  test('missing bazel fails with the tool and value it tried', () {
    final dir = _tempDir();
    expect(
      () => resolveBazelClient(
        environment: {'PATH': dir.path},
        step: 'nested build',
      ),
      throwsA(
        isA<ToolUnavailable>()
            .having((error) => error.tool, 'tool', 'bazel')
            .having((error) => error.tried, 'tried', contains(dir.path))
            .having((error) => error.step, 'step', 'nested build'),
      ),
    );
  });

  test('missing unzip fails with the tool and value it tried', () {
    final dir = _tempDir();
    expect(
      () => resolveHostTool(
        tool: 'unzip',
        environment: {'PATH': dir.path},
        step: 'unzip App.framework.zip',
      ),
      throwsA(
        isA<ToolUnavailable>()
            .having((error) => error.tool, 'tool', 'unzip')
            .having((error) => error.tried, 'tried', contains(dir.path))
            .having((error) => error.step, 'step', 'unzip App.framework.zip'),
      ),
    );
  });

  if (!Platform.isWindows) {
    test('a non-executable BAZEL fails with the value it tried', () {
      final dir = _tempDir();
      final file = _fakeFile(dir, 'not_executable_bazel');
      expect(
        () => resolveBazelClient(
          environment: {'BAZEL': file.path},
          step: 'nested build',
        ),
        throwsA(
          isA<ToolUnavailable>()
              .having((error) => error.tool, 'tool', 'bazel')
              .having((error) => error.tried, 'tried', contains(file.path))
              .having((error) => error.step, 'step', 'nested build'),
        ),
      );
    });

    test('a non-executable bazel on PATH is named when none is usable', () {
      final dir = _tempDir();
      final file = _fakeFile(dir, 'bazel');
      expect(
        () => resolveBazelClient(
          environment: {'PATH': dir.path},
          step: 'nested build',
        ),
        throwsA(
          isA<ToolUnavailable>()
              .having((error) => error.tool, 'tool', 'bazel')
              .having((error) => error.tried, 'tried', contains(file.path))
              .having(
                (error) => error.tried,
                'tried says not executable',
                contains('not executable'),
              )
              .having((error) => error.step, 'step', 'nested build'),
        ),
      );
    });

    test('a non-executable unzip on PATH is named when none is usable', () {
      final dir = _tempDir();
      final file = _fakeFile(dir, 'unzip');
      expect(
        () => resolveHostTool(
          tool: 'unzip',
          environment: {'PATH': dir.path},
          step: 'unzip App.framework.zip',
        ),
        throwsA(
          isA<ToolUnavailable>()
              .having((error) => error.tool, 'tool', 'unzip')
              .having((error) => error.tried, 'tried', contains(file.path))
              .having(
                (error) => error.tried,
                'tried says not executable',
                contains('not executable'),
              )
              .having((error) => error.step, 'step', 'unzip App.framework.zip'),
        ),
      );
    });
  }

  test('a spawn failure names the executable it tried', () {
    final dir = _tempDir();
    final missing = '${dir.path}${Platform.pathSeparator}missing_bazel';
    expect(
      () => runHostTool(
        executable: missing,
        args: const [],
        step: 'nested build',
      ),
      throwsA(
        isA<ToolUnavailable>()
            .having((error) => error.tool, 'tool', missing)
            .having((error) => error.step, 'step', 'nested build'),
      ),
    );
  });
}
