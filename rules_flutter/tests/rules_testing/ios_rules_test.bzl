"""Direct `rules_testing` analysis tests for iOS rules."""

load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_testing//lib:analysis_test.bzl", "analysis_test", "test_suite")
load(
    "//flutter:ios.bzl",
    "flutter_apple_plugin_library",
    "flutter_apple_plugins_aggregator",
    "flutter_darwin_xcframework_import",
    "flutter_ios_engine",
    "flutter_ios_info_plist_gen",
    "flutter_ios_native_frameworks_gen",
    "flutter_ios_privacy_manifests_gen",
    "flutter_ios_registrant_gen",
    "flutter_ios_runner_lib_gen",
    "flutter_ios_simulator_build",
    "flutter_ios_simulator_build_test",
    "flutter_xtool_bundle_version",
    "flutter_xtool_ios_bundle",
    "ios_sim_debug_app",
)
load(
    "//flutter/tests:apple_bundling.bzl",
    "fake_application",
    "fake_macho_binary",
)
load(":rule_coverage.bzl", "expect_action", "expect_default_outputs", "expect_no_actions")

visibility(["//tests/..."])

_IOS_CONFIG = {
    "//command_line_option:compilation_mode": "dbg",
    "//command_line_option:platforms": str(Label("//flutter/platforms:ios_arm64")),
    str(Label("//flutter/settings:apple_backend")): "xtool",
}

def _apple_plugins_aggregator_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_no_actions(env, target)

def _apple_plugins_aggregator_test(name):
    fake_application(
        name = name + "_app",
        debug = True,
        tags = ["manual"],
    )
    flutter_apple_plugins_aggregator(
        name = name + "_subject",
        application = name + "_app",
        platform = "ios",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _apple_plugins_aggregator_test_impl,
        target = name + "_subject",
        config_settings = _IOS_CONFIG,
    )

def _darwin_xcframework_import_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_no_actions(env, target)

def _darwin_xcframework_import_test(name):
    fake_macho_binary(
        name = name + "_bin",
        platform = "ios",
        tags = ["manual"],
    )
    flutter_darwin_xcframework_import(
        name = name + "_subject",
        xcframework_imports = [name + "_bin"],
        framework_name = "Flutter",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _darwin_xcframework_import_test_impl,
        target = name + "_subject",
        config_settings = _IOS_CONFIG,
    )

def _ios_engine_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_no_actions(env, target)

def _ios_engine_test(name):
    flutter_ios_engine(
        name = name + "_subject",
        backend = "xtool",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _ios_engine_test_impl,
        target = name + "_subject",
        config_settings = _IOS_CONFIG,
    )

def _ios_simulator_build_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_no_actions(env, target)

def _ios_simulator_build_test(name):
    fake_macho_binary(
        name = name + "_bin",
        platform = "ios",
        tags = ["manual"],
    )
    flutter_ios_simulator_build(
        name = name + "_subject",
        targets = [name + "_bin"],
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _ios_simulator_build_test_impl,
        target = name + "_subject",
        config_settings = _IOS_CONFIG,
    )

def _ios_simulator_build_test_case_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)

def _ios_simulator_build_test_case(name):
    fake_macho_binary(
        name = name + "_bin",
        platform = "ios",
        tags = ["manual"],
    )
    flutter_ios_simulator_build_test(
        name = name + "_subject",
        targets = [name + "_bin"],
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _ios_simulator_build_test_case_impl,
        target = name + "_subject",
        config_settings = _IOS_CONFIG,
    )

def _ios_sim_debug_app_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_no_actions(env, target)

def _ios_sim_debug_app_test(name):
    fake_macho_binary(
        name = name + "_bin",
        platform = "ios",
        tags = ["manual"],
    )
    ios_sim_debug_app(
        name = name + "_subject",
        app = name + "_bin",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _ios_sim_debug_app_test_impl,
        target = name + "_subject",
        config_settings = _IOS_CONFIG,
    )

def _ios_info_plist_gen_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_default_outputs(env, target, ["Info.plist"])
    expect_action(env, target, "TemplateExpand")

def _ios_info_plist_gen_test(name):
    flutter_ios_info_plist_gen(
        name = name + "_subject",
        app_name = "TestApp",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _ios_info_plist_gen_test_impl,
        target = name + "_subject",
        config_settings = _IOS_CONFIG,
    )

def _xtool_bundle_version_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_default_outputs(env, target, [target.label.name + ".bundle_version"])
    expect_action(env, target, "FileWrite")

def _xtool_bundle_version_test(name):
    flutter_xtool_bundle_version(
        name = name + "_subject",
        build_version = "1.2.3",
        short_version_string = "1.2",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _xtool_bundle_version_test_impl,
        target = name + "_subject",
        config_settings = _IOS_CONFIG,
    )

def _xtool_ios_bundle_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_action(
        env,
        target,
        "FlutterXtoolIosBundle",
        args = ["bundle", "--platform", "ios_sim", "--app-name", "Runner"],
    )

def _xtool_ios_bundle_test(name):
    fake_macho_binary(
        name = name + "_bin",
        platform = "ios",
        tags = ["manual"],
    )
    flutter_xtool_ios_bundle(
        name = name + "_subject",
        app_name = "Runner",
        bundle_id = "com.example.runner",
        executable = name + "_bin",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _xtool_ios_bundle_test_impl,
        target = name + "_subject",
        config_settings = _IOS_CONFIG,
    )

def _ios_native_frameworks_gen_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_action(env, target, "FlutterIOSNativeAssetFramework")

def _ios_native_frameworks_gen_test(name):
    fake_application(
        name = name + "_app",
        debug = False,
        macho_aot = True,
        code_assets = ["libbar.dylib"],
        tags = ["manual"],
    )
    flutter_ios_native_frameworks_gen(
        name = name + "_subject",
        application = name + "_app",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _ios_native_frameworks_gen_test_impl,
        target = name + "_subject",
        config_settings = _IOS_CONFIG,
    )

def _ios_privacy_manifests_gen_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_action(env, target, "Symlink")

def _ios_privacy_manifests_gen_test(name):
    write_file(
        name = name + "_manifest",
        out = name + "_PrivacyInfo.xcprivacy",
        content = ["<plist></plist>"],
        tags = ["manual"],
    )
    fake_application(
        name = name + "_app",
        debug = False,
        apple_privacy_manifests = [":" + name + "_manifest"],
        tags = ["manual"],
    )
    flutter_ios_privacy_manifests_gen(
        name = name + "_subject",
        application = name + "_app",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _ios_privacy_manifests_gen_test_impl,
        target = name + "_subject",
        config_settings = _IOS_CONFIG,
    )

def _apple_plugin_library_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_action(env, target, "FileWrite")

def _apple_plugin_library_test(name):
    write_file(
        name = name + "_swift",
        out = name + "_Plugin.swift",
        content = ["import Foundation"],
        tags = ["manual"],
    )
    flutter_apple_plugin_library(
        name = name + "_subject",
        srcs = [":" + name + "_swift"],
        module_name = "test_plugin",
        platform = "ios",
        backend = "xtool",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _apple_plugin_library_test_impl,
        target = name + "_subject",
        config_settings = _IOS_CONFIG,
    )

def _ios_runner_lib_gen_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_action(env, target, "FileWrite")

def _ios_runner_lib_gen_test(name):
    fake_application(
        name = name + "_app",
        debug = True,
        tags = ["manual"],
    )
    flutter_ios_engine(
        name = name + "_engine",
        backend = "xtool",
        tags = ["manual"],
    )
    flutter_ios_registrant_gen(
        name = name + "_registrant",
        application = name + "_app",
        tags = ["manual"],
    )
    flutter_ios_runner_lib_gen(
        name = name + "_subject",
        engine = ":" + name + "_engine",
        registrant = ":" + name + "_registrant",
        backend = "xtool",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _ios_runner_lib_gen_test_impl,
        target = name + "_subject",
        config_settings = _IOS_CONFIG,
    )

def ios_rules_test_suite(name):
    """Direct analysis tests for iOS and Apple common rules.

    Args:
        name: The test suite name.
    """
    test_suite(
        name = name,
        tests = [
            _apple_plugins_aggregator_test,
            _darwin_xcframework_import_test,
            _ios_engine_test,
            _ios_simulator_build_test,
            _ios_simulator_build_test_case,
            _ios_sim_debug_app_test,
            _ios_info_plist_gen_test,
            _xtool_bundle_version_test,
            _xtool_ios_bundle_test,
            _ios_native_frameworks_gen_test,
            _ios_privacy_manifests_gen_test,
            _apple_plugin_library_test,
            _ios_runner_lib_gen_test,
        ],
    )
