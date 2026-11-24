"""Direct `rules_testing` test for `dart_fix`.

`dart_fix` applies the `dart_analyze` aspect to its `target` and hands the
aspect's `dart fix` products to an executable. The test pins what the rule
publishes: the executable, the two output groups and the environment through
which the applier finds the products, and the runfiles that carry them. The one
action the rule registers is the executable's symlink to the applier tool.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:truth.bzl", "matching")
load("//dart:defs.bzl", "dart_fix", "dart_library")
load(":truth_helpers.bzl", "WINDOWS_ATTR", "exe_extension", "expect_executable_symlink")

visibility(["//dart/..."])

def _dart_fix_test(env, target):
    """Asserts the providers and the executable symlink of `dart_fix`."""
    ext = exe_extension(env)
    subject = env.expect.that_target(target)
    subject.executable().short_path_equals("dart/tests/dart_fix_direct_subject" + ext)
    subject.output_group("dart_fix_fixes").contains_predicate(matching.file_basename_contains(".dart_analyze.fixes"))
    subject.output_group("dart_fix_manifest").contains_predicate(
        matching.file_basename_contains(".dart_analyze.fix_manifest.json"),
    )
    subject.runfiles().contains_at_least_predicates([
        matching.str_endswith(".dart_analyze.fixes"),
        matching.str_endswith(".dart_analyze.fix_manifest.json"),
        matching.str_endswith("dart/private/tools/fix_applier" + ext),
    ])
    environment = subject.provider(RunEnvironmentInfo).environment()
    environment.keys().contains_exactly(["DART_FIX_FIXES", "DART_FIX_MANIFEST"])
    env.expect.that_str(target[RunEnvironmentInfo].environment["DART_FIX_FIXES"]).contains(".dart_analyze.fixes")
    env.expect.that_str(target[RunEnvironmentInfo].environment["DART_FIX_MANIFEST"]).contains(".fix_manifest.json")
    expect_executable_symlink(env, target, "*dart/private/tools/fix_applier" + ext)

def dart_fix_direct_test_suite(name):
    """Declares the direct test of `dart_fix`.

    Args:
      name: Name of the generated `test_suite`. Instantiate it as `dart_fix_direct`: the test
        expects the subject's executable at that name.
    """
    dart_library(
        name = name + "_library",
        srcs = [":lib/direct_model.dart"],
        package_name = "direct_fix_pkg",
        tags = ["manual"],
    )
    dart_fix(
        name = name + "_subject",
        tags = ["manual"],
        target = ":" + name + "_library",
    )
    analysis_test(
        name = name + "_test",
        attr_values = {"size": "small"},
        attrs = WINDOWS_ATTR,
        impl = _dart_fix_test,
        target = ":" + name + "_subject",
    )
    native.test_suite(name = name, tests = [":" + name + "_test"])
