"""Direct `rules_testing` analysis tests for `//flutter:native_assets.bzl` rules.

Tests `flutter_native_asset`, `flutter_data_asset`, and `flutter_native_assets_manifest`.
"""

load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_testing//lib:analysis_test.bzl", "analysis_test", "test_suite")
load("//flutter:defs.bzl", "flutter_application")
load("//flutter:native_assets.bzl", "flutter_data_asset", "flutter_native_asset", "flutter_native_assets_manifest")
load("//flutter:providers.bzl", "FlutterDataAssetInfo", "FlutterInfo", "FlutterNativeAssetInfo")
load(":rule_coverage.bzl", "expect_action", "expect_default_outputs", "expect_no_actions")

visibility(["//tests/..."])

_MAIN = "lib/web_fixture_main.dart"

def _flutter_native_asset_analysis_test_impl(env, target):
    env.expect.that_target(target).has_provider(FlutterNativeAssetInfo)
    env.expect.that_target(target).has_provider(FlutterInfo)
    info = target[FlutterNativeAssetInfo]
    env.expect.that_str(info.asset_id).equals("package:foo/test_asset.so")
    env.expect.that_str(info.link_mode).equals("dynamic_loading_bundle")
    env.expect.that_str(info.bundle_filename).equals("libtest_asset.so")
    expect_default_outputs(env, target, ["libtest_asset.so"])
    expect_action(
        env,
        target,
        "Symlink",
        inputs = ["libasset_fixture.so"],
    )

def _flutter_native_asset_analysis_test(name):
    flutter_native_asset(
        name = name + "_subject",
        asset_id = "package:foo/test_asset.so",
        library = "//flutter/tests/dart_asset_fixture:asset_fixture_shared",
        bundle_filename = "libtest_asset.so",
        link_mode = "dynamic_loading_bundle",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _flutter_native_asset_analysis_test_impl,
        target = name + "_subject",
    )

def _flutter_data_asset_analysis_test_impl(env, target):
    env.expect.that_target(target).has_provider(FlutterDataAssetInfo)
    env.expect.that_target(target).has_provider(FlutterInfo)
    info = target[FlutterDataAssetInfo]
    env.expect.that_str(info.asset_id).equals("package:foo/blob.bin")
    env.expect.that_str(info.package).equals("foo")
    env.expect.that_str(info.name).equals("blob.bin")
    expect_default_outputs(env, target, [target.label.name.replace("_subject", "_blob.bin")])
    expect_no_actions(env, target)

def _flutter_data_asset_analysis_test(name):
    write_file(
        name = name + "_blob",
        out = name + "_blob.bin",
        content = ["blob"],
        tags = ["manual"],
    )
    flutter_data_asset(
        name = name + "_subject",
        asset_id = "package:foo/blob.bin",
        file = ":" + name + "_blob",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _flutter_data_asset_analysis_test_impl,
        target = name + "_subject",
    )

def _flutter_native_assets_manifest_analysis_test_impl(env, target):
    expect_default_outputs(env, target, [target.label.name.replace("_subject", "_app.native_assets.json")])
    expect_no_actions(env, target)

def _flutter_native_assets_manifest_analysis_test(name):
    flutter_application(
        name = name + "_app",
        package_name = "manifest_probe",
        main = _MAIN,
        tags = ["manual"],
    )
    flutter_native_assets_manifest(
        name = name + "_subject",
        application = ":" + name + "_app",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _flutter_native_assets_manifest_analysis_test_impl,
        target = name + "_subject",
    )

def native_assets_rules_test_suite(name):
    """Direct analysis tests for `flutter_native_asset`, `flutter_data_asset`, and `flutter_native_assets_manifest`.

    Args:
        name: The test suite name.
    """
    test_suite(
        name = name,
        tests = [
            _flutter_native_asset_analysis_test,
            _flutter_data_asset_analysis_test,
            _flutter_native_assets_manifest_analysis_test,
        ],
    )
