"""Helper functions for `flutter.pub` package and spoke generation.

Extracted helpers for pubspec identity validation, asset condition merging,
pub-asset BUILD attribute formatting, and `package:test` runner wrappers.
"""

load(
    "//flutter/private:flutter_pub_semver.bzl",
    "parse_pub_version",
    "pub_version_text",
)
load(
    "//flutter/private:flutter_pubspec.bzl",
    "asset_flavor_error",
    "parse_pubspec",
)
load("//flutter/private:starlark_literal.bzl", "starlark_string_literal")

visibility(["//flutter/..."])

def _sorted_flavor_set(flavors):
    """The deduplicated, sorted flavor names, for order-insensitive comparison."""
    seen = {}
    for flavor in flavors:
        seen[flavor] = True
    return sorted(seen.keys())

def merge_pub_asset_conditions(expanded, package_name):
    """Merge per-file `flutter.assets` entries the way flutter_tools does.

    flutter_tools keeps one entry per declaration and bundles a file when ANY
    of its entries survives filtering, so every entry for one file merges:
    any entry without `platforms` makes the file unconditional, otherwise the
    file's platforms are the union of its entries' lists. Entries for one
    file whose flavor sets differ conflict (compared as sets, so order does
    not matter); the caller fails the fetch with the returned message.

    Args:
        expanded: Per-file entries from
            `expand_pub_asset_entries(...).expanded`.
        package_name: The pub package the entries come from, for the conflict
            message.

    Returns:
        A `struct(platforms, flavors, conflict)`: the merged condition dicts
        and the fetch failure naming the package, the file and both flavor
        lists, or `""` when the entries agree. A file with one entry keeps its
        declared order, so single-entry spokes render byte-identically.
    """
    by_path = {}
    order = []
    for entry in expanded:
        key = ":" + entry.path
        if key not in by_path:
            by_path[key] = []
            order.append(key)
        by_path[key].append(entry)
    platforms = {}
    flavors = {}
    for key in order:
        entries = by_path[key]
        first = entries[0]
        for other in entries[1:]:
            if _sorted_flavor_set(other.flavors) != _sorted_flavor_set(first.flavors):
                return struct(
                    platforms = {},
                    flavors = {},
                    conflict = asset_flavor_error(
                        package_name,
                        first.path,
                        first.flavors,
                        other.flavors,
                    ),
                )
        if first.flavors:
            flavors[key] = list(first.flavors)
        union = {}
        unconditional = False
        for entry in entries:
            if not entry.platforms:
                unconditional = True
                break
            for platform in entry.platforms:
                union[platform] = True
        if unconditional:
            continue
        if len(entries) == 1:
            platforms[key] = list(first.platforms)
        else:
            platforms[key] = sorted(union.keys())
    return struct(platforms = platforms, flavors = flavors, conflict = "")

def build_pkg_asset_conditions(expanded, package_name):
    """Build the `pkg_asset_platforms` / `pkg_asset_flavors` dicts.

    Same keys as `pkg_assets` (`":" + path`), but only for entries that
    actually restrict: unconditional files stay out of both dicts, so the
    emitted attrs stay empty for packages without conditions. Entries for
    one file merge (see `merge_pub_asset_conditions`); conflicting flavors
    fail the spoke fetch.

    Args:
        expanded: Per-file entries from
            `expand_pub_asset_entries(...).expanded`.
        package_name: The pub package the entries come from.

    Returns:
        A `(platforms, flavors)` tuple of dicts.
    """
    merged = merge_pub_asset_conditions(expanded, package_name)
    if merged.conflict:
        fail(merged.conflict)
    return (merged.platforms, merged.flavors)

def _format_label_dict_literal(d, indent = "        "):
    """Render `{":foo": "foo", ":bar": "bar"}` as a multi-line BUILD source dict."""
    if not d:
        return "{}"
    keys = sorted(d.keys())

    # Keys and values are asset, font and shader paths from the pubspec and
    # the file-system walk: attacker-controlled for hosted packages. Each
    # renders through the escaping helper, so the dict parses back exactly.
    lines = [
        "{indent}{k}: {v},".format(
            indent = indent,
            k = starlark_string_literal(k),
            v = starlark_string_literal(d[k]),
        )
        for k in keys
    ]
    return "{\n" + "\n".join(lines) + "\n" + indent[:-4] + "}"

def _format_string_list_dict_literal(d, indent = "        "):
    """Render `{":foo": ["a", "b"]}` as a multi-line BUILD source dict."""
    if not d:
        return "{}"
    lines = []
    for k in sorted(d.keys()):
        # Keys are walked asset paths (see above); values are flavor and
        # platform names from the pubspec, helper-rendered for the same
        # reason: a flavor name may hold any string the pubspec declares.
        values = ", ".join([starlark_string_literal(v) for v in d[k]])
        lines.append(
            "{indent}{k}: [{values}],".format(
                indent = indent,
                k = starlark_string_literal(k),
                values = values,
            ),
        )
    return "{\n" + "\n".join(lines) + "\n" + indent[:-4] + "}"

def format_pub_asset_attrs(
        fonts_json_str,
        font_files,
        pkg_assets,
        pkg_shaders,
        pkg_asset_platforms = {},
        pkg_asset_flavors = {}):
    """Render the pub-asset attrs as BUILD source, omitting empty ones.

    Args:
        fonts_json_str: JSON-encoded font definitions.
        font_files: Font file label map.
        pkg_assets: Package asset label map.
        pkg_shaders: Package shader label map.
        pkg_asset_platforms: Platform restriction map.
        pkg_asset_flavors: Flavor restriction map.

    Returns:
        Rendered attribute lines string.
    """
    parts = []
    if fonts_json_str:
        parts.append("    fonts_json = " + starlark_string_literal(fonts_json_str) + ",")
    if font_files:
        parts.append("    font_files = {},".format(_format_label_dict_literal(font_files)))
    if pkg_assets:
        parts.append("    pkg_assets = {},".format(_format_label_dict_literal(pkg_assets)))
    if pkg_asset_platforms:
        parts.append("    pkg_asset_platforms = {},".format(
            _format_string_list_dict_literal(pkg_asset_platforms),
        ))
    if pkg_asset_flavors:
        parts.append("    pkg_asset_flavors = {},".format(
            _format_string_list_dict_literal(pkg_asset_flavors),
        ))
    if pkg_shaders:
        parts.append("    pkg_shaders = {},".format(_format_label_dict_literal(pkg_shaders)))
    return "\n".join(parts) + ("\n" if parts else "")

# File extensions a shader may `#include`: the spoke links them beside a
# top-level declared shader so its scoped include glob resolves.
_PATH_SPOKE_SHADER_INCLUDE_EXTS = ("glsl", "frag", "vert")

def scoped_shader_includes_block(shader_paths):
    """Render `shader_includes` covering only the declared shaders' own directories.

    Each non-empty dirname contributes `<dir>/**/*.glsl|frag|vert`; a
    top-level shader contributes root `*.ext`. Sorted for determinism, so
    `example/build/` output can never become an include through a
    package-wide `**` glob.

    Args:
        shader_paths: Declared shader paths (the `pkg_shaders` values).

    Returns:
        The `shader_includes = glob(...)` BUILD block.
    """
    dirs = {}
    for path in shader_paths:
        dirs[path.rpartition("/")[0]] = True
    lines = []
    for d in sorted(dirs.keys()):
        for ext in _PATH_SPOKE_SHADER_INCLUDE_EXTS:
            pattern = d + "/**/*." + ext if d else "*." + ext

            # `d` is a declared shader's own directory, read from the
            # pubspec; the pattern renders through the escaping helper.
            lines.append("        " + starlark_string_literal(pattern) + ",")
    return "    shader_includes = glob(\n        [\n{}\n        ],\n        allow_empty = True,\n    ),".format("\n".join(lines))

def format_pub_asset_attrs_with_shaders(
        fonts_json_str,
        font_files,
        pkg_assets,
        pkg_shaders,
        pkg_asset_platforms = {},
        pkg_asset_flavors = {}):
    """Render the pub-asset attrs plus the scoped `shader_includes` block.

    Args:
        fonts_json_str: JSON-encoded font definitions.
        font_files: Font file label map.
        pkg_assets: Package asset label map.
        pkg_shaders: Package shader label map; a non-empty map appends the
            `shader_includes` block scoped to the declared shaders' directories.
        pkg_asset_platforms: Platform restriction map.
        pkg_asset_flavors: Flavor restriction map.

    Returns:
        Rendered attribute lines string, ending with the `shader_includes`
        block when `pkg_shaders` is non-empty.
    """
    res = format_pub_asset_attrs(
        fonts_json_str,
        font_files,
        pkg_assets,
        pkg_shaders,
        pkg_asset_platforms,
        pkg_asset_flavors,
    )
    if pkg_shaders:
        res += scoped_shader_includes_block(sorted(pkg_shaders.values())) + "\n"
    return res

def parse_pubspec_identity(content):
    """The `(name, version)` identity a path spoke verifies against its lock entry.

    A path package's overlays and curated code assets are selected by the
    lock key and the lock's version, so the spoke must check that the
    package's own pubspec.yaml agrees — otherwise a directory whose
    pubspec names another package, or whose version moved since the lock
    was resolved, gets another package's overlay and native code assets.

    A pubspec with no `version:` field (or an empty one) reads as
    `"0.0.0"` — exactly how `pub get` locks it (pub's `Version.none`), so
    unversioned `publish_to: none` packages agree with the lock. The
    comparison itself is semantic (see `parse_pub_version`): quoting,
    surrounding whitespace and the YAML scalar type do not matter.

    Args:
        content: Full pubspec.yaml content as a string.

    Returns:
        A `struct(name, version)` of strings; the name is `""` when
        absent, unparsable, or not a scalar, and the version is `"0.0.0"`
        when unstated. A missing pubspec therefore never matches a lock
        key and fails closed at the caller's comparison.
    """
    pubspec = parse_pubspec(content)
    name = pubspec.get("name", "")
    version = pub_version_text(pubspec.get("version", ""))
    return struct(
        name = "" if name == None else str(name),
        version = "0.0.0" if version == "" else version,
    )

def missing_pubspec_refusal(hub_name, package_name):
    """The fetch refusal for a path package with no readable pubspec name.

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the hub and the lock key.

    Args:
        hub_name: Name of the pub hub being fetched, shown in the message.
        package_name: Lock key of the path package lacking a readable pubspec.

    Returns:
        The refusal message string, which the caller passes to `fail()`.
    """
    return (
        "flutter.pub hub \"" + hub_name + "\": path dependency \"" +
        package_name + "\" has no readable pubspec.yaml naming the " +
        "package. Overlays and code assets are selected by lock name; " +
        "re-resolve the lock so the package carries a pubspec that " +
        "agrees with it."
    )

def pubspec_name_refusal(hub_name, package_name, actual):
    """The fetch refusal for a path package whose pubspec names another package.

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the hub, the lock key, and both values.

    Args:
        hub_name: Name of the pub hub being fetched, shown in the message.
        package_name: Lock key of the path package.
        actual: Package name found in the pubspec.yaml.

    Returns:
        The refusal message string, which the caller passes to `fail()`.
    """
    return (
        "flutter.pub hub \"" + hub_name + "\": path dependency \"" +
        package_name + "\" names itself \"" + actual + "\" in its " +
        "pubspec.yaml but the lock calls it \"" + package_name + "\". " +
        "Overlays and code assets are selected by lock name; re-resolve " +
        "the lock (or rename the package) so the two agree."
    )

def pubspec_version_refusal(hub_name, package_name, locked, actual):
    """The fetch refusal for a path package whose version moved since the lock.

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the hub, the lock key, and both values.
    A pubspec with no `version:` field reads as `0.0.0` (the way `pub get`
    locks it), so an unversioned package shows `0.0.0` on the pubspec side
    here when the lock moved on.

    Args:
        hub_name: Name of the pub hub being fetched, shown in the message.
        package_name: Lock key of the path package.
        locked: Version recorded in the lock entry.
        actual: Version found in the pubspec.yaml.

    Returns:
        The refusal message string, which the caller passes to `fail()`.
    """
    return (
        "flutter.pub hub \"" + hub_name + "\": path dependency \"" +
        package_name + "\" locks version \"" + locked + "\" but its " +
        "pubspec.yaml says \"" + actual + "\" (a pubspec with no " +
        "`version:` field reads as \"0.0.0\", the way `pub get` locks " +
        "it). Overlays and code assets are selected by lock version; " +
        "re-resolve the lock so the two agree."
    )

def malformed_pub_version_refusal(hub_name, package_name, bad_value):
    """The fetch refusal for a path package with an unparsable version.

    Either side can be bad: the lock entry or the package's own pubspec.
    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the hub, the lock key, and the bad value.

    Args:
        hub_name: Name of the pub hub being fetched, shown in the message.
        package_name: Lock key of the path package.
        bad_value: The version string that failed to parse.

    Returns:
        The refusal message string, which the caller passes to `fail()`.
    """
    return (
        "flutter.pub hub \"" + hub_name + "\": path dependency \"" +
        package_name + "\" has malformed version \"" + bad_value + "\" " +
        "in its pubspec.yaml or the lock entry. Versions are " +
        "major.minor.patch with optional -pre-release and +build (a " +
        "pubspec with no `version:` field reads as \"0.0.0\"); fix the " +
        "version or re-resolve the lock."
    )

def check_pubspec_identity_mismatch(hub_name, package_name, lock_version, pubspec_text):
    """Fail when the package's pubspec name or version disagrees with the lock.

    Overlays and curated code assets are selected by the lock key and the
    lock's version, so a directory whose pubspec names another package, or
    whose version moved since the lock was resolved, must not silently get
    another package's overlay and native code assets. Each mismatch fails
    naming the hub, the lock key, and both values, telling the user to
    re-resolve. The two versions compare as parsed semantic versions (a
    missing pubspec version reads as `0.0.0`, like `pub get` locks it); an
    unparsable version on either side fails naming the bad value.

    Args:
        hub_name: The name of the pub hub.
        package_name: The expected package name from the lockfile.
        lock_version: The locked version string.
        pubspec_text: The raw pubspec.yaml content.
    """
    identity = parse_pubspec_identity(pubspec_text)
    if not pubspec_text.strip() or not identity.name:
        fail(missing_pubspec_refusal(hub_name, package_name))
    if identity.name != package_name:
        fail(pubspec_name_refusal(hub_name, package_name, identity.name))
    locked = parse_pub_version(lock_version)
    if not locked.ok:
        fail(malformed_pub_version_refusal(hub_name, package_name, locked.text))
    actual = parse_pub_version(identity.version)
    if not actual.ok:
        fail(malformed_pub_version_refusal(hub_name, package_name, actual.text))
    if actual.canonical != locked.canonical:
        fail(pubspec_version_refusal(hub_name, package_name, locked.text, actual.text))

def make_flutter_test_package_bzl_content(forward_flutter_providers = False, ctx = None):
    """Generates `flutter_test_package.bzl` content for a `package:test` spoke.

    Args:
        forward_flutter_providers: When True (merged SCC spokes), forwards
            `DartKernelInfo`, `DartAnalyzableInfo`, and `FlutterInfo` from
            `library` when present. When False (single-package spokes),
            preserves the exact single-package spoke content.
        ctx: The repository or module context. Unused now that
            `DartTestRunnerInfo` and `DartTestRunnerSnapshotInfo` are exported
            on `@rules_dart//dart:providers.bzl`.

    Returns:
        The Starlark source string for `flutter_test_package.bzl`.
    """
    _ = ctx
    if forward_flutter_providers:
        providers_load = (
            'load("@rules_dart//dart:providers.bzl", "DartAnalyzableInfo", ' +
            '"DartInfo", "DartKernelInfo", "DartTestRunnerInfo", ' +
            '"DartTestRunnerSnapshotInfo")'
        )
    else:
        providers_load = (
            'load("@rules_dart//dart:providers.bzl", "DartInfo", ' +
            '"DartTestRunnerInfo", "DartTestRunnerSnapshotInfo")'
        )
    extra_load = (
        '\nload("@rules_flutter//flutter:providers.bzl", "FlutterInfo")' if forward_flutter_providers else ""
    )
    return_block = """\
    providers = [
        library[DefaultInfo],
        library[DartInfo],
        DartTestRunnerInfo(runner = runner),
    ]
    for p in (DartKernelInfo, DartAnalyzableInfo, FlutterInfo):
        if p in library:
            providers.append(library[p])
    return providers""" if forward_flutter_providers else """\
    return [
        library[DefaultInfo],
        library[DartInfo],
        DartTestRunnerInfo(runner = runner),
    ]"""
    return """\
{providers_load}{extra_load}

def _flutter_test_package_impl(ctx):
    library = ctx.attr.library
    dills = [f for f in ctx.attr.runner[DefaultInfo].files.to_list() if f.extension == "dill"]
    if len(dills) != 1:
        fail("%s: `runner` must produce exactly one `.dill`, got %s" % (ctx.label, dills))
    runner = dills[0]
    if ctx.attr.snapshot != None:
        snapshot = ctx.attr.snapshot[DartTestRunnerSnapshotInfo].snapshot
        if snapshot != None:
            runner = snapshot
{return_block}

flutter_test_package = rule(
    implementation = _flutter_test_package_impl,
    attrs = {{
        "library": attr.label(
            doc = "The `package:test` `dart_library`.",
            mandatory = True,
            providers = [DartInfo],
        ),
        "runner": attr.label(
            doc = "A kernel-mode `dart_binary` built from `library`.",
            mandatory = True,
        ),
        "snapshot": attr.label(
            doc = (
                "A `dart_test_runner_snapshot` of `runner`. Its snapshot " +
                "runs in place of the kernel when one was built."
            ),
            providers = [DartTestRunnerSnapshotInfo],
        ),
    }},
    doc = "`package:test` as a dependency, carrying the runner built from it.",
)
""".format(
        providers_load = providers_load,
        extra_load = extra_load,
        return_block = return_block,
    )
