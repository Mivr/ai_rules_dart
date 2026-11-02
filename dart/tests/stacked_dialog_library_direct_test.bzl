"""Direct `rules_testing` test for the `stacked_dialog_library` macro.

`stacked_dialog_library` wraps a `dart_library` around one `dart_codegen` per source, run by
the stacked `dialog` shim, that emits `.dialogs.dart` straight into the package. The test pins the
wrapping library's providers and that codegen target's providers and action.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("//dart/ext/stacked:defs.bzl", "stacked_dialog_library")
load(":ext_direct_helpers.bzl", "ANNOTATIONS", "LANGUAGE_VERSION", "PACKAGE", "expect_library_builder", "library_builder_targets", "source_of")

def _stacked_dialog_library_test(env, targets):
    """Asserts the providers and the codegen action `stacked_dialog_library` declares."""
    expect_library_builder(env, targets, "stacked_dialog", [".dialogs.dart"], "*stacked/shim_dialog*")

def stacked_dialog_library_direct_test_suite(name):
    """Declares the direct test of `stacked_dialog_library`.

    Args:
      name: Name of the generated `test_suite`.
    """
    stacked_dialog_library(
        name = name + "_subject",
        srcs = [source_of("stacked_dialog")],
        annotation_dep = ANNOTATIONS,
        language_version = LANGUAGE_VERSION,
        package_name = PACKAGE,
        tags = ["manual"],
    )
    analysis_test(
        name = name + "_test",
        attr_values = {"size": "small"},
        impl = _stacked_dialog_library_test,
        targets = library_builder_targets(name, "stacked_dialog"),
    )
    native.test_suite(name = name, tests = [":" + name + "_test"])
