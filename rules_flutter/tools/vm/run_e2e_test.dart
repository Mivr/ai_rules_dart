import 'package:test/test.dart';

import 'vm_e2e.dart';

void main() {
  group('parseE2eArgs', () {
    test('defaults to the CI matrix on Linux, stopping at first failure', () {
      final E2eRunOptions options = parseE2eArgs(['my-vm']);
      expect(options.vmName, 'my-vm');
      expect(options.isWindows, isFalse);
      expect(options.keepGoing, isFalse);
      expect(options.folders, e2eDefaultFolders);
    });

    test('parses Windows, keep-going and an explicit folder list', () {
      final E2eRunOptions options = parseE2eArgs([
        'my-vm',
        '--windows',
        '--keep-going',
        '--folders=e2e/smoke, e2e/hello_world',
      ]);
      expect(options.vmName, 'my-vm');
      expect(options.isWindows, isTrue);
      expect(options.keepGoing, isTrue);
      expect(options.folders, ['e2e/smoke', 'e2e/hello_world']);
    });
  });

  group('renderE2eSummary', () {
    test('an all-pass run lists every folder', () {
      expect(
        renderE2eSummary(const [
          E2eFolderResult('.', 0, true, 'tail'),
          E2eFolderResult('e2e/smoke', 4, true, 'tail'),
        ], false),
        '\n========== SUMMARY (linux) ==========\n'
        '  PASS  .\n'
        '  PASS  e2e/smoke\n'
        '\nAll 2 folders passed.\n',
      );
    });

    test('a failing run reports each failure with its tail', () {
      expect(
        renderE2eSummary(const [
          E2eFolderResult('.', 0, true, 'tail'),
          E2eFolderResult('e2e/smoke', 1, false, 'last lines'),
        ], true),
        '\n========== SUMMARY (windows) ==========\n'
        '  PASS  .\n'
        '  FAIL  e2e/smoke\n'
        '\n1 folder(s) FAILED:\n'
        '\n----- e2e/smoke (exit 1) -----\n'
        'last lines\n',
      );
    });
  });
}
