/// Pure argument parsing, pass rules and summary formatting for
/// `tools/vm/run_e2e.dart`, split out for unit testing: nothing here touches
/// a VM, SSH or Bazel.
///
/// Uses only dart:core — no pubspec needed.
library;

/// The `folders` matrix from `.github/workflows/ci.yaml` (the `test` job).
const List<String> ciFolders = [
  '.',
  'e2e/smoke',
  'e2e/hello_world',
  'e2e/library_deps',
  'e2e/analysis',
  'e2e/dart_test',
  'e2e/dart_test_pkg',
  'e2e/codegen',
  'e2e/pub_deps',
  'e2e/pub_lock',
  'e2e/web_app',
  'e2e/gazelle',
  'e2e/cross_compile',
  'e2e/pub_lock_cross_module',
  'e2e/pub_lock_dedup',
  'e2e/pub_lock_upgrade',
  'e2e/ext_exemplar',
  'e2e/dual_build',
  'e2e/fix',
  'e2e/analyze_composition',
  'e2e/link_hook',
];

/// Usage message printed when the VM name is missing.
const String e2eUsage =
    'Usage: dart run tools/vm/run_e2e.dart <vm-name> [--windows] '
    '[--folders=a,b,c] [--keep-going]';

/// One folder's `bazel test //...` outcome.
class FolderResult {
  const FolderResult(this.folder, this.exitCode, this.pass, this.tail);

  /// Repo-relative folder that was tested.
  final String folder;

  /// Bazel's exit code (`RD_EXIT=`), or `-2` on timeout.
  final int exitCode;

  /// Whether the folder counts as passing.
  final bool pass;

  /// Last lines of the combined stdout/stderr, for the failure report.
  final String tail;
}

/// Parsed `run_e2e.dart` command line.
class E2eOptions {
  const E2eOptions({
    required this.vmName,
    required this.isWindows,
    required this.keepGoing,
    required this.folders,
    required this.usesDefaultFolders,
  });

  /// VM name (the first positional argument).
  final String vmName;

  /// Whether `--windows` was passed.
  final bool isWindows;

  /// Whether `--keep-going` was passed.
  final bool keepGoing;

  /// Folders to test: `--folders=` split on commas, else [ciFolders].
  final List<String> folders;

  /// Whether [folders] is the default matrix (gates the expected-failure run).
  final bool usesDefaultFolders;
}

/// Parses [args] into [E2eOptions], or returns null when the VM name is
/// missing and the caller must print [e2eUsage] and exit 2.
E2eOptions? parseE2eOptions(List<String> args) {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) return null;
  final foldersArg = args
      .firstWhere((a) => a.startsWith('--folders='), orElse: () => '')
      .replaceFirst('--folders=', '');
  final usesDefaultFolders = foldersArg.isEmpty;
  return E2eOptions(
    vmName: positional.first,
    isWindows: args.contains('--windows'),
    keepGoing: args.contains('--keep-going'),
    folders: usesDefaultFolders
        ? ciFolders
        : foldersArg.split(',').map((s) => s.trim()).toList(),
    usesDefaultFolders: usesDefaultFolders,
  );
}

/// Whether an `RD_EXIT=` code counts as a pass: 0 (success) and 4 (no test
/// targets) pass; anything else fails.
bool folderPass(int exitCode) => exitCode == 0 || exitCode == 4;

/// Formats the final per-folder PASS/FAIL summary and failure report.
String formatSummary(List<FolderResult> all, bool isWindows) {
  final out = StringBuffer();
  out.writeln(
    '\n========== SUMMARY (${isWindows ? "windows" : "linux"}) ==========',
  );
  for (final result in all) {
    out.writeln('  ${result.pass ? "PASS" : "FAIL"}  ${result.folder}');
  }
  final failed = all.where((r) => !r.pass).toList();
  if (failed.isEmpty) {
    out.writeln('\nAll ${all.length} folders passed.');
    return out.toString();
  }
  out.writeln('\n${failed.length} folder(s) FAILED:');
  for (final result in failed) {
    out.writeln('\n----- ${result.folder} (exit ${result.exitCode}) -----');
    out.writeln(result.tail);
  }
  return out.toString();
}
