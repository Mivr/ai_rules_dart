"""Direct `rules_testing` test for the `library_builder_library` macro.

`library_builder_library` wraps a `dart_library` around one `dart_codegen` per
source, which runs the builder's shim and emits one file per requested output
suffix straight into the package. This test instantiates it with two suffixes
and an arbitrary shim, to pin the macro itself rather than any one builder's
wrapper: the wrapping library's providers and the codegen target's providers
and action.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("//dart/ext/_shared:defs.bzl", "library_builder_library")
load(":ext_direct_helpers.bzl", "ANNOTATIONS", "LANGUAGE_VERSION", "PACKAGE", "expect_library_builder", "library_builder_targets", "source_of")

visibility(["//dart/..."])

def _library_builder_library_test(env, targets):
    """Asserts the providers and the codegen action `library_builder_library` declares."""
    suffixes = [".first.dart", ".second.dart"]
    expect_library_builder(env, targets, "library_builder", suffixes, "*freezed/shim*")

def library_builder_library_direct_test_suite(name):
    """Declares the direct test of `library_builder_library`.

    Args:
      name: Name of the generated `test_suite`.
    """
    library_builder_library(
        name = name + "_subject",
        srcs = [source_of("library_builder")],
        annotation_dep = ANNOTATIONS,
        language_version = LANGUAGE_VERSION,
        output_suffixes = [".first.dart", ".second.dart"],
        package_name = PACKAGE,
        shim = "//dart/ext/freezed:shim",
        tags = ["manual"],
    )
    analysis_test(
        name = name + "_test",
        attr_values = {"size": "small"},
        impl = _library_builder_library_test,
        targets = library_builder_targets(name, "library_builder"),
    )
    native.test_suite(name = name, tests = [":" + name + "_test"])
