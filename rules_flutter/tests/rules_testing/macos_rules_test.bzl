"""Direct `rules_testing` analysis tests for macOS rules."""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test", "test_suite")
load(
    "//flutter:macos.bzl",
    "flutter_macos_engine",
    "flutter_macos_info_plist_gen",
    "flutter_macos_menu_xib_gen",
    "flutter_macos_native_libs_gen",
    "flutter_macos_privacy_manifests_gen",
    "flutter_macos_registrant_gen",
    "flutter_macos_runner_lib_gen",
)
load(
    "//flutter/tests:apple_bundling.bzl",
    "fake_application",
)
load(":rule_coverage.bzl", "expect_action", "expect_default_outputs", "expect_no_actions")

visibility(["//tests/..."])

_MACOS_CONFIG = {
    "//command_line_option:compilation_mode": "dbg",
    "//command_line_option:platforms": str(Label("//flutter/platforms:macos_arm64")),
    str(Label("//flutter/settings:apple_backend")): "xtool",
}

def _macos_engine_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_no_actions(env, target)

def _macos_engine_test(name):
    flutter_macos_engine(
        name = name + "_subject",
        backend = "xtool",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _macos_engine_test_impl,
        target = name + "_subject",
        config_settings = _MACOS_CONFIG,
    )

def _macos_privacy_manifests_gen_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_no_actions(env, target)

def _macos_privacy_manifests_gen_test(name):
    fake_application(
        name = name + "_app",
        debug = False,
        tags = ["manual"],
    )
    flutter_macos_privacy_manifests_gen(
        name = name + "_subject",
        application = name + "_app",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _macos_privacy_manifests_gen_test_impl,
        target = name + "_subject",
        config_settings = _MACOS_CONFIG,
    )

def _macos_info_plist_gen_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_default_outputs(env, target, ["Info.plist"])
    expect_action(env, target, "TemplateExpand")

def _macos_info_plist_gen_test(name):
    flutter_macos_info_plist_gen(
        name = name + "_subject",
        app_name = "TestMacApp",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _macos_info_plist_gen_test_impl,
        target = name + "_subject",
        config_settings = _MACOS_CONFIG,
    )

def _macos_menu_xib_gen_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_default_outputs(env, target, ["MainMenu.xib"])
    expect_action(env, target, "TemplateExpand")

def _macos_menu_xib_gen_test(name):
    flutter_macos_menu_xib_gen(
        name = name + "_subject",
        app_name = "TestMacApp",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _macos_menu_xib_gen_test_impl,
        target = name + "_subject",
        config_settings = _MACOS_CONFIG,
    )

def _macos_native_libs_gen_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_action(
        env,
        target,
        "FlutterMacOSNativeLibs",
        args = ["copy-files", "--platform", "macos"],
    )

def _macos_native_libs_gen_test(name):
    fake_application(
        name = name + "_app",
        debug = False,
        native_libs = ["libnative.dylib"],
        tags = ["manual"],
    )
    flutter_macos_native_libs_gen(
        name = name + "_subject",
        application = name + "_app",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _macos_native_libs_gen_test_impl,
        target = name + "_subject",
        config_settings = _MACOS_CONFIG,
    )

def _macos_registrant_gen_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_default_outputs(env, target, [target.label.name + "_native_plugin_registrant.swift"])
    expect_action(env, target, "FileWrite")

def _macos_registrant_gen_test(name):
    fake_application(
        name = name + "_app",
        debug = False,
        plugin_name = "test_plugin",
        plugin_class = "TestPlugin",
        tags = ["manual"],
    )
    flutter_macos_registrant_gen(
        name = name + "_subject",
        application = name + "_app",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _macos_registrant_gen_test_impl,
        target = name + "_subject",
        config_settings = _MACOS_CONFIG,
    )

def _macos_runner_lib_gen_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_action(env, target, "FileWrite")

def _macos_runner_lib_gen_test(name):
    fake_application(
        name = name + "_app",
        debug = True,
        tags = ["manual"],
    )
    flutter_macos_engine(
        name = name + "_engine",
        backend = "xtool",
        tags = ["manual"],
    )
    flutter_macos_registrant_gen(
        name = name + "_registrant",
        application = name + "_app",
        tags = ["manual"],
    )
    flutter_macos_runner_lib_gen(
        name = name + "_subject",
        engine = ":" + name + "_engine",
        registrant = ":" + name + "_registrant",
        backend = "xtool",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _macos_runner_lib_gen_test_impl,
        target = name + "_subject",
        config_settings = _MACOS_CONFIG,
    )

def macos_rules_test_suite(name):
    """Direct analysis tests for macOS rules.

    Args:
        name: The test suite name.
    """
    test_suite(
        name = name,
        tests = [
            _macos_engine_test,
            _macos_privacy_manifests_gen_test,
            _macos_info_plist_gen_test,
            _macos_menu_xib_gen_test,
            _macos_native_libs_gen_test,
            _macos_registrant_gen_test,
            _macos_runner_lib_gen_test,
        ],
    )
