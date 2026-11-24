"""Analysis tests for the ObjC target `flutter_apple_plugin_library` emits.

The inner `objc_library` must see the plugin's declared deps, and its
`objc_copts` must not leak into the Swift compile. A non-empty `objc_copts`
on the `xtool` backend is refused by name before anything is emitted, so the
refusal message is pinned directly.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("//flutter:ios.bzl", "flutter_apple_plugin_library")
load(
    "//flutter/private:flutter_apple_plugin_library.bzl",
    "objc_copts_xtool_refusal",
    "plugin_defines_xtool_refusal",
)

visibility(["//flutter/tests/..."])

_IOS_ENGINE = "//flutter/private:apple_engine_framework_ios"

def _objc_target_surface_test_impl(ctx):
    """The ObjC target gets the plugin deps and `objc_copts`; Swift gets neither `objc_copts`."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ctx.attr.expected_objc_deps,
        ctx.attr.objc_deps,
        "the ObjC target deps are the framework import followed by the plugin deps",
    )
    asserts.equals(
        env,
        ctx.attr.expected_objc_copts,
        ctx.attr.objc_copts,
        "objc_copts follow copts on the ObjC target",
    )
    asserts.equals(
        env,
        ctx.attr.expected_swift_copts,
        ctx.attr.swift_copts,
        "the Swift copts stay exactly spec.copts plus bridging options",
    )
    asserts.false(
        env,
        "-DSAMPLE_OBJC=1" in ctx.attr.swift_copts,
        "objc_copts must never reach the Swift compile",
    )
    return unittest.end(env)

_objc_target_surface_test = unittest.make(
    _objc_target_surface_test_impl,
    attrs = {
        "expected_objc_copts": attr.string_list(mandatory = True),
        "expected_objc_deps": attr.string_list(mandatory = True),
        "expected_swift_copts": attr.string_list(mandatory = True),
        "objc_copts": attr.string_list(mandatory = True),
        "objc_deps": attr.string_list(mandatory = True),
        "swift_copts": attr.string_list(mandatory = True),
    },
)

def _objc_copts_xtool_refusal_test_impl(ctx):
    """The xtool refusal names the plugin target, `objc_copts` and the backend."""
    env = unittest.begin(ctx)
    message = objc_copts_xtool_refusal(ctx.attr.plugin_name)
    asserts.true(env, ctx.attr.plugin_name in message, "the refusal must name the plugin: %s" % message)
    asserts.true(env, "objc_copts" in message, "the refusal must name objc_copts: %s" % message)
    asserts.true(env, "xtool" in message, "the refusal must name the xtool backend: %s" % message)
    return unittest.end(env)

_objc_copts_xtool_refusal_test = unittest.make(
    _objc_copts_xtool_refusal_test_impl,
    attrs = {
        "plugin_name": attr.string(mandatory = True),
    },
)

def _plugin_defines_surface_test_impl(ctx):
    """The ObjC compile sees every define; Swift sees only value-less names."""
    env = unittest.begin(ctx)
    for flag in ctx.attr.required_objc:
        asserts.true(env, flag in ctx.attr.objc_copts, "%s missing from ObjC: %s" % (flag, ctx.attr.objc_copts))
    for flag in ctx.attr.required_swift:
        asserts.true(env, flag in ctx.attr.swift_copts, "%s missing from Swift: %s" % (flag, ctx.attr.swift_copts))
    for flag in ctx.attr.forbidden_swift:
        asserts.false(env, flag in ctx.attr.swift_copts, "%s reached Swift: %s" % (flag, ctx.attr.swift_copts))
    return unittest.end(env)

_plugin_defines_surface_test = unittest.make(
    _plugin_defines_surface_test_impl,
    attrs = {
        "forbidden_swift": attr.string_list(default = []),
        "objc_copts": attr.string_list(mandatory = True),
        "required_objc": attr.string_list(default = []),
        "required_swift": attr.string_list(default = []),
        "swift_copts": attr.string_list(mandatory = True),
    },
)

def _plugin_defines_xtool_refusal_test_impl(ctx):
    """The xtool refusal names the target, `ios_plugin_defines` and the backend."""
    env = unittest.begin(ctx)
    message = plugin_defines_xtool_refusal(ctx.attr.plugin_name)
    asserts.true(env, ctx.attr.plugin_name in message, "the refusal must name the plugin: %s" % message)
    asserts.true(env, "ios_plugin_defines" in message, "the refusal must name ios_plugin_defines: %s" % message)
    asserts.true(env, "xtool" in message, "the refusal must name the xtool backend: %s" % message)
    return unittest.end(env)

_plugin_defines_xtool_refusal_test = unittest.make(
    _plugin_defines_xtool_refusal_test_impl,
    attrs = {
        "plugin_name": attr.string(mandatory = True),
    },
)

def apple_objc_deps_test_suite(name):
    """Declares the ObjC dep/copts fixtures and the tests over them.

    Args:
        name: Prefix for every target declared here.
    """
    write_file(
        name = name + "_sample_m",
        out = name + "_Sample.m",
        content = [
            "#import \"%s_Sample.h\"" % name,
            "",
            "int sample_objc(void) { return 1; }",
        ],
        tags = ["manual"],
    )
    write_file(
        name = name + "_sample_h",
        out = name + "_Sample.h",
        content = [
            "#pragma once",
            "",
            "int sample_objc(void);",
        ],
        tags = ["manual"],
    )
    cc_library(
        name = name + "_sample_headers",
        hdrs = [name + "_Sample.h"],
        tags = ["manual"],
    )

    # One ObjC source and a declared dep: the inner target takes the framework
    # import first, then the dep, and appends objc_copts after copts.
    objc_plugin = name + "_objc_copts_plugin"
    flutter_apple_plugin_library(
        name = objc_plugin,
        srcs = [name + "_Sample.m"],
        module_name = "apple_objc_deps",
        platform = "ios",
        deps = [":" + name + "_sample_headers"],
        copts = ["-DSAMPLE_SWIFT=1"],
        objc_copts = ["-DSAMPLE_OBJC=1"],
        tags = ["manual"],
    )
    after = native.existing_rules()
    objc_rule = after["_" + objc_plugin + "__objc"]
    swift_rule = after[objc_plugin]
    _objc_target_surface_test(
        name = name + "_objc_copts_surface",
        objc_deps = [str(d) for d in objc_rule["deps"]],
        expected_objc_deps = [
            _IOS_ENGINE,
            ":" + name + "_sample_headers",
        ],
        objc_copts = [str(c) for c in objc_rule["copts"]],
        expected_objc_copts = ["-DSAMPLE_SWIFT=1", "-DSAMPLE_OBJC=1"],
        swift_copts = [str(c) for c in swift_rule["copts"]],
        expected_swift_copts = ["-DSAMPLE_SWIFT=1"],
    )

    # The same dep without objc_copts: the Swift copts are exactly base's, and
    # copts still reaches both compiles.
    plain_plugin = name + "_plain_plugin"
    flutter_apple_plugin_library(
        name = plain_plugin,
        srcs = [name + "_Sample.m"],
        module_name = "apple_objc_deps_plain",
        platform = "ios",
        deps = [":" + name + "_sample_headers"],
        copts = ["-DSAMPLE_SWIFT=1"],
        tags = ["manual"],
    )
    after = native.existing_rules()
    plain_objc_rule = after["_" + plain_plugin + "__objc"]
    plain_swift_rule = after[plain_plugin]
    _objc_target_surface_test(
        name = name + "_plain_surface",
        objc_deps = [str(d) for d in plain_objc_rule["deps"]],
        expected_objc_deps = [
            _IOS_ENGINE,
            ":" + name + "_sample_headers",
        ],
        objc_copts = [str(c) for c in plain_objc_rule["copts"]],
        expected_objc_copts = ["-DSAMPLE_SWIFT=1"],
        swift_copts = [str(c) for c in plain_swift_rule["copts"]],
        expected_swift_copts = ["-DSAMPLE_SWIFT=1"],
    )

    # A pure-ObjC plugin: every define reaches the ObjC compile, while only
    # the value-less name reaches Swift (a Swift condition carries no value).
    defines_plugin = name + "_plugin_defines_objc_plugin"
    flutter_apple_plugin_library(
        name = defines_plugin,
        srcs = [name + "_Sample.m"],
        module_name = "apple_objc_defines",
        platform = "ios",
        copts = ["-DSAMPLE_SWIFT=1"],
        plugin_defines = ["PERMISSION_CAMERA=1", "PERMISSION_MICROPHONE"],
        tags = ["manual"],
    )
    after = native.existing_rules()
    _plugin_defines_surface_test(
        name = name + "_plugin_defines_objc_surface",
        objc_copts = [str(c) for c in after["_" + defines_plugin + "__objc"]["copts"]],
        required_objc = ["-DSAMPLE_SWIFT=1", "-DPERMISSION_CAMERA=1", "-DPERMISSION_MICROPHONE"],
        swift_copts = [str(c) for c in after[defines_plugin]["copts"]],
        required_swift = ["-DSAMPLE_SWIFT=1", "-DPERMISSION_MICROPHONE"],
        forbidden_swift = ["-DPERMISSION_CAMERA", "-DPERMISSION_CAMERA=1"],
    )

    # A mixed plugin: its ObjC half gets objc_copts and every define, its
    # Swift half only the value-less one.
    write_file(
        name = name + "_mixed_swift",
        out = name + "_Mixed.swift",
        content = [
            "public func sample_mixed() -> Int {",
            "  return 1",
            "}",
        ],
        tags = ["manual"],
    )
    mixed_plugin = name + "_plugin_defines_mixed_plugin"
    flutter_apple_plugin_library(
        name = mixed_plugin,
        srcs = [name + "_Sample.m", name + "_Mixed.swift"],
        module_name = "apple_defines_mixed",
        platform = "ios",
        copts = ["-DSAMPLE_SWIFT=1"],
        objc_copts = ["-DSAMPLE_MIXED_OBJC=1"],
        plugin_defines = ["PERMISSION_CAMERA=1", "PERMISSION_MICROPHONE"],
        tags = ["manual"],
    )
    after = native.existing_rules()
    _plugin_defines_surface_test(
        name = name + "_plugin_defines_mixed_surface",
        objc_copts = [str(c) for c in after["_" + mixed_plugin + "__objc"]["copts"]],
        required_objc = [
            "-DSAMPLE_SWIFT=1",
            "-DSAMPLE_MIXED_OBJC=1",
            "-DPERMISSION_CAMERA=1",
            "-DPERMISSION_MICROPHONE",
        ],
        swift_copts = [str(c) for c in after["_" + mixed_plugin + "__swift"]["copts"]],
        required_swift = ["-DSAMPLE_SWIFT=1", "-DPERMISSION_MICROPHONE"],
        forbidden_swift = ["-DSAMPLE_MIXED_OBJC=1", "-DPERMISSION_CAMERA", "-DPERMISSION_CAMERA=1"],
    )

    # A value-less entry reaches both compiles.
    flag_plugin = name + "_plugin_defines_flag_plugin"
    flutter_apple_plugin_library(
        name = flag_plugin,
        srcs = [name + "_Sample.m"],
        module_name = "apple_defines_flag",
        platform = "ios",
        plugin_defines = ["PLUGIN_FLAG"],
        tags = ["manual"],
    )
    after = native.existing_rules()
    _plugin_defines_surface_test(
        name = name + "_plugin_defines_flag_surface",
        objc_copts = [str(c) for c in after["_" + flag_plugin + "__objc"]["copts"]],
        required_objc = ["-DPLUGIN_FLAG"],
        swift_copts = [str(c) for c in after[flag_plugin]["copts"]],
        required_swift = ["-DPLUGIN_FLAG"],
    )

    _plugin_defines_xtool_refusal_test(
        name = name + "_plugin_defines_xtool_refusal",
        plugin_name = name + "_plugin_defines_xtool",
    )

    # An empty objc_copts on xtool is accepted: this target would fail the
    # package load otherwise.
    flutter_apple_plugin_library(
        name = name + "_xtool_empty_objc_copts",
        srcs = [name + "_Sample.m"],
        module_name = "apple_objc_deps_xtool",
        platform = "ios",
        deps = [":" + name + "_sample_headers"],
        objc_copts = [],
        backend = "xtool",
        tags = ["manual"],
    )

    _objc_copts_xtool_refusal_test(
        name = name + "_xtool_objc_copts_refusal",
        plugin_name = name + "_xtool_objc_copts",
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_objc_copts_surface",
            ":" + name + "_plain_surface",
            ":" + name + "_plugin_defines_objc_surface",
            ":" + name + "_plugin_defines_mixed_surface",
            ":" + name + "_plugin_defines_flag_surface",
            ":" + name + "_plugin_defines_xtool_refusal",
            ":" + name + "_xtool_objc_copts_refusal",
        ],
    )
