import 'package:inventory/finding.dart';
import 'package:inventory/rules/depset.dart';
import 'package:inventory/rules/toolchain.dart';
import 'package:inventory/source_tree.dart';
import 'package:test/test.dart';

List<Finding> _actions(String bzl, {bool allowSpread = false}) =>
    checkActionToolchains(SourceTree.inMemory({'m/pkg/a.bzl': bzl}), [
      (module: 'm', bzlDir: 'pkg', allowSpread: allowSpread),
    ]);

void main() {
  group('action-toolchain', () {
    test('a top-level toolchain passes', () {
      expect(
        _actions(
          'ctx.actions.run(\n    outputs = [o],\n    toolchain = None,\n)\n',
        ),
        isEmpty,
      );
    });

    test('a toolchain that is nested, commented or quoted is missing', () {
      final List<Finding> findings = _actions(
        'ctx.actions.run(env = f(toolchain = None))\n'
        'ctx.actions.run_shell(\n    # toolchain = None,\n    command = "x",\n)\n'
        'ctx.actions.run(arguments = ["toolchain = None"])\n'
        'ctx.actions.run(toolchain == None)\n',
      );
      expect(findings.map((f) => f.line), [1, 2, 6, 7]);
    });

    test('a docstring mention is not a call, an alias is a problem', () {
      final List<Finding> findings = _actions(
        '"""Wraps `ctx.actions.run(`."""\nrun = ctx.actions.run\n',
      );
      expect(findings.single.line, 2);
      expect(findings.single.message, contains('without a call'));
    });

    test('a spread is skipped only where the scope allows it', () {
      const src = 'ctx.actions.run(**kwargs)\n';
      expect(_actions(src), hasLength(1));
      expect(_actions(src, allowSpread: true), isEmpty);
    });

    test('an allow comment with a reason silences one call', () {
      expect(
        _actions(
          'def f(ctx):\n'
          '    # lint-allow: action-toolchain runs a tool from the host\n'
          '    ctx.actions.run(executable = x)\n',
        ),
        isEmpty,
      );
    });
  });

  group('sdk-files-legacy', () {
    final String modern = [
      for (final a in [
        'sdk_root',
        'compile_files',
        'runtime_files',
        'analyze_files',
      ])
        'x = ctx.attr.$a[DefaultInfo].files\n',
    ].join();

    List<Finding> check(String text) => checkSdkFiles(
      SourceTree.inMemory({'m/toolchain.bzl': text}),
      path: 'm/toolchain.bzl',
    );

    test('DefaultInfo reads pass', () {
      expect(check(modern), isEmpty);
    });

    test('a legacy .files read is caught', () {
      expect(
        check('${modern}y = ctx.attr.sdk_root.files\nz = analyze_files.files\n')
            .map((f) => f.line),
        [5, 6],
      );
    });

    test('a dropped read is reported', () {
      expect(
        check(modern.replaceAll('compile_files', 'other')).single.message,
        contains('compile_files'),
      );
    });
  });

  group('depset-flatten', () {
    List<Finding> flatten(Map<String, String> files) => checkDepsetFlatten(
      SourceTree.inMemory(files),
      (path) => !path.contains('/tests/'),
    );

    test('finds a flattened depset in production Starlark only', () {
      final List<Finding> findings = flatten({
        'm/a.bzl': 'for f in files.to_list():\n    pass\n',
        'm/tests/a.bzl': 'x = files.to_list()\n',
        'm/a.dart': 'x.to_list();\n',
      });
      expect(findings.single.file, 'm/a.bzl');
      expect(findings.single.key, 'for f in files.to_list():');
    });

    test('a comment, a string and a longer name are not a flatten', () {
      expect(
        flatten({
          'm/a.bzl':
              '# files.to_list()\nx = "a.to_list()"\ny = a.to_list_all()\n',
        }),
        isEmpty,
      );
    });

    test('an allow comment on the line or the line above needs a reason', () {
      expect(
        flatten({
          'm/a.bzl':
              'a.to_list()  # lint-allow: depset-flatten terminal rule, runs once\n'
              '# lint-allow: depset-flatten terminal rule\nb.to_list()\n',
        }),
        isEmpty,
      );
      expect(
        flatten({'m/a.bzl': 'a.to_list()  # lint-allow: depset-flatten\n'}),
        hasLength(1),
      );
    });
  });
}
