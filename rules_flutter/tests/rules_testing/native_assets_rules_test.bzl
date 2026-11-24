"""Direct `rules_testing` analysis tests for `//flutter:native_assets.bzl` rules.

Tests `flutter_data_asset`.
"""

load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_testing//lib:analysis_test.bzl", "analysis_test", "test_suite")
load("//flutter:native_assets.bzl", "flutter_data_asset")
load("//flutter:providers.bzl", "FlutterDataAssetInfo", "FlutterInfo")
load(":rule_coverage.bzl", "expect_default_outputs", "expect_no_actions")

visibility(["//tests/..."])

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

def native_assets_rules_test_suite(name):
    """Direct analysis tests for `flutter_data_asset`.

    Args:
        name: The test suite name.
    """
    test_suite(
        name = name,
        tests = [
            _flutter_data_asset_analysis_test,
        ],
    )
