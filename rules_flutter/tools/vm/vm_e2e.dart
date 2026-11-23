/// Pure helpers for the e2e VM runner.
///
/// [`run_e2e.dart`](run_e2e.dart) shells out to a VM for every step; the flag
/// parsing, the per-folder result and the summary rendering below need no VM,
/// so they live here where unit tests can reach them without credentials.
library;

import 'dart:io';

/// The default folder matrix, mirroring the `e2e` job in
/// `.github/workflows/ci.yaml`. `.` is the root module (Starlark unit tests).
/// Override with `--folders=` to scope a run (e.g. just the Linux or Windows
/// subset).
const e2eDefaultFolders = [
  '.',
  'e2e/smoke',
  'e2e/hello_world',
  'e2e/ffi_example',
  'e2e/plugin_example',
  'e2e/ffi_plugin_example',
  'e2e/codegen',
];

/// What to run and where, parsed from the command line.
class E2eRunOptions {
  /// Creates parsed options.
  const new({
    required this.vmName,
    required this.isWindows,
    required this.keepGoing,
    required this.folders,
  });

  /// The GCP VM to run on.
  final String vmName;

  /// Whether the VM runs Windows (short output root, cmd commands).
  final bool isWindows;

  /// Whether to run the remaining folders after a failure.
  final bool keepGoing;

  /// The folders to run `bazel test //...` in, in order.
  final List<String> folders;
}

/// Parses [args] to [E2eRunOptions].
///
/// Prints usage and exits 2 when no VM name is given.
E2eRunOptions parseE2eArgs(List<String> args) {
  final List<String> positional = args
      .where((a) => !a.startsWith('--'))
      .toList();
  if (positional.isEmpty) {
    stderr.writeln(
      'Usage: dart run tools/vm/run_e2e.dart <vm-name> [--windows] '
      '[--folders=a,b,c] [--keep-going]',
    );
    exit(2);
  }
  final String vmName = positional.first;
  final bool isWindows = args.contains('--windows');
  final bool keepGoing = args.contains('--keep-going');
  final String foldersArg = args
      .firstWhere((a) => a.startsWith('--folders='), orElse: () => '')
      .replaceFirst('--folders=', '');
  final List<String> folders = foldersArg.isEmpty
      ? e2eDefaultFolders
      : foldersArg.split(',').map((s) => s.trim()).toList();
  return E2eRunOptions(
    vmName: vmName,
    isWindows: isWindows,
    keepGoing: keepGoing,
    folders: folders,
  );
}

/// The outcome of one folder's `bazel test //...` run.
class E2eFolderResult {
  /// Creates one folder's outcome.
  const new(this.folder, this.exitCode, this.pass, this.tail);

  /// The folder that ran.
  final String folder;

  /// The test exit code (`RF_EXIT`), where 4 means "no test targets".
  final int exitCode;

  /// Whether the folder passed (exit 0, or 4 for no test targets).
  final bool pass;

  /// The last lines of the combined output, printed for failures.
  final String tail;
}

/// Renders the final summary over [results], byte for byte as printed.
///
/// The caller writes the result and exits non-zero when any folder failed.
String renderE2eSummary(List<E2eFolderResult> results, bool isWindows) {
  final out = StringBuffer();
  out.writeln(
    '\n========== SUMMARY (${isWindows ? "windows" : "linux"}) ==========',
  );
  for (final r in results) {
    out.writeln('  ${r.pass ? "PASS" : "FAIL"}  ${r.folder}');
  }
  final List<E2eFolderResult> failed = results.where((r) => !r.pass).toList();
  if (failed.isEmpty) {
    out.writeln('\nAll ${results.length} folders passed.');
  } else {
    out.writeln('\n${failed.length} folder(s) FAILED:');
    for (final r in failed) {
      out.writeln('\n----- ${r.folder} (exit ${r.exitCode}) -----');
      out.writeln(r.tail);
    }
  }
  return out.toString();
}
