"""Direct `rules_testing` test for the `built_value_library` macro.

`built_value_library` wraps a `dart_library` around two `dart_codegen` targets per source:
one runs the built_value shim and emits the `.built_value.g.part` shard, the other
merges that shard into `<src>.g.dart`. The test pins the wrapping library's
providers and both codegen targets' providers and actions.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("//dart/ext/built_value:defs.bzl", "built_value_library")
load(":ext_direct_helpers.bzl", "ANNOTATIONS", "LANGUAGE_VERSION", "PACKAGE", "expect_shared_part", "shared_part_targets", "source_of")

visibility(["//dart/..."])

def _built_value_library_test(env, targets):
    """Asserts the providers and the codegen actions `built_value_library` declares."""
    expect_shared_part(env, targets, "built_value", ".built_value.g.part", "*built_value/shim*")

def built_value_library_direct_test_suite(name):
    """Declares the direct test of `built_value_library`.

    Args:
      name: Name of the generated `test_suite`.
    """
    built_value_library(
        name = name + "_subject",
        srcs = [source_of("built_value")],
        annotation_dep = ANNOTATIONS,
        language_version = LANGUAGE_VERSION,
        package_name = PACKAGE,
        tags = ["manual"],
    )
    analysis_test(
        name = name + "_test",
        attr_values = {"size": "small"},
        impl = _built_value_library_test,
        targets = shared_part_targets(name, "built_value"),
    )
    native.test_suite(name = name, tests = [":" + name + "_test"])
