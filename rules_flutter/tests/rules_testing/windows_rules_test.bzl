"""Direct `rules_testing` analysis tests for Windows rules."""

load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_testing//lib:analysis_test.bzl", "analysis_test", "test_suite")
load("//flutter:providers.bzl", "FlutterWindowsPluginInfo")
load(
    "//flutter:windows.bzl",
    "flutter_windows_app",
    "flutter_windows_bundle",
    "flutter_windows_engine",
    "flutter_windows_plugin_library",
    "flutter_windows_registrant_gen",
    "flutter_windows_runner_lib_gen",
)
load("//flutter/tests:apple_bundling.bzl", "fake_application")
load(":rule_coverage.bzl", "expect_action", "expect_default_outputs", "expect_no_actions")

visibility(["//tests/..."])

_WINDOWS_CONFIG = {
    "//command_line_option:compilation_mode": "dbg",
    "//command_line_option:platforms": str(Label("//flutter/platforms:windows_x64")),
}

def _windows_engine_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    env.expect.that_target(target).has_provider(CcInfo)
    expect_default_outputs(env, target, ["flutter_windows.dll"])

def _windows_engine_test(name):
    flutter_windows_engine(
        name = name + "_subject",
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:windows"],
    )
    analysis_test(
        name = name,
        impl = _windows_engine_test_impl,
        target = name + "_subject",
        config_settings = _WINDOWS_CONFIG,
        attr_values = {"target_compatible_with": ["@platforms//os:windows"]},
    )

def _windows_plugin_library_test_impl(env, target):
    env.expect.that_target(target).has_provider(FlutterWindowsPluginInfo)
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_no_actions(env, target)

def _windows_plugin_library_test(name):
    write_file(
        name = name + "_plugin_cpp",
        out = name + "_plugin.cpp",
        content = ["// dummy"],
        tags = ["manual"],
    )
    write_file(
        name = name + "_plugin_h",
        out = name + "_plugin.h",
        content = ["// dummy"],
        tags = ["manual"],
    )
    flutter_windows_plugin_library(
        name = name + "_subject",
        srcs = [":" + name + "_plugin_cpp"],
        hdrs = [":" + name + "_plugin_h"],
        includes = ["include"],
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _windows_plugin_library_test_impl,
        target = name + "_subject",
    )

def _windows_runner_lib_gen_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)

def _windows_runner_lib_gen_test(name):
    fake_application(
        name = name + "_app",
        debug = False,
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:windows"],
    )
    flutter_windows_engine(
        name = name + "_engine",
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:windows"],
    )
    flutter_windows_registrant_gen(
        name = name + "_registrant",
        application = name + "_app",
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:windows"],
    )
    flutter_windows_runner_lib_gen(
        name = name + "_subject",
        engine = name + "_engine",
        registrant = name + "_registrant",
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:windows"],
    )
    analysis_test(
        name = name,
        impl = _windows_runner_lib_gen_test_impl,
        target = name + "_subject",
        config_settings = _WINDOWS_CONFIG,
        attr_values = {"target_compatible_with": ["@platforms//os:windows"]},
    )

def _windows_registrant_gen_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_default_outputs(env, target, [
        target.label.name + "_native_plugin_registrant.cc",
        target.label.name + "_native_plugin_registrant.h",
    ])
    expect_action(env, target, "FileWrite")

def _windows_registrant_gen_test(name):
    fake_application(
        name = name + "_app",
        debug = False,
        tags = ["manual"],
    )
    flutter_windows_registrant_gen(
        name = name + "_subject",
        application = name + "_app",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _windows_registrant_gen_test_impl,
        target = name + "_subject",
    )

def _windows_bundle_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_action(
        env,
        target,
        "FlutterWindowsBundle",
        args = ["--config"],
    )

def _windows_bundle_test(name):
    fake_application(
        name = name + "_app",
        debug = False,
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:windows"],
    )
    flutter_windows_engine(
        name = name + "_engine",
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:windows"],
    )
    flutter_windows_registrant_gen(
        name = name + "_registrant",
        application = name + "_app",
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:windows"],
    )
    flutter_windows_runner_lib_gen(
        name = name + "_runner",
        engine = name + "_engine",
        registrant = name + "_registrant",
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:windows"],
    )
    flutter_windows_bundle(
        name = name + "_subject",
        application = name + "_app",
        runner = name + "_runner",
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:windows"],
    )
    analysis_test(
        name = name,
        impl = _windows_bundle_test_impl,
        target = name + "_subject",
        config_settings = _WINDOWS_CONFIG,
        attr_values = {"target_compatible_with": ["@platforms//os:windows"]},
    )

def _windows_app_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_action(
        env,
        target,
        "FlutterWindowsBundle",
        args = ["--config"],
    )

def _windows_app_test(name):
    fake_application(
        name = name + "_app",
        debug = False,
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:windows"],
    )
    flutter_windows_app(
        name = name + "_subject",
        application = name + "_app",
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:windows"],
    )
    analysis_test(
        name = name,
        impl = _windows_app_test_impl,
        target = name + "_subject",
        config_settings = _WINDOWS_CONFIG,
        attr_values = {"target_compatible_with": ["@platforms//os:windows"]},
    )

def windows_rules_test_suite(name):
    """Direct analysis tests for Windows rules.

    Args:
        name: The test suite name.
    """
    test_suite(
        name = name,
        tests = [
            _windows_engine_test,
            _windows_plugin_library_test,
            _windows_runner_lib_gen_test,
            _windows_registrant_gen_test,
            _windows_bundle_test,
            _windows_app_test,
        ],
    )
