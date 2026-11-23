/// Unit tests for `tools/vm/run_e2e_options.dart`: argument parsing, the
/// folder pass rule and the summary formatting.
///
/// Run with the pinned SDK (no VM, no Bazel, no pubspec needed):
///   dart run tools/vm/test/run_e2e_options_test.dart
library;

import 'dart:io';

import '../run_e2e_options.dart';

void _check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
}

bool _sameFolders(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void _testParse() {
  _check(parseE2eOptions([]) == null, 'empty args need a usage error');
  _check(
    parseE2eOptions(['--windows', '--keep-going']) == null,
    'flags alone need a usage error',
  );

  final minimal = parseE2eOptions(['my-vm'])!;
  _check(minimal.vmName == 'my-vm', 'vm name is the first positional');
  _check(!minimal.isWindows, 'windows defaults to false');
  _check(!minimal.keepGoing, 'keep-going defaults to false');
  _check(_sameFolders(minimal.folders, ciFolders), 'default folder matrix');
  _check(minimal.usesDefaultFolders, 'default matrix is marked default');

  final full = parseE2eOptions([
    'my-vm',
    '--windows',
    '--keep-going',
    '--folders=e2e/a, e2e/b',
  ])!;
  _check(full.vmName == 'my-vm', 'vm name with flags');
  _check(full.isWindows, 'windows flag');
  _check(full.keepGoing, 'keep-going flag');
  _check(
    _sameFolders(full.folders, ['e2e/a', 'e2e/b']),
    'folders split on commas and trimmed, got ${full.folders}',
  );
  _check(!full.usesDefaultFolders, 'explicit folders are not the default');

  final firstWins = parseE2eOptions(['one', 'two'])!;
  _check(firstWins.vmName == 'one', 'first positional is the vm name');

  _check(
    e2eUsage ==
        'Usage: dart run tools/vm/run_e2e.dart <vm-name> [--windows] '
            '[--folders=a,b,c] [--keep-going]',
    'usage message is unchanged',
  );
  stdout.writeln('ok parse');
}

void _testFolderMatrix() {
  _check(
    _sameFolders(ciFolders, [
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
    ]),
    'folder matrix mirrors the CI test job',
  );
  stdout.writeln('ok folder matrix');
}

void _testFolderPass() {
  _check(folderPass(0), 'exit 0 passes');
  _check(folderPass(4), 'exit 4 (no test targets) passes');
  _check(!folderPass(1), 'exit 1 fails');
  _check(!folderPass(2), 'exit 2 fails');
  _check(!folderPass(-1), 'missing RD_EXIT fails');
  _check(!folderPass(-2), 'a timeout fails');
  stdout.writeln('ok folder pass');
}

void _testSummaryAllPass() {
  final text = formatSummary(const [
    FolderResult('.', 0, true, ''),
    FolderResult('e2e/smoke', 4, true, ''),
  ], false);
  _check(
    text ==
        '\n========== SUMMARY (linux) ==========\n'
            '  PASS  .\n'
            '  PASS  e2e/smoke\n'
            '\nAll 2 folders passed.\n',
    'all-pass summary is unchanged, got:\n$text',
  );
  stdout.writeln('ok summary all pass');
}

void _testSummaryFailed() {
  final text = formatSummary(const [
    FolderResult('.', 0, true, ''),
    FolderResult('e2e/smoke', 1, false, 'line1\nline2'),
  ], true);
  _check(
    text ==
        '\n========== SUMMARY (windows) ==========\n'
            '  PASS  .\n'
            '  FAIL  e2e/smoke\n'
            '\n1 folder(s) FAILED:\n'
            '\n----- e2e/smoke (exit 1) -----\n'
            'line1\nline2\n',
    'failure summary is unchanged, got:\n$text',
  );
  stdout.writeln('ok summary failed');
}

void main() {
  _testParse();
  _testFolderMatrix();
  _testFolderPass();
  _testSummaryAllPass();
  _testSummaryFailed();
  stdout.writeln('All run_e2e_options tests passed.');
}
