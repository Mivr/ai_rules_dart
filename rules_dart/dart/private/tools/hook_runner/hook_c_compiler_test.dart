import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:test/test.dart';

import 'hook_c_compiler.dart';

// A fake toolchain on disk (the runner checks every tool exists): what
// Bazel's MSVC toolchain names (absolute, outside the exec root) and the
// script `build_hooks.bzl` writes beside the action (exec-root-relative).
late String _msvc;
late String _execRoot;
const _prompt =
    'bazel-out/x64_windows-fastbuild/bin/external/sqlite3/'
    'sqlite3.hook_tools/msvc_env.bat';

// A path is absolute with a leading `/` or, on Windows, a drive.
String _absolute(String path) =>
    path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path)
    ? path
    : '$_execRoot/$path';

/// [path] as the build input spells a file: `Uri.toFilePath()`.
String _native(String path) => Uri.file(path).toFilePath();

void _touch(String path) => File(path).createSync(recursive: true);

/// The build input a hook gets, as JSON, for [os] with [compiler].
Future<(BuildInput, List<String>)> _input(
  OS os,
  CCompilerConfig? compiler,
) async {
  final extension = CodeAssetExtension(
    targetArchitecture: Architecture.x64,
    targetOS: os,
    linkModePreference: LinkModePreference.dynamic,
    cCompiler: compiler,
  );
  final builder = BuildInputBuilder()
    ..setupShared(
      packageRoot: Uri.directory('$_execRoot/pkg'),
      packageName: 'sqlite3',
      outputDirectoryShared: Uri.directory('$_execRoot/shared'),
      outputFile: Uri.file('$_execRoot/output.json'),
    )
    ..config.setupBuild(linkingEnabled: false)
    ..setupBuildInput()
    ..addExtension(extension);
  final BuildInput input = builder.build();
  return (input, await extension.validateBuildInput(input));
}

Map<String, Object?> _cCompilerJson(BuildInput input) {
  final config = input.json['config']! as Map<String, Object?>;
  final extensions = config['extensions']! as Map<String, Object?>;
  final code = extensions['code_assets']! as Map<String, Object?>;
  return code['c_compiler']! as Map<String, Object?>;
}

// The input names each file by its path, as `Uri.toFilePath()` spells it.
void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hook_c_compiler_test');
    _msvc = '${tmp.path}/vs/VC/Tools/MSVC/14.44/bin/HostX64/x64';
    _execRoot = '${tmp.path}/execroot/_main';
    for (final tool in ['cl.exe', 'link.exe', 'lib.exe']) {
      _touch('$_msvc/$tool');
    }
    _touch('$_execRoot/$_prompt');
    for (final tool in ['clang', 'ld', 'ar']) {
      _touch('$_execRoot/bazel-out/k8/bin/x.hook_tools/$tool');
    }
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test(
    'a Windows target names MSVC and the Developer Command Prompt',
    () async {
      final (BuildInput input, List<String> errors) = await _input(
        OS.windows,
        cCompilerConfig(
          targetOS: OS.windows,
          cc: '$_msvc/cl.exe',
          ld: '$_msvc/link.exe',
          ar: '$_msvc/lib.exe',
          developerPrompt: _prompt,
          absolute: _absolute,
        ),
      );
      expect(errors, isEmpty);
      final Map<String, Object?> json = _cCompilerJson(input);
      expect(json['cc'], _native('$_msvc/cl.exe'));
      expect(json['ld'], _native('$_msvc/link.exe'));
      expect(json['ar'], _native('$_msvc/lib.exe'));
      expect(json['windows'], {
        'developer_command_prompt': {
          'script': _native('$_execRoot/$_prompt'),
          'arguments': <String>[],
        },
      });
      final WindowsCCompilerConfig windows =
          input.config.code.cCompiler!.windows;
      expect(windows.developerCommandPrompt!.arguments, isEmpty);
    },
  );

  test(
    'a Windows target without a script still has its windows part',
    () async {
      // The CI failure: "No value was provided for
      // 'config.extensions.code_assets.c_compiler.windows'".
      final (BuildInput input, List<String> errors) = await _input(
        OS.windows,
        cCompilerConfig(
          targetOS: OS.windows,
          cc: '$_msvc/cl.exe',
          ld: '$_msvc/link.exe',
          ar: '$_msvc/lib.exe',
          developerPrompt: null,
          absolute: _absolute,
        ),
      );
      expect(errors, isEmpty);
      expect(_cCompilerJson(input)['windows'], <String, Object?>{});
      expect(
        input.config.code.cCompiler!.windows.developerCommandPrompt,
        isNull,
      );
    },
  );

  test('a Linux target has no windows part', () async {
    final (BuildInput input, List<String> errors) = await _input(
      OS.linux,
      cCompilerConfig(
        targetOS: OS.linux,
        cc: 'bazel-out/k8/bin/x.hook_tools/clang',
        ld: 'bazel-out/k8/bin/x.hook_tools/ld',
        ar: 'bazel-out/k8/bin/x.hook_tools/ar',
        developerPrompt: null,
        absolute: _absolute,
      ),
    );
    expect(errors, isEmpty);
    final Map<String, Object?> json = _cCompilerJson(input);
    expect(json.containsKey('windows'), isFalse);
    expect(
      json['cc'],
      _native('$_execRoot/bazel-out/k8/bin/x.hook_tools/clang'),
    );
  });

  test('no C toolchain gives no c_compiler', () {
    expect(
      cCompilerConfig(
        targetOS: OS.windows,
        cc: null,
        ld: null,
        ar: null,
        developerPrompt: null,
        absolute: _absolute,
      ),
      isNull,
    );
  });
}
