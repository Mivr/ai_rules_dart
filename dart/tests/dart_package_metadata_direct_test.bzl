"""Direct `rules_testing` test for `dart_package_metadata`.

The rule registers no action: it only declares a package's name and language
version. The test pins both fields it publishes, and that it publishes nothing a
dependency edge could pick up (`DartInfo`).
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:truth.bzl", "subjects")
load("//dart:defs.bzl", "dart_package_metadata")
load("//dart:providers.bzl", "DartInfo", "DartPackageMetadataInfo")
load(":truth_helpers.bzl", "provider_of")

def _dart_package_metadata_test(env, target):
    """Asserts the `DartPackageMetadataInfo` `dart_package_metadata` publishes."""
    metadata = provider_of(
        env,
        target,
        DartPackageMetadataInfo,
        "DartPackageMetadataInfo",
        {"package_name": subjects.str, "language_version": subjects.str},
    )
    metadata.package_name().equals("metadata_subject_pkg")
    metadata.language_version().equals("3.11")
    env.expect.that_bool(DartInfo in target, "DartInfo published").equals(False)

def dart_package_metadata_direct_test_suite(name):
    """Declares the direct test of `dart_package_metadata`.

    Args:
      name: Name of the generated `test_suite`.
    """
    dart_package_metadata(
        name = name + "_subject",
        language_version = "3.11",
        package_name = "metadata_subject_pkg",
        tags = ["manual"],
    )
    analysis_test(
        name = name + "_test",
        attr_values = {"size": "small"},
        impl = _dart_package_metadata_test,
        target = ":" + name + "_subject",
    )
    native.test_suite(name = name, tests = [":" + name + "_test"])
