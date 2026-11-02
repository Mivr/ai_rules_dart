"""Direct `rules_testing` test for the `freezed_library` macro.

`freezed_library` wraps a `dart_library` around one `dart_codegen` per source, run by
the freezed shim, that emits `.freezed.dart` straight into the package. The test pins the
wrapping library's providers and that codegen target's providers and action.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("//dart/ext/freezed:defs.bzl", "freezed_library")
load(":ext_direct_helpers.bzl", "ANNOTATIONS", "LANGUAGE_VERSION", "PACKAGE", "expect_library_builder", "library_builder_targets", "source_of")

def _freezed_library_test(env, targets):
    """Asserts the providers and the codegen action `freezed_library` declares."""
    expect_library_builder(env, targets, "freezed", [".freezed.dart"], "*freezed/shim*")

def freezed_library_direct_test_suite(name):
    """Declares the direct test of `freezed_library`.

    Args:
      name: Name of the generated `test_suite`.
    """
    freezed_library(
        name = name + "_subject",
        srcs = [source_of("freezed")],
        annotation_dep = ANNOTATIONS,
        language_version = LANGUAGE_VERSION,
        package_name = PACKAGE,
        tags = ["manual"],
    )
    analysis_test(
        name = name + "_test",
        attr_values = {"size": "small"},
        impl = _freezed_library_test,
        targets = library_builder_targets(name, "freezed"),
    )
    native.test_suite(name = name, tests = [":" + name + "_test"])
