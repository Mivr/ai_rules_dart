"""Refusal rules for a plugin manifest's local-target walk.

`parse_plugin_local_package` (the strict parser) refuses what Bazel cannot
translate. The walk used to treat every refusal as "no local targets", so a
multi-target plugin silently built only its primary target. This file decides
which refusals may stay silent: a manifest the lenient spoke parser reads
(declarative) never may, and a program-style manifest may only when it has no
sibling target to drop.
"""

load(":swiftpm_manifest.bzl", "parse_swiftpm_plugin_package")
load(":swiftpm_manifest_lex.bzl", "lex_swiftpm_manifest")

visibility(["//flutter/..."])

_TARGET_CALLS = ["target", "binaryTarget", "systemLibrary", "executableTarget", "plugin", "macro"]

def _count_target_calls(tokens):
    """Count the non-test target declarations in a lexed manifest.

    Args:
        tokens: The lexer's token list.

    Returns:
        The number of `.target(`-style calls, `testTarget` excluded.
    """
    count = 0
    for i in range(len(tokens) - 2):
        if tokens[i].kind == "punct" and tokens[i].text == "." and tokens[i + 1].kind == "word" and \
           tokens[i + 1].text in _TARGET_CALLS and tokens[i + 2].text == "(":
            count += 1
    return count

def local_manifest_decision(plugin, text, parsed, other_source_dirs):
    """Decide whether a strict-parser result may be ignored by the walk.

    Args:
        plugin: The pub plugin name, for messages.
        text: The `Package.swift` text.
        parsed: The `parse_plugin_local_package` result for `text`.
        other_source_dirs: Directories under the manifest's `Sources` other
            than the primary one.

    Returns:
        `struct(ok, error, parsed)`: `ok` is False when the spoke fetch must
        fail with `error`; otherwise `parsed.ok` says whether to translate.
    """
    if parsed.ok:
        return struct(ok = True, error = "", parsed = parsed)
    refuse = struct(ok = False, error = parsed.error, parsed = parsed)
    if parse_swiftpm_plugin_package(plugin, text).ok:
        return refuse
    lexed = lex_swiftpm_manifest(text, plugin)
    if other_source_dirs or (lexed.ok and _count_target_calls(lexed.tokens) > 1):
        return refuse
    return struct(ok = True, error = "", parsed = parsed)
