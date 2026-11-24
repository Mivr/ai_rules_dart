"""Flutter plugin rule.

Declares a Flutter plugin with Dart code and platform metadata.

Platform-specific native dependencies use select() in BUILD files:

    flutter_plugin(
        name = "url_launcher",
        srcs = glob(["lib/**/*.dart"]),
        platforms = ["android", "ios", "macos", "linux", "windows", "web"],
        dart_plugin_class = "UrlLauncherPlugin",
        native_deps = select({
            "@platforms//os:linux": [":url_launcher_linux_cc"],
            "@platforms//os:windows": [":url_launcher_windows_cc"],
            "//conditions:default": [],
        }),
    )
"""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_dart//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo")
load("@rules_dart//dart:utils.bzl", "BUILD_HOOK_ATTRS", "BUILD_HOOK_FRAGMENTS", "MODULAR_KERNEL_TOOLCHAINS", "dart_info", "dart_package_identity", "declare_hooks", "derive_lib_root", "derive_package_name", "native_defines_reset", "register_hook_actions")
load("@rules_swift//swift:swift.bzl", "SwiftInfo")
load("//flutter:providers.bzl", "FlutterApplePluginInfo", "FlutterDataAssetInfo", "FlutterInfo")
load("//flutter/private:common.bzl", "collect_binding_contracts", "collect_native_libs")
load("//flutter/private:flutter_desktop_plugin_info.bzl", "FlutterLinuxPluginInfo", "FlutterWindowsPluginInfo")
load("//flutter/private:flutter_info.bzl", "LINK_HOOK_ATTR", "flutter_asset_channels", "flutter_info", "flutter_native_channels", "flutter_plugin_libraries")
load("//flutter/private:flutter_library.bzl", "SKY_ENGINE_ATTR", "flutter_analyzable_info")
load("//flutter/private:native_sources.bzl", "collect_native_source_pairs", "native_sources_aspect")

visibility(["//flutter/..."])

def build_plugin_struct(name, plugin_platforms, implements = "", direct = False):
    """Build a plugin metadata struct from per-platform metadata.

    Args:
        name: Plugin package name.
        plugin_platforms: Dict of platform -> {pluginClass, dartPluginClass, ...}.
        implements: Umbrella package name this plugin implements, or "".
        direct: Whether this plugin is a direct dependency.

    Returns:
        A struct with name, platforms dict, implements, and direct.
    """
    return struct(
        name = name,
        platforms = plugin_platforms,
        implements = implements if implements != None else "",
        direct = direct,
    )

def _apple_plugin_platform(ctx):
    """Detect the Apple platform of a `swift_library` from its constraints."""
    macos_label = ctx.attr._macos_constraint.label
    ios_label = ctx.attr._ios_constraint.label
    for constraint in getattr(ctx.rule.attr, "target_compatible_with", []):
        if constraint.label == macos_label:
            return "macos"
        if constraint.label == ios_label:
            return "ios"
    return None

def _apple_link_sdk_lists(target):
    """Collect SDK frameworks and dylibs from a target's linker flags."""
    sdk_frameworks = []
    sdk_dylibs = []
    if CcInfo in target:
        # lint-allow: depset-flatten one Apple plugin library's native link inputs, for its SDK link flags; not a Dart closure
        for li in target[CcInfo].linking_context.linker_inputs.to_list():
            flags = li.user_link_flags
            for idx in range(len(flags)):
                if flags[idx] == "-framework" and idx + 1 < len(flags):
                    fw = flags[idx + 1]
                    if fw not in sdk_frameworks:
                        sdk_frameworks.append(fw)
                elif flags[idx].startswith("-l") and len(flags[idx]) > 2:
                    dylib = flags[idx][2:]
                    if dylib not in sdk_dylibs:
                        sdk_dylibs.append(dylib)
    return sdk_frameworks, sdk_dylibs

def _apple_plugin_aspect_impl(target, ctx):
    if FlutterApplePluginInfo in target:
        return []
    if ctx.rule.kind != "swift_library":
        return []
    platform = _apple_plugin_platform(ctx)
    if not platform:
        return []
    sdk_frameworks, sdk_dylibs = _apple_link_sdk_lists(target)
    return [
        FlutterApplePluginInfo(
            module_name = getattr(ctx.rule.attr, "module_name", ""),
            platform = platform,
            swift_srcs = depset(getattr(ctx.rule.files, "srcs", [])),
            objc_srcs = depset(),
            headers = depset(),
            modulemap = None,
            sdk_frameworks = tuple(sdk_frameworks),
            sdk_dylibs = tuple(sdk_dylibs),
        ),
    ]

_apple_plugin_aspect = aspect(
    implementation = _apple_plugin_aspect_impl,
    attrs = {
        "_ios_constraint": attr.label(
            doc = "iOS platform constraint value, matched against the owning target to detect its Apple platform.",
            default = "@platforms//os:ios",
        ),
        "_macos_constraint": attr.label(
            doc = "macOS platform constraint value, matched against the owning target to detect its Apple platform.",
            default = "@platforms//os:macos",
        ),
    },
    doc = "Collects Apple plugin info from the `swift_library` targets a plugin owns.",
)

def _plugin_platforms_and_implements(ctx):
    """Decode the plugin's per-platform metadata and implements from its attrs.

    Args:
        ctx: Rule context.

    Returns:
        Tuple of (platforms_dict, implements_string).
    """
    if ctx.attr.plugin_platforms_json:
        data = json.decode(ctx.attr.plugin_platforms_json)
        implements = ""
        if type(data) == "dict":
            if "__implements__" in data and type(data["__implements__"]) == "string":
                implements = data.pop("__implements__")
            elif "implements" in data and type(data["implements"]) == "string":
                implements = data.pop("implements")
        return data, implements
    plugin_platforms = {}
    for p in ctx.attr.platforms:
        info = {}
        if ctx.attr.plugin_class:
            info["pluginClass"] = ctx.attr.plugin_class
        if ctx.attr.dart_plugin_class:
            info["dartPluginClass"] = ctx.attr.dart_plugin_class
        if p == "android" and ctx.attr.android_package:
            info["package"] = ctx.attr.android_package
        plugin_platforms[p] = info
    return plugin_platforms, ""

def _collect_native_lib_sources(ctx):
    """Pair native libraries with the sources their bindings were generated from."""
    return collect_native_source_pairs(ctx.attr.native_deps)

def _collect_extra_apple_libraries(libs, platform, package_name, attr_name):
    """Collect one `apple_libs`/`macos_libs`/`ios_libs` attr into extra-library structs."""
    entries = []
    for lib in libs:
        info = lib[FlutterApplePluginInfo] if FlutterApplePluginInfo in lib else None
        if attr_name == "apple_libs":
            if info == None:
                fail(
                    "flutter_plugin: apple_libs entry %s must provide FlutterApplePluginInfo " % lib.label +
                    "(use flutter_apple_plugin_library, or pass platform libraries via macos_libs / ios_libs).",
                )
            platform_name = info.platform
            if platform_name not in ("macos", "ios"):
                fail(
                    "flutter_plugin: apple_libs entry %s has invalid FlutterApplePluginInfo.platform %r " % (
                        lib.label,
                        platform_name,
                    ) + "(expected 'macos' or 'ios').",
                )
        else:
            if info != None and info.platform not in ("", platform):
                fail(
                    "flutter_plugin: %s entry %s has FlutterApplePluginInfo.platform = %r, expected '%s'." % (
                        attr_name,
                        lib.label,
                        info.platform,
                        platform,
                    ),
                )
            platform_name = platform
        entries.append(struct(
            platform = platform_name,
            label = lib.label,
            cc_info = lib[CcInfo] if CcInfo in lib else None,
            swift_info = lib[SwiftInfo] if SwiftInfo in lib else None,
            files = lib[DefaultInfo].files,
            sdk_frameworks = tuple(info.sdk_frameworks) if info != None else (),
            sdk_dylibs = tuple(info.sdk_dylibs) if info != None else (),
            framework_infos = getattr(info, "framework_infos", depset()),
            package = package_name,
        ))
    return entries

def _extra_apple_plugin_libraries(ctx, package_name):
    """Collect the `apple_libs`, `macos_libs` and `ios_libs` channels."""
    return (
        _collect_extra_apple_libraries(ctx.attr.apple_libs, "", package_name, "apple_libs") +
        _collect_extra_apple_libraries(ctx.attr.macos_libs, "macos", package_name, "macos_libs") +
        _collect_extra_apple_libraries(ctx.attr.ios_libs, "ios", package_name, "ios_libs")
    )

def _collect_desktop_plugin_libraries(libs, provider, provider_name, rule_name, attr_name, package_name):
    """Collect one `linux_libs`/`windows_libs` attr into source-bundle structs."""
    entries = []
    for lib in libs:
        if provider not in lib:
            fail("flutter_plugin: %s entry %s must provide %s (use %s)." % (attr_name, lib.label, provider_name, rule_name))
        info = lib[provider]
        entries.append(struct(
            label = lib.label,
            srcs = info.srcs,
            hdrs = info.hdrs,
            include_dirs = info.include_dirs,
            package = package_name,
        ))
    return entries

def _extra_linux_plugin_libraries(ctx, package_name):
    return _collect_desktop_plugin_libraries(
        ctx.attr.linux_libs,
        FlutterLinuxPluginInfo,
        "FlutterLinuxPluginInfo",
        "flutter_linux_plugin_library",
        "linux_libs",
        package_name,
    )

def _extra_windows_plugin_libraries(ctx, package_name):
    return _collect_desktop_plugin_libraries(
        ctx.attr.windows_libs,
        FlutterWindowsPluginInfo,
        "FlutterWindowsPluginInfo",
        "flutter_windows_plugin_library",
        "windows_libs",
        package_name,
    )

def _collect_plugin_asset_infos(assets, provider, provider_name, rule_name, attr_name):
    """Collect one `data_assets` attr into provider structs."""
    infos = []
    for dep in assets:
        if provider not in dep:
            fail(
                "flutter_plugin: %s entry %s must provide " % (attr_name, dep.label) +
                "%s (use %s)." % (provider_name, rule_name),
            )
        infos.append(dep[provider])
    return infos

def _extra_data_assets(ctx):
    return _collect_plugin_asset_infos(
        ctx.attr.data_assets,
        FlutterDataAssetInfo,
        "FlutterDataAssetInfo",
        "flutter_data_asset",
        "data_assets",
    )

def _check_plugin_resources(ctx):
    """Reject Dart sources mis-filed under `resources` instead of `srcs`."""
    for f in ctx.files.resources:
        if f.extension == "dart":
            fail(
                ("%s: `%s` is a Dart source in `resources`. `resources` names " +
                 "the non-Dart remainder of `lib/`; Dart sources belong in " +
                 "`srcs`.") % (ctx.label, f.short_path),
            )

def _plugin_dart_infos(ctx, package_name, lib_root):
    """The Dart-channel providers of a plugin: files, `dart_info`, analyzable info.

    A plugin's build hook runs as a `flutter_library`'s does.
    """
    hooks = declare_hooks(ctx, ctx.files.srcs, ctx.files.resources)
    info = dart_info(
        label = ctx.label,
        package = dart_package_identity(
            package_name = package_name,
            lib_root = lib_root,
            language_version = ctx.attr.language_version,
            version = ctx.attr.version,
            package_files = ctx.files.data,
        ),
        deps = ctx.attr.deps,
        srcs = ctx.files.srcs,
        resources = ctx.files.resources,
        code_assets = ctx.attr.code_assets,
        link_hook = ctx.file.link_hook,
        hooks = hooks,
    )
    register_hook_actions(ctx, hooks, info.owned_packages[0], [dep[DartInfo] for dep in ctx.attr.deps])
    return [
        DefaultInfo(files = depset(ctx.files.srcs + ctx.files.resources)),
        info,
        flutter_analyzable_info(ctx, package_name, lib_root),
    ]

def _plugin_flutter_info(ctx, package_name, plugin, extra):
    """The `FlutterInfo` provider aggregating every channel the plugin adds to."""
    return flutter_info(
        deps = ctx.attr.deps,
        plugins = [plugin],
        asset_channels = flutter_asset_channels(
            apple_privacy_manifests = extra.privacy,
        ),
        plugin_libraries = flutter_plugin_libraries(
            apple_plugin_libraries = extra.apple,
            linux_plugin_libraries = extra.linux,
            windows_plugin_libraries = extra.windows,
        ),
        native_channels = flutter_native_channels(
            native_libs = extra.native_libs,
            native_lib_sources = extra.native_lib_sources,
            binding_contracts = extra.binding_contracts,
            data_assets = extra.data_assets,
        ),
    )

def _flutter_plugin_impl(ctx):
    package_name = derive_package_name(ctx.attr.package_name, ctx.label.package, ctx.label.name)
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)

    # Build plugin metadata.
    # If plugin_platforms_json is set, decode it directly.
    # Otherwise construct from scalar attrs (for manual BUILD files).
    plugin_platforms, implements = _plugin_platforms_and_implements(ctx)
    plugin = build_plugin_struct(
        name = package_name,
        plugin_platforms = plugin_platforms,
        implements = implements,
    )

    # Collect native libs from native_deps.
    native_libs = collect_native_libs(ctx.attr.native_deps)

    # And what their bindings were generated from, for the ones whose build said
    # so. Carried to the app rather than used here: a plugin bundles nothing, and
    # the app is where the dev config that a reload reads is written.
    binding_contracts = collect_binding_contracts(ctx.attr.native_deps)

    # `native_deps` and the Native Assets alike: an asset's own rule pairs the
    # library it declares with its sources, on its `FlutterInfo`.
    native_lib_sources = _collect_native_lib_sources(ctx)

    # Pull CcInfo + SwiftInfo from the per-platform Apple plugin libraries
    # so the runner aggregator can merge them into the runner's
    # swift_library compilation/link inputs. Targets in `apple_libs`
    # declare their target platform via `FlutterApplePluginInfo.platform`
    # (produced by `flutter_apple_plugin_library`), while `macos_libs` and
    # `ios_libs` accept platform-specific `CcInfo`/`SwiftInfo` targets
    # directly. Set `apple_libs` via `select()` on the target platform so
    # only one platform's swift_library analyzes per build.
    extra_apple_plugin_libraries = _extra_apple_plugin_libraries(ctx, package_name)

    # Pull source bundles from linux + windows plugin libraries so the
    # corresponding runner can fold them into its compile.
    extra_linux_plugin_libraries = _extra_linux_plugin_libraries(ctx, package_name)
    extra_windows_plugin_libraries = _extra_windows_plugin_libraries(ctx, package_name)

    extra_data_assets = _extra_data_assets(ctx)

    extra_apple_privacy_manifests = list(ctx.files.apple_privacy_files)

    # `resources` names the non-Dart remainder of `lib/`; a Dart source there
    # is a mis-filed `srcs` entry, and identical paths with identical
    # extensions would otherwise collide silently. Mirrors `dart_library`.
    _check_plugin_resources(ctx)

    # A plugin contributes on more channels than a library does, but the shape
    # is the same: name what this target adds, and let each constructor merge
    # the dependencies.
    extra = struct(
        native_libs = native_libs,
        binding_contracts = binding_contracts,
        native_lib_sources = native_lib_sources,
        apple = extra_apple_plugin_libraries,
        linux = extra_linux_plugin_libraries,
        windows = extra_windows_plugin_libraries,
        privacy = extra_apple_privacy_manifests,
        data_assets = extra_data_assets,
    )
    return _plugin_dart_infos(ctx, package_name, lib_root) + [_plugin_flutter_info(ctx, package_name, plugin, extra)]

# Without a build hook; a hook's actions are rules_dart's, tested there.
# rule_test_coverage: no-actions
flutter_plugin = rule(
    implementation = _flutter_plugin_impl,
    attrs = {
        "_sky_engine": SKY_ENGINE_ATTR,
        "srcs": attr.label_list(
            doc = "Dart source files for the plugin's public API.",
            allow_files = [".dart"],
        ),
        "deps": attr.label_list(
            doc = "Dart/Flutter library dependencies.",
            providers = [DartInfo],
        ),
        "data": attr.label_list(
            doc = "The package's own files outside `lib/`: its `pubspec.yaml`, its licence, and " +
                  "the files its pubspec names (assets, fonts, shaders), which an app's asset " +
                  "bundle reads as `flutter build` does. Runtime-only.",
            allow_files = True,
        ),
        "resources": attr.label_list(
            doc = "Non-Dart files this package ships inside `lib/` — part of its published surface, but never compiled (a web plugin's bundled JS/wasm, templates, YAML). Anything under `lib/` is addressable as `package:<name>/<path>` whatever its extension, so these are members of the package: they ride `DartInfo.transitive_resources` and are staged wherever the whole package is staged, mirroring `dart_library`. `.dart` files belong in `srcs`.",
            allow_files = True,
        ),
        "package_name": attr.string(
            doc = "The Dart package name. If omitted, derived from label.",
        ),
        "platforms": attr.string_list(
            doc = "Platforms this plugin supports (android, ios, macos, linux, windows, web).",
        ),
        "plugin_class": attr.string(
            doc = "Native plugin class name (for platform channel registration).",
        ),
        "android_package": attr.string(
            doc = "Java package of the Android `plugin_class`, as " +
                  "`flutter.plugin.platforms.android.package` in a pubspec. " +
                  "Required when `platforms` lists android with a " +
                  "`plugin_class`. Its Kotlin/Java is built from the plugin's " +
                  "own Android project (`android/`), as part of the Gradle " +
                  "model of the app that depends on it.",
        ),
        "dart_plugin_class": attr.string(
            doc = "Dart-only plugin class name (for Dart-side registration).",
        ),
        "plugin_platforms_json": attr.string(
            doc = "JSON-encoded per-platform metadata dict. Overrides platforms/plugin_class/dart_plugin_class if set.",
        ),
        # Every attribute that leaves Dart for native code takes `native_defines_reset`: native code is configured
        # once, whatever environment the application's Dart modules compile with.
        "native_deps": attr.label_list(
            doc = "Native dependencies. Use select() for platform-conditional deps.",
            aspects = [native_sources_aspect],
            cfg = native_defines_reset,
        ),
        "code_assets": attr.label_list(
            doc = "`dart_code_asset` targets: native libraries this package " +
                  "owns that Bazel builds (a `cc_shared_library`) rather than " +
                  "a build hook. Declared on the owning package rather than on " +
                  "the consuming application so they propagate the way a " +
                  "hook's do — depending on the package is enough.",
            providers = [DartCodeAssetInfo],
            cfg = native_defines_reset,
        ),
        "version": attr.string(
            doc = "The package's own version, as resolved by pub (e.g. `2.2.0`). " +
                  "Set automatically by the generated pub spokes; leave it empty on " +
                  "hand-written targets, which have no resolved version to state. " +
                  "Mirrors `dart_library`'s attribute, and has its one use: when a " +
                  "single package name arrives from two hubs, two records stating " +
                  "different versions fail the build instead of the first one " +
                  "silently standing in for the second. An empty version never " +
                  "conflicts.",
        ),
        "link_hook": LINK_HOOK_ATTR,
        "language_version": attr.string(
            doc = "Dart language version (`<major>.<minor>`) for this package's `package_config.json` entry. Mirrors `dart_library`'s attribute. Empty string means defer to the toolchain default.",
        ),
        "apple_libs": attr.label_list(
            doc = "Per-platform Apple plugin libraries (`flutter_apple_plugin_library`) carrying the plugin's macOS / iOS native code and `FlutterApplePluginInfo` provider. Set this via `select()` on the target platform so only one platform's library analyzes per build — both with the same module name in the same configuration would conflict on the produced `<module>.swiftmodule` output.",
            aspects = [_apple_plugin_aspect],
            providers = [CcInfo],
            cfg = native_defines_reset,
        ),
        "macos_libs": attr.label_list(
            doc = "macOS Apple plugin libraries providing `CcInfo` (and optionally `SwiftInfo`). Routed to the macOS runner aggregator.",
            providers = [CcInfo],
            cfg = native_defines_reset,
        ),
        "ios_libs": attr.label_list(
            doc = "iOS Apple plugin libraries providing `CcInfo` (and optionally `SwiftInfo`). Routed to the iOS runner aggregator.",
            providers = [CcInfo],
            cfg = native_defines_reset,
        ),
        "linux_libs": attr.label_list(
            doc = "Linux plugin source bundles (`flutter_linux_plugin_library`). Propagated through `FlutterInfo.linux_plugin_libraries` so the Linux runner folds them into its `cc_common.compile()` pass.",
            providers = [FlutterLinuxPluginInfo],
            cfg = native_defines_reset,
        ),
        "windows_libs": attr.label_list(
            doc = "Windows plugin source bundles (`flutter_windows_plugin_library`). Propagated through `FlutterInfo.windows_plugin_libraries` so the Windows runner folds them into its `cc_common.compile()` pass.",
            providers = [FlutterWindowsPluginInfo],
            cfg = native_defines_reset,
        ),
        "data_assets": attr.label_list(
            doc = "Native Assets `DataAsset` declarations (each a `flutter_data_asset` target). Propagated through `FlutterInfo.data_assets` and bundled at `flutter_assets/packages/<pkg>/<name>` by `flutter_application`.",
            providers = [FlutterDataAssetInfo],
            cfg = native_defines_reset,
        ),
        "apple_privacy_files": attr.label_list(
            doc = "`PrivacyInfo.xcprivacy` files this plugin contributes to the iOS / macOS app bundle. Apple requires every framework to ship a privacy manifest since iOS 17.4 / macOS 14.4; the App Store submission validator walks the bundle and aggregates them. Propagated through `FlutterInfo.apple_privacy_manifests` and threaded into the platform application bundle's `Resources/<pkg>/PrivacyInfo.xcprivacy` slot. Auto-detected by `flutter_pub_package` from both layouts pub plugins use (`Sources/<pkg>/PrivacyInfo.xcprivacy` and `Sources/<pkg>/Resources/PrivacyInfo.xcprivacy`).",
            allow_files = [".xcprivacy"],
        ),
    } | BUILD_HOOK_ATTRS,
    # The Dart exec tools are the build hook's.
    toolchains = MODULAR_KERNEL_TOOLCHAINS,
    fragments = BUILD_HOOK_FRAGMENTS,
    doc = "Declares a Flutter plugin with platform metadata and optional native dependencies.",
)
