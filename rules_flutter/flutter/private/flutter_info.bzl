"""The `FlutterInfo` constructor.

`FlutterInfo` is built by several rules — `flutter_library`, `flutter_plugin`,
and `flutter_data_asset`.
Construction goes through here so no caller decides how a field merges: a rule
that does not contribute on a channel must still forward its dependencies'
values, and writing `depset()` instead silently drops them.

Reading does not go through here: `FlutterInfo` stays public and is indexed
directly by every consumer.

This mirrors `dart_info()` in rules_dart, deliberately — the two providers
travel together and a reader who has understood one should recognise the other.
The one structural difference is that `DartInfo` always records a package of
its own, so it needs a second constructor for the degenerate case, while every
`FlutterInfo` channel is optional by nature. Contributing on none of them is an
ordinary call with no arguments, not a special one.
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "owned_package_records")
load("//flutter:providers.bzl", "FlutterInfo")

visibility(["//flutter/..."])

def _merge_depsets(dep_infos, direct, field):
    """Merges one plain depset channel: this target's files over its dependencies'."""
    return depset(direct = direct, transitive = [getattr(info, field) for info in dep_infos])

def flutter_asset_channels(apple_privacy_manifests = []):
    """Groups what a target contributes to the bundled-file channels.

    One of the parameter objects `flutter_info()` takes. What an app's asset
    bundle holds is read from the pubspecs, not carried here.

    Args:
      apple_privacy_manifests: `PrivacyInfo.xcprivacy` files this target ships.

    Returns:
      A struct carrying the channel above.
    """
    return struct(
        apple_privacy_manifests = apple_privacy_manifests,
    )

def flutter_plugin_libraries(
        apple_plugin_libraries = [],
        android_plugin_libraries = [],
        linux_plugin_libraries = [],
        windows_plugin_libraries = []):
    """Groups what a target contributes to the per-platform plugin channels.

    One channel per platform rather than one tagged union, because the
    integration mechanisms genuinely differ: Apple carries compiled
    `CcInfo`/`SwiftInfo` to link against, Android carries `JavaInfo` and
    resource manifests, Linux and Windows carry source bundles their runner
    folds into its own compile. Apple multiplexes macOS and iOS in one channel
    precisely because those two do share a mechanism.

    Args:
      apple_plugin_libraries: Apple plugin library structs this target declares
        (`platform`, `label`, `cc_info`, `swift_info`, `package`).
      android_plugin_libraries: Android plugin library structs this target
        declares (`label`, `java_info`, `resources_info`, `package`).
      linux_plugin_libraries: Linux plugin source bundles this target declares
        (`label`, `srcs`, `hdrs`, `include_dirs`, `package`).
      windows_plugin_libraries: Windows plugin source bundles, same shape.

    Returns:
      A struct carrying the four channels above.
    """
    return struct(
        apple_plugin_libraries = apple_plugin_libraries,
        android_plugin_libraries = android_plugin_libraries,
        linux_plugin_libraries = linux_plugin_libraries,
        windows_plugin_libraries = windows_plugin_libraries,
    )

def flutter_native_channels(
        native_libs = [],
        native_lib_sources = [],
        binding_contracts = [],
        data_assets = []):
    """Groups what a target contributes to the native-code channels.

    Args:
      native_libs: Shared libraries this target contributes, typically from a
        plugin's `native_deps`.
      native_lib_sources: `struct(library, sources)` pairs this target
        contributes — the first-party sources each of its native libraries is
        built from.
      binding_contracts: `struct(library, contract)` pairs this target
        contributes, one per `flutter_native_library` in its `native_deps`.
      data_assets: `FlutterDataAssetInfo` providers this target declares.

    Returns:
      A struct carrying the four channels above.
    """
    return struct(
        native_libs = native_libs,
        native_lib_sources = native_lib_sources,
        binding_contracts = binding_contracts,
        data_assets = data_assets,
    )

def _merge_asset_channels(dep_infos, channels):
    """Merges one `flutter_asset_channels` over its dependencies' contributions."""
    return struct(
        apple_privacy_manifests = depset(
            direct = channels.apple_privacy_manifests,
            transitive = [info.apple_privacy_manifests for info in dep_infos],
        ),
    )

def _merge_plugin_libraries(dep_infos, channels):
    """Merges one `flutter_plugin_libraries` over its dependencies' contributions."""
    return struct(
        apple_plugin_libraries = depset(
            direct = channels.apple_plugin_libraries,
            transitive = [info.apple_plugin_libraries for info in dep_infos],
        ),
        android_plugin_libraries = depset(
            direct = channels.android_plugin_libraries,
            transitive = [info.android_plugin_libraries for info in dep_infos],
        ),
        linux_plugin_libraries = depset(
            direct = channels.linux_plugin_libraries,
            transitive = [info.linux_plugin_libraries for info in dep_infos],
        ),
        windows_plugin_libraries = depset(
            direct = channels.windows_plugin_libraries,
            transitive = [info.windows_plugin_libraries for info in dep_infos],
        ),
    )

def _merge_native_channels(dep_infos, channels):
    """Merges one `flutter_native_channels` over its dependencies' contributions."""
    return struct(
        transitive_native_libs = _merge_depsets(dep_infos, channels.native_libs, "transitive_native_libs"),
        native_lib_sources = _merge_depsets(dep_infos, channels.native_lib_sources, "native_lib_sources"),
        binding_contracts = _merge_depsets(dep_infos, channels.binding_contracts, "binding_contracts"),
        data_assets = depset(
            direct = channels.data_assets,
            transitive = [info.data_assets for info in dep_infos],
        ),
    )

def _copy_plugin_with_direct(p, direct):
    """Copies a plugin struct with an updated direct flag."""
    return struct(
        name = p.name,
        platforms = p.platforms,
        implements = getattr(p, "implements", ""),
        direct = direct,
        _depth = getattr(p, "_depth", 0),
    )

def _copy_plugin_with_depth(p, depth):
    """Copies a plugin struct with an updated depth value."""
    return struct(
        name = p.name,
        platforms = p.platforms,
        implements = getattr(p, "implements", ""),
        direct = getattr(p, "direct", False),
        _depth = depth,
    )

def _is_pub_package(dep):
    """Whether `dep` is a third-party pub package rather than app-owned code.

    The generated pub spokes state the version pub resolved on every package
    record they build; a hand-written target states none. A merged
    multi-package target is a pub package when any package it owns is.

    Args:
        dep: A dependency target.

    Returns:
        True when `dep` owns a package record that states a version.
    """
    if DartInfo not in dep:
        return False
    for record in owned_package_records(dep[DartInfo]):
        if getattr(record, "version", ""):
            return True
    return False

def _is_direct_plugin(is_plugin_target, is_pub_package, p):
    """Determines whether a plugin struct should be marked direct.

    Flutter counts only the dependencies of the application's own pubspec. A
    plugin is direct when the dependency is that plugin itself, or when it is a
    library the application owns that depends on the plugin. The plugin
    dependencies of a third-party pub package never make a plugin direct.

    Args:
        is_plugin_target: Whether the dependency is itself a plugin.
        is_pub_package: Whether the dependency is a third-party pub package.
        p: The plugin struct, with its depth relative to the dependency.

    Returns:
        True when the plugin is direct.
    """
    if getattr(p, "direct", False):
        return True
    depth = getattr(p, "_depth", 0)
    if is_plugin_target:
        return depth == 0
    if is_pub_package:
        return False
    return depth == 1

def dedup_plugins(all_plugins):
    """Deduplicates plugin structs by name, keeping first occurrence.

    A plugin reached through two paths in the dependency graph — the common
    case for a federated pub plugin — must be registered once. Deduplication
    never loses the direct mark and keeps the shallowest depth over all paths,
    so the result does not depend on the order the paths are listed in.

    Args:
        all_plugins: List of plugin structs.

    Returns:
        List of unique plugin structs, in first-seen order.
    """
    seen = {}
    unique = []
    for p in all_plugins:
        if p.name not in seen:
            seen[p.name] = len(unique)
            unique.append(p)
            continue
        idx = seen[p.name]
        merged = unique[idx]
        if getattr(p, "_depth", 0) < getattr(merged, "_depth", 0):
            merged = _copy_plugin_with_depth(merged, getattr(p, "_depth", 0))
        if getattr(p, "direct", False) and not getattr(merged, "direct", False):
            merged = _copy_plugin_with_direct(merged, True)
        unique[idx] = merged
    return unique

def collect_flutter_plugin_deps(deps):
    """Collects the plugin sets `deps` propagate on `FlutterInfo`.

    An application and a platform integration-test rule both read the same
    channels off their dependencies; collecting them here keeps one definition
    of what a plugin dependency contributes.

    Args:
        deps: Targets that may provide `FlutterInfo`.

    Returns:
        A struct with `all_plugins` (deduplicated) and one depset per plugin
        library kind, plus `apple_privacy_manifests`.
    """
    all_dep_plugins = []
    apple_plugin_lib_depsets = []
    android_plugin_lib_depsets = []
    linux_plugin_lib_depsets = []
    windows_plugin_lib_depsets = []
    apple_privacy_manifest_depsets = []
    for dep in deps:
        if FlutterInfo not in dep:
            continue
        info = dep[FlutterInfo]
        is_plugin_target = any([getattr(p, "_depth", 0) == 0 for p in info.plugins])
        is_pub_package = _is_pub_package(dep)
        for p in info.plugins:
            direct = _is_direct_plugin(is_plugin_target, is_pub_package, p)
            if direct != getattr(p, "direct", False):
                all_dep_plugins.append(_copy_plugin_with_direct(p, direct))
            else:
                all_dep_plugins.append(p)
        apple_plugin_lib_depsets.append(info.apple_plugin_libraries)
        android_plugin_lib_depsets.append(info.android_plugin_libraries)
        linux_plugin_lib_depsets.append(info.linux_plugin_libraries)
        windows_plugin_lib_depsets.append(info.windows_plugin_libraries)
        apple_privacy_manifest_depsets.append(info.apple_privacy_manifests)
    return struct(
        all_plugins = dedup_plugins(all_dep_plugins),
        android_plugin_libraries = depset(transitive = android_plugin_lib_depsets),
        apple_plugin_libraries = depset(transitive = apple_plugin_lib_depsets),
        apple_privacy_manifests = depset(transitive = apple_privacy_manifest_depsets),
        linux_plugin_libraries = depset(transitive = linux_plugin_lib_depsets),
        windows_plugin_libraries = depset(transitive = windows_plugin_lib_depsets),
    )

def flutter_info(
        deps = [],
        plugins = [],
        asset_channels = None,
        plugin_libraries = None,
        native_channels = None):
    """Builds a `FlutterInfo`, merging its dependencies' contributions.

    The caller supplies only what this target contributes itself, grouped into
    the parameter objects built by `flutter_asset_channels()`,
    `flutter_plugin_libraries()` and `flutter_native_channels()`; everything transitive is merged here, so every
    dependency's contribution on every channel arrives without the caller
    naming it. Adding a field to `FlutterInfo` is therefore a change to this
    function and its group constructors, and nothing else. A group the caller
    passes nothing for is left at its default, which contributes empty values.

    An unknown channel fails analysis: an unknown keyword to any group
    constructor is an error, and a hand-built struct missing a field fails when
    its field is read here.

    A `deps` entry with no `FlutterInfo` is skipped rather than an error: a
    Flutter target's `deps` legally holds plain `dart_library` targets, and
    every caller would otherwise re-derive that check.

    Args:
      deps: Targets whose `FlutterInfo` contributions are merged in. Entries
        without one are ignored.
      plugins: Plugin metadata structs this target declares. Deduplicated by
        name against the dependencies' plugins, this target's first.
      asset_channels: A `flutter_asset_channels()` struct with this target's
        `apple_privacy_manifests`.
      plugin_libraries: A `flutter_plugin_libraries()` struct with this
        target's per-platform plugin libraries.
      native_channels: A `flutter_native_channels()` struct with this target's
        `native_libs`, `native_lib_sources`, `binding_contracts` and
        `data_assets`.

    Returns:
      A `FlutterInfo` carrying this target's channels merged with every dependency's.
    """
    if asset_channels == None:
        asset_channels = flutter_asset_channels()
    if plugin_libraries == None:
        plugin_libraries = flutter_plugin_libraries()
    if native_channels == None:
        native_channels = flutter_native_channels()
    dep_infos = [dep[FlutterInfo] for dep in deps if FlutterInfo in dep]

    dep_plugins = []
    for info in dep_infos:
        for p in info.plugins:
            d = getattr(p, "_depth", 0)
            dep_plugins.append(_copy_plugin_with_depth(p, d + 1))

    own_plugins = []
    for p in plugins:
        own_plugins.append(_copy_plugin_with_depth(p, 0))

    assets = _merge_asset_channels(dep_infos, asset_channels)
    libraries = _merge_plugin_libraries(dep_infos, plugin_libraries)
    native = _merge_native_channels(dep_infos, native_channels)

    return FlutterInfo(
        # A list, not a depset: the structs carry a `platforms` dict, which is
        # unhashable. Order is meaningful to the registrant generators, and
        # this target's own plugins come first.
        plugins = dedup_plugins(own_plugins + dep_plugins),
        transitive_native_libs = native.transitive_native_libs,
        native_lib_sources = native.native_lib_sources,
        binding_contracts = native.binding_contracts,
        apple_plugin_libraries = libraries.apple_plugin_libraries,
        android_plugin_libraries = libraries.android_plugin_libraries,
        linux_plugin_libraries = libraries.linux_plugin_libraries,
        windows_plugin_libraries = libraries.windows_plugin_libraries,
        apple_privacy_manifests = assets.apple_privacy_manifests,
        data_assets = native.data_assets,
    )

# The attribute `flutter_library` and `flutter_plugin` share for a package's
# link hook, which `flutter_application` runs for the assets it lists in
# `link_hook_assets`. Mirrors `dart_library.link_hook`.
LINK_HOOK_ATTR = attr.label(
    doc = "The package's `hook/link.dart`, if it has one. An application " +
          "that lists the package's assets in `link_hook_assets` runs it " +
          "over the compiler's recorded uses in a release or profile build. " +
          "Keep it out of `srcs`; its imports (`hooks`, `data_assets`, " +
          "`record_use`) are ordinary `deps`.",
    allow_single_file = [".dart"],
)
