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

/// Whether [attributesText] keeps `/dart/tests/` out of `git archive`.
bool archiveExcludesDartTests(String attributesText) => attributesText
    .split('\n')
    .any((line) => line.trim() == '/dart/tests/ export-ignore');

/// Guards that `@rules_testing` stays dev-only and `dart/tests` stays out of
/// release archives, so published consumers never load or resolve it.
///
/// Arguments are the `rlocationpath`s of `MODULE.bazel` and `.gitattributes`.
void main(List<String> args) {
  group('dev dependency archive guard', () {
    test('MODULE.bazel declares rules_testing as a dev dependency', () {
      final String text = File(Runfiles.create().rlocation(args[0]))
          .readAsStringSync();
      expect(rulesTestingIsDevDependency(text), isTrue);
    });

    test('.gitattributes export-ignores /dart/tests/', () {
      final String text = File(Runfiles.create().rlocation(args[1]))
          .readAsStringSync();
      expect(archiveExcludesDartTests(text), isTrue);
    });
  });

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

    test('.gitattributes without the export-ignore line fails', () {
      expect(archiveExcludesDartTests('examples export-ignore\n'), isFalse);
      expect(archiveExcludesDartTests('dart/tests export-ignore\n'), isFalse);
    });

    test('.gitattributes with the export-ignore line passes', () {
      expect(
        archiveExcludesDartTests(
          'a export-ignore\n/dart/tests/ export-ignore\n',
        ),
        isTrue,
      );
    });
  });
}
