"""Direct `rules_testing` tests for `dart_code_asset`.

The rule registers no action: it binds an already-built library, or a system
library name, to a code-asset id. One test per way of supplying the library pins
what the rule publishes: the `DartCodeAssetInfo` fields and the default outputs.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:truth.bzl", "matching", "subjects")
load("//dart:defs.bzl", "dart_code_asset")
load("//dart:providers.bzl", "DartCodeAssetInfo")
load(":truth_helpers.bzl", "provider_of", "short_path_subject")

_PREBUILT = "//dart/tests/cc_fixture:prebuilt_fixture"
_ATTRS = {
    "asset_id": subjects.str,
    "link_mode": subjects.str,
    "dynamic_library": short_path_subject,
    "system_uri": subjects.str,
}

def _bundled_asset_test(env, target):
    """Asserts a `dynamic_loading_bundle` asset carries its prebuilt library."""
    asset = provider_of(env, target, DartCodeAssetInfo, "DartCodeAssetInfo", _ATTRS)
    asset.asset_id().equals("package:direct_asset/bundled.g.dart")
    asset.link_mode().equals("dynamic_loading_bundle")
    asset.system_uri().equals("")
    asset.dynamic_library().contains("prebuilt_fixture")
    env.expect.that_target(target).default_outputs().contains_predicate(
        matching.file_basename_contains("prebuilt_fixture"),
    )

def _system_asset_test(env, target):
    """Asserts a `dynamic_loading_system` asset carries its URI and no file."""
    asset = provider_of(env, target, DartCodeAssetInfo, "DartCodeAssetInfo", _ATTRS)
    asset.asset_id().equals("package:direct_asset/system.g.dart")
    asset.link_mode().equals("dynamic_loading_system")
    asset.system_uri().equals("libdirect.so.0")
    asset.dynamic_library().equals("")
    env.expect.that_target(target).default_outputs().contains_exactly([])

def dart_code_asset_direct_test_suite(name):
    """Declares the direct tests of `dart_code_asset`.

    Args:
      name: Name of the generated `test_suite`.
    """
    dart_code_asset(
        name = name + "_bundled_subject",
        asset_id = "package:direct_asset/bundled.g.dart",
        prebuilt = _PREBUILT,
        tags = ["manual"],
    )
    dart_code_asset(
        name = name + "_system_subject",
        asset_id = "package:direct_asset/system.g.dart",
        link_mode = "dynamic_loading_system",
        system_uri = "libdirect.so.0",
        tags = ["manual"],
    )
    analysis_test(
        name = name + "_bundled_test",
        attr_values = {"size": "small"},
        impl = _bundled_asset_test,
        target = ":" + name + "_bundled_subject",
    )
    analysis_test(
        name = name + "_system_test",
        attr_values = {"size": "small"},
        impl = _system_asset_test,
        target = ":" + name + "_system_subject",
    )
    native.test_suite(name = name, tests = [":" + name + "_bundled_test", ":" + name + "_system_test"])
