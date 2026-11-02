"""Direct `rules_testing` test for the `stacked_bottomsheet_library` macro.

`stacked_bottomsheet_library` wraps a `dart_library` around one `dart_codegen` per source, run by
the stacked `bottomsheet` shim, that emits `.bottomsheets.dart` straight into the package. The test pins the
wrapping library's providers and that codegen target's providers and action.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("//dart/ext/stacked:defs.bzl", "stacked_bottomsheet_library")
load(":ext_direct_helpers.bzl", "ANNOTATIONS", "LANGUAGE_VERSION", "PACKAGE", "expect_library_builder", "library_builder_targets", "source_of")

visibility(["//dart/..."])

def _stacked_bottomsheet_library_test(env, targets):
    """Asserts the providers and the codegen action `stacked_bottomsheet_library` declares."""
    expect_library_builder(env, targets, "stacked_bottomsheet", [".bottomsheets.dart"], "*stacked/shim_bottomsheet*")

def stacked_bottomsheet_library_direct_test_suite(name):
    """Declares the direct test of `stacked_bottomsheet_library`.

    Args:
      name: Name of the generated `test_suite`.
    """
    stacked_bottomsheet_library(
        name = name + "_subject",
        srcs = [source_of("stacked_bottomsheet")],
        annotation_dep = ANNOTATIONS,
        language_version = LANGUAGE_VERSION,
        package_name = PACKAGE,
        tags = ["manual"],
    )
    analysis_test(
        name = name + "_test",
        attr_values = {"size": "small"},
        impl = _stacked_bottomsheet_library_test,
        targets = library_builder_targets(name, "stacked_bottomsheet"),
    )
    native.test_suite(name = name, tests = [":" + name + "_test"])
