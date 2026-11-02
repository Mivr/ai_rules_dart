"""Direct `rules_testing` test for the `dart_analysis_test` rule.

`dart_analysis_test` applies the `dart_analyze` aspect to the targets it lists
and carries the aspect's stamps in the runfiles of a do-nothing test binary. The
test pins what the rule publishes: the test executable and the runfiles holding
the analysis and format-check stamps of the listed target. The one action the
rule registers is the executable's symlink to the do-nothing tool.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:truth.bzl", "matching")
load("//dart:defs.bzl", "dart_analysis_test", "dart_library")
load(":truth_helpers.bzl", "WINDOWS_ATTR", "exe_extension", "expect_executable_symlink")

def _dart_analysis_test_test(env, target):
    """Asserts the providers and the executable symlink of `dart_analysis_test`."""
    ext = exe_extension(env)
    subject = env.expect.that_target(target)
    subject.executable().short_path_equals("dart/tests/dart_analysis_test_direct_subject" + ext)
    subject.runfiles().contains_at_least_predicates([
        matching.str_endswith("dart_analysis_test_direct_library.dart_analyze.analyzed"),
        matching.str_endswith("dart_analysis_test_direct_library.dart_analyze.formatted"),
        matching.str_endswith("dart/private/tools/noop" + ext),
    ])
    expect_executable_symlink(env, target, "*dart/private/tools/noop" + ext)

def dart_analysis_test_direct_test_suite(name):
    """Declares the direct test of `dart_analysis_test`.

    Args:
      name: Name of the generated `test_suite`. Instantiate it as `dart_analysis_test_direct`:
        the test expects the subject's executable at that name.
    """
    dart_library(
        name = name + "_library",
        srcs = [":lib/direct_model.dart"],
        package_name = "direct_analysis_pkg",
        tags = ["manual"],
    )
    dart_analysis_test(
        name = name + "_subject",
        tags = ["manual"],
        targets = [":" + name + "_library"],
    )
    analysis_test(
        name = name + "_test",
        attr_values = {"size": "small"},
        attrs = WINDOWS_ATTR,
        impl = _dart_analysis_test_test,
        target = ":" + name + "_subject",
    )
    native.test_suite(name = name, tests = [":" + name + "_test"])
