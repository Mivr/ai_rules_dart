"""Direct `rules_testing` test for the `json_serializable_library` macro.

`json_serializable_library` wraps a `dart_library` around two `dart_codegen` targets per source:
one runs the json_serializable shim and emits the `.json_serializable.g.part` shard, the other
merges that shard into `<src>.g.dart`. The test pins the wrapping library's
providers and both codegen targets' providers and actions.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("//dart/ext/json_serializable:defs.bzl", "json_serializable_library")
load(":ext_direct_helpers.bzl", "ANNOTATIONS", "LANGUAGE_VERSION", "PACKAGE", "expect_shared_part", "shared_part_targets", "source_of")

visibility(["//dart/..."])

def _json_serializable_library_test(env, targets):
    """Asserts the providers and the codegen actions `json_serializable_library` declares."""
    expect_shared_part(env, targets, "json_serializable", ".json_serializable.g.part", "*json_serializable/shim*")

def json_serializable_library_direct_test_suite(name):
    """Declares the direct test of `json_serializable_library`.

    Args:
      name: Name of the generated `test_suite`.
    """
    json_serializable_library(
        name = name + "_subject",
        srcs = [source_of("json_serializable")],
        annotation_dep = ANNOTATIONS,
        language_version = LANGUAGE_VERSION,
        package_name = PACKAGE,
        tags = ["manual"],
    )
    analysis_test(
        name = name + "_test",
        attr_values = {"size": "small"},
        impl = _json_serializable_library_test,
        targets = shared_part_targets(name, "json_serializable"),
    )
    native.test_suite(name = name, tests = [":" + name + "_test"])
