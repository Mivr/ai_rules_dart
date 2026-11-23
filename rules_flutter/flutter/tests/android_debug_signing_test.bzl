"""Analysis tests for debug APK signing in `flutter_android_app`.

In debug builds (`-c dbg`), `flutter_android_apk_overlay` defaults to APK
Signature Scheme v2 alone (`v2`) when `minSdkVersion` is 24 or higher, and
falls back to `v1_v2` below API 24 so the APK remains installable on older
Android platforms. An explicit `@rules_android//flags:apk_signing_method` flag
always overrides this default. Release builds keep `v1_v2` signing.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_android//providers:providers.bzl", "ApkInfo")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//flutter/private:flutter_android_apk_overlay.bzl", "flutter_android_apk_overlay", "overlay_signing_select")

visibility(["//flutter/tests/..."])

def _fake_android_binary_impl(ctx):
    """Stands in for `android_binary`: an unsigned APK plus deploy info."""
    unsigned_apk = ctx.actions.declare_file(ctx.label.name + "_unsigned.apk")
    ctx.actions.write(output = unsigned_apk, content = "fake unsigned apk")
    signed_apk = ctx.actions.declare_file(ctx.label.name + "_signed.apk")
    ctx.actions.write(output = signed_apk, content = "fake signed apk")
    deploy_info = ctx.actions.declare_file(ctx.label.name + ".deploy_info.pb")
    ctx.actions.write(output = deploy_info, content = "")
    merged_manifest = ctx.actions.declare_file(ctx.label.name + "_AndroidManifest.xml")
    ctx.actions.write(output = merged_manifest, content = "<manifest/>")
    return [
        DefaultInfo(files = depset([signed_apk])),
        ApkInfo(
            signed_apk = signed_apk,
            unsigned_apk = unsigned_apk,
            deploy_jar = signed_apk,
            coverage_metadata = None,
            signing_keys = [],
            signing_lineage = None,
            signing_min_v3_rotation_api_version = "",
            keystore = None,
        ),
        JavaInfo(output_jar = signed_apk, compile_jar = signed_apk),
        OutputGroupInfo(android_deploy_info = depset([deploy_info, merged_manifest])),
    ]

_fake_android_binary = rule(
    implementation = _fake_android_binary_impl,
)

def _stub_android_sdk_impl(ctx):
    """Stands in for the Android SDK toolchain: `zipalign` and `apksigner`."""
    zipalign = ctx.actions.declare_file(ctx.label.name + "_zipalign.sh")
    ctx.actions.write(output = zipalign, content = "#!/bin/sh\nexit 0\n", is_executable = True)
    apksigner = ctx.actions.declare_file(ctx.label.name + "_apksigner.sh")
    ctx.actions.write(output = apksigner, content = "#!/bin/sh\nexit 0\n", is_executable = True)
    return [platform_common.ToolchainInfo(android_sdk_info = struct(zip_align = zipalign, apk_signer = apksigner))]

_stub_android_sdk = rule(
    implementation = _stub_android_sdk_impl,
)

def _stub_android_toolchain_impl(ctx):
    """Stands in for the Android toolchain: the deploy-info writer."""
    writer = ctx.actions.declare_file(ctx.label.name + "_deploy_info_writer.sh")
    ctx.actions.write(output = writer, content = "#!/bin/sh\nexit 0\n", is_executable = True)
    return [platform_common.ToolchainInfo(deploy_info_writer = struct(files_to_run = writer))]

_stub_android_toolchain = rule(
    implementation = _stub_android_toolchain_impl,
)

_EXTRA_TOOLCHAINS = [
    str(Label("//flutter/tests:_debug_signing_stub_sdk_toolchain")),
    str(Label("//flutter/tests:_debug_signing_stub_android_toolchain")),
]

def _is_split(action):
    """Whether `action` writes (or reads) one of the debug split APKs."""
    return any([
        f.basename.endswith(("_base.apk", "_payload.apk", "_base_unsigned.apk", "_payload_unsigned.apk"))
        for f in list(action.outputs.to_list())
    ])

def _sign_action(env):
    """Extracts the unique full-APK ApkSignerTool action from target actions."""
    actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "ApkSignerTool" and not _is_split(a)
    ]
    asserts.equals(
        env,
        1,
        len(actions),
        "expected exactly one full-APK ApkSignerTool action, got %s" %
        [a.mnemonic for a in analysistest.target_actions(env)],
    )
    return actions[0] if actions else None

def _split_actions(env, mnemonic):
    """Maps `base`/`payload` to the split's `mnemonic` action."""
    found = {}
    for a in analysistest.target_actions(env):
        if a.mnemonic != mnemonic:
            continue
        for kind in ("base", "payload"):
            names = [f.basename for f in a.outputs.to_list()]
            if any([n.endswith(("_%s.apk" % kind, "_%s_unsigned.apk" % kind)) for n in names]):
                found[kind] = a
    return found

def _input_names(action):
    """The basenames of an action's inputs."""
    return [f.basename for f in action.inputs.to_list()]

def _flag_value(argv, flag):
    """Returns the value following `flag` in `argv`, or None."""
    for i, arg in enumerate(argv):
        if arg == flag and i + 1 < len(argv):
            return argv[i + 1]
    return None

def _debug_min_sdk_24_test_impl(ctx):
    """Verifies that debug signing defaults to v2 only for minSdk >= 24."""
    env = analysistest.begin(ctx)
    action = _sign_action(env)
    argv = action.argv
    asserts.equals(env, "false", _flag_value(argv, "--v1-signing-enabled"))
    asserts.equals(env, "true", _flag_value(argv, "--v2-signing-enabled"))
    asserts.equals(env, "false", _flag_value(argv, "--v4-signing-enabled"))
    return analysistest.end(env)

def _debug_min_sdk_21_test_impl(ctx):
    """Verifies that debug signing defaults to v1_v2 for minSdk < 24."""
    env = analysistest.begin(ctx)
    action = _sign_action(env)
    argv = action.argv
    asserts.equals(env, "true", _flag_value(argv, "--v1-signing-enabled"))
    asserts.equals(env, "true", _flag_value(argv, "--v2-signing-enabled"))
    asserts.equals(env, "false", _flag_value(argv, "--v4-signing-enabled"))
    return analysistest.end(env)

def _debug_explicit_flag_test_impl(ctx):
    """Verifies that an explicit apk_signing_method flag overrides the debug default."""
    env = analysistest.begin(ctx)
    action = _sign_action(env)
    argv = action.argv
    asserts.equals(env, "true", _flag_value(argv, "--v1-signing-enabled"))
    asserts.equals(env, "false", _flag_value(argv, "--v2-signing-enabled"))
    asserts.equals(env, "false", _flag_value(argv, "--v4-signing-enabled"))
    return analysistest.end(env)

def _release_equals_base_test_impl(ctx):
    """Verifies that a release configuration's signing arguments equal the base."""
    env = analysistest.begin(ctx)
    action = _sign_action(env)
    argv = action.argv
    asserts.equals(env, "true", _flag_value(argv, "--v1-signing-enabled"))
    asserts.equals(env, "true", _flag_value(argv, "--v2-signing-enabled"))
    asserts.equals(env, "false", _flag_value(argv, "--v4-signing-enabled"))
    return analysistest.end(env)

_debug_min_sdk_24_test = analysistest.make(
    _debug_min_sdk_24_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "dbg",
        "//command_line_option:extra_toolchains": _EXTRA_TOOLCHAINS,
    },
)

_debug_min_sdk_21_test = analysistest.make(
    _debug_min_sdk_21_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "dbg",
        "//command_line_option:extra_toolchains": _EXTRA_TOOLCHAINS,
    },
)

_debug_explicit_flag_test = analysistest.make(
    _debug_explicit_flag_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "dbg",
        str(Label("@rules_android//flags:apk_signing_method")): "v1",
        "//command_line_option:extra_toolchains": _EXTRA_TOOLCHAINS,
    },
)

_release_equals_base_test = analysistest.make(
    _release_equals_base_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:extra_toolchains": _EXTRA_TOOLCHAINS,
    },
)

def _split_outputs_test_impl(ctx):
    """Debug: base_apk and payload_apk are one signed .apk each, outside the default outputs."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    groups = target[OutputGroupInfo]
    full = _sign_action(env)
    signers = _split_actions(env, "ApkSignerTool")
    for kind in ("base", "payload"):
        files = getattr(groups, kind + "_apk").to_list()
        asserts.equals(env, 1, len(files), "%s_apk must hold one file" % kind)
        asserts.true(env, files[0].basename.endswith(".apk"))
        asserts.true(env, files[0] not in target[DefaultInfo].files.to_list(), "%s_apk is not a default output" % kind)
        signer = signers.get(kind)
        asserts.true(env, signer != None, "no ApkSignerTool for the %s split" % kind)
        if signer:
            asserts.equals(env, [files[0].path], [f.path for f in signer.outputs.to_list()])

            # The same keystore and signing flags as the full APK.
            asserts.equals(env, _flag_value(full.argv, "--ks"), _flag_value(signer.argv, "--ks"))
            asserts.equals(env, "pass:android", _flag_value(signer.argv, "--ks-pass"))
            for flag in ("--v1-signing-enabled", "--v2-signing-enabled", "--v4-signing-enabled"):
                asserts.equals(env, _flag_value(full.argv, flag), _flag_value(signer.argv, flag))
            keystore = _flag_value(signer.argv, "--ks")
            asserts.true(
                env,
                keystore in [f.path for f in signer.inputs.to_list()],
                "the keystore %s is a signing input" % keystore,
            )
    return analysistest.end(env)

def _split_isolation_test_impl(ctx):
    """Debug: only the payload split depends on flutter_assets; only the base on the native libs."""
    env = analysistest.begin(ctx)
    overlays = _split_actions(env, "FlutterApkOverlay")
    asserts.true(env, "base" in overlays and "payload" in overlays, "both split overlays exist")
    if "base" in overlays and "payload" in overlays:
        base_inputs = _input_names(overlays["base"])
        payload_inputs = _input_names(overlays["payload"])
        assets = ctx.attr.assets_name
        asserts.false(env, assets in base_inputs, "the base split must not read flutter_assets: %s" % base_inputs)
        asserts.true(env, assets in payload_inputs, "the payload split reads flutter_assets: %s" % payload_inputs)
        asserts.true(env, "--no-flutter-assets" in overlays["base"].argv)
        asserts.false(env, ctx.attr.libs_name in payload_inputs, "the payload split must not read the native libs")
    return analysistest.end(env)

def _release_no_splits_test_impl(ctx):
    """Release: no split action is registered and both split groups are empty."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    for a in analysistest.target_actions(env):
        asserts.false(env, _is_split(a), "release registered a split action: %s" % a.mnemonic)
    counts = {}
    for a in analysistest.target_actions(env):
        counts[a.mnemonic] = counts.get(a.mnemonic, 0) + 1
    for mnemonic in ("FlutterApkOverlay", "AndroidZipAlign", "ApkSignerTool", "WriteDeployInfo"):
        asserts.equals(env, 1, counts.get(mnemonic, 0), "release registers one %s" % mnemonic)
    asserts.equals(env, [], target[OutputGroupInfo].base_apk.to_list())
    asserts.equals(env, [], target[OutputGroupInfo].payload_apk.to_list())
    return analysistest.end(env)

_split_outputs_test = analysistest.make(
    _split_outputs_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "dbg",
        "//command_line_option:extra_toolchains": _EXTRA_TOOLCHAINS,
    },
)

_split_isolation_test = analysistest.make(
    _split_isolation_test_impl,
    attrs = {
        "assets_name": attr.string(),
        "libs_name": attr.string(),
    },
    config_settings = {
        "//command_line_option:compilation_mode": "dbg",
        "//command_line_option:extra_toolchains": _EXTRA_TOOLCHAINS,
    },
)

_release_no_splits_test = analysistest.make(
    _release_no_splits_test_impl,
    config_settings = {
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:extra_toolchains": _EXTRA_TOOLCHAINS,
    },
)

def _setup_fixtures(name):
    """Creates the stub toolchains, binaries and overlays for the debug signing suite."""
    _stub_android_sdk(
        name = "_debug_signing_stub_sdk",
        tags = ["manual"],
    )
    native.toolchain(
        name = "_debug_signing_stub_sdk_toolchain",
        toolchain = ":_debug_signing_stub_sdk",
        toolchain_type = "@rules_android//toolchains/android_sdk:toolchain_type",
    )
    _stub_android_toolchain(
        name = "_debug_signing_stub_android",
        tags = ["manual"],
    )
    native.toolchain(
        name = "_debug_signing_stub_android_toolchain",
        toolchain = ":_debug_signing_stub_android",
        toolchain_type = "@rules_android//toolchains/android:toolchain_type",
    )
    write_file(
        name = name + "_native_libs",
        out = name + "_native_libs.jar",
        content = ["fake native libs jar"],
        tags = ["manual"],
    )
    write_file(
        name = name + "_flutter_assets",
        out = name + "_flutter_assets.zip",
        content = ["fake flutter assets"],
        tags = ["manual"],
    )
    _fake_android_binary(
        name = name + "_fake_binary",
        tags = ["manual"],
    )
    flutter_android_apk_overlay(
        name = name + "_overlay_sdk_24",
        binary = ":" + name + "_fake_binary",
        native_libs_jar = ":" + name + "_native_libs",
        flutter_assets = ":" + name + "_flutter_assets",
        signing = overlay_signing_select(24),
        tags = ["manual"],
    )
    flutter_android_apk_overlay(
        name = name + "_overlay_sdk_21",
        binary = ":" + name + "_fake_binary",
        native_libs_jar = ":" + name + "_native_libs",
        flutter_assets = ":" + name + "_flutter_assets",
        signing = overlay_signing_select(21),
        tags = ["manual"],
    )

def android_debug_signing_test_suite(name):
    """Test suite verifying debug APK signing defaults and overrides.

    Args:
      name: Prefix for suite and subtargets.
    """
    _setup_fixtures(name)

    _debug_min_sdk_24_test(
        name = name + "_min_sdk_24_v2",
        target_under_test = ":" + name + "_overlay_sdk_24",
    )
    _debug_min_sdk_21_test(
        name = name + "_min_sdk_21_v1_v2",
        target_under_test = ":" + name + "_overlay_sdk_21",
    )
    _debug_explicit_flag_test(
        name = name + "_flag_override_v1",
        target_under_test = ":" + name + "_overlay_sdk_24",
    )
    _release_equals_base_test(
        name = name + "_release_equals_base",
        target_under_test = ":" + name + "_overlay_sdk_24",
    )

    _split_outputs_test(
        name = name + "_split_outputs",
        target_under_test = ":" + name + "_overlay_sdk_24",
    )
    _split_isolation_test(
        name = name + "_split_isolation",
        target_under_test = ":" + name + "_overlay_sdk_24",
        assets_name = name + "_flutter_assets.zip",
        libs_name = name + "_native_libs.jar",
    )
    _release_no_splits_test(
        name = name + "_release_no_splits",
        target_under_test = ":" + name + "_overlay_sdk_24",
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_split_outputs",
            ":" + name + "_split_isolation",
            ":" + name + "_release_no_splits",
            ":" + name + "_min_sdk_24_v2",
            ":" + name + "_min_sdk_21_v1_v2",
            ":" + name + "_flag_override_v1",
            ":" + name + "_release_equals_base",
        ],
    )
