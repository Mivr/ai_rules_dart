"""Direct `rules_testing` analysis tests for Linux rules."""

load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_testing//lib:analysis_test.bzl", "analysis_test", "test_suite")
load(
    "//flutter:linux.bzl",
    "flutter_linux_app",
    "flutter_linux_bundle",
    "flutter_linux_engine",
    "flutter_linux_plugin_library",
    "flutter_linux_registrant_gen",
    "flutter_linux_runner_lib_gen",
)
load("//flutter:providers.bzl", "FlutterLinuxPluginInfo")
load("//flutter/tests:apple_bundling.bzl", "fake_application")
load(":rule_coverage.bzl", "expect_action", "expect_default_outputs", "expect_no_actions")

visibility(["//tests/..."])

def _linux_engine_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    env.expect.that_target(target).has_provider(CcInfo)
    expect_default_outputs(env, target, ["libflutter_linux_gtk.so"])

def _linux_engine_test(name):
    flutter_linux_engine(
        name = name + "_subject",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _linux_engine_test_impl,
        target = name + "_subject",
    )

def _linux_plugin_library_test_impl(env, target):
    env.expect.that_target(target).has_provider(FlutterLinuxPluginInfo)
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_no_actions(env, target)

def _linux_plugin_library_test(name):
    write_file(
        name = name + "_plugin_cc",
        out = name + "_plugin.cc",
        content = ["// dummy"],
        tags = ["manual"],
    )
    write_file(
        name = name + "_plugin_h",
        out = name + "_plugin.h",
        content = ["// dummy"],
        tags = ["manual"],
    )
    flutter_linux_plugin_library(
        name = name + "_subject",
        srcs = [":" + name + "_plugin_cc"],
        hdrs = [":" + name + "_plugin_h"],
        includes = ["include"],
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _linux_plugin_library_test_impl,
        target = name + "_subject",
    )

def _linux_runner_lib_gen_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)

def _linux_runner_lib_gen_test(name):
    fake_application(
        name = name + "_app",
        debug = False,
        tags = ["manual"],
    )
    flutter_linux_engine(
        name = name + "_engine",
        tags = ["manual"],
    )
    flutter_linux_registrant_gen(
        name = name + "_registrant",
        application = name + "_app",
        tags = ["manual"],
    )
    flutter_linux_runner_lib_gen(
        name = name + "_subject",
        engine = name + "_engine",
        registrant = name + "_registrant",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _linux_runner_lib_gen_test_impl,
        target = name + "_subject",
    )

def _linux_registrant_gen_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_default_outputs(env, target, [
        target.label.name + "_native_plugin_registrant.cc",
        target.label.name + "_native_plugin_registrant.h",
    ])
    expect_action(env, target, "FileWrite")

def _linux_registrant_gen_test(name):
    fake_application(
        name = name + "_app",
        debug = False,
        tags = ["manual"],
    )
    flutter_linux_registrant_gen(
        name = name + "_subject",
        application = name + "_app",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _linux_registrant_gen_test_impl,
        target = name + "_subject",
    )

def _linux_bundle_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_action(
        env,
        target,
        "FlutterLinuxBundle",
        args = ["--config"],
    )

def _linux_bundle_test(name):
    fake_application(
        name = name + "_app",
        debug = False,
        tags = ["manual"],
    )
    flutter_linux_engine(
        name = name + "_engine",
        tags = ["manual"],
    )
    flutter_linux_registrant_gen(
        name = name + "_registrant",
        application = name + "_app",
        tags = ["manual"],
    )
    flutter_linux_runner_lib_gen(
        name = name + "_runner",
        engine = name + "_engine",
        registrant = name + "_registrant",
        tags = ["manual"],
    )
    flutter_linux_bundle(
        name = name + "_subject",
        application = name + "_app",
        runner = name + "_runner",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _linux_bundle_test_impl,
        target = name + "_subject",
    )

def _linux_app_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)
    expect_action(
        env,
        target,
        "FlutterLinuxBundle",
        args = ["--config"],
    )

def _linux_app_test(name):
    fake_application(
        name = name + "_app",
        debug = False,
        tags = ["manual"],
    )
    flutter_linux_app(
        name = name + "_subject",
        application = name + "_app",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _linux_app_test_impl,
        target = name + "_subject",
    )

def linux_rules_test_suite(name):
    """Direct analysis tests for Linux rules.

    Args:
        name: The test suite name.
    """
    test_suite(
        name = name,
        tests = [
            _linux_engine_test,
            _linux_plugin_library_test,
            _linux_runner_lib_gen_test,
            _linux_registrant_gen_test,
            _linux_bundle_test,
            _linux_app_test,
        ],
    )
