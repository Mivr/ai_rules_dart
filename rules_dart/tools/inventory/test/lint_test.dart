import 'package:inventory/debt.dart';
import 'package:inventory/finding.dart';
import 'package:inventory/lint.dart';
import 'package:inventory/subsystems.dart';
import 'package:test/test.dart';

import 'trees.dart';

final SubsystemTable _table = SubsystemTable.parse('''
{"source_extensions": ["bzl", "dart"], "test_paths": ["**/tests/**"],
 "subsystems": []}
''');

List<Finding> _lint(Map<String, String?> overrides) =>
    runLint(cleanTree(overrides), _table).findings;

void main() {
  test('a clean repository has nothing to report', () {
    expect(_lint({}), isEmpty);
  });

  group('one new violation of each rule is found, with file and line', () {
    test('depset-flatten', () {
      final List<Finding> findings = _lint({
        'rules_dart/dart/private/new.bzl': 'x = 1\ny = deps.to_list()\n',
      });
      expect(
        findings.single.display,
        startsWith('rules_dart/dart/private/new.bzl:2: [depset-flatten]'),
      );
    });

    test('download-unpinned: a raw ctx.download', () {
      final List<Finding> findings = _lint({
        'rules_flutter/flutter/private/new.bzl':
            'def f(ctx):\n    ctx.download(url)\n',
      });
      expect(findings.single.rule, 'download-unpinned');
      expect(findings.single.file, 'rules_flutter/flutter/private/new.bzl');
      expect(findings.single.line, 2);
    });

    test('download-unpinned: an http_archive without a checksum', () {
      final List<Finding> findings = _lint({
        'rules_dart/e2e/x/MODULE.bazel':
            'http_archive(name = "x", urls = [])\n',
      });
      expect(findings.single.rule, 'download-unpinned');
      expect(findings.single.line, 1);
    });

    test('pub-fetch-unvalidated', () {
      final List<Finding> findings = _lint({
        'rules_dart/dart/pub/private/new.bzl':
            'def f(ctx):\n    pinned_download(ctx)\n',
      });
      expect(findings.single.rule, 'pub-fetch-unvalidated');
      expect(findings.single.line, 2);
    });

    test('action-toolchain', () {
      final List<Finding> findings = _lint({
        'rules_dart/dart/private/new.bzl':
            'def f(ctx):\n    ctx.actions.run(executable = x)\n',
      });
      expect(findings.single.rule, 'action-toolchain');
      expect(findings.single.line, 2);
    });

    test('sdk-files-legacy', () {
      final List<Finding> findings = _lint({
        'rules_dart/dart/toolchain.bzl':
            '${cleanFiles()['rules_dart/dart/toolchain.bzl']}y = sdk_root.files\n',
      });
      expect(findings.single.rule, 'sdk-files-legacy');
      expect(findings.single.line, 5);
    });

    test('bazel-dep-floor', () {
      final List<Finding> findings = _lint({
        'rules_flutter/MODULE.bazel':
            cleanFiles()['rules_flutter/MODULE.bazel']!.replaceFirst(
              '0.2.20',
              '0.2.26',
            ),
      });
      expect(findings.single.rule, 'bazel-dep-floor');
      expect(findings.single.line, 1);
    });

    test('maven-lock-unpinned', () {
      final List<Finding> findings = _lint({
        'rules_flutter/e2e/app/m_install.json': '{"version": "3", "artifacts": {"androidx.annotation:annotation": {"shasums": {"jar": "abc"}, "version": "1.9.1"}}}',
      });
      expect(findings.single.rule, 'maven-lock-unpinned');
      expect(findings.single.file, 'rules_flutter/e2e/app/MODULE.bazel');
    });
  });

  test('a rule whose scope has no files is a setup error, not a pass', () {
    expect(
      () => _lint({'rules_flutter/e2e/app/MODULE.bazel': null}),
      throwsA(isA<SetupException>()),
    );
  });

  test('test Starlark may flatten, production may not', () {
    expect(
      _lint({'rules_dart/dart/tests/new.bzl': 'x = deps.to_list()\n'}),
      isEmpty,
    );
  });

  test('debt covers a violation; a second one of the same line is new', () {
    final List<Finding> one = _lint({
      'rules_dart/dart/private/new.bzl': 'x = deps.to_list()\n',
    });
    final List<DebtEntry> debt = debtFor(one);
    expect(applyDebt(one, debt).fresh, isEmpty);
    final List<Finding> two = _lint({
      'rules_dart/dart/private/new.bzl':
          'x = deps.to_list()\ny = a\nx = deps.to_list()\n',
    });
    expect(applyDebt(two, debt).fresh.single.line, 3);
  });
}
