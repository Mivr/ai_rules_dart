// Pure-Dart Mach-O 64-bit binary patcher and stub generator.
//
// Replaces macOS-only `xcrun vtool`, `xcrun install_name_tool`, and
// `xcrun clang -dynamiclib` (for empty debug stub dylibs) so Apple framework
// packaging and Mach-O post-processing work identically on Linux and macOS.
//
// Zero external pub dependencies (only `dart:convert`, `dart:io`,
// `dart:math`, `dart:typed_data`).
import 'macho_cli.dart';
import 'macho_copy.dart';
import 'macho_patch.dart';
import 'macho_stub.dart';
import 'macho_verify.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    usageError(
      'Expected subcommand: "patch", "stub", "fat", "verify", "copy-assets", '
      '"assemble-macos-framework", or "copy-files".',
    );
  }
  final String subcommand = args.first;
  final List<String> rest = args.sublist(1);
  switch (subcommand) {
    case 'patch':
      runPatch(rest);
    case 'stub':
      runStub(rest);
    case 'fat':
      runFat(rest);
    case 'verify':
      runVerify(rest);
    case 'copy-assets':
      runCopyAssets(rest);
    case 'assemble-macos-framework':
      runAssembleMacosFramework(rest);
    case 'copy-files':
      runCopyFiles(rest);
    default:
      usageError(
        'Unknown subcommand "$subcommand". Expected "patch", "stub", "fat", '
        '"verify", "copy-assets", "assemble-macos-framework", or "copy-files".',
      );
  }
}
