"""Analysis tests for the analyze_size attribute.

Tests:
- analyze_size = True registers one gen_snapshot action whose argv has
  --print-instructions-sizes-to= with a path under the target's own output directory
  and whose outputs include <name>_size.json.
- default analyze_size = False leaves argv and outputs unchanged.
- debug mode fails analysis naming the attribute and debug mode.
- extra_gen_snapshot_options = ["--print-instructions-sizes-to=x.json"] fails with
  dedicated message naming analyze_size and <name>_size.json.
- flutter_android_binary_proxy with analyze_size = True outputs <name>_size.json in
  default outputs and analyze_size output group.
- flutter_android_binary_proxy with analyze_size = True fails in debug mode.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_android//providers:providers.bzl", "ApkInfo")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:common.bzl", "HOST_COMPATIBLE")
load("//flutter/private:flutter_android_application.bzl", "flutter_android_bundle")
load("//flutter/private:flutter_android_binary_proxy.bzl", "flutter_android_binary_proxy")
load("//flutter/private:flutter_aot_target.bzl", "flutter_aot_target")
load("//flutter/private:flutter_application.bzl", "flutter_application")

visibility(["//flutter/tests/..."])

_PACKAGE = "analyze_size_fixture"
_MAIN = "lib/language_version_main.dart"

def _aot_action(env):
    """Returns the single gen_snapshot action for the target under test."""
    actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic in ("FlutterAotElf", "FlutterAotMacho")
    ]
    asserts.equals(
        env,
        1,
        len(actions),
        "expected exactly one AOT action, got %s" % ([a.mnemonic for a in actions]),
    )
    return actions[0] if actions else None

def _analyze_size_flags_test_impl(ctx):
    """`analyze_size = True` passes --print-instructions-sizes-to and declares <name>_size.json."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    action = _aot_action(env)
    flags = [a for a in action.argv if a.startswith("--print-instructions-sizes-to=")]
    asserts.equals(
        env,
        1,
        len(flags),
        "expected exactly one --print-instructions-sizes-to flag, got %s" % (action.argv,),
    )
    flag_path = flags[0].split("=", 1)[1]
    asserts.true(
        env,
        tut.label.name in flag_path,
        "expected path under target's own output directory, got %s" % flag_path,
    )

    action_outputs = [f.basename for f in action.outputs.to_list()]
    asserts.true(
        env,
        tut.label.name + "_size.json" in action_outputs,
        "action outputs must include <name>_size.json",
    )

    default_outputs = [f.basename for f in tut[DefaultInfo].files.to_list()]
    asserts.true(
        env,
        tut.label.name + "_size.json" in default_outputs,
        "default outputs must include <name>_size.json",
    )

    has_group = OutputGroupInfo in tut and hasattr(tut[OutputGroupInfo], "analyze_size")
    asserts.true(env, has_group, "target must provide analyze_size output group")
    if has_group:
        group_files = [f.basename for f in tut[OutputGroupInfo].analyze_size.to_list()]
        asserts.true(env, tut.label.name + "_size.json" in group_files, "output group must include <name>_size.json")

    return analysistest.end(env)

def _analyze_size_default_test_impl(ctx):
    """With default analyze_size = False argv and outputs are unchanged."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    action = _aot_action(env)
    flags = [a for a in action.argv if a.startswith("--print-instructions-sizes-to=")]
    asserts.equals(env, 0, len(flags), "expected no --print-instructions-sizes-to flag by default")

    action_outputs = [f.basename for f in action.outputs.to_list()]
    asserts.false(env, tut.label.name + "_size.json" in action_outputs, "action outputs must not include size.json")

    default_outputs = [f.basename for f in tut[DefaultInfo].files.to_list()]
    asserts.false(env, tut.label.name + "_size.json" in default_outputs, "default outputs must not include size.json")

    has_group = OutputGroupInfo in tut and hasattr(tut[OutputGroupInfo], "analyze_size")
    asserts.false(env, has_group, "target must not provide analyze_size output group by default")

    return analysistest.end(env)

def _analyze_size_debug_fail_test_impl(ctx):
    """debug mode with analyze_size = True fails naming the attribute and debug mode."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "analyze_size")
    asserts.expect_failure(env, "debug mode")
    return analysistest.end(env)

def _refuse_print_instructions_sizes_test_impl(ctx):
    """extra_gen_snapshot_options = ['--print-instructions-sizes-to=...'] fails naming analyze_size."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "analyze_size = True")
    asserts.expect_failure(env, "_size.json")
    return analysistest.end(env)

def _proxy_analyze_size_test_impl(ctx):
    """proxy outputs <name>_size.json in default outputs and analyze_size output group."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    expected_name = tut.label.name + "_size.json"
    default_outputs = [f.basename for f in tut[DefaultInfo].files.to_list()]
    asserts.true(env, expected_name in default_outputs, "default outputs must include <name>_size.json")

    has_group = OutputGroupInfo in tut and hasattr(tut[OutputGroupInfo], "analyze_size")
    asserts.true(env, has_group, "proxy must provide analyze_size output group")
    if has_group:
        group_files = [f.basename for f in tut[OutputGroupInfo].analyze_size.to_list()]
        asserts.true(env, expected_name in group_files, "output group must include <name>_size.json")

    return analysistest.end(env)

def _bundle_analyze_size_test_impl(ctx):
    """flutter_android_bundle with analyze_size = True exposes the analyze_size group."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    has_group = OutputGroupInfo in tut and hasattr(tut[OutputGroupInfo], "analyze_size")
    asserts.true(env, has_group, "bundle must provide analyze_size output group")
    if has_group:
        files = [f.basename for f in tut[OutputGroupInfo].analyze_size.to_list()]
        asserts.true(env, "_fake_bundle_app_size_size.json" in files, "bundle must forward app's size.json")
    return analysistest.end(env)

def _bundle_default_test_impl(ctx):
    """flutter_android_bundle by default does not expose analyze_size group."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    has_group = OutputGroupInfo in tut and hasattr(tut[OutputGroupInfo], "analyze_size")
    asserts.false(env, has_group, "default bundle must not provide analyze_size output group")
    return analysistest.end(env)

_FASTBUILD = {
    "//command_line_option:compilation_mode": "fastbuild",
    str(Label("//flutter:profile")): False,
}

_DEBUG = {
    "//command_line_option:compilation_mode": "dbg",
    str(Label("//flutter:profile")): False,
}

_analyze_size_flags_test = analysistest.make(_analyze_size_flags_test_impl, config_settings = _FASTBUILD)
_analyze_size_default_test = analysistest.make(_analyze_size_default_test_impl, config_settings = _FASTBUILD)
_analyze_size_debug_fail_test = analysistest.make(
    _analyze_size_debug_fail_test_impl,
    config_settings = _DEBUG,
    expect_failure = True,
)
_refuse_print_instructions_sizes_test = analysistest.make(
    _refuse_print_instructions_sizes_test_impl,
    config_settings = _FASTBUILD,
    expect_failure = True,
)
_proxy_analyze_size_test = analysistest.make(_proxy_analyze_size_test_impl, config_settings = _FASTBUILD)
_proxy_debug_fail_test = analysistest.make(
    _analyze_size_debug_fail_test_impl,
    config_settings = _DEBUG,
    expect_failure = True,
)
_bundle_analyze_size_test = analysistest.make(_bundle_analyze_size_test_impl, config_settings = _FASTBUILD)
_bundle_default_test = analysistest.make(_bundle_default_test_impl, config_settings = _FASTBUILD)

def _fake_bundle_app_impl(ctx):
    """Fake application providing FlutterApplicationInfo and OutputGroupInfo with size."""
    assets = ctx.actions.declare_directory(ctx.label.name + "_assets")
    ctx.actions.run(
        executable = ctx.executable._bundle_tool,
        arguments = [],
        outputs = [assets],
        toolchain = None,
    )
    icu = ctx.actions.declare_file(ctx.label.name + "_icudtl.dat")
    ctx.actions.write(icu, "")
    aot = ctx.actions.declare_file(ctx.label.name + "_libapp.so")
    ctx.actions.write(aot, "")
    default_files = [aot]
    output_groups = {}
    if ctx.attr.with_size:
        size_file = ctx.actions.declare_file(ctx.label.name + "_size.json")
        ctx.actions.write(size_file, "{}")
        default_files.append(size_file)
        output_groups["analyze_size"] = depset([size_file])
    return [
        DefaultInfo(files = depset(default_files)),
        OutputGroupInfo(**output_groups),
        FlutterApplicationInfo(
            kernel_dill = None,
            aot_output = aot,
            aot_strip = False,
            flutter_assets = assets,
            icu_data = icu,
            is_debug = False,
            native_libs = [],
            plugins = [],
            bundled_code_assets = depset(),
        ),
    ]

_fake_bundle_app = rule(
    implementation = _fake_bundle_app_impl,
    attrs = {
        "with_size": attr.bool(default = False),
        "_bundle_tool": attr.label(
            default = Label("//flutter/private/tools:android_bundle"),
            executable = True,
            cfg = "exec",
        ),
    },
)

def _fake_overlay_with_size_impl(ctx):
    """Fake apk overlay providing ApkInfo and OutputGroupInfo with analyze_size."""
    signed_apk = ctx.actions.declare_file(ctx.label.name + "_signed.apk")
    ctx.actions.write(output = signed_apk, content = "signed apk")
    size_file = ctx.actions.declare_file(ctx.label.name + "_bundle_size.json")
    ctx.actions.write(output = size_file, content = "{}")
    return [
        DefaultInfo(files = depset([signed_apk])),
        ApkInfo(
            signed_apk = signed_apk,
            unsigned_apk = signed_apk,
            deploy_jar = signed_apk,
            coverage_metadata = None,
            signing_keys = [],
            signing_lineage = None,
            signing_min_v3_rotation_api_version = "",
            keystore = None,
        ),
        JavaInfo(output_jar = signed_apk, compile_jar = signed_apk),
        OutputGroupInfo(analyze_size = depset([size_file])),
    ]

_fake_overlay_with_size = rule(
    implementation = _fake_overlay_with_size_impl,
)

def analyze_size_test_suite(name):
    """Defines analysis tests for analyze_size on flutter_application and proxy.

    Args:
        name: The test_suite target name.
    """
    flutter_application(
        name = "_app_size_active",
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        analyze_size = True,
        target_compatible_with = HOST_COMPATIBLE,
        tags = ["manual"],
    )
    _analyze_size_flags_test(
        name = name + "_application_flags",
        target_under_test = ":_app_size_active",
    )

    flutter_application(
        name = "_app_size_default",
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        target_compatible_with = HOST_COMPATIBLE,
        tags = ["manual"],
    )
    _analyze_size_default_test(
        name = name + "_application_default",
        target_under_test = ":_app_size_default",
    )

    _analyze_size_debug_fail_test(
        name = name + "_application_debug_fails",
        target_under_test = ":_app_size_active",
    )

    flutter_application(
        name = "_app_refuse_print_sizes",
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        extra_gen_snapshot_options = ["--print-instructions-sizes-to=x.json"],
        target_compatible_with = HOST_COMPATIBLE,
        tags = ["manual"],
    )
    _refuse_print_instructions_sizes_test(
        name = name + "_application_refuses_flag",
        target_under_test = ":_app_refuse_print_sizes",
    )

    flutter_aot_target(
        name = "_aot_target_size_active",
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        analyze_size = True,
        target_compatible_with = HOST_COMPATIBLE,
        tags = ["manual"],
    )
    _analyze_size_flags_test(
        name = name + "_aot_target_flags",
        target_under_test = ":_aot_target_size_active",
    )
    _analyze_size_debug_fail_test(
        name = name + "_aot_target_debug_fails",
        target_under_test = ":_aot_target_size_active",
    )

    flutter_aot_target(
        name = "_aot_refuse_print_sizes",
        package_name = _PACKAGE,
        main = _MAIN,
        srcs = [_MAIN],
        extra_gen_snapshot_options = ["--print-instructions-sizes-to=x.json"],
        target_compatible_with = HOST_COMPATIBLE,
        tags = ["manual"],
    )
    _refuse_print_instructions_sizes_test(
        name = name + "_aot_refuses_flag",
        target_under_test = ":_aot_refuse_print_sizes",
    )

    _fake_bundle_app(
        name = "_fake_bundle_app_size",
        with_size = True,
        tags = ["manual"],
    )
    flutter_android_bundle(
        name = "_bundle_size_active",
        application = ":_fake_bundle_app_size",
        android_abi = "arm64-v8a",
        analyze_size = True,
        tags = ["manual"],
    )
    _bundle_analyze_size_test(
        name = name + "_bundle_size_active",
        target_under_test = ":_bundle_size_active",
    )

    _fake_bundle_app(
        name = "_fake_bundle_app_nosize",
        with_size = False,
        tags = ["manual"],
    )
    flutter_android_bundle(
        name = "_bundle_size_default",
        application = ":_fake_bundle_app_nosize",
        android_abi = "arm64-v8a",
        tags = ["manual"],
    )
    _bundle_default_test(
        name = name + "_bundle_size_default",
        target_under_test = ":_bundle_size_default",
    )

    _fake_overlay_with_size(
        name = "_fake_overlay_size",
        tags = ["manual"],
    )
    flutter_android_binary_proxy(
        name = "_proxy_size_active",
        binary = ":_fake_overlay_size",
        analyze_size = True,
        tags = ["manual"],
    )
    _proxy_analyze_size_test(
        name = name + "_proxy_outputs",
        target_under_test = ":_proxy_size_active",
    )
    _proxy_debug_fail_test(
        name = name + "_proxy_debug_fails",
        target_under_test = ":_proxy_size_active",
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_application_flags",
            ":" + name + "_application_default",
            ":" + name + "_application_debug_fails",
            ":" + name + "_application_refuses_flag",
            ":" + name + "_aot_target_flags",
            ":" + name + "_aot_target_debug_fails",
            ":" + name + "_aot_refuses_flag",
            ":" + name + "_bundle_size_active",
            ":" + name + "_bundle_size_default",
            ":" + name + "_proxy_outputs",
            ":" + name + "_proxy_debug_fails",
        ],
    )
