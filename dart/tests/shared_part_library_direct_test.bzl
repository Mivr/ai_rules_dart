"""Direct `rules_testing` test for the `shared_part_library` macro.

`shared_part_library` wraps a `dart_library` around two `dart_codegen` targets
per source: one runs the builder's shim and emits the requested part shard, the
other merges the shards into `<src>.g.dart`. This test instantiates it with an
arbitrary shim and part suffix, to pin the macro itself rather than any one
builder's wrapper: the wrapping library's providers and both codegen targets'
providers and actions.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("//dart/ext/_shared:defs.bzl", "shared_part_library")
load(":ext_direct_helpers.bzl", "ANNOTATIONS", "LANGUAGE_VERSION", "PACKAGE", "expect_shared_part", "shared_part_targets", "source_of")

def _shared_part_library_test(env, targets):
    """Asserts the providers and the codegen actions `shared_part_library` declares."""
    expect_shared_part(env, targets, "shared_part", ".direct.g.part", "*json_serializable/shim*")

def shared_part_library_direct_test_suite(name):
    """Declares the direct test of `shared_part_library`.

    Args:
      name: Name of the generated `test_suite`.
    """
    shared_part_library(
        name = name + "_subject",
        srcs = [source_of("shared_part")],
        annotation_dep = ANNOTATIONS,
        language_version = LANGUAGE_VERSION,
        package_name = PACKAGE,
        part_suffix = ".direct.g.part",
        shim = "//dart/ext/json_serializable:shim",
        tags = ["manual"],
    )
    analysis_test(
        name = name + "_test",
        attr_values = {"size": "small"},
        impl = _shared_part_library_test,
        targets = shared_part_targets(name, "shared_part"),
    )
    native.test_suite(name = name, tests = [":" + name + "_test"])
