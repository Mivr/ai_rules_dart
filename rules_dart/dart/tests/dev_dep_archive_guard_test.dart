import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// Whether [moduleText] declares `rules_testing` as a dev dependency.
bool rulesTestingIsDevDependency(String moduleText) {
  final RegExpMatch? decl = RegExp(
    r'bazel_dep\(([^)]*name\s*=\s*"rules_testing"[^)]*)\)',
  ).firstMatch(moduleText);
  if (decl == null) return false;
  return RegExp(r'dev_dependency\s*=\s*True').hasMatch(decl.group(1)!);
}

/// Whether [attributesText] keeps `/dart/tests/` out of `git archive` and
/// stamps `/BUILD.bazel` so `//:analysis_config` drops missing fixture options.
bool archiveExcludesDartTests(String attributesText) {
  final Set<String> lines = attributesText
      .split('\n')
      .map((String line) => line.trim())
      .toSet();
  return lines.contains('/dart/tests/ export-ignore') &&
      lines.contains('/BUILD.bazel export-subst');
}

/// Whether root [buildText] exports the guarded files to `//dart/tests:__pkg__`
/// and guards `_TEST_FIXTURE_OPTIONS` in `//:analysis_config` on the archive
/// stamp.
bool rootBuildGuardsFixtureOptions(String buildText) =>
    buildText.contains('"BUILD.bazel"') &&
    buildText.contains(r'_ARCHIVE_STAMP = "$Format:%H$"') &&
    buildText.contains(
      r'_HAS_DART_TESTS = _ARCHIVE_STAMP.startswith("$Format")',
    ) &&
    buildText.contains(
      'options = [":analysis_options"] + '
      '(_TEST_FIXTURE_OPTIONS if _HAS_DART_TESTS else [])',
    );

/// Guards that `@rules_testing` stays dev-only and `dart/tests` stays out of
/// release archives, so published consumers never load or resolve it.
///
/// Arguments are the `rlocationpath`s of `MODULE.bazel`, `.gitattributes` and
/// root `BUILD.bazel`.
void main(List<String> args) {
  _registerLiveTreeTests(args);
  _registerUnitTests();
}

void _registerLiveTreeTests(List<String> args) {
  group('dev dependency archive guard', () {
    test('MODULE.bazel declares rules_testing as a dev dependency', () {
      final String text = File(Runfiles.create().rlocation(args[0]))
          .readAsStringSync();
      expect(rulesTestingIsDevDependency(text), isTrue);
    });

    test(
      '.gitattributes export-ignores /dart/tests/ and stamps /BUILD.bazel',
      () {
        final String text = File(Runfiles.create().rlocation(args[1]))
            .readAsStringSync();
        expect(archiveExcludesDartTests(text), isTrue);
      },
    );

    test(
      'root BUILD.bazel guards //dart/tests fixture options on archive stamp',
      () {
        final String text = File(Runfiles.create().rlocation(args[2]))
            .readAsStringSync();
        expect(rootBuildGuardsFixtureOptions(text), isTrue);
      },
    );
  });
}

void _registerUnitTests() {
  group('guard unit tests', () {
    test('a rules_testing dep without dev_dependency fails', () {
      expect(
        rulesTestingIsDevDependency(
          'bazel_dep(name = "rules_testing", version = "0.9.0")\n',
        ),
        isFalse,
      );
    });

    test('a dev_dependency on another dep does not count', () {
      expect(
        rulesTestingIsDevDependency(
          'bazel_dep(name = "rules_testing", version = "0.9.0")\n'
          'bazel_dep(name = "x", version = "1", dev_dependency = True)\n',
        ),
        isFalse,
      );
    });

    test('a dev rules_testing dep passes', () {
      expect(
        rulesTestingIsDevDependency(
          'bazel_dep(name = "rules_testing", version = "0.9.0", '
          'dev_dependency = True)\n',
        ),
        isTrue,
      );
    });

    test('.gitattributes without both archive attributes fails', () {
      expect(archiveExcludesDartTests('examples export-ignore\n'), isFalse);
      expect(
        archiveExcludesDartTests(
          'dart/tests export-ignore\n/BUILD.bazel export-subst\n',
        ),
        isFalse,
      );
      expect(archiveExcludesDartTests('/dart/tests/ export-ignore\n'), isFalse);
    });

    test('.gitattributes with both archive attributes passes', () {
      expect(
        archiveExcludesDartTests(
          'a export-ignore\n'
          '/dart/tests/ export-ignore\n'
          '/BUILD.bazel export-subst\n',
        ),
        isTrue,
      );
    });

    test('root BUILD.bazel without archive-guarded fixture options fails', () {
      expect(
        rootBuildGuardsFixtureOptions(
          'dart_analysis_config(\n'
          '    name = "analysis_config",\n'
          '    options = [":analysis_options", "//dart/tests/analyze_aspect_fixture:options"],\n'
          ')\n',
        ),
        isFalse,
      );
    });

    test('root BUILD.bazel with archive-guarded fixture options passes', () {
      expect(
        rootBuildGuardsFixtureOptions(
          'exports_files([".gitattributes", "BUILD.bazel", "MODULE.bazel"])\n'
          r'_ARCHIVE_STAMP = "$Format:%H$"'
          '\n'
          r'_HAS_DART_TESTS = _ARCHIVE_STAMP.startswith("$Format")'
          '\n'
          'dart_analysis_config(\n'
          '    name = "analysis_config",\n'
          '    options = [":analysis_options"] + '
          '(_TEST_FIXTURE_OPTIONS if _HAS_DART_TESTS else []),\n'
          ')\n',
        ),
        isTrue,
      );
    });
  });
}
