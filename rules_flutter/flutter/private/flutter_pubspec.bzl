"""Plain data from a pub package's `pubspec.yaml` `flutter:` section.

The caller reads the pubspec with `yaml_to_json` from
`@rules_dart//dart/pub:yaml.bzl`, which fails naming the file on anything
that is not one YAML mapping: booleans arrive as booleans, empty values as
None and every other scalar as a string holding its source text. This module
only reads keys and values out of that:

- `parse_flutter_plugin_block`: `flutter.plugin`, for the plugin spoke.
- `pubspec_file_roots`: where the files the section names live (assets,
  fonts, shaders, licences, deferred components' assets), for the files a
  spoke offers the asset bundle.

It interprets and validates nothing. The asset tool runs the Flutter tool's
own `flutter_manifest.dart` and `asset.dart` over every package's pubspec
when an app bundles: an app's bad manifest fails the bundle action with the
tool's message, and a dependency's is reported and skipped, as under
`flutter build`.
"""

visibility(["//flutter/..."])

def parse_flutter_block(pubspec):
    """Return the `flutter:` sub-dict, or empty dict when absent.

    Args:
        pubspec: The decoded pubspec.yaml mapping.

    Returns:
        The `flutter:` mapping as a dict, or an empty dict when absent.
    """
    flutter = pubspec.get("flutter")
    return flutter if type(flutter) == "dict" else {}

# ---------------------------------------------------------------------------
# flutter.plugin
# ---------------------------------------------------------------------------

def _coerce_plugin_value(v):
    # Booleans stay booleans; everything else stringifies. None → empty string.
    if type(v) == "bool":
        return v
    if v == None:
        return ""
    return str(v)

def parse_flutter_plugin_block(pubspec):
    """Parse `flutter.plugin` out of a decoded pubspec.yaml.

    Args:
        pubspec: The decoded pubspec.yaml mapping.

    Returns:
        A struct with:
            present: bool — True iff a `flutter.plugin` block exists.
            platforms: dict of `<platform> -> dict[key, value]`. Empty dict
                when no `platforms:` key is present.
            implements: str — value of `flutter.plugin.implements` or `""`.
            ffi_plugin: bool — value of `flutter.plugin.ffiPlugin` or False.
    """
    flutter = parse_flutter_block(pubspec)
    plugin = flutter.get("plugin")
    if type(plugin) != "dict":
        return struct(
            present = False,
            platforms = {},
            implements = "",
            ffi_plugin = False,
        )

    platforms_raw = plugin.get("platforms", {})
    platforms = {}
    if type(platforms_raw) == "dict":
        for name, info in platforms_raw.items():
            if type(info) == "dict":
                platforms[name] = {k: _coerce_plugin_value(v) for k, v in info.items()}

    implements_raw = plugin.get("implements", "")
    implements = str(implements_raw) if implements_raw != None else ""

    ffi_raw = plugin.get("ffiPlugin", False)
    ffi_plugin = ffi_raw if type(ffi_raw) == "bool" else False

    return struct(
        present = True,
        platforms = platforms,
        implements = implements,
        ffi_plugin = ffi_plugin,
    )

# ---------------------------------------------------------------------------
# The files the `flutter:` section names
# ---------------------------------------------------------------------------

def _path_entries(raw):
    """The paths of an asset or shader list: string items, and a map item's `path`."""
    if type(raw) != "list":
        return []
    paths = []
    for item in raw:
        if type(item) == "dict":
            item = item.get("path")
        if type(item) == "string":
            paths.append(item)
    return paths

def _named_paths(flutter):
    """`(path, is_shader)` for every relative path `flutter:` names, as written."""
    named = [(p, False) for p in _path_entries(flutter.get("assets"))]
    named += [(p, True) for p in _path_entries(flutter.get("shaders"))]
    fonts = flutter.get("fonts")
    for family in fonts if type(fonts) == "list" else []:
        files = family.get("fonts") if type(family) == "dict" else None
        for font in files if type(files) == "list" else []:
            asset = font.get("asset") if type(font) == "dict" else None
            if type(asset) == "string":
                named.append((asset, False))
    licenses = flutter.get("licenses")
    for license in licenses if type(licenses) == "list" else []:
        if type(license) == "string":
            named.append((license, False))
    deferred = flutter.get("deferred-components")
    for component in deferred if type(deferred) == "list" else []:
        if type(component) == "dict":
            named += [(p, False) for p in _path_entries(component.get("assets"))]
    return named

# A segment that may climb out of the directories before it once the tool reads
# the path as a URI: `..`, or one holding an escape (`%2E%2E` is `..`) or a
# backslash (a separator in a string entry).
def _may_climb(segment):
    return segment == ".." or "%" in segment or "\\" in segment

# A segment taken as a directory or file name: nothing in it could be URI
# syntax (a dot segment, a query, a fragment, a scheme) or climb.
def _plain(segment):
    return segment not in ("", ".") and not _may_climb(segment) and not [c for c in ("?", "#", ":") if c in segment]

def pubspec_file_roots(pubspec):
    """Where the files a pubspec's `flutter:` section names live, as plain names.

    Each named path gives its leading directories, up to the first segment
    that is not a plain name, and a top-level file gives its own name: the
    Flutter tool finds the file, its resolution variants (`2.0x/...`), a
    directory's files and a shader's includes under them, and reads them as
    a URI, which this does not. A path that may climb out of its leading
    directories once read as a URI (a `..`, an escape or a backslash in it),
    one whose first segment is not plain (`./`), and a shader at the
    package root, whose includes are the root's files, give the whole
    package.

    Args:
        pubspec: The decoded pubspec.yaml mapping.

    Returns:
        `struct(dirs, files, whole)`: sorted directory and top-level file
        names, and whether the whole package is needed.
    """
    dirs, files = {}, {}
    for path, is_shader in _named_paths(parse_flutter_block(pubspec)):
        parts = path.split("/")
        if [p for p in parts if _may_climb(p)]:
            return struct(dirs = [], files = [], whole = True)
        prefix = []
        for part in parts[:-1]:
            if not _plain(part):
                break
            prefix.append(part)
        if prefix:
            dirs["/".join(prefix)] = True
        elif len(parts) == 1 and _plain(parts[0]) and not is_shader:
            files[parts[0]] = True
        else:
            return struct(dirs = [], files = [], whole = True)
    return struct(dirs = sorted(dirs.keys()), files = sorted(files.keys()), whole = False)
