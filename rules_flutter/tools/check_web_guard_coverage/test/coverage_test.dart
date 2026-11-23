/// Unit tests for the web-guard fixture coverage check.
///
/// Every input below is a fixture string: these tests never read the
/// checkout, so they prove the parser and the coverage rules on their own.
library;

import 'package:test/test.dart';

import '../coverage.dart';

const String _source = '''
    for spelling in [
        "file",
        "app_scheme",
    ]:
        flutter_web_bundle(
            name = "_web_guard_hostile_" + spelling,
            tags = ["manual"],
        )
        flutter_web_bundle(
            name = "_web_guard_hostile_%s_js" % spelling,
            compiler = "dart2js",
            tags = ["manual"],
        )
    # _web_guard_hostile_commented must not count.
    flutter_web_bundle(
        name = "_web_guard_hostile_extra",
        tags = ["manual"],
    )
''';

const Set<String> _fixtures = {
  '_web_guard_hostile_file',
  '_web_guard_hostile_file_js',
  '_web_guard_hostile_app_scheme',
  '_web_guard_hostile_app_scheme_js',
  '_web_guard_hostile_extra',
};

/// A workflow with one step that builds [targets]. Its `if` fails the job
/// when the build succeeds; [grepsGuard] and [failOnSuccess] remove one half
/// of that must-fail shape, [continueOnError] and [skip] disable the step.
String _workflow({
  required List<String> targets,
  bool grepsGuard = true,
  bool failOnSuccess = true,
  bool continueOnError = false,
  bool skip = false,
}) {
  final condition = skip ? '\n        if: false' : '';
  final allowedToFail = continueOnError
      ? '\n        continue-on-error: true'
      : '';
  final String list = targets.join(' ');
  final success = failOnSuccess
      ? '''
            if out=\$(bazel build "\$target" 2>&1); then
              echo "\$out"
              echo "expected \$target to fail, but it succeeded"
              exit 1
            fi'''
      : '''
            if out=\$(bazel build "\$target" 2>&1); then
              echo "\$out"
            fi''';
  final grep = grepsGuard
      ? '''
            echo "\$out" | grep -F "is not a declared input"'''
      : '';
  return '''
jobs:
  unit-tests:
    steps:
      - name: Web-guard hostile imports fail on the guard refusal$condition$allowedToFail
        run: |
          for target in $list; do
$success
$grep
          done
''';
}

void main() {
  group('findHostileFixtures', () {
    test('expands both targets per spelling and keeps literal targets', () {
      expect(findHostileFixtures(_source), _fixtures);
    });

    test('ignores a commented-out target and format placeholders', () {
      final Set<String> fixtures = findHostileFixtures(_source);
      expect(fixtures, isNot(contains('_web_guard_hostile_commented')));
      expect(fixtures, isNot(contains('_web_guard_hostile_%s_js')));
      expect(fixtures, isNot(contains('_web_guard_hostile_')));
    });
  });

  group('checkWebGuardCoverage', () {
    test('passes when every fixture is named by a must-fail guard step', () {
      expect(
        checkWebGuardCoverage(
          fixtures: _fixtures,
          workflows: {
            'ci.yaml': _workflow(targets: _fixtures.toList()),
          },
        ),
        isEmpty,
      );
    });

    test('names a fixture dropped from the guard step', () {
      final List<String> errors = checkWebGuardCoverage(
        fixtures: _fixtures,
        workflows: {
          'ci.yaml': _workflow(
            targets: _fixtures
                .where((f) => f != '_web_guard_hostile_file')
                .toList(),
          ),
        },
      );
      expect(
        errors.join('\n'),
        allOf(
          contains("'_web_guard_hostile_file' is not named"),
          isNot(contains("'_web_guard_hostile_file_js' is not named")),
        ),
      );
    });

    test('does not let a dart2js twin cover its default-compiler fixture', () {
      final List<String> errors = checkWebGuardCoverage(
        fixtures: {'_web_guard_hostile_file', '_web_guard_hostile_file_js'},
        workflows: {
          'ci.yaml': _workflow(
            targets: const ['//flutter/tests:_web_guard_hostile_file_js'],
          ),
        },
      );
      expect(
        errors.join('\n'),
        contains("'_web_guard_hostile_file' is not named"),
      );
    });

    test('fails when the step stops pinning the guard message', () {
      final List<String> errors = checkWebGuardCoverage(
        fixtures: _fixtures,
        workflows: {
          'ci.yaml': _workflow(
            targets: _fixtures.toList(),
            grepsGuard: false,
          ),
        },
      );
      expect(errors, hasLength(_fixtures.length));
    });

    test('fails when the step no longer fails a successful build', () {
      final List<String> errors = checkWebGuardCoverage(
        fixtures: _fixtures,
        workflows: {
          'ci.yaml': _workflow(
            targets: _fixtures.toList(),
            failOnSuccess: false,
          ),
        },
      );
      expect(errors, hasLength(_fixtures.length));
    });

    test('fails when the step is allowed to fail', () {
      final List<String> errors = checkWebGuardCoverage(
        fixtures: _fixtures,
        workflows: {
          'ci.yaml': _workflow(
            targets: _fixtures.toList(),
            continueOnError: true,
          ),
        },
      );
      expect(errors, hasLength(_fixtures.length));
    });

    test('fails when the step is skipped', () {
      final List<String> errors = checkWebGuardCoverage(
        fixtures: _fixtures,
        workflows: {
          'ci.yaml': _workflow(targets: _fixtures.toList(), skip: true),
        },
      );
      expect(errors, hasLength(_fixtures.length));
    });

    test('ignores a commented-out fixture line in the workflow', () {
      final String workflow =
          _workflow(
            targets: _fixtures
                .where((f) => f != '_web_guard_hostile_app_scheme')
                .toList(),
          ).replaceFirst(
            '          done',
            '          # //flutter/tests:_web_guard_hostile_app_scheme\n'
                '          done',
          );
      final List<String> errors = checkWebGuardCoverage(
        fixtures: _fixtures,
        workflows: {'ci.yaml': workflow},
      );
      expect(
        errors.join('\n'),
        contains("'_web_guard_hostile_app_scheme' is not named"),
      );
    });
  });
}
