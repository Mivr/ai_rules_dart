"""Analysis tests for moving the debug flutter_assets out of App.framework."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter:ios.bzl", "flutter_ios_app")
load("//flutter/private:flutter_ios_application.bzl", "flutter_ios_framework")
load(":apple_bundling.bzl", "fake_application")

visibility(["//flutter/tests/..."])

def _assets_dirs(files):
    """The directory artifacts among `files`."""
    return [f for f in files if f.is_directory]

def _split_debug_assets_test_impl(ctx):
    """Checks the framework's files and flutter_assets output group."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    defaults = tut[DefaultInfo].files.to_list()
    assets = tut[OutputGroupInfo].flutter_assets.to_list()
    defaults_nodes = [f.short_path for f in defaults if not f.is_directory]
    defaults_assets = [f.short_path for f in _assets_dirs(defaults)]

    asserts.equals(
        env,
        ctx.attr.expected_assets,
        [f.short_path for f in assets],
        "the flutter_assets output group must be exactly the split debug assets directory",
    )
    asserts.equals(
        env,
        ctx.attr.expected_default_assets,
        defaults_assets,
        "DefaultInfo's flutter_assets directories differ",
    )

    binaries = [f for f in defaults if f.basename == "App"]
    plists = [f for f in defaults if f.basename == "Info.plist"]
    asserts.equals(env, 1, len(binaries), "DefaultInfo must contain the App binary")
    asserts.equals(env, 1, len(plists), "DefaultInfo must contain Info.plist")
    asserts.equals(
        env,
        2,
        len(defaults_nodes),
        "DefaultInfo has unexpected extra files: %s" % [f.short_path for f in defaults],
    )
    return analysistest.end(env)

_DBG_CONFIG = {
    "//command_line_option:compilation_mode": "dbg",
    "//command_line_option:extra_execution_platforms": [str(Label("//flutter/platforms:macos_arm64"))],
    "//command_line_option:platforms": str(Label("//flutter/platforms:ios_arm64")),
    "//command_line_option:xcode_version_config": str(Label("//flutter/tests:ios_test_fake_xcode_config")),
    str(Label("//flutter:profile")): False,
}

_OPT_CONFIG = {
    "//command_line_option:compilation_mode": "opt",
    "//command_line_option:extra_execution_platforms": [str(Label("//flutter/platforms:macos_arm64"))],
    "//command_line_option:platforms": str(Label("//flutter/platforms:ios_arm64")),
    "//command_line_option:xcode_version_config": str(Label("//flutter/tests:ios_test_fake_xcode_config")),
    str(Label("//flutter:profile")): False,
}

_split_debug_assets_test = analysistest.make(
    _split_debug_assets_test_impl,
    attrs = {
        "expected_assets": attr.string_list(mandatory = True),
        "expected_default_assets": attr.string_list(mandatory = True),
    },
    config_settings = _DBG_CONFIG,
)

_release_split_assets_test = analysistest.make(
    _split_debug_assets_test_impl,
    attrs = {
        "expected_assets": attr.string_list(mandatory = True),
        "expected_default_assets": attr.string_list(mandatory = True),
    },
    config_settings = _OPT_CONFIG,
)

def _xtool_split_refused_impl(ctx):
    """Checks that the xtool backend refuses a split it cannot place."""
    env = analysistest.begin(ctx)
    for expected in ["'split_debug_assets'", "'xtool' backend", "flutter_xtool_ios_bundle"]:
        asserts.expect_failure(env, expected)
    return analysistest.end(env)

_xtool_split_refused_test = analysistest.make(
    _xtool_split_refused_impl,
    expect_failure = True,
    config_settings = {
        "//command_line_option:compilation_mode": "dbg",
        "//command_line_option:extra_execution_platforms": [str(Label("//flutter/platforms:macos_arm64"))],
        "//command_line_option:platforms": str(Label("//flutter/platforms:ios_arm64")),
        "//command_line_option:xcode_version_config": str(Label("//flutter/tests:ios_test_fake_xcode_config")),
        str(Label("//flutter:profile")): False,
        str(Label("//flutter/settings:apple_backend")): "xtool",
    },
)

def _resource_group_test_impl(ctx):
    """Checks the filegroup and resource group the macro builds for the assets."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ctx.attr.expected_structured_resources,
        ctx.attr.actual_structured_resources,
        "the resource group must take the output group through the filegroup",
    )
    asserts.equals(
        env,
        ctx.attr.expected_prefixes,
        ctx.attr.actual_prefixes,
        "the resource group must strip this framework's own directory",
    )
    asserts.equals(
        env,
        "filegroup",
        ctx.attr.actual_filegroup_kind,
        "the output group must be read through a filegroup",
    )
    return unittest.end(env)

_resource_group_test = unittest.make(
    _resource_group_test_impl,
    attrs = {
        "actual_filegroup_kind": attr.string(mandatory = True),
        "actual_prefixes": attr.string_list(mandatory = True),
        "actual_structured_resources": attr.string_list(mandatory = True),
        "expected_prefixes": attr.string_list(mandatory = True),
        "expected_structured_resources": attr.string_list(mandatory = True),
    },
)

_SelectedResourcesInfo = provider(
    doc = "The resources a configured app target selected from its select expression.",
    fields = {
        "labels": "The selected resource targets as labels.",
    },
)

def _selected_resources_impl(ctx):
    """Records the resource labels this configuration selected."""
    return [_SelectedResourcesInfo(labels = [str(target.label) for target in ctx.attr.resources])]

_selected_resources = rule(
    implementation = _selected_resources_impl,
    attrs = {
        "resources": attr.label_list(
            doc = "The app's resources attribute, including its select expression.",
        ),
    },
    doc = "Captures which resources an app selects in the current configuration.",
)

def _app_resource_selection_test_impl(ctx):
    """Checks the app's selected resources for this configuration."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    asserts.equals(env, ctx.attr.expected, tut[_SelectedResourcesInfo].labels)
    return analysistest.end(env)

_app_resource_selection_test = analysistest.make(
    _app_resource_selection_test_impl,
    attrs = {
        "expected": attr.string_list(mandatory = True),
    },
    config_settings = _DBG_CONFIG,
)

_release_app_resource_selection_test = analysistest.make(
    _app_resource_selection_test_impl,
    attrs = {
        "expected": attr.string_list(mandatory = True),
    },
    config_settings = _OPT_CONFIG,
)

def _debug_split_assets_action_test_impl(ctx):
    """Checks that FlutterIOSDebugAssets has no kernel input and kernel is a separate output."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    actions = analysistest.target_actions(env)

    # 1. kernel_blob.bin is its own separate output produced by a Symlink action
    symlinks = [
        a
        for a in actions
        if a.mnemonic == "Symlink" and any([f.basename == "kernel_blob.bin" for f in a.outputs.to_list()])
    ]
    asserts.equals(env, 1, len(symlinks), "expected a Symlink action for kernel_blob.bin")
    kernel_inputs = []
    if symlinks:
        kernel_inputs = symlinks[0].inputs.to_list()
        symlink_input_names = [f.basename for f in kernel_inputs]
        asserts.true(
            env,
            any([name.endswith(".dill") for name in symlink_input_names]),
            "kernel_blob.bin Symlink must take kernel dill as input: %s" % symlink_input_names,
        )

    # 2. FlutterIOSDebugAssets action has no kernel input and does not output kernel_blob.bin
    debug_assets = [a for a in actions if a.mnemonic == "FlutterIOSDebugAssets"]
    asserts.equals(env, 1, len(debug_assets), "expected exactly one FlutterIOSDebugAssets action")
    if debug_assets:
        inputs = debug_assets[0].inputs.to_list()
        input_names = [f.basename for f in inputs]
        asserts.false(
            env,
            "app.dill" in input_names,
            "FlutterIOSDebugAssets must not take app.dill as input: %s" % input_names,
        )
        asserts.false(
            env,
            any([k in inputs for k in kernel_inputs]),
            "FlutterIOSDebugAssets must not take any kernel input: %s" % inputs,
        )
        outputs = [f.basename for f in debug_assets[0].outputs.to_list()]
        asserts.false(
            env,
            "kernel_blob.bin" in outputs,
            "FlutterIOSDebugAssets must not output kernel_blob.bin: %s" % outputs,
        )

    # 3. OutputGroupInfo.flutter_assets contains both the assets directory and kernel_blob.bin
    assets_group = [f.short_path for f in tut[OutputGroupInfo].flutter_assets.to_list()]
    asserts.true(
        env,
        any([p.endswith("App.framework/flutter_assets") for p in assets_group]),
        "flutter_assets output group must contain App.framework/flutter_assets: %s" % assets_group,
    )
    asserts.true(
        env,
        any([p.endswith("kernel/flutter_assets/kernel_blob.bin") for p in assets_group]),
        "flutter_assets output group must contain kernel_blob.bin: %s" % assets_group,
    )

    return analysistest.end(env)

_debug_split_assets_action_test = analysistest.make(
    _debug_split_assets_action_test_impl,
    config_settings = _DBG_CONFIG,
)

def _debug_split_incremental_cutoff_test_impl(ctx):
    """Checks that a kernel change does not invalidate the assets action (early cut-off)."""
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)

    debug_assets = [a for a in actions if a.mnemonic == "FlutterIOSDebugAssets"]
    asserts.equals(env, 1, len(debug_assets), "expected FlutterIOSDebugAssets action")

    symlinks = [
        a
        for a in actions
        if a.mnemonic == "Symlink" and any([f.basename == "kernel_blob.bin" for f in a.outputs.to_list()])
    ]
    asserts.equals(env, 1, len(symlinks), "expected kernel Symlink action")

    if debug_assets and symlinks:
        asset_inputs = [f.path for f in debug_assets[0].inputs.to_list()]
        kernel_inputs = [f.path for f in symlinks[0].inputs.to_list()]
        overlap = [p for p in asset_inputs if p in kernel_inputs]
        asserts.equals(
            env,
            [],
            overlap,
            "assets action must not share inputs with kernel action for cut-off: %s" % overlap,
        )

    return analysistest.end(env)

_debug_split_incremental_cutoff_test = analysistest.make(
    _debug_split_incremental_cutoff_test_impl,
    config_settings = _DBG_CONFIG,
)

def _debug_bundle_contents_path_test_impl(ctx):
    """Checks that bundle-mapped relative paths match the base bundle layout path by path."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    assets = tut[OutputGroupInfo].flutter_assets.to_list()
    prefixes = ctx.attr.strip_prefixes

    mapped_paths = []
    for asset in assets:
        short = asset.short_path
        matched = False
        for prefix in prefixes:
            pkg_prefix = ctx.label.package + "/" + prefix + "/"
            if short.startswith(pkg_prefix):
                mapped_paths.append(short[len(pkg_prefix):])
                matched = True
                break
        asserts.true(
            env,
            matched,
            "asset %s must match one of the strip prefixes %s" % (short, prefixes),
        )

    expected = sorted(["flutter_assets", "flutter_assets/kernel_blob.bin"])
    asserts.equals(
        env,
        expected,
        sorted(mapped_paths),
        "debug bundle contents must place kernel_blob.bin under flutter_assets matching base",
    )
    return analysistest.end(env)

_debug_bundle_contents_path_test = analysistest.make(
    _debug_bundle_contents_path_test_impl,
    attrs = {
        "strip_prefixes": attr.string_list(mandatory = True),
    },
    config_settings = _DBG_CONFIG,
)

def _aot_and_unsplit_unchanged_test_impl(ctx):
    """Checks that unsplit debug and AOT builds remain unchanged from the base."""
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    actions = analysistest.target_actions(env)

    assets_group = tut[OutputGroupInfo].flutter_assets.to_list()
    asserts.equals(
        env,
        [],
        assets_group,
        "flutter_assets output group must be empty for unsplit/AOT builds: %s" % assets_group,
    )

    symlinks = [
        a
        for a in actions
        if a.mnemonic == "Symlink" and any([f.basename == "kernel_blob.bin" for f in a.outputs.to_list()])
    ]
    asserts.equals(
        env,
        [],
        symlinks,
        "unsplit/AOT builds must not register kernel Symlink action: %s" % symlinks,
    )

    if ctx.attr.is_unsplit_debug:
        debug_assets = [a for a in actions if a.mnemonic == "FlutterIOSDebugAssets"]
        asserts.equals(env, 1, len(debug_assets), "expected FlutterIOSDebugAssets action in unsplit debug")
        if debug_assets:
            inputs = [f.basename for f in debug_assets[0].inputs.to_list()]
            asserts.true(
                env,
                any([name.endswith(".dill") for name in inputs]),
                "unsplit debug build must keep kernel.dill as input to FlutterIOSDebugAssets: %s" % inputs,
            )
    else:
        debug_assets = [a for a in actions if a.mnemonic == "FlutterIOSDebugAssets"]
        asserts.equals(env, 0, len(debug_assets), "AOT build must not register FlutterIOSDebugAssets")

    return analysistest.end(env)

_aot_and_unsplit_unchanged_test = analysistest.make(
    _aot_and_unsplit_unchanged_test_impl,
    attrs = {
        "is_unsplit_debug": attr.bool(default = False),
    },
    config_settings = _DBG_CONFIG,
)

_aot_unchanged_test = analysistest.make(
    _aot_and_unsplit_unchanged_test_impl,
    attrs = {
        "is_unsplit_debug": attr.bool(default = False),
    },
    config_settings = _OPT_CONFIG,
)

def _split_debug_asset_fixtures(name):
    """Declares the debug and release application and framework fixtures.

    Args:
        name: Prefix for every target declared here.
    """
    fake_application(
        name = name + "_debug_app",
        debug = True,
        tags = ["manual"],
    )
    fake_application(
        name = name + "_release_app",
        debug = False,
        macho_aot = True,
        tags = ["manual"],
    )
    flutter_ios_framework(
        name = name + "_debug_split",
        application = ":" + name + "_debug_app",
        split_debug_assets = True,
        tags = ["manual"],
    )
    flutter_ios_framework(
        name = name + "_debug_base",
        application = ":" + name + "_debug_app",
        tags = ["manual"],
    )
    flutter_ios_framework(
        name = name + "_release_split",
        application = ":" + name + "_release_app",
        split_debug_assets = True,
        tags = ["manual"],
    )

def _split_debug_asset_framework_tests(name):
    """Declares the framework file and output-group tests.

    Args:
        name: Prefix for every target declared here.
    """
    _split_debug_assets_test(
        name = name + "_debug_split_files",
        target_under_test = ":" + name + "_debug_split",
        expected_assets = [
            "flutter/tests/" + name + "_debug_split/App.framework/flutter_assets",
            "flutter/tests/" + name + "_debug_split/kernel/flutter_assets/kernel_blob.bin",
        ],
        expected_default_assets = [],
    )
    _release_split_assets_test(
        name = name + "_release_split_keeps_framework_assets",
        target_under_test = ":" + name + "_release_split",
        expected_assets = [],
        expected_default_assets = ["flutter/tests/" + name + "_release_split/App.framework/flutter_assets"],
    )
    _split_debug_assets_test(
        name = name + "_debug_base_files",
        target_under_test = ":" + name + "_debug_base",
        expected_assets = [],
        expected_default_assets = ["flutter/tests/" + name + "_debug_base/App.framework/flutter_assets"],
    )
    _xtool_split_refused_test(
        name = name + "_xtool_split_refused",
        target_under_test = ":" + name + "_debug_split",
    )
    _debug_split_assets_action_test(
        name = name + "_debug_split_assets_action",
        target_under_test = ":" + name + "_debug_split",
    )
    _debug_split_incremental_cutoff_test(
        name = name + "_debug_split_incremental_cutoff",
        target_under_test = ":" + name + "_debug_split",
    )
    _debug_bundle_contents_path_test(
        name = name + "_debug_bundle_contents_paths",
        target_under_test = ":" + name + "_debug_split",
        strip_prefixes = [
            name + "_debug_split/App.framework",
            name + "_debug_split/kernel",
        ],
    )
    _aot_and_unsplit_unchanged_test(
        name = name + "_unsplit_unchanged",
        target_under_test = ":" + name + "_debug_base",
        is_unsplit_debug = True,
    )
    _aot_unchanged_test(
        name = name + "_aot_unchanged",
        target_under_test = ":" + name + "_release_split",
        is_unsplit_debug = False,
    )

def _split_debug_asset_bundles(name):
    """Declares the apps that take the split assets and their resource probes.

    Args:
        name: Prefix for every target declared here.

    Returns:
        A `(declared rules, debug app name, release app name)` tuple.
    """
    debug_app = name + "_debug_bundle"
    release_app = name + "_release_bundle"
    runtime_srcs = [
        "@rules_flutter//flutter/private/runners/ios:AppDelegate.swift",
        "@rules_flutter//flutter/private/runners/ios:SceneDelegate.swift",
    ]
    info_plist = "@rules_flutter//flutter/private/runners/ios:Info.plist"
    flutter_ios_app(
        name = debug_app,
        application = ":" + name + "_debug_app",
        bundle_id = "com.example.splitdebug.debug",
        srcs = runtime_srcs,
        info_plist = info_plist,
        entitlements = False,
        app_icons = [],
        tags = ["manual"],
    )
    flutter_ios_app(
        name = release_app,
        application = ":" + name + "_release_app",
        bundle_id = "com.example.splitdebug.release",
        srcs = runtime_srcs,
        info_plist = info_plist,
        entitlements = False,
        app_icons = [],
        tags = ["manual"],
    )

    after = native.existing_rules()
    _selected_resources(
        name = name + "_debug_app_resources",
        resources = after[debug_app]["resources"],
        tags = ["manual"],
    )
    _selected_resources(
        name = name + "_release_app_resources",
        resources = after[release_app]["resources"],
        tags = ["manual"],
    )
    return after, debug_app, release_app

def _split_debug_asset_bundle_tests(name, after, debug_app, release_app):
    """Declares the resource-group and app-selection tests.

    Args:
        name: Prefix for every target declared here.
        after: The declared rules, as read after the app macros ran.
        debug_app: The debug app target name.
        release_app: The release app target name.
    """
    group = "__%s_split_debug_assets_group" % debug_app
    filegroup = "__%s_split_debug_assets" % debug_app
    _resource_group_test(
        name = name + "_debug_root_assets_group",
        actual_filegroup_kind = after[filegroup]["kind"],
        actual_structured_resources = [str(r) for r in after[group]["structured_resources"]],
        actual_prefixes = after[group]["strip_structured_resources_prefixes"],
        expected_structured_resources = [":" + filegroup],
        expected_prefixes = [
            "__%s_app_framework/App.framework" % debug_app,
            "__%s_app_framework/kernel" % debug_app,
        ],
    )

    # Reuse the exact select expression the macro gave ios_application, so the
    # debug and release rows below check the app's real resource choice.
    _app_resource_selection_test(
        name = name + "_debug_app_root_assets",
        target_under_test = ":" + name + "_debug_app_resources",
        expected = [
            str(Label(":__%s_privacy_manifests" % debug_app)),
            str(Label(":" + group)),
        ],
    )
    _release_app_resource_selection_test(
        name = name + "_release_app_keeps_framework_assets",
        target_under_test = ":" + name + "_release_app_resources",
        expected = [str(Label(":__%s_privacy_manifests" % release_app))],
    )

def ios_split_debug_assets_test_suite(name):
    """Declares the split-debug-assets analysis tests.

    Args:
        name: Prefix for every target declared here.
    """
    _split_debug_asset_fixtures(name)
    _split_debug_asset_framework_tests(name)
    after, debug_app, release_app = _split_debug_asset_bundles(name)
    _split_debug_asset_bundle_tests(name, after, debug_app, release_app)

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_debug_split_files",
            ":" + name + "_release_split_keeps_framework_assets",
            ":" + name + "_debug_base_files",
            ":" + name + "_xtool_split_refused",
            ":" + name + "_debug_root_assets_group",
            ":" + name + "_debug_app_root_assets",
            ":" + name + "_release_app_keeps_framework_assets",
            ":" + name + "_debug_split_assets_action",
            ":" + name + "_debug_split_incremental_cutoff",
            ":" + name + "_debug_bundle_contents_paths",
            ":" + name + "_unsplit_unchanged",
            ":" + name + "_aot_unchanged",
        ],
    )
