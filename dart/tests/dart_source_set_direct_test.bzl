"""Direct `rules_testing` test for `dart_source_set`.

`dart_source_set` assembles its sources into one tree artifact. The test pins
what the rule publishes (the directory as its only default output, and in the
runfiles) and the one `DartCopyTree` action: the root and prefix-replacement
flags that place each file, and the sources and copy tool it reads.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:truth.bzl", "matching")
load("//dart:defs.bzl", "dart_source_set")
load(":truth_helpers.bzl", "action_of", "expect_default_outputs", "expect_inputs")

visibility(["//dart/..."])

def _dart_source_set_test(env, target):
    """Asserts the providers and the `DartCopyTree` action of `dart_source_set`."""
    expect_default_outputs(env, target, ["dart/tests/dart_source_set_direct_subject"])
    env.expect.that_target(target).runfiles().contains_at_least_predicates([
        matching.str_endswith("dart/tests/dart_source_set_direct_subject"),
    ])
    action = action_of(env, target, "DartCopyTree")
    action.argv().contains_at_least(["--root", "dart/tests", "--workspace", "--file"])
    action.contains_flag_values([("--replace", "lib")])
    action.argv().contains_at_least(["dart/tests/lib/direct_model.dart", "dart/tests/lib/direct_schema.drift"])
    expect_inputs(action, [
        "dart/tests/lib/direct_model.dart",
        "dart/tests/lib/direct_schema.drift",
        "*dart/private/tools/copy_tree.dill",
    ])

def dart_source_set_direct_test_suite(name):
    """Declares the direct test of `dart_source_set`.

    Args:
      name: Name of the generated `test_suite`. Instantiate it as `dart_source_set_direct`: the
        test expects the subject at that name.
    """
    dart_source_set(
        name = name + "_subject",
        srcs = [":lib/direct_model.dart", ":lib/direct_schema.drift"],
        replace_prefixes = {"lib": "pkg/lib"},
        tags = ["manual"],
    )
    analysis_test(
        name = name + "_test",
        attr_values = {"size": "small"},
        impl = _dart_source_set_test,
        target = ":" + name + "_subject",
    )
    native.test_suite(name = name, tests = [":" + name + "_test"])
