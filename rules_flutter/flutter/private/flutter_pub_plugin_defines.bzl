"""Validation for `flutter.pub(ios_plugin_defines = ...)`.

The extension refuses a key that names no locked package and an entry that
is not a C preprocessor name before it creates any spoke. A spoke then
refuses a non-empty list when the package has no Apple sources or when an
overlay BUILD replaces the generated Apple targets, because either way the
defines would reach nothing. Every helper is pure so unit tests drive them
with plain strings and lists.
"""

load(":flutter_pub_apple.bzl", "detect_apple_plugin_sources")

visibility(["//flutter/..."])

plugin_defines_attr = attr.string_list(
    doc = "Preprocessor defines for this package's Apple libraries, from " +
          "`flutter.pub(ios_plugin_defines = ...)`. A non-empty list on a " +
          "package with no Apple sources, or whose BUILD comes from an " +
          "overlay, fails the fetch because the defines would reach nothing.",
    default = [],
)

def check_plugin_defines(ctx, package_name, plugin_block, uses_overlay):
    """Refuse defines that cannot reach a generated Apple compile.

    Args:
        ctx: The spoke's repository context, carrying `plugin_defines`.
        package_name: The pub package name the helper messages name.
        plugin_block: The parsed `flutter.plugin` block.
        uses_overlay: Whether an overlay BUILD replaces the generated one.

    Returns:
        None; fails the fetch with the matching refusal when the list cannot
        reach a compile.
    """
    defines = ctx.attr.plugin_defines if hasattr(ctx.attr, "plugin_defines") else []
    error = plugin_defines_overlay_error(package_name, defines, uses_overlay)
    if not error and defines:
        apple = detect_apple_plugin_sources(ctx, package_name, plugin_block)
        error = plugin_defines_apple_error(package_name, defines, apple.macos_srcs, apple.ios_srcs)
    if error:
        fail(error)

def _is_letter(char):
    """Whether `char` is an ASCII letter."""
    return ("A" <= char and char <= "Z") or ("a" <= char and char <= "z")

def _is_digit(char):
    """Whether `char` is an ASCII digit."""
    return "0" <= char and char <= "9"

def _is_preprocessor_name(name):
    """Whether `name` matches `[A-Za-z_][A-Za-z0-9_]*`."""
    if not name:
        return False
    first = name[0]
    if first != "_" and not _is_letter(first):
        return False
    for char in name[1:].elems():
        if char != "_" and not _is_letter(char) and not _is_digit(char):
            return False
    return True

def _entry_name(entry):
    """The part of `NAME=VALUE` before the first `=`, or the whole entry."""
    separator = entry.find("=")
    if separator < 0:
        return entry
    return entry[:separator]

def ios_plugin_defines_lock_error(defines, lock_packages, sdk_packages = ()):
    """Refuses a define key or entry that cannot reach a locked plugin.

    Args:
        defines: The `flutter.pub` tag's plugin-name -> define strings
            dictionary.
        lock_packages: The package names the lock resolves.
        sdk_packages: The locked Flutter SDK package names; a key naming one
            is refused.

    Returns:
        The first error in sorted-key order naming
        `flutter.pub(ios_plugin_defines = ...)`, the plugin and the offending
        entry, or the empty string when every key is locked and every entry
        is a preprocessor name or `NAME=VALUE`.
    """
    available = {name: True for name in lock_packages}
    sdk = {name: True for name in sdk_packages}
    for plugin in sorted(defines.keys()):
        if plugin not in available:
            return (
                "flutter.pub(ios_plugin_defines = ...): key \"{plugin}\" " +
                "is not a package in the lock. Name a locked package, or " +
                "remove the entry."
            ).format(plugin = plugin)
        if plugin in sdk:
            return (
                "flutter.pub(ios_plugin_defines = ...): key \"{plugin}\" " +
                "is a Flutter SDK package; Flutter SDK packages are not " +
                "configurable through ios_plugin_defines. Remove the entry."
            ).format(plugin = plugin)
        for entry in defines[plugin]:
            if not _is_preprocessor_name(_entry_name(entry)):
                return (
                    "flutter.pub(ios_plugin_defines = ...): \"{plugin}\" " +
                    "lists \"{entry}\", which is not a preprocessor name or " +
                    "NAME=VALUE. Use a name such as PERMISSION_CAMERA, " +
                    "optionally followed by =VALUE."
                ).format(plugin = plugin, entry = entry)
    return ""

def plugin_defines_apple_error(plugin, defines, macos_srcs, ios_srcs):
    """Refuses a non-empty define list for a package with no Apple sources.

    Args:
        plugin: The pub package name the defines are keyed by.
        defines: The package's define strings.
        macos_srcs: Detected macOS Apple source directories.
        ios_srcs: Detected iOS Apple source directories.

    Returns:
        The refusal naming the plugin, or the empty string when the list is
        empty or at least one platform has Apple sources.
    """
    if not defines or macos_srcs or ios_srcs:
        return ""
    return (
        "flutter.pub(ios_plugin_defines = ...): \"{plugin}\" has no iOS " +
        "or macOS Apple sources, so its defines reach nothing. Remove the " +
        "entry."
    ).format(plugin = plugin)

def plugin_defines_overlay_error(plugin, defines, uses_overlay):
    """Refuses a non-empty define list for a package an overlay BUILD covers.

    Args:
        plugin: The pub package name the defines are keyed by.
        defines: The package's define strings.
        uses_overlay: Whether an overlay BUILD resolves for the package.

    Returns:
        The refusal naming the plugin, or the empty string when the list is
        empty or no overlay replaces the generated targets.
    """
    if not defines or not uses_overlay:
        return ""
    return (
        "flutter.pub(ios_plugin_defines = ...): \"{plugin}\" uses an " +
        "overlay BUILD, so the generated Apple targets do not receive its " +
        "defines. Remove the entry or pass the flags in the overlay."
    ).format(plugin = plugin)
