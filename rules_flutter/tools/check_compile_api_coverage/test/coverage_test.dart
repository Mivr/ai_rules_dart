/// Unit tests for the compile-api negative target coverage check.
///
/// Every input below is a fixture string: these tests never read the
/// checkout, so they prove the parser and the coverage rules on their own.
library;

import 'package:test/test.dart';

import '../coverage.dart';

const String _source = '''
    _compile_api_caller(
        name = "_compile_api_build_negative",
        main = "compile_api_undeclared_main.dart",
        tags = ["manual"],
    )

    # Run it explicitly to see the refusal (it is manual, not in build_test).
    _compile_api_caller(
        name = "_compile_api_build_negative_incremental",
        main = "compile_api_undeclared_main.dart",
        extra_flags = ["--incremental"],
        tags = ["manual"],
        target_compatible_with = _HOST_COMPATIBLE,
    )

    _compile_api_caller(
        name = "_compile_api_build_negative_pkg",
        main = "compile_api_undeclared_pkg_main.dart",
        deps = [":_compile_api_dep"],
        extra_flags = ["--incremental", "--define=a=(b"],
        tags = ["manual"],
        target_compatible_with = _HOST_COMPATIBLE,
    )

    # _compile_api_caller(name = "_compile_api_build_negative_commented", tags = ["manual"])
    _compile_api_caller(
        name = "_compile_api_build_negative_built",
        main = "compile_api_main.dart",
        tags = ["no-sandbox"],
    )
''';

const Set<String> _targets = {
  '_compile_api_build_negative_incremental',
  '_compile_api_build_negative_pkg',
};

/// A workflow with one step that builds [targets] one after the other, each
/// in the shape of the sibling step: an `if` that fails the job when the
/// build succeeds, then a grep of the refusal. [grepRefusal] and
/// [failOnSuccess] remove one half of that must-fail shape; [grepSuffix]
/// follows the grep and [flags] sit after `bazel build`; [continueOnError]
/// and [skip] disable the step.
String _workflow({
  required List<String> targets,
  bool grepRefusal = true,
  bool failOnSuccess = true,
  String grepSuffix = '',
  bool continueOnError = false,
  bool skip = false,
  String flags = '',
}) {
  final String header = [
    if (skip) '        if: false',
    if (continueOnError) '        continue-on-error: true',
  ].join('\n');
  final exit = failOnSuccess ? '\n            exit 1' : '';
  final grep = grepRefusal
      ? '\n          echo "\$out" | grep -F "is not a declared input"'
            '$grepSuffix'
      : '';
  final String builds = targets
      .map(
        (target) =>
            '''
          if out=\$(bazel build $flags//flutter/tests:$target 2>&1); then
            echo "\$out"
            echo "expected $target to fail, but it succeeded"$exit
          fi$grep''',
      )
      .join('\n');
  return '''
jobs:
  unit-tests:
    steps:
      - name: Negative compiles fail on the refusal
${header.isEmpty ? '' : '$header\n'}        run: |
$builds
      - name: Later step
        run: echo done
''';
}

void main() {
  group('findNegativeTargets', () {
    test('finds every manual suffixed negative', () {
      expect(findNegativeTargets(_source), _targets);
    });

    test('does not return the unsuffixed sibling or a non-manual target', () {
      final Set<String> found = findNegativeTargets(_source);
      expect(found, isNot(contains('_compile_api_build_negative')));
      expect(found, isNot(contains('_compile_api_build_negative_built')));
    });

    test('ignores a commented-out declaration', () {
      expect(
        findNegativeTargets(_source),
        isNot(contains('_compile_api_build_negative_commented')),
      );
    });

    test('keeps a target whose tags cannot be read as a list', () {
      final Set<String> found = findNegativeTargets('''
_compile_api_caller(
    name = "_compile_api_build_negative_var",
    tags = _TAGS,
)
''');
      expect(found, {'_compile_api_build_negative_var'});
    });

    test('keeps the literal prefix of a name built at load time', () {
      final Set<String> found = findNegativeTargets('''
for suffix in ["a"]:
    _compile_api_caller(
        name = "_compile_api_build_negative_" + suffix,
        tags = ["manual"],
    )
''');
      expect(found, {'_compile_api_build_negative_'});
    });

    test('finds nothing in a source without negatives', () {
      expect(findNegativeTargets('foo(name = "bar")'), isEmpty);
    });
  });

  group('checkCompileApiCoverage', () {
    test('passes when one step builds both targets and greps the refusal', () {
      final List<String> errors = checkCompileApiCoverage(
        targets: _targets,
        workflows: {'ci.yaml': _workflow(targets: _targets.toList())},
      );
      expect(errors, isEmpty);
    });

    test('passes with a local spawn strategy on one build', () {
      final List<String> errors = checkCompileApiCoverage(
        targets: {'_compile_api_build_negative_pkg'},
        workflows: {
          'ci.yaml': _workflow(
            targets: ['_compile_api_build_negative_pkg'],
            flags: '--spawn_strategy=local ',
          ),
        },
      );
      expect(errors, isEmpty);
    });

    test('passes with a loop over the targets', () {
      const workflow = r'''
jobs:
  unit-tests:
    steps:
      - name: Negatives
        run: |
          for target in \
            //flutter/tests:_compile_api_build_negative_incremental \
            //flutter/tests:_compile_api_build_negative_pkg; do
            if out=$(bazel build "$target" 2>&1); then
              echo "$out"
              exit 1
            fi
            echo "$out" | grep -F "is not a declared input"
          done
''';
      expect(
        checkCompileApiCoverage(
          targets: _targets,
          workflows: {'ci.yaml': workflow},
        ),
        isEmpty,
      );
    });

    test('passes with a build split over continuation lines', () {
      const workflow = r'''
jobs:
  unit-tests:
    steps:
      - name: Negatives
        run: |
          if out=$(bazel build \
              //flutter/tests:_compile_api_build_negative_pkg 2>&1); then
            exit 1
          fi
          echo "$out" | grep -F "is not a declared input"
''';
      expect(
        checkCompileApiCoverage(
          targets: {'_compile_api_build_negative_pkg'},
          workflows: {'ci.yaml': workflow},
        ),
        isEmpty,
      );
    });

    test('fails on the base: no workflow names either target', () {
      final List<String> errors = checkCompileApiCoverage(
        targets: _targets,
        workflows: {
          'ci.yaml': _workflow(targets: ['_compile_api_build_negative']),
        },
      );
      final String text = errors.join('\n');
      expect(errors, hasLength(2));
      expect(text, contains("'_compile_api_build_negative_incremental'"));
      expect(text, contains("'_compile_api_build_negative_pkg'"));
    });

    test('names only the target that lost its build', () {
      final List<String> errors = checkCompileApiCoverage(
        targets: _targets,
        workflows: {
          'ci.yaml': _workflow(
            targets: ['_compile_api_build_negative_incremental'],
          ),
        },
      );
      expect(errors, hasLength(1));
      expect(errors.single, contains("'_compile_api_build_negative_pkg'"));
    });

    test('fails when the targets list is empty', () {
      final List<String> errors = checkCompileApiCoverage(
        targets: {},
        workflows: {'ci.yaml': _workflow(targets: _targets.toList())},
      );
      expect(errors.join('\n'), contains('vacuous'));
    });

    test('fails when there is no workflow at all', () {
      expect(
        checkCompileApiCoverage(targets: _targets, workflows: {}),
        hasLength(2),
      );
    });

    test('fails when the step stops pinning the refusal', () {
      final List<String> errors = checkCompileApiCoverage(
        targets: _targets,
        workflows: {
          'ci.yaml': _workflow(
            targets: _targets.toList(),
            grepRefusal: false,
          ),
        },
      );
      expect(errors, hasLength(2));
    });

    test('fails when one build in the step loses its grep', () {
      final String both = _workflow(targets: _targets.toList());
      final String dropped = both.replaceFirst(
        '          echo "\$out" | grep -F "is not a declared input"\n',
        '',
      );
      final List<String> errors = checkCompileApiCoverage(
        targets: _targets,
        workflows: {'ci.yaml': dropped},
      );
      expect(errors, hasLength(1));
      expect(
        errors.single,
        contains("'_compile_api_build_negative_incremental'"),
      );
    });

    test('fails when the grep result is discarded', () {
      final List<String> errors = checkCompileApiCoverage(
        targets: _targets,
        workflows: {
          'ci.yaml': _workflow(
            targets: _targets.toList(),
            grepSuffix: ' || true',
          ),
        },
      );
      expect(errors, hasLength(2));
    });

    test('fails when the step no longer fails a successful build', () {
      final List<String> errors = checkCompileApiCoverage(
        targets: _targets,
        workflows: {
          'ci.yaml': _workflow(
            targets: _targets.toList(),
            failOnSuccess: false,
          ),
        },
      );
      expect(errors, hasLength(2));
    });

    test('fails when the step is allowed to fail', () {
      final List<String> errors = checkCompileApiCoverage(
        targets: _targets,
        workflows: {
          'ci.yaml': _workflow(
            targets: _targets.toList(),
            continueOnError: true,
          ),
        },
      );
      expect(errors, hasLength(2));
    });

    test('fails when the step is skipped', () {
      final List<String> errors = checkCompileApiCoverage(
        targets: _targets,
        workflows: {
          'ci.yaml': _workflow(targets: _targets.toList(), skip: true),
        },
      );
      expect(errors, hasLength(2));
    });

    test('fails when only an echo mentions the target and the refusal', () {
      const workflow = '''
jobs:
  unit-tests:
    steps:
      - name: Mentions
        run: |
          echo "//flutter/tests:_compile_api_build_negative_pkg is not a declared input"
''';
      final List<String> errors = checkCompileApiCoverage(
        targets: {'_compile_api_build_negative_pkg'},
        workflows: {'ci.yaml': workflow},
      );
      expect(errors, hasLength(1));
    });

    test('fails when the build only runs on success (negated if)', () {
      const workflow = r'''
jobs:
  unit-tests:
    steps:
      - name: Negated
        run: |
          if ! out=$(bazel build //flutter/tests:_compile_api_build_negative_pkg 2>&1); then
            exit 1
          fi
          echo "$out" | grep -F "is not a declared input"
''';
      expect(
        checkCompileApiCoverage(
          targets: {'_compile_api_build_negative_pkg'},
          workflows: {'ci.yaml': workflow},
        ),
        hasLength(1),
      );
    });

    test('ignores a commented-out build line in the workflow', () {
      final String workflow =
          _workflow(
            targets: ['_compile_api_build_negative_incremental'],
          ).replaceFirst(
            '      - name: Later step',
            '      # - name: Old step\n'
                '      #   run: bazel build //flutter/tests:_compile_api_build_negative_pkg\n'
                '      - name: Later step',
          );
      final List<String> errors = checkCompileApiCoverage(
        targets: _targets,
        workflows: {'ci.yaml': workflow},
      );
      expect(errors, hasLength(1));
      expect(errors.single, contains("'_compile_api_build_negative_pkg'"));
    });

    test('does not let a longer target name cover a shorter one', () {
      final List<String> errors = checkCompileApiCoverage(
        targets: {'_compile_api_build_negative_pkg'},
        workflows: {
          'ci.yaml': _workflow(
            targets: ['_compile_api_build_negative_pkg_extra'],
          ),
        },
      );
      expect(errors, hasLength(1));
    });

    test('accepts coverage spread over two workflows', () {
      final List<String> errors = checkCompileApiCoverage(
        targets: _targets,
        workflows: {
          'ci.yaml': _workflow(
            targets: ['_compile_api_build_negative_incremental'],
          ),
          'full.yaml': _workflow(targets: ['_compile_api_build_negative_pkg']),
        },
      );
      expect(errors, isEmpty);
    });

    test('reports an unresolvable load-time name as uncovered', () {
      final List<String> errors = checkCompileApiCoverage(
        targets: {'_compile_api_build_negative_'},
        workflows: {'ci.yaml': _workflow(targets: _targets.toList())},
      );
      expect(errors, hasLength(1));
    });
  });
}
