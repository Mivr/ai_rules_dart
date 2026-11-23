"""Analysis tests for `flutter_android_aar`.

The AAR is made by one archive action over declared inputs: the module's AOT
library for `android_abi`, the `flutter_assets` tree and the generated
manifest. The engine the host app needs rides in the `engine_maven` output
group, taken from the pinned `flutter_android_engine_<abi>` repository; the
rule declares no download of its own. Release and profile are packaged, debug
fails analysis.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:flutter_android_application.bzl", "flutter_android_aar")
load("//flutter/private:flutter_application.bzl", "flutter_application")

visibility(["//flutter/tests/..."])

_RELEASE = {"//command_line_option:compilation_mode": "opt"}
_PROFILE = {
    "//command_line_option:compilation_mode": "opt",
    str(Label("//flutter:profile")): True,
}
_DEBUG = {"//command_line_option:compilation_mode": "dbg"}

def _archive_action(env):
    """The one `FlutterAndroidAar` action of the target under test."""
    actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterAndroidAar"]
    asserts.equals(env, 1, len(actions), "expected exactly one FlutterAndroidAar action")
    return actions[0] if actions else None

def _archive_test_impl(ctx):
    """The archive action reads the AOT library, assets and manifest, and declares the .aar."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    action = _archive_action(env)
    if action == None:
        return analysistest.end(env)
    inputs = [f.path for f in action.inputs.to_list()]
    aot_inputs = [p for p in inputs if p.endswith("_aar_application.so")]
    asserts.equals(env, 1, len(aot_inputs), "expected one AOT library in %s" % inputs)
    asserts.true(env, [p for p in inputs if p.endswith("flutter_assets")], "assets tree in %s" % inputs)
    asserts.true(env, [p for p in inputs if p.endswith("_aar/AndroidManifest.xml")], "manifest in %s" % inputs)
    asserts.false(
        env,
        [p for p in inputs if p.endswith("_aar_application.dill")],
        "unexpected application kernel dill in %s" % inputs,
    )

    # Everything is a declared input: the only executable is the Dart tool, with no host tool.
    asserts.true(env, [p for p in inputs if p.endswith("tools/android_bundle")], "bundle tool in %s" % inputs)
    for arg in (action.argv or []):
        asserts.false(env, arg.startswith("/bin/") or arg.startswith("/usr/bin/"), "host tool in argv: %s" % arg)
    for path in inputs:
        asserts.false(env, path.startswith("/bin/") or path.startswith("/usr/bin/"), "host tool in inputs: %s" % path)
    asserts.equals(env, ["aar"], [a for a in action.argv if a == "aar"])
    lib_flags = [i for i, a in enumerate(action.argv) if a == "--lib"]
    asserts.equals(env, 1, len(lib_flags), "expected one --lib flag in %s" % action.argv)
    if lib_flags:
        idx = lib_flags[0]
        asserts.equals(
            env,
            [ctx.attr.expected_abi, ctx.attr.expected_machine, aot_inputs[0]],
            action.argv[idx + 1:idx + 4],
        )
    outputs = [f.basename for f in action.outputs.to_list()]
    asserts.equals(env, [ctx.attr.aar_name], outputs)
    asserts.equals(env, [ctx.attr.aar_name], [f.basename for f in target[DefaultInfo].files.to_list()])
    return analysistest.end(env)

def _engine_test_impl(ctx):
    """`engine_maven` holds the pinned engine jar and the rule downloads nothing."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    jars = target[OutputGroupInfo].engine_maven.to_list()
    asserts.equals(env, ctx.attr.engines, sorted([j.owner.repo_name.split("+")[-1] for j in jars]))
    for jar in jars:
        asserts.equals(env, "flutter.jar", jar.basename)
        asserts.true(env, jar.path.startswith("external/"), "engine jar %s is not external" % jar.path)

    # No download of its own: the only actions are the archive and the manifest write.
    mnemonics = sorted({a.mnemonic: True for a in analysistest.target_actions(env)}.keys())
    asserts.equals(env, ["FileWrite", "FlutterAndroidAar"], mnemonics)
    return analysistest.end(env)

def _error_test_impl(ctx):
    """Analysis fails with the expected message."""
    env = analysistest.begin(ctx)
    for msg in ctx.attr.messages:
        asserts.expect_failure(env, msg)
    return analysistest.end(env)

_attrs = {
    "aar_name": attr.string(),
    "engines": attr.string_list(),
    "expected_abi": attr.string(default = "arm64-v8a"),
    "expected_machine": attr.string(default = "183"),
}
_archive_test = analysistest.make(_archive_test_impl, attrs = _attrs, config_settings = _RELEASE)
_profile_archive_test = analysistest.make(_archive_test_impl, attrs = _attrs, config_settings = _PROFILE)
_engine_test = analysistest.make(_engine_test_impl, attrs = _attrs, config_settings = _RELEASE)
_profile_engine_test = analysistest.make(_engine_test_impl, attrs = _attrs, config_settings = _PROFILE)
_error_test = analysistest.make(
    _error_test_impl,
    attrs = {"messages": attr.string_list()},
    expect_failure = True,
    config_settings = _RELEASE,
)
_debug_error_test = analysistest.make(
    _error_test_impl,
    attrs = {"messages": attr.string_list()},
    expect_failure = True,
    config_settings = _DEBUG,
)

def _release_transition_impl(_settings, _attr):
    """Forces release (`-c opt`) mode."""
    return {"//command_line_option:compilation_mode": "opt"}

_release_transition = transition(
    implementation = _release_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:compilation_mode"],
)

def _release_aar_impl(ctx):
    """Forwards the files of the AAR built in release mode."""
    return [DefaultInfo(files = depset(ctx.attr.aar[0][DefaultInfo].files.to_list()))]

_release_aar = rule(
    implementation = _release_aar_impl,
    attrs = {
        "aar": attr.label(doc = "The AAR to build in release mode.", cfg = _release_transition),
        "_allowlist_function_transition": attr.label(
            doc = "Function-transition allowlist the transition requires.",
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Builds an AAR with `-c opt` whatever the invoking mode, so a test can inspect the archive.",
)

def _declare_aar_fixtures():
    """Declares the shared `flutter_application` and `flutter_android_aar` fixtures."""
    flutter_application(
        name = "_aar_application",
        package_name = "aar_fixture",
        main = "lib/language_version_main.dart",
        tags = ["manual"],
    )
    flutter_android_aar(
        name = "_aar_default",
        application = ":_aar_application",
        package_name = "com.example.module",
        tags = ["manual"],
    )
    flutter_android_aar(
        name = "_aar_arm64",
        application = ":_aar_application",
        package_name = "com.example.module",
        android_abi = "arm64-v8a",
        tags = ["manual"],
    )
    flutter_android_aar(
        name = "_aar_x64",
        application = ":_aar_application",
        package_name = "com.example.module",
        android_abi = "x86_64",
        tags = ["manual"],
    )
    flutter_android_aar(
        name = "_aar_unknown",
        application = ":_aar_application",
        package_name = "com.example.module",
        android_abi = "armeabi-v7a",
        tags = ["manual"],
    )
    _release_aar(name = "release_aar", aar = ":_aar_default", tags = ["manual"])
    _release_aar(name = "release_aar_x64", aar = ":_aar_x64", tags = ["manual"])

def _declare_archive_tests(name):
    """Declares the archive action analysis tests for `name`."""
    _archive_test(
        name = name + "_archive",
        target_under_test = ":_aar_default",
        aar_name = "_aar_default.aar",
        expected_abi = "arm64-v8a",
        expected_machine = "183",
        size = "small",
    )
    _archive_test(
        name = name + "_archive_arm64",
        target_under_test = ":_aar_arm64",
        aar_name = "_aar_arm64.aar",
        expected_abi = "arm64-v8a",
        expected_machine = "183",
        size = "small",
    )
    _archive_test(
        name = name + "_archive_x64",
        target_under_test = ":_aar_x64",
        aar_name = "_aar_x64.aar",
        expected_abi = "x86_64",
        expected_machine = "62",
        size = "small",
    )
    _profile_archive_test(
        name = name + "_archive_profile",
        target_under_test = ":_aar_default",
        aar_name = "_aar_default.aar",
        expected_abi = "arm64-v8a",
        expected_machine = "183",
        size = "small",
    )

def _declare_engine_tests(name):
    """Declares the `engine_maven` output group analysis tests for `name`."""
    _engine_test(
        name = name + "_engine_arm64",
        target_under_test = ":_aar_default",
        engines = ["flutter_android_engine_arm64"],
        size = "small",
    )
    _engine_test(
        name = name + "_engine_explicit_arm64",
        target_under_test = ":_aar_arm64",
        engines = ["flutter_android_engine_arm64"],
        size = "small",
    )
    _engine_test(
        name = name + "_engine_x64",
        target_under_test = ":_aar_x64",
        engines = ["flutter_android_engine_x64"],
        size = "small",
    )
    _profile_engine_test(
        name = name + "_engine_profile_arm64",
        target_under_test = ":_aar_default",
        engines = ["flutter_android_engine_arm64"],
        size = "small",
    )
    _profile_engine_test(
        name = name + "_engine_profile_x64",
        target_under_test = ":_aar_x64",
        engines = ["flutter_android_engine_x64"],
        size = "small",
    )

def android_aar_test_suite(name):
    """Instantiate the fixtures and the analysis tests over them.

    Args:
      name: The test_suite name.
    """
    _declare_aar_fixtures()
    _declare_archive_tests(name)
    _declare_engine_tests(name)
    _error_test(
        name = name + "_unknown_abi",
        target_under_test = ":_aar_unknown",
        messages = ["android_abi", "armeabi-v7a"],
        size = "small",
    )
    _debug_error_test(
        name = name + "_debug",
        target_under_test = ":_aar_default",
        messages = ["flutter_android_aar", "debug"],
        size = "small",
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + suffix
            for suffix in [
                "_archive",
                "_archive_arm64",
                "_archive_x64",
                "_archive_profile",
                "_engine_arm64",
                "_engine_explicit_arm64",
                "_engine_x64",
                "_engine_profile_arm64",
                "_engine_profile_x64",
                "_unknown_abi",
                "_debug",
            ]
        ],
    )
