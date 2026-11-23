"""Validation and selectors for `flutter.pub(ios_plugin_deps = ...)`.

The extension refuses a key that names no locked package before it creates
any spoke repository. A spoke then refuses an entry when the package has
no Apple sources or when an overlay BUILD replaces the generated Apple
targets, because either way the dependency would reach nothing. Every
helper is pure so unit tests drive them with plain strings and lists.
"""

visibility(["//flutter/..."])

def ios_plugin_deps_lock_error(plugin_deps, lock_packages, sdk_packages = ()):
    """Refuses a plugin deps key that names no package in the lock.

    Args:
        plugin_deps: The `flutter.pub` tag's plugin-name -> label dictionary.
        lock_packages: The package names the lock resolves.
        sdk_packages: The locked Flutter SDK package names; a key naming one
            is refused.

    Returns:
        The first error in sorted-key order naming
        `flutter.pub(ios_plugin_deps = ...)` and the offending plugin key,
        or the empty string when every key is locked and none is an SDK package.
    """
    available = {name: True for name in lock_packages}
    sdk = {name: True for name in sdk_packages}
    for plugin in sorted(plugin_deps.keys()):
        if plugin not in available:
            return (
                'flutter.pub(ios_plugin_deps = ...): key "{plugin}" ' +
                "is not a package in the lock. Name a locked package, or " +
                "remove the entry."
            ).format(plugin = plugin)
        if plugin in sdk:
            return (
                'flutter.pub(ios_plugin_deps = ...): key "{plugin}" ' +
                "is a Flutter SDK package; Flutter SDK packages are not " +
                "configurable through ios_plugin_deps. Remove the entry."
            ).format(plugin = plugin)
    return ""

def plugin_native_deps_apple_error(plugin, label, macos_srcs, ios_srcs):
    """Refuses a mapped native dependency for a package with no Apple sources.

    Args:
        plugin: The pub package name the dependency is keyed by.
        label: The native dependency label, or None / empty when unset.
        macos_srcs: Detected macOS Apple source directories.
        ios_srcs: Detected iOS Apple source directories.

    Returns:
        The refusal naming the plugin, or the empty string when unset
        or at least one platform has Apple sources.
    """
    if not label or macos_srcs or ios_srcs:
        return ""
    return (
        'flutter.pub(ios_plugin_deps = ...): "{plugin}" has no iOS ' +
        "or macOS Apple sources, so its dependency reaches nothing. Remove " +
        "the entry."
    ).format(plugin = plugin)

def plugin_native_deps_overlay_error(plugin, label, uses_overlay):
    """Refuses a mapped native dependency for a package an overlay BUILD covers.

    Args:
        plugin: The pub package name the dependency is keyed by.
        label: The native dependency label, or None / empty when unset.
        uses_overlay: Whether an overlay BUILD resolves for the package.

    Returns:
        The refusal naming the plugin, or the empty string when unset
        or no overlay replaces the generated targets.
    """
    if not label or not uses_overlay:
        return ""
    return (
        'flutter.pub(ios_plugin_deps = ...): "{plugin}" uses an ' +
        "overlay BUILD, so the generated Apple targets do not receive its " +
        "dependency. Remove the entry or list it in the overlay."
    ).format(plugin = plugin)

def check_plugin_native_deps(ctx, package_name, apple, uses_overlay):
    """Refuse native deps that cannot reach a generated Apple compile.

    Args:
        ctx: The spoke's repository context, carrying `plugin_native_deps`.
        package_name: The pub package name the helper messages name.
        apple: The `detect_apple_plugin_sources` struct.
        uses_overlay: Whether an overlay BUILD replaces the generated one.

    Returns:
        None; fails the fetch with the matching refusal when the dependency
        cannot reach a compile.
    """
    label = ctx.attr.plugin_native_deps if hasattr(ctx.attr, "plugin_native_deps") else None
    error = plugin_native_deps_overlay_error(package_name, label, uses_overlay)
    if not error and label:
        macos_srcs = apple.macos_srcs if apple and hasattr(apple, "macos_srcs") else []
        ios_srcs = apple.ios_srcs if apple and hasattr(apple, "ios_srcs") else []
        error = plugin_native_deps_apple_error(package_name, label, macos_srcs, ios_srcs)
    if error:
        fail(error)

def mapped_apple_plugin_deps(label, macos_srcs, ios_srcs):
    """Maps a plugin's native dependency label to platform dep lists.

    Args:
        label: The native dependency label, or None when unmapped.
        macos_srcs: Detected macOS Apple source directories.
        ios_srcs: Detected iOS Apple source directories.

    Returns:
        `struct(mapped, macos, ios)`: `mapped` is False and both lists are
        empty when `label` is None; otherwise `mapped` is True and each list
        holds the one label string for a platform whose source-dir list is
        non-empty (both empty when neither has sources).
    """
    if label == None:
        return struct(mapped = False, macos = [], ios = [])
    label_str = str(label)
    return struct(
        mapped = True,
        macos = [label_str] if macos_srcs else [],
        ios = [label_str] if ios_srcs else [],
    )
