import 'dart:io';

import 'package:e2e_sweep/sweep.dart';
import 'package:test/test.dart';

void main() {
  group('failureNote', () {
    test('prefers the runner complaint', () {
      const log = '''
Starting local Bazel server
ERROR: something else
spec /x/e2e.yaml: command "test" exited 1:
more
''';
      expect(failureNote(log), 'command "test" exited 1:');
    });

    test('falls back to the first Bazel error, then the last line', () {
      expect(failureNote('INFO: x\nERROR: boom\nINFO: y\n'), 'ERROR: boom');
      expect(failureNote('a\nb\n'), 'b');
      expect(failureNote(''), 'no output');
    });

    test('cuts a long line', () {
      expect(failureNote('ERROR: ${'x' * 400}').length, 160);
    });
  });

  group('renderTable', () {
    const rows = [
      SweepResult(
        module: 'rules_dart',
        name: 'a',
        outcome: Outcome.passed,
        seconds: 3,
        note: '',
      ),
      SweepResult(
        module: 'rules_flutter',
        name: 'b|c',
        outcome: Outcome.skipped,
        seconds: 0,
        note: 'needs a Mac | or a device',
      ),
      SweepResult(
        module: 'rules_flutter',
        name: 'd',
        outcome: Outcome.failed,
        seconds: 9,
        note: 'boom',
        inCi: false,
      ),
    ];

    test('has one row per result and the counts', () {
      final table = renderTable(rows);
      expect(table, contains('| rules_dart/a | PASS | 3 | yes |  |'));
      expect(table, contains(r'needs a Mac \| or a device'));
      expect(
        table,
        contains(
          'Total 3: 1 passed, 1 failed, 1 cannot run on this host, '
          '0 not workspaces; 1 workspaces no workflow names.',
        ),
      );
    });
  });

  group('namedInWorkflows', () {
    const dart = Workspace('rules_dart', 'smoke', '/x');
    const flutter = Workspace('rules_flutter', 'smoke', '/y');
    final workflows = {
      'dart-ci.yaml': 'run: bazel test //... in rules_dart/e2e/smoke',
      'flutter-ci.yaml': 'run: bazel run -- --workspace=e2e/smoke_extra',
    };

    test('matches by module family and whole name', () {
      expect(namedInWorkflows(workflows, dart), isTrue);
      expect(namedInWorkflows(workflows, flutter), isFalse);
    });
  });

  group('discover', () {
    test('lists workspaces by name and tells helpers from workspaces', () {
      final root = Directory.systemTemp.createTempSync('sweep_test_');
      addTearDown(() => root.deleteSync(recursive: true));
      for (final name in ['zeta', 'alpha', '_helper']) {
        Directory('${root.path}/rules_dart/e2e/$name')
            .createSync(recursive: true);
      }
      File('${root.path}/rules_dart/e2e/zeta/MODULE.bazel')
          .writeAsStringSync('');
      File('${root.path}/rules_dart/e2e/zeta/e2e.yaml').writeAsStringSync('');
      File('${root.path}/rules_dart/e2e/alpha/MODULE.bazel')
          .writeAsStringSync('');
      final found = discover(root.path, 'rules_dart');
      expect(found.map((w) => w.name), ['_helper', 'alpha', 'zeta']);
      expect(found.map((w) => w.isWorkspace), [false, true, true]);
      expect(found.map((w) => w.hasSpec), [false, false, true]);
      expect(found.first.id, 'rules_dart/_helper');
    });
  });
}
