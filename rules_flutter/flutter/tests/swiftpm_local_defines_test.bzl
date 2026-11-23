"""Analysis tests for plugin defines on plugin-local ObjC and Swift targets.

The defines must reach the `.m` and `.mm` compile of an ObjC-only local
target and the Swift compile of a local Swift target, while staying out of
`CcInfo.compilation_context.defines` so no dependent inherits them.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load(
    "//flutter/private:flutter_apple_plugin_library.bzl",
    "flutter_apple_plugin_library",
    "flutter_apple_plugin_objc_library",
    "flutter_apple_plugin_objc_settings",
)

visibility(["//flutter/tests/..."])

_STRING_DEFINES = [
    'LIBRARY_NAME="my-plugin"',
    'ESCAPED_NAME=\\"from-podspec\\"',
    'GREETING="hello world"',
    "PLAIN_NUM=1",
]

_STRING_DEFINE_ARGV = [
    '-DLIBRARY_NAME="my-plugin"',
    '-DESCAPED_NAME="from-podspec"',
    '-DGREETING="hello world"',
    "-DPLAIN_NUM=1",
]

def _apple_test_config_settings(platform):
    """Config settings that analyze an Apple target off macOS."""
    return {
        "//command_line_option:extra_execution_platforms": [str(Label("//flutter/platforms:macos_arm64"))],
        "//command_line_option:platforms": str(Label("//flutter/platforms:%s_arm64" % platform)),
        "//command_line_option:xcode_version_config": str(Label("//flutter/tests:ios_test_fake_xcode_config")),
        str(Label("//flutter:profile")): False,
    }

def _action_argv(env, mnemonic):
    """The concatenated `argv` of every action with one mnemonic."""
    argv = []
    for action in analysistest.target_actions(env):
        if action.mnemonic != mnemonic:
            continue
        if action.argv != None:
            argv.extend(action.argv)
    return argv

def _objc_define_argv_test_impl(ctx):
    """Local cSettings copts and plugin defines reach the `.m` compile."""
    env = analysistest.begin(ctx)
    argv = _action_argv(env, "ObjcCompile")
    asserts.true(env, bool(argv), "Expected an ObjcCompile action carrying argv")
    for flag in ["-DLOCAL_C_DEF=7", "-DPERMISSION_CAMERA=1", "-DPLUGIN_FLAG"] + _STRING_DEFINE_ARGV:
        asserts.true(env, flag in argv, "%s missing from ObjcCompile argv: %s" % (flag, argv))
    tut = analysistest.target_under_test(env)
    asserts.true(env, CcInfo in tut, "Expected CcInfo on %s" % tut.label)
    if CcInfo in tut:
        paths = [h.path for h in tut[CcInfo].compilation_context.headers.to_list()]
        asserts.true(
            env,
            any([path.endswith("Flutter.framework/Modules/module.modulemap") for path in paths]),
            "Flutter's module map missing from CcInfo headers: %s" % paths,
        )
        defines = tut[CcInfo].compilation_context.defines.to_list()
        string_names = [d.partition("=")[0] for d in _STRING_DEFINES]
        for name in ["LOCAL_C_DEF", "PERMISSION_CAMERA", "PLUGIN_FLAG"] + string_names:
            asserts.false(
                env,
                any([name in define for define in defines]),
                "%s leaked into CcInfo.compilation_context.defines: %s" % (name, defines),
            )
    return analysistest.end(env)

def _swift_define_argv_test_impl(ctx):
    """A `select`-gated copt and the value-less plugin define reach Swift."""
    env = analysistest.begin(ctx)
    argv = _action_argv(env, "SwiftCompile")
    asserts.true(env, bool(argv), "Expected a SwiftCompile action carrying argv")
    for flag in ["-DPLAT_SWIFT", "-DPLUGIN_FLAG"]:
        asserts.true(env, flag in argv, "%s missing from SwiftCompile argv: %s" % (flag, argv))
    for flag in ["-DPERMISSION_CAMERA", "-DPERMISSION_CAMERA=1"]:
        asserts.false(env, flag in argv, "%s reached the Swift compile: %s" % (flag, argv))
    return analysistest.end(env)

_ios_objc_define_argv_test = analysistest.make(
    _objc_define_argv_test_impl,
    config_settings = _apple_test_config_settings("ios"),
)

_ios_swift_define_argv_test = analysistest.make(
    _swift_define_argv_test_impl,
    config_settings = _apple_test_config_settings("ios"),
)

def swiftpm_local_defines_test_suite(name):
    """Declares the local define fixtures and the analysis tests over them.

    Args:
        name: Prefix for every target declared here.
    """
    objc_src = name + "_local.m"
    swift_src = name + "_local.swift"
    write_file(
        name = name + "_objc_src",
        out = objc_src,
        content = [
            "int local_value(void) { return 1; }",
        ],
    )
    write_file(
        name = name + "_swift_src",
        out = swift_src,
        content = [
            "public func localValue() -> Int {",
            "  return 1",
            "}",
        ],
    )

    objc_target = name + "_objc"
    flutter_apple_plugin_objc_library(
        name = objc_target,
        srcs = [":" + objc_src],
        module_name = name + "_objc",
        platform = "ios",
        settings = flutter_apple_plugin_objc_settings(copts = ["-DLOCAL_C_DEF=7"]),
        plugin_defines = ["PERMISSION_CAMERA=1", "PLUGIN_FLAG"] + _STRING_DEFINES,
    )
    _ios_objc_define_argv_test(
        name = name + "_objc_define_argv",
        size = "small",
        target_under_test = ":_" + objc_target + "__objc",
    )

    # The pure-ObjC and the mixed ObjC+Swift plugin libraries emit the same
    # `_<name>__objc` compile; both must keep the string-literal quotes.
    string_tests = []
    for kind, kind_srcs in {
        "plain": [":" + objc_src],
        "mixed": [":" + objc_src, ":" + swift_src],
    }.items():
        lib = "%s_%s_lib" % (name, kind)
        flutter_apple_plugin_library(
            name = lib,
            srcs = kind_srcs,
            module_name = lib,
            platform = "ios",
            copts = ["-DLOCAL_C_DEF=7"],
            plugin_defines = ["PERMISSION_CAMERA=1", "PLUGIN_FLAG"] + _STRING_DEFINES,
            tags = ["manual"],
        )
        _ios_objc_define_argv_test(
            name = "%s_%s_string_define_argv" % (name, kind),
            size = "small",
            target_under_test = ":_" + lib + "__objc",
        )
        string_tests.append(":%s_%s_string_define_argv" % (name, kind))

    swift_target = name + "_swift"
    flutter_apple_plugin_library(
        name = swift_target,
        srcs = [":" + swift_src],
        module_name = name + "_swift",
        platform = "ios",
        copts = select({
            "@platforms//os:ios": ["-DPLAT_SWIFT"],
            "//conditions:default": [],
        }),
        plugin_defines = ["PERMISSION_CAMERA=1", "PLUGIN_FLAG"],
        tags = ["manual"],
    )
    _ios_swift_define_argv_test(
        name = name + "_swift_define_argv",
        size = "small",
        target_under_test = ":" + swift_target,
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_objc_define_argv",
            ":" + name + "_swift_define_argv",
        ] + string_tests,
    )
