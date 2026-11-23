"""Direct `rules_testing` test for `dart_package_member`.

The rule registers no action: it states one member package of a merged
`dart_library` and publishes that package's record. The test pins the record's
fields (name, root, version, language version and the code assets the member
owns), the sources and resources the member exposes as default outputs, and that
the member provides no `DartInfo`, so it can never be a dependency itself.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:truth.bzl", "subjects")
load("//dart:defs.bzl", "dart_code_asset", "dart_package_member")
load("//dart:providers.bzl", "DartInfo", "DartPackageInfo")
load(":truth_helpers.bzl", "asset_ids", "expect_default_outputs", "provider_of")

visibility(["//dart/..."])

_ATTRS = {
    "package_name": subjects.str,
    "lib_root": subjects.str,
    "version": subjects.str,
    "language_version": subjects.str,
    "code_assets": asset_ids,
}

def _dart_package_member_test(env, target):
    """Asserts the `DartPackageInfo` and default outputs of `dart_package_member`."""
    package = provider_of(env, target, DartPackageInfo, "DartPackageInfo", _ATTRS)
    package.package_name().equals("direct_member")
    package.lib_root().equals("dart/tests")
    package.version().equals("1.2.3")
    package.language_version().equals("3.11")
    package.code_assets().contains_exactly(["package:direct_member/native.g.dart"])
    expect_default_outputs(
        env,
        target,
        ["dart/tests/lib/direct_model.dart", "dart/tests/lib/direct_schema.drift"],
    )
    env.expect.that_bool(DartInfo in target, "DartInfo published").equals(False)

def dart_package_member_direct_test_suite(name):
    """Declares the direct test of `dart_package_member`.

    Args:
      name: Name of the generated `test_suite`.
    """
    dart_code_asset(
        name = name + "_asset",
        asset_id = "package:direct_member/native.g.dart",
        link_mode = "dynamic_loading_process",
        tags = ["manual"],
    )
    dart_package_member(
        name = name + "_subject",
        code_assets = [":" + name + "_asset"],
        language_version = "3.11",
        package_name = "direct_member",
        resources = [":lib/direct_schema.drift"],
        srcs = [":lib/direct_model.dart"],
        tags = ["manual"],
        version = "1.2.3",
    )
    analysis_test(
        name = name + "_test",
        attr_values = {"size": "small"},
        impl = _dart_package_member_test,
        target = ":" + name + "_subject",
    )
    native.test_suite(name = name, tests = [":" + name + "_test"])
