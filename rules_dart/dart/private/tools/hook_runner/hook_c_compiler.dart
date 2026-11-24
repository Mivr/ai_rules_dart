// The C compiler a hook's input names, kept apart from `hook_runner.dart` (on
// `package:code_assets` alone) so that a test builds the input a hook gets
// for each target OS.

import 'package:code_assets/code_assets.dart';

/// The `c_compiler` of a hook's input, or null when Bazel resolved no C
/// toolchain ([cc] null).
///
/// For a Windows target `package:code_assets` requires a `windows` part, and
/// `package:native_toolchain_c` runs its [developerPrompt] script once to
/// get the environment (`INCLUDE`, `LIB`, `PATH`) of every MSVC call. Without
/// one it runs the `vcvars` script of the Visual Studio [cc] belongs to.
/// [absolute] makes Bazel's exec-root-relative paths absolute.
CCompilerConfig? cCompilerConfig({
  required OS targetOS,
  required String? cc,
  required String? ld,
  required String? ar,
  required String? developerPrompt,
  required String Function(String) absolute,
}) {
  if (cc == null) return null;
  return CCompilerConfig(
    compiler: Uri.file(absolute(cc)),
    linker: Uri.file(absolute(ld!)),
    archiver: Uri.file(absolute(ar!)),
    windows: targetOS != OS.windows
        ? null
        : WindowsCCompilerConfig(
            developerCommandPrompt: developerPrompt == null
                ? null
                : DeveloperCommandPrompt(
                    script: Uri.file(absolute(developerPrompt)),
                    arguments: const [],
                  ),
          ),
  );
}
