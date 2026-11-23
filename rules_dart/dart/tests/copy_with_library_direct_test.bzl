"""Direct `rules_testing` test for the `copy_with_library` macro.

`copy_with_library` wraps a `dart_library` around two `dart_codegen` targets per source:
one runs the copy_with_extension_gen shim and emits the `.copy_with_extension_gen.g.part` shard, the other
merges that shard into `<src>.g.dart`. The test pins the wrapping library's
providers and both codegen targets' providers and actions.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("//dart/ext/copy_with_extension_gen:defs.bzl", "copy_with_library")
load(":ext_direct_helpers.bzl", "ANNOTATIONS", "LANGUAGE_VERSION", "PACKAGE", "expect_shared_part", "shared_part_targets", "source_of")

visibility(["//dart/..."])

def _copy_with_library_test(env, targets):
    """Asserts the providers and the codegen actions `copy_with_library` declares."""
    expect_shared_part(env, targets, "copy_with", ".copy_with_extension_gen.g.part", "*copy_with_extension_gen/shim*")

def copy_with_library_direct_test_suite(name):
    """Declares the direct test of `copy_with_library`.

    Args:
      name: Name of the generated `test_suite`.
    """
    copy_with_library(
        name = name + "_subject",
        srcs = [source_of("copy_with")],
        annotation_dep = ANNOTATIONS,
        language_version = LANGUAGE_VERSION,
        package_name = PACKAGE,
        tags = ["manual"],
    )
    analysis_test(
        name = name + "_test",
        attr_values = {"size": "small"},
        impl = _copy_with_library_test,
        targets = shared_part_targets(name, "copy_with"),
    )
    native.test_suite(name = name, tests = [":" + name + "_test"])
