"""Static `flutter_apple_xcframework_import` on the `xtool` backend stays out of `Frameworks/`.

A static import is linked into the runner executable and must not be copied
into `Payload/<App>.app/Frameworks/` (iOS) or `<App>.app/Contents/Frameworks/`
(macOS). Both the direct case (`runner_deps`) and the plugin-dep case
(`flutter_apple_plugin_library(deps = ...)`) are covered, next to a dynamic
import that must still be embedded. The analysis tests read the runner and
bundle action argv; the probes build the real archives and list their entries.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//flutter:ios.bzl", "flutter_apple_plugin_library", "flutter_apple_xcframework_import", "flutter_ios_app")
load("//flutter:macos.bzl", "flutter_macos_app")
load(":apple_bundling.bzl", "fake_application", "fake_xcframework", "macho_verify_probe")

visibility(["//flutter/tests/..."])

_STATIC_NAMES = ["StaticKit", "PluginStaticKit"]
_DYNAMIC_NAME = "DynamicKit"

def _transition_impl(_settings, attr):
    return {
        "//command_line_option:platforms": str(Label("//flutter/platforms:%s_arm64" % attr.platform)),
        "//flutter/settings:apple_backend": "xtool",
    }

_transition = transition(
    implementation = _transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:platforms",
        "//flutter/settings:apple_backend",
    ],
)

def _targets_impl(ctx):
    return [DefaultInfo(files = depset(transitive = [t[DefaultInfo].files for t in ctx.attr.targets]))]

_targets = rule(
    implementation = _targets_impl,
    attrs = {
        "platform": attr.string(mandatory = True, doc = "`ios` or `macos`."),
        "targets": attr.label_list(cfg = _transition, mandatory = True, doc = "Targets built on xtool."),
    },
    doc = "Builds its targets in the xtool configuration of one Apple platform.",
)

def _values_after(argv, flag):
    """The values that follow each occurrence of `flag` in `argv`."""
    return [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == flag]

def _static_framework_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    runner = [a for a in actions if a.mnemonic == "FlutterXtoolRunner"]
    bundle = [a for a in actions if a.mnemonic == ctx.attr.bundle_mnemonic]
    asserts.equals(env, 1, len(runner), "Expected one FlutterXtoolRunner action")
    asserts.equals(env, 1, len(bundle), "Expected one %s action" % ctx.attr.bundle_mnemonic)
    if len(runner) != 1 or len(bundle) != 1:
        return analysistest.end(env)

    runner_fws = _values_after(runner[0].argv, "--framework")
    bundle_fws = _values_after(bundle[0].argv, "--framework")
    for name in _STATIC_NAMES:
        asserts.true(
            env,
            any([("/%s.xcframework/" % name) in fw for fw in runner_fws]),
            "Expected the runner to link static %s, got %s" % (name, runner_fws),
        )
        asserts.false(
            env,
            any([name in fw for fw in bundle_fws]),
            "Static %s must not be a bundle --framework, got %s" % (name, bundle_fws),
        )
        asserts.false(
            env,
            any([name in arg for arg in bundle[0].argv]),
            "Static %s must not appear in the bundle argv, got %s" % (name, bundle[0].argv),
        )
    asserts.true(
        env,
        any([("/%s.xcframework/" % _DYNAMIC_NAME) in fw for fw in bundle_fws]),
        "Expected the dynamic %s to be embedded, got %s" % (_DYNAMIC_NAME, bundle_fws),
    )
    asserts.true(
        env,
        any([("/%s.xcframework/" % _DYNAMIC_NAME) in fw for fw in runner_fws]),
        "Expected the runner to see the dynamic %s, got %s" % (_DYNAMIC_NAME, runner_fws),
    )
    return analysistest.end(env)

_static_framework_test = analysistest.make(
    _static_framework_test_impl,
    attrs = {
        "bundle_mnemonic": attr.string(mandatory = True, doc = "Mnemonic of the platform's bundle action."),
    },
    doc = "Asserts static frameworks reach only the runner compile, dynamic ones also the bundle.",
)

def _fixture_kits(name, platform):
    """Declare the static, dynamic and plugin-dep frameworks plus the engine for one platform."""
    engine_name = "FlutterMacOS" if platform == "macos" else "Flutter"
    fake_xcframework(name = name + "_engine_xcf", framework_name = engine_name, platform = platform, tags = ["manual"])
    for kit in _STATIC_NAMES + [_DYNAMIC_NAME]:
        xcf = name + "_" + kit + ".xcframework"
        fake_xcframework(name = xcf, framework_name = kit, platform = platform, tags = ["manual"])
        flutter_apple_xcframework_import(
            name = name + "_" + kit,
            framework = ":" + xcf,
            linkage = "dynamic" if kit == _DYNAMIC_NAME else "static",
        )
    write_file(
        name = name + "_plugin_swift",
        out = name + "_StaticPlugin.swift",
        content = ["import Foundation", "public class StaticPlugin {}"],
        tags = ["manual"],
    )
    flutter_apple_plugin_library(
        name = name + "_plugin_lib",
        srcs = [":" + name + "_plugin_swift"],
        module_name = "static_plugin",
        platform = platform,
        engine = ":" + name + "_engine_xcf",
        deps = [":" + name + "_PluginStaticKit"],
        backend = "xtool",
        tags = ["manual"],
    )
    fake_application(
        name = name + "_application",
        debug = False,
        macho_aot = True,
        apple_plugin_libraries = [":" + name + "_plugin_lib"],
        tags = ["manual"],
    )

def _declare_app(name, platform):
    """Declare the xtool app whose frameworks the tests inspect; returns its target name."""
    app = name + "_app"
    runner_deps = [":" + name + "_StaticKit", ":" + name + "_" + _DYNAMIC_NAME, ":" + name + "_plugin_lib"]
    if platform == "macos":
        write_file(
            name = name + "_entitlements",
            out = name + "_DebugProfile.entitlements",
            content = [
                '<?xml version="1.0" encoding="UTF-8"?>',
                '<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>',
            ],
            tags = ["manual"],
        )
        flutter_macos_app(
            name = app,
            application = ":" + name + "_application",
            bundle_id = "com.example.static.macos",
            minimum_os_version = "13.4",
            entitlements = ":" + name + "_entitlements",
            srcs = [
                "@rules_flutter//flutter/private/runners/macos:AppDelegate.swift",
                "@rules_flutter//flutter/private/runners/macos:MainFlutterWindow.swift",
            ],
            info_plist = "@rules_flutter//flutter/private/runners/macos:Info.plist",
            engine = ":" + name + "_engine_xcf",
            runner_deps = runner_deps,
            backend = "xtool",
            tags = ["manual"],
        )
    else:
        flutter_ios_app(
            name = app,
            application = ":" + name + "_application",
            bundle_id = "com.example.static.ios",
            minimum_os_version = "15.4",
            srcs = [
                "@rules_flutter//flutter/private/runners/ios:AppDelegate.swift",
                "@rules_flutter//flutter/private/runners/ios:SceneDelegate.swift",
            ],
            info_plist = "@rules_flutter//flutter/private/runners/ios:Info.plist",
            engine = ":" + name + "_engine_xcf",
            runner_deps = runner_deps,
            signing = False,
            backend = "xtool",
            tags = ["manual"],
        )
    return app

def _declare_probe(name, platform, app):
    """Declare the probe that lists the built archive's entries; returns its target name."""
    if platform == "macos":
        prefix = app + ".app/Contents/Frameworks/"
        binary = app + ".app/Contents/MacOS/" + app
        engine_entry = prefix + "FlutterMacOS.framework/FlutterMacOS"
    else:
        prefix = "Payload/" + app + ".app/Frameworks/"
        binary = "Payload/" + app + ".app/" + app
        engine_entry = prefix + "Flutter.framework/Flutter"
    probe = name + "_bundle_verify"
    macho_verify_probe(
        name = probe,
        target = ":" + app,
        binary_relpath = binary,
        expected_entries = [
            binary,
            engine_entry,
            prefix + _DYNAMIC_NAME + ".framework/" + _DYNAMIC_NAME,
        ],
        forbidden_entries = [prefix + kit + ".framework" for kit in _STATIC_NAMES],
        tags = ["manual"],
    )
    return probe

def _declare_platform(name, platform, bundle_mnemonic):
    """Declare the fixtures, the analysis test and the built-bundle check for one platform."""
    _fixture_kits(name, platform)
    app = _declare_app(name, platform)
    probe = _declare_probe(name, platform, app)
    _targets(
        name = name + "_built",
        platform = platform,
        targets = [":" + probe],
        tags = ["manual"],
    )
    build_test(name = name + "_bundle_build_test", targets = [":" + name + "_built"], size = "small")
    _static_framework_test(
        name = name + "_argv_test",
        target_under_test = ":" + app,
        bundle_mnemonic = bundle_mnemonic,
        size = "small",
    )
    return [name + "_argv_test", name + "_bundle_build_test"]

def xtool_static_xcframework_test_suite(name):
    """Declare the static-import tests for the iOS and macOS xtool bundles.

    Args:
        name: Name of the `test_suite` and prefix of every target declared.
    """
    tests = (
        _declare_platform(name + "_ios", "ios", "FlutterXtoolIosBundle") +
        _declare_platform(name + "_macos", "macos", "FlutterXtoolMacosBundle")
    )
    native.test_suite(name = name, tests = [":" + t for t in tests])
