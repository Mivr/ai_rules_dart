"""Direct `rules_testing` analysis tests for Android rules."""

load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("@rules_testing//lib:analysis_test.bzl", "analysis_test", "test_suite")
load(
    "//flutter:android.bzl",
    "flutter_android_app",
    "flutter_android_engine",
    "flutter_android_manifest_gen",
    "flutter_android_permissions_manifest",
    "flutter_android_plugin_library",
    "flutter_android_runner_lib_gen",
)
load("//flutter/tests:apple_bundling.bzl", "fake_application")
load(":rule_coverage.bzl", "expect_action", "expect_default_outputs", "expect_no_actions")

visibility(["//tests/..."])

def _android_manifest_gen_test_impl(env, target):
    expect_default_outputs(env, target, ["AndroidManifest.xml"])
    expect_action(
        env,
        target,
        "TemplateExpand",
        inputs = ["AndroidManifest.xml"],
    )

def _android_manifest_gen_test(name):
    flutter_android_manifest_gen(
        name = name + "_subject",
        package_name = "com.example.test",
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _android_manifest_gen_test_impl,
        target = name + "_subject",
    )

def _android_permissions_manifest_test_impl(env, target):
    expect_default_outputs(env, target, ["AndroidManifest.xml"])
    expect_action(
        env,
        target,
        "FileWrite",
    )

def _android_permissions_manifest_test(name):
    flutter_android_permissions_manifest(
        name = name + "_subject",
        permissions = ["android.permission.INTERNET"],
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _android_permissions_manifest_test_impl,
        target = name + "_subject",
    )

def _android_engine_test_impl(env, target):
    env.expect.that_target(target).has_provider(JavaInfo)
    expect_no_actions(env, target)

def _android_engine_test(name):
    flutter_android_engine(
        name = name + "_subject",
        neverlink = True,
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:android"],
    )
    analysis_test(
        name = name,
        impl = _android_engine_test_impl,
        target = name + "_subject",
        attr_values = {"target_compatible_with": ["@platforms//os:android"]},
    )

def _android_plugin_library_test_impl(env, target):
    env.expect.that_target(target).has_provider(JavaInfo)

def _android_plugin_library_test(name):
    write_file(
        name = name + "_plugin_kt",
        out = name + "_plugin/MyPlugin.kt",
        content = ["package com.example.plugin"],
        tags = ["manual"],
    )
    flutter_android_plugin_library(
        name = name + "_subject",
        srcs = [":" + name + "_plugin_kt"],
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:android"],
    )
    analysis_test(
        name = name,
        impl = _android_plugin_library_test_impl,
        target = name + "_subject",
        attr_values = {"target_compatible_with": ["@platforms//os:android"]},
    )

def _android_runner_lib_gen_test_impl(env, target):
    env.expect.that_target(target).has_provider(JavaInfo)

def _android_runner_lib_gen_test(name):
    flutter_android_engine(
        name = name + "_engine",
        neverlink = True,
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:android"],
    )
    flutter_android_runner_lib_gen(
        name = name + "_subject",
        package_name = "com.example.test",
        engine = ":" + name + "_engine",
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:android"],
    )
    analysis_test(
        name = name,
        impl = _android_runner_lib_gen_test_impl,
        target = name + "_subject",
        attr_values = {"target_compatible_with": ["@platforms//os:android"]},
    )

def _android_app_test_impl(env, target):
    env.expect.that_target(target).has_provider(DefaultInfo)

def _android_app_test(name):
    fake_application(
        name = name + "_app",
        debug = False,
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:android"],
    )
    flutter_android_app(
        name = name + "_subject",
        application = ":" + name + "_app",
        package_name = "com.example.test",
        tags = ["manual"],
        target_compatible_with = ["@platforms//os:android"],
    )
    analysis_test(
        name = name,
        impl = _android_app_test_impl,
        target = name + "_subject",
        attr_values = {"target_compatible_with": ["@platforms//os:android"]},
    )

def android_rules_test_suite(name):
    """Direct analysis tests for Android rules.

    Args:
        name: The test suite name.
    """
    test_suite(
        name = name,
        tests = [
            _android_manifest_gen_test,
            _android_permissions_manifest_test,
            _android_engine_test,
            _android_plugin_library_test,
            _android_runner_lib_gen_test,
            _android_app_test,
        ],
    )
