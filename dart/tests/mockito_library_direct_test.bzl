"""Direct `rules_testing` test for the `mockito_library` macro.

`mockito_library` wraps a `dart_library` around one `dart_codegen` per source, run by
the mockito shim, that emits `.mocks.dart` straight into the package. The test pins the
wrapping library's providers and that codegen target's providers and action.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("//dart/ext/mockito:defs.bzl", "mockito_library")
load(":ext_direct_helpers.bzl", "ANNOTATIONS", "LANGUAGE_VERSION", "PACKAGE", "expect_library_builder", "library_builder_targets", "source_of")

def _mockito_library_test(env, targets):
    """Asserts the providers and the codegen action `mockito_library` declares."""
    expect_library_builder(env, targets, "mockito", [".mocks.dart"], "*mockito/shim*")

def mockito_library_direct_test_suite(name):
    """Declares the direct test of `mockito_library`.

    Args:
      name: Name of the generated `test_suite`.
    """
    mockito_library(
        name = name + "_subject",
        srcs = [source_of("mockito")],
        annotation_dep = ANNOTATIONS,
        language_version = LANGUAGE_VERSION,
        package_name = PACKAGE,
        tags = ["manual"],
    )
    analysis_test(
        name = name + "_test",
        attr_values = {"size": "small"},
        impl = _mockito_library_test,
        targets = library_builder_targets(name, "mockito"),
    )
    native.test_suite(name = name, tests = [":" + name + "_test"])
