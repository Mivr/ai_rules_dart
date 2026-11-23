"""Flutter integration test rule.

Compiles a Flutter application together with an in-app integration test
entrypoint (`package:integration_test` / `package:flutter_test` `WidgetTester`
code) for the target platform and runs it end-to-end under a platform runner.

For `platform = "web"`:
  1. Generates `<name>_bootstrap.dart` which initializes the live integration
     test binding (`IntegrationTestWidgetsFlutterBinding` when
     `package:integration_test` is in `deps`, or a built-in
     `LiveTestWidgetsFlutterBinding` subclass otherwise), connects back to the
     host runner over a WebSocket (`/__flutter_integration_ws__`), and drives
     the suite via `package:test_api/backend.dart` `RemoteListener`.
  2. Wraps `<name>_bootstrap.dart` in the standard Flutter web engine bootstrap
     (`ui_web.bootstrapEngine`) and compiles the whole app + test to JS/WASM
     with local CanvasKit/Skwasm and bundled `flutter_assets/`.
  3. Runs `flutter_integration_test_runner`, which serves the built web bundle
     over `http://127.0.0.1:<ephemeral>`, launches the hermetic pinned
     `chrome-headless-shell` binary with its pinned shared-library closure, and
     collects test results and any uncaught errors.

For `platform = "linux"`:
  1. Generates `<name>_linux_bootstrap.dart` which initializes the live
     integration test binding, connects back to the host runner over the
     WebSocket URL in `FLUTTER_INTEGRATION_TEST_HARNESS_URL`, and drives the
     suite via `RemoteListener`.
  2. Compiles the app + test to a kernel `.dill` (and in non-debug modes AOT
     `libapp.so`), compiles the C++ GTK runner + native C++ plugin registrant +
     Linux plugin C++ sources against the hermetic Chromium sysroot, and
     assembles the `<name>_linux` desktop bundle directory.
  3. Runs `flutter_integration_test_runner`, which starts the hermetic pinned
     `Xvfb` virtual display (`-displayfd`), launches the compiled Linux desktop
     application against that display and the pinned GTK3/Mesa/EGL/GLib runtime
     shared-library closure, and collects test results and any uncaught errors.

For `platform = "android"`:
  1. Generates `<name>_android_bootstrap.dart` which initializes the live
     integration test binding, connects back to the host runner over a localhost
     WebSocket forwarded into the emulator via `adb reverse`, and drives the
     suite via `RemoteListener`.
  2. Compiles the app + test to a kernel `.dill` (and in non-debug modes AOT
     `libapp.so`) for `android_x64`, generates `GeneratedPluginRegistrant.java`,
     compiles transitive Android plugin libraries, and packages a real signed
     Android APK via `android_binary`.
  3. Runs `flutter_integration_test_runner`, which boots the hermetic pinned
     Android emulator (`x86_64` API 35 `aosp_atd`) headless with KVM and
     SwiftShader, sets up `adb reverse`, installs and launches the APK, monitors
     for crashes/ANRs, and collects test results and any uncaught errors.
"""

load(
    "@rules_dart//dart:providers.bzl",
    "DartInfo",
)
load(
    "@rules_dart//dart:utils.bzl",
    "derive_lib_root",
)
load(
    "//flutter/private:app_entrypoint.bzl",
    "app_main_location",
)
load(
    "//flutter/private:common.bzl",
    "FLUTTER_DEPS_DOC",
)
load(
    "//flutter/private:flutter_integration_test_android.bzl",
    "declare_android_integration_test",
)
load(
    "//flutter/private:flutter_integration_test_bootstrap.bzl",
    "make_linux_integration_bootstrap_content",
)
load(
    "//flutter/private:flutter_integration_test_ios.bzl",
    "assemble_ios_integration_test",
    "exposes_package",
    "ios_integration_bootstrap_substitutions",
    "resolve_main_and_srcs",
)
load(
    "//flutter/private:flutter_integration_test_linux.bzl",
    "linux_integration_test_rule",
)
load(
    "//flutter/private:flutter_integration_test_web.bzl",
    "web_integration_test_rule",
)

visibility(["//flutter/..."])

# The iOS bootstrap shares the Linux bootstrap's shape (a JIT build with
# dart:io available, driven via `RemoteListener`), but not its harness-URL
# read: on iOS `Platform.environment` is always empty, so the iOS bootstrap
# expands the same Linux template with the iOS prologue chosen by
# `ios_integration_bootstrap_substitutions`
# (`flutter_integration_test_ios.bzl`, where iOS-only code lives): the
# data-container file fallback and the flushed failure. The Linux generator
# itself is unchanged.
def _flutter_ios_integration_bootstrap_impl(ctx):
    if not exposes_package(ctx.attr.deps, ["flutter_test"]):
        fail((
            "flutter_integration_test target {name} must depend on " +
            "package:flutter_test. Add `@<hub>//:flutter_test` to deps."
        ).format(name = ctx.label.name))

    main_file, _extra_srcs = resolve_main_and_srcs(ctx)
    package_name = ctx.attr.package_name or ctx.label.name
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)
    main_location = app_main_location(package_name, lib_root, main_file)
    has_integration_test = exposes_package(ctx.attr.deps, ["integration_test"])
    bootstrap = ctx.actions.declare_file(ctx.label.name + ".dart")
    ctx.actions.expand_template(
        template = ctx.file._bootstrap_template,
        output = bootstrap,
        substitutions = ios_integration_bootstrap_substitutions(
            make_linux_integration_bootstrap_content(
                test_import = main_location.uri,
                has_integration_test = has_integration_test,
            ),
        ),
    )
    return [DefaultInfo(files = depset([bootstrap]))]

flutter_ios_integration_bootstrap = rule(
    implementation = _flutter_ios_integration_bootstrap_impl,
    attrs = {
        "main": attr.label(
            doc = "The integration test .dart entry point. Optional when `srcs` " +
                  "contains a single `.dart` file.",
            allow_single_file = [".dart"],
        ),
        "srcs": attr.label_list(
            doc = "Integration test Dart source files.",
            allow_files = [".dart"],
        ),
        "app_srcs": attr.label_list(
            doc = "Dart source files for the application under test (e.g. `[\"lib/main.dart\"]`).",
            allow_files = [".dart"],
        ),
        "package_name": attr.string(
            doc = "Dart package name (from pubspec.yaml). Defaults to target name.",
        ),
        "deps": attr.label_list(
            doc = FLUTTER_DEPS_DOC,
            providers = [DartInfo],
        ),
        "_bootstrap_template": attr.label(
            default = Label("//flutter/private/integration_test_bootstrap:linux_bootstrap.dart.tpl"),
            allow_single_file = True,
            doc = "The shared Linux bootstrap program expanded with the iOS harness-URL prologue.",
        ),
    },
    doc = "Resolves the integration test entrypoint and writes its iOS bootstrap.",
)

def _merge_integration_test_deps(deps, app_deps, app):
    """The caller's test deps plus `app_deps` and `app`, without duplicates.

    Args:
        deps: The caller's `deps`.
        app_deps: Extra app dependencies.
        app: An optional app library target.

    Returns:
        The merged dependency list.
    """
    merged_deps = list(deps)
    for extra in list(app_deps) + ([app] if app != None else []):
        if extra not in merged_deps:
            merged_deps.append(extra)
    return merged_deps

def _ios_integration_test(name, package_name, deps, ios_bundle_id, ios_runner_srcs, ios_info_plist, kwargs):
    """Declares the iOS bootstrap and simulator test targets.

    Args:
        name: The test target's name.
        package_name: The resolved Dart package name.
        deps: The merged dependencies.
        ios_bundle_id: Optional explicit bundle ID.
        ios_runner_srcs: Optional Runner Swift sources.
        ios_info_plist: Optional `Info.plist` override.
        kwargs: The macro's extra attributes.
    """
    helper_tags = ["manual"]
    flutter_ios_integration_bootstrap(
        name = "__%s_bootstrap" % name,
        package_name = package_name,
        deps = deps,
        main = kwargs.get("main"),
        srcs = kwargs.get("srcs", []),
        app_srcs = kwargs.get("app_srcs", []),
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )
    assemble_ios_integration_test(
        name = name,
        package_name = package_name,
        deps = deps,
        ios_bundle_id = ios_bundle_id,
        ios_runner_srcs = ios_runner_srcs,
        ios_info_plist = ios_info_plist,
        platform = "ios",
        bootstrap = ":__%s_bootstrap" % name,
        **kwargs
    )

def flutter_integration_test(
        name,
        package_name = "",
        deps = [],
        app_deps = [],
        app = None,
        platform = "web",
        android_package = "",
        android_deps = [],
        pub_hub_name = None,
        ios_bundle_id = "",
        ios_runner_srcs = None,
        ios_info_plist = None,
        **kwargs):
    """Builds and runs an end-to-end Flutter integration test on a real platform.

    Compiles the application and the integration test (`WidgetTester` code) into
    a real platform bundle and drives it via the platform runner. On `web`, the
    built web bundle is served from `127.0.0.1` and executed inside a hermetic,
    pinned `chrome-headless-shell` browser. On `linux`, the built GTK desktop
    bundle is executed inside a hermetic, pinned `Xvfb` virtual display with
    pinned GTK3 and Mesa software OpenGL/EGL libraries. On `android`, the built
    Android APK is installed and executed inside a hermetic, pinned headless
    Android `x86_64` emulator accelerated with KVM. On `ios`, the built
    simulator-debug app is installed and executed on an iOS simulator from the
    macOS host (needs a macOS host with Xcode, a simulator runtime, and the
    package's `ios/Runner` sources).

    Args:
        name: Name of the integration test target that this macro defines.
        package_name: Dart package name (from `pubspec.yaml`). Defaults to `name`.
        deps: Dependencies (`dart_library` / `flutter_library`) for the test and app.
        app_deps: Optional additional dependencies for the app, merged with `deps`.
        app: Optional library target for the app under test, merged with `deps`.
        platform: Target platform (`"web"`, `"linux"`, `"android"`, or `"ios"`, defaults to `"web"`).
        android_package: Optional Android application ID when `platform = "android"`.
            Defaults to `"com.example.<package_name>"`.
        android_deps: Optional additional Android library targets (`kt_android_library`,
            `android_library`, `flutter_android_plugin_library`) when `platform = "android"`.
            Workspace plugins that set `android_libs` on `flutter_plugin` are
            collected automatically from `deps`.
        pub_hub_name: Optional `flutter.pub` hub name (e.g. `"deps"`) whose
            `@<pub_hub_name>//android:all_android_plugin_libs` aggregator should
            be linked when `platform = "android"`.
        ios_bundle_id: Optional iOS bundle ID when `platform = "ios"`.
            Used verbatim when set. Defaults to
            `"com.example.<package path>.<name>.<label hash>"`, where the
            hash covers the test target's full label, so two tests never
            share an id; pass `ios_bundle_id` to keep a fixed id. The test
            runs with the `exclusive` tag (merged with `tags`), so Bazel
            never runs two simulator tests at once.
        ios_runner_srcs: Optional Runner Swift sources when `platform = "ios"`.
            Defaults to `None`, which discovers the package's
            `ios/Runner/*.swift`.
        ios_info_plist: Optional `Info.plist` override when `platform = "ios"`.
            Defaults to `None`, which preprocesses the package's
            `ios/Runner/Info.plist`.
        **kwargs: Additional attributes forwarded to the rule (`main`, `srcs`,
            `app_srcs`, `assets`, `shaders`, `compiler`, `renderer`,
            `native_deps`, `defines`, `data`, `env`, etc.). With
            `platform = "android"`, `defines_files` (`.json` / `.env` files of Dart
            defines) is also accepted and reaches the app the test builds.
    """
    merged_deps = _merge_integration_test_deps(deps, app_deps, app)
    resolved_package_name = package_name or name

    if platform == "android":
        declare_android_integration_test(
            name = name,
            package_name = resolved_package_name,
            deps = merged_deps,
            android_package = android_package,
            android_deps = android_deps,
            pub_hub_name = pub_hub_name,
            kwargs = kwargs,
        )
    elif platform == "ios":
        _ios_integration_test(
            name = name,
            package_name = resolved_package_name,
            deps = merged_deps,
            ios_bundle_id = ios_bundle_id,
            ios_runner_srcs = ios_runner_srcs,
            ios_info_plist = ios_info_plist,
            kwargs = kwargs,
        )
    elif platform == "linux":
        linux_integration_test_rule(
            name = name,
            package_name = resolved_package_name,
            deps = merged_deps,
            platform = platform,
            **kwargs
        )
    else:
        web_integration_test_rule(
            name = name,
            package_name = resolved_package_name,
            deps = merged_deps,
            platform = platform,
            **kwargs
        )
