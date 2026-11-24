"""Flutter rules for macOS desktop builds.

Two tiers of API:

    Tier 1 — flutter_macos_app (self-contained, recommended):

        load("@rules_flutter//flutter:macos.bzl", "flutter_macos_app")
        load("@rules_flutter//flutter:defs.bzl", "flutter_application")

        flutter_application(name = "my_app", main = "lib/main.dart", deps = [...])

        flutter_macos_app(
            name = "my_app_macos",
            application = ":my_app",
            bundle_id = "com.example.myapp",
            app_name = "My App",
        )

    Prerequisites: run `flutter create --platforms=macos .` in your package to
    generate the conventional `macos/Runner/` directory with AppDelegate.swift,
    MainFlutterWindow.swift, MainMenu.xib, and Info.plist.

    Tier 2 — composable rules (advanced, full control):

        load("@rules_flutter//flutter:macos.bzl",
            "flutter_macos_engine",
            "flutter_macos_framework_gen",
            "flutter_macos_info_plist_gen",
            "flutter_macos_menu_xib_gen",
            "flutter_macos_native_libs_gen",
            "flutter_macos_registrant_gen",
            "flutter_macos_runner_lib_gen")

        flutter_macos_framework_gen(name = "my_framework", application = ":my_app")
        flutter_macos_registrant_gen(name = "my_registrant", application = ":my_app")
        flutter_macos_engine(name = "my_engine")
        flutter_macos_native_libs_gen(name = "my_native_libs", application = ":my_app")
        flutter_macos_info_plist_gen(name = "my_info_plist", app_name = "My App")
        flutter_macos_menu_xib_gen(name = "my_menu_xib", app_name = "My App")

        flutter_macos_runner_lib_gen(
            name = "my_runner",
            registrant = ":my_registrant",
            engine = ":my_engine",
        )

        macos_application(
            name = "my_macos_app",
            bundle_id = "com.example.myapp",
            additional_contents = {
                ":my_framework": "Frameworks",
                ":my_native_libs": "Frameworks",
            },
            infoplists = [":my_info_plist"],
            resources = [":my_menu_xib"],
            deps = [":my_runner"],
        )
"""

load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@rules_swift//swift:swift.bzl", "swift_library")
load("//flutter/private:constants.bzl", _MACOS_MINIMUM_OS_VERSION = "MACOS_MINIMUM_OS_VERSION")
load(
    "//flutter/private:flutter_apple_plugin_library.bzl",
    _flutter_apple_plugin_library_macro = "flutter_apple_plugin_library",
    _flutter_apple_plugin_objc_library = "flutter_apple_plugin_objc_library",
    _flutter_apple_plugin_objc_settings = "flutter_apple_plugin_objc_settings",
    _flutter_xtool_apple_plugin_library = "flutter_xtool_apple_plugin_library",
)
load("//flutter/private:flutter_apple_plugins_aggregator.bzl", _flutter_apple_plugins_aggregator = "flutter_apple_plugins_aggregator")
load("//flutter/private:flutter_apple_xcframework_import.bzl", _flutter_apple_xcframework_import = "flutter_apple_xcframework_import")
load(
    "//flutter/private:flutter_macos_application.bzl",
    _flutter_macos_framework_rule = "flutter_macos_framework",
    _flutter_macos_native_libs_rule = "flutter_macos_native_libs",
    _flutter_macos_privacy_manifests_rule = "flutter_macos_privacy_manifests",
)
load("//flutter/private:flutter_macos_registrant.bzl", _flutter_macos_registrant_rule = "flutter_macos_registrant")
load("//flutter/private:flutter_plist_merge.bzl", _flutter_entitlements_merge = "flutter_entitlements_merge")
load("//flutter/private:flutter_xtool_bundle.bzl", _flutter_darwin_xcframework_import = "flutter_darwin_xcframework_import", _flutter_xtool_bundle_version = "flutter_xtool_bundle_version", _flutter_xtool_macos_bundle = "flutter_xtool_macos_bundle")
load("//flutter/private:macos_app.bzl", _flutter_macos_app = "flutter_macos_app", _flutter_macos_engine = "flutter_macos_engine")

visibility("public")

# Re-exported for the generated local-plugin BUILD files and `e2e/ios_example`.
flutter_apple_plugin_objc_library = _flutter_apple_plugin_objc_library
flutter_apple_plugin_objc_settings = _flutter_apple_plugin_objc_settings

# Re-export for user BUILD files.
MACOS_MINIMUM_OS_VERSION = _MACOS_MINIMUM_OS_VERSION

# Merges entitlement additions into a base entitlements file — the additive
# seam rules_apple's single-file `entitlements` attribute does not provide.
# Wired into flutter_macos_app as `additional_entitlements`; exposed for
# Tier 2 users assembling a macos_application themselves.
flutter_entitlements_merge = _flutter_entitlements_merge

# Host-agnostic xtool framework import, versioning, and macOS bundle rules.
# rule_test_coverage: no-actions
flutter_darwin_xcframework_import = _flutter_darwin_xcframework_import

# Imports one prebuilt .xcframework or .framework on the selected Apple
# backend, for iOS and macOS alike.
# rule_test_coverage: no-actions
flutter_apple_xcframework_import = _flutter_apple_xcframework_import

flutter_xtool_bundle_version = _flutter_xtool_bundle_version
flutter_xtool_macos_bundle = _flutter_xtool_macos_bundle

# Tier 1 app assembly and engine import live in flutter/private/macos_app.bzl;
# re-exported here so user BUILD files are unaffected.
# rule_test_coverage: no-actions
flutter_macos_engine = _flutter_macos_engine
flutter_macos_app = _flutter_macos_app

# -- Composable rules (Tier 2) ------------------------------------------------
#
# Like every other *_gen macro in this file, these default to
# `tags = ["manual"]`: the targets are only meaningful as deps of a
# `macos_application` and run Apple-only tooling, so a standalone `//...`
# build (host configuration) is wrong everywhere and fails outright on
# non-macOS hosts.

def flutter_macos_framework_gen(name, minimum_os_version = MACOS_MINIMUM_OS_VERSION, **kwargs):
    """Generates App.framework. See `flutter_macos_framework`.

    Args:
        name: Name of the target that produces `App.framework`.
        minimum_os_version: Minimum macOS deployment target.
        **kwargs: Forwarded to the underlying rule. `tags` defaults to
            `["manual"]` — build via the consuming `macos_application`.
    """
    tags = kwargs.pop("tags", ["manual"])
    _flutter_macos_framework_rule(
        name = name,
        minimum_os_version = minimum_os_version,
        tags = tags,
        **kwargs
    )

def flutter_macos_registrant_gen(name, **kwargs):
    """Generates the macOS GeneratedPluginRegistrant. See `flutter_macos_registrant`.

    Args:
        name: Name of the target that holds the generated macOS `GeneratedPluginRegistrant` sources.
        **kwargs: Forwarded to the underlying rule. `tags` defaults to
            `["manual"]` — build via the consuming `macos_application`.
    """
    tags = kwargs.pop("tags", ["manual"])
    _flutter_macos_registrant_rule(name = name, tags = tags, **kwargs)

def flutter_macos_native_libs_gen(name, minimum_os_version = MACOS_MINIMUM_OS_VERSION, **kwargs):
    """Exposes native dylibs for bundling. See `flutter_macos_native_libs`.

    Args:
        name: Name of the target that exposes the native dylibs for bundling.
        minimum_os_version: Minimum macOS deployment target.
        **kwargs: Forwarded to the underlying rule. `tags` defaults to
            `["manual"]` — build via the consuming `macos_application`.
    """
    tags = kwargs.pop("tags", ["manual"])
    _flutter_macos_native_libs_rule(
        name = name,
        minimum_os_version = minimum_os_version,
        tags = tags,
        **kwargs
    )

# rule_test_coverage: no-actions
def flutter_macos_privacy_manifests_gen(name, **kwargs):
    """Exposes plugin privacy manifests. See `flutter_macos_privacy_manifests`.

    Args:
        name: Name of the target that exposes the plugins' privacy manifests.
        **kwargs: Forwarded to the underlying rule. `tags` defaults to
            `["manual"]` — build via the consuming `macos_application`.
    """
    tags = kwargs.pop("tags", ["manual"])
    _flutter_macos_privacy_manifests_rule(name = name, tags = tags, **kwargs)

# Public wrapper that compiles a Flutter plugin's macOS Apple sources into a
# swift_library. Use directly to wire a monorepo plugin's BUILD.bazel without
# going through the ext/ overlay system; for pub.dev plugins, flutter_pub_package
# emits this automatically.
flutter_apple_plugin_library = _flutter_apple_plugin_library_macro

# Aggregates per-plugin Apple swift_libraries from a flutter_application's
# transitive dep graph. Pass to runner_lib_gen `application` to thread plugin
# Swift modules + link inputs into the runner.
# rule_test_coverage: no-actions
flutter_apple_plugins_aggregator = _flutter_apple_plugins_aggregator

def flutter_macos_info_plist_gen(name, app_name, **kwargs):
    """Generates a macOS Info.plist from the default Bazel template.

    Args:
        name: Target name. Pass to macos_application infoplists.
        app_name: Display name (CFBundleDisplayName, CFBundleName).
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    tags = kwargs.pop("tags", ["manual"])

    expand_template(
        name = name,
        template = "@rules_flutter//flutter/private/runners/macos:Info.plist",
        out = name + "/Info.plist",
        substitutions = {"APP_NAME": app_name},
        tags = tags,
        **kwargs
    )

def flutter_macos_menu_xib_gen(name, app_name, **kwargs):
    """Generates a MainMenu.xib from the default Bazel template.

    Args:
        name: Target name. Pass to macos_application resources.
        app_name: Display name shown in the menu bar.
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    tags = kwargs.pop("tags", ["manual"])

    expand_template(
        name = name,
        template = "@rules_flutter//flutter/private/runners/macos:MainMenu.xib",
        out = name + "/MainMenu.xib",
        substitutions = {"APP_NAME": app_name},
        tags = tags,
        **kwargs
    )

def flutter_macos_runner_lib_gen(
        name,
        registrant,
        engine,
        application = None,
        module_name = "Runner",
        backend = "rules_apple",
        **kwargs):
    """Generates a swift_library for the default macOS runner.

    Uses template AppDelegate.swift and MainFlutterWindow.swift from
    rules_flutter. This replaces `flutter create --platforms=macos` output
    for users who don't need custom runner files.

    When `application` is set, an internal flutter_apple_plugins_aggregator
    target is created and added to the runner's `swift_library.deps` so the
    generated registrant's `import <PluginModule>` lines resolve and the
    linker pulls in each transitive plugin's static archive.

    Args:
        name: Target name. Add to macos_application deps.
        registrant: A flutter_macos_registrant_gen target (Swift source).
        engine: A flutter_macos_engine target (FlutterMacOS.framework).
        application: A flutter_application target. Required to wire pub
            plugins' macOS Swift modules + link inputs into the runner;
            optional only for legacy Tier-2 setups with no native plugins.
        module_name: Swift module name (default "Runner").
        backend: Apple bundling backend: `"rules_apple"` (default) or
            `"xtool"` (explicit opt-in).
        **kwargs: Additional arguments passed to swift_library.
    """
    if backend not in ("rules_apple", "xtool"):
        fail("flutter_macos_runner_lib_gen: backend must be 'rules_apple' or 'xtool', got %r" % backend)
    tags = kwargs.pop("tags", ["manual"])
    internal_tags = tags if "manual" in tags else tags + ["manual"]

    deps = [engine]
    if application:
        aggregator_name = "_%s__apple_plugins_aggregator" % name
        _flutter_apple_plugins_aggregator(
            name = aggregator_name,
            application = application,
            platform = "macos",
            tags = internal_tags,
            visibility = ["//visibility:private"],
        )
        deps.append(":" + aggregator_name)

    runner_srcs = [
        registrant,
        "@rules_flutter//flutter/private/runners/macos:AppDelegate.swift",
        "@rules_flutter//flutter/private/runners/macos:MainFlutterWindow.swift",
    ]
    if backend == "rules_apple":
        swift_library(
            name = name,
            srcs = runner_srcs,
            module_name = module_name,
            tags = tags,
            deps = deps,
            **kwargs
        )
    else:
        _flutter_xtool_apple_plugin_library(
            name = name,
            srcs = runner_srcs,
            module_name = module_name,
            platform = "macos",
            deps = deps,
            tags = tags,
            **kwargs
        )

# -- Convenience macro (Tier 1) -----------------------------------------------
