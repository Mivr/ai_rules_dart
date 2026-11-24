"""Compose `flutter.pub(ios_plugin_defines = ...)` entries into compile options.

Every entry (`NAME` or `NAME=VALUE`) becomes a target-local `-D<entry>` on a
C-family compile. A Swift compilation condition carries no value, so only a
value-less `NAME` reaches a Swift compile. The composition uses `+` so a
`select()` from `.when(platforms:)` stays concatenable.
"""

visibility(["//flutter/..."])

_VALUE_SPECIALS = " \"'\\$\t"

def plugin_define_name(define):
    """The macro name of a `NAME` / `NAME=VALUE` entry."""
    return define.partition("=")[0]

def dedupe_plugin_defines(defines):
    """Drop earlier entries that a later entry with the same macro name overrides.

    Args:
        defines: `NAME` / `NAME=VALUE` entries in declaration order.

    Returns:
        The entries with one per macro name; the last occurrence wins and keeps
        its position.
    """
    last = {}
    for idx, define in enumerate(defines):
        last[plugin_define_name(define)] = idx
    return [define for idx, define in enumerate(defines) if last[plugin_define_name(define)] == idx]

def _unescape_shell_layer(text):
    """Undo one shell escape layer: `\\"` `\\\\` `\\'` and `\\ ` lose their backslash."""
    out = []
    idx = 0
    for _ in range(len(text) + 1):
        if idx >= len(text):
            break
        if text[idx] == "\\" and idx + 1 < len(text) and text[idx + 1] in ("\"", "\\", "'", " "):
            out.append(text[idx + 1])
            idx += 2
        else:
            out.append(text[idx])
            idx += 1
    return "".join(out)

def _normalize_define_value(value):
    """The C preprocessor replacement text of a define's raw `VALUE`."""
    if len(value) >= 2 and value[0] == "'" and value[-1] == "'":
        inner = value[1:-1]
        if inner.startswith("\"") or inner.startswith("\\\""):
            value = inner
    if len(value) >= 6 and value.startswith("\"\\\"") and value.endswith("\\\"\""):
        value = value[1:-1]
    if len(value) >= 4 and value.startswith("\\\"") and value.endswith("\\\""):
        value = _unescape_shell_layer(value)
    return value

def _objc_define_flag(define):
    """One `objc_library(copts)` entry that tokenizes back to the exact `-D` argv element."""
    name, eq, value = define.partition("=")
    value = _normalize_define_value(value)
    flag = "-D" + name + eq + value
    if not eq or not any([c in _VALUE_SPECIALS for c in value.elems()]):
        return flag
    return "'" + flag.replace("$", "$$").replace("'", "'\\''") + "'"

def plugin_define_copts(defines):
    """The C-family `-D` flags for a plugin's define entries, deduplicated by macro name.

    A value holding a quote, backslash, space, tab or `$` is Bourne-quoted so
    `objc_library`'s make-variable expansion and shell tokenization hand Clang
    the exact `-DNAME=VALUE` argument.

    Args:
        defines: List of `NAME` or `NAME=VALUE` define entries from `ios_plugin_defines`.

    Returns:
        A list of `-D<entry>` strings, one per distinct macro name.
    """
    return [_objc_define_flag(define) for define in dedupe_plugin_defines(defines)]

def plugin_swift_define_copts(defines):
    """The Swift `-D` flags: only value-less entries, because a condition has no value.

    Args:
        defines: List of `NAME` or `NAME=VALUE` define entries from `ios_plugin_defines`.

    Returns:
        A list of `-D<NAME>` strings for the deduplicated entries that contain no `=`.
    """
    return ["-D" + define for define in dedupe_plugin_defines(defines) if "=" not in define]

def plugin_objc_copts(copts, objc_copts, plugin_defines):
    """Compose ObjC compile options, keeping a `select()` in `copts` intact.

    Args:
        copts: Shared compile options for the plugin; may be a `select()`.
        objc_copts: Extra compile options that apply only to Objective-C sources.
        plugin_defines: List of `NAME` or `NAME=VALUE` define entries turned into `-D` flags.

    Returns:
        The concatenation of `copts`, `objc_copts` and the `-D` flags, built with `+`.
    """
    return copts + objc_copts + plugin_define_copts(plugin_defines)

def plugin_swift_copts(copts, plugin_defines):
    """Compose Swift compile options, keeping a `select()` in `copts` intact.

    Args:
        copts: Shared compile options for the plugin; may be a `select()`.
        plugin_defines: List of `NAME` or `NAME=VALUE` define entries; only value-less ones are kept.

    Returns:
        The concatenation of `copts` and the Swift `-D` flags, built with `+`.
    """
    return copts + plugin_swift_define_copts(plugin_defines)
