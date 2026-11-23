/// Tests for the README install-block check (M-7, COV-63 docs half).
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import '../readme_check.dart';

/// The fixed block: the v0.20.0 / 0.18.0 CI-tested pair.
const _good = '''
bazel_dep(name = "ai_rules_flutter", version = "0.20.0", repo_name = "rules_flutter")
bazel_dep(name = "ai_rules_dart", version = "0.18.0", repo_name = "rules_dart")

archive_override(
    module_name = "ai_rules_flutter",
    urls = ["https://github.com/Mivr/rules_flutter/releases/download/v0.20.0/rules_flutter-v0.20.0.tar.gz"],
    integrity = "sha256-1AyJQxzuzfL4p4A8wex8VUZerGOXIokNlhPv+2yYNug=",
    strip_prefix = "rules_flutter-0.20.0",
)

archive_override(
    module_name = "ai_rules_dart",
    urls = ["https://github.com/Mivr/rules_dart/releases/download/v0.18.0/rules_dart-v0.18.0.tar.gz"],
    integrity = "sha256-9sFt975mhYbFlKNUJ0F9dExQzCu6yv9Dc+WEGsxVuO0=",
    strip_prefix = "rules_dart-0.18.0",
)
''';

/// The block on main: pre-rename module names with no overrides.
const _main = '''
bazel_dep(name = "rules_flutter", version = "0.5.0")
bazel_dep(name = "rules_dart", version = "0.11.1")
''';

/// A minimal README holding [block] as its install block.
String _readme(String block) => '### MODULE.bazel\n\n```starlark\n$block```\n';

/// The checked-in README.md, through the runfiles the BUILD wires in.
String _checkedInReadme() {
  const key = 'README_CHECK_README_RLOCATION';
  final String? rlocation = Platform.environment[key];
  if (rlocation == null || rlocation.isEmpty) {
    throw StateError(
      '$key is not set; the test needs //:README.md in `data`',
    );
  }
  return File(Runfiles.create().rlocation(rlocation)).readAsStringSync();
}

void main() {
  test('a resolvable pair passes', () {
    expect(checkInstallBlock(_readme(_good)), isEmpty);
  });

  test("main's names fail", () {
    expect(checkInstallBlock(_readme(_main)), isNotEmpty);
  });

  test('a missing archive_override fails', () {
    final String without = _good.replaceFirst('archive_override(', 'overrid(');
    expect(checkInstallBlock(_readme(without)), isNotEmpty);
  });

  test('a URL tag that disagrees fails', () {
    final String moved = _good.replaceFirst(
      'download/v0.20.0/',
      'download/v0.19.0/',
    );
    expect(checkInstallBlock(_readme(moved)), isNotEmpty);
  });

  test('a strip_prefix that disagrees fails', () {
    final String moved = _good.replaceFirst(
      'strip_prefix = "rules_flutter-0.20.0"',
      'strip_prefix = "rules_flutter-0.19.0"',
    );
    expect(checkInstallBlock(_readme(moved)), isNotEmpty);
  });

  test('a non-SRI integrity fails', () {
    final String hex = _good.replaceFirst(
      'sha256-1AyJQxzuzfL4p4A8wex8VUZerGOXIokNlhPv+2yYNug=',
      'd40c89431ceecdf2f8a7803cc1ec7c55465eac639722890d9613effb6c9836e8',
    );
    expect(checkInstallBlock(_readme(hex)), isNotEmpty);
  });

  test('a wrong repo_name fails', () {
    final String renamed = _good.replaceFirst(
      'repo_name = "rules_flutter"',
      'repo_name = "other"',
    );
    expect(checkInstallBlock(_readme(renamed)), isNotEmpty);
  });

  test('the checked-in README passes', () {
    expect(checkInstallBlock(_checkedInReadme()), isEmpty);
  });
}
