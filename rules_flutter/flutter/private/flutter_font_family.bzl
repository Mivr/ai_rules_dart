"""A public `flutter_font_family` rule and the shared font validation.

COV-29. A font family declares each font with the asset path of the file it
ships, so a font and its file pair by that path and never by their position
in a list. `flutter_font_family` and the legacy `fonts_json` / `font_files`
path that `flutter_library` and `flutter_plugin` share both go through the
checks here: an asset with no file, a file no family names, and a weight or
style flutter_tools refuses all fail analysis, naming the target, the family
and the path. The refusal text is flutter_tools' own, for example
`Invalid value 750 ((int)) for font -> weight.`.
"""

load("//flutter/private:asset_uri.bzl", "normalize_asset_uri")
load("//flutter/private:flutter_manifest_validate.bzl", "dart_str", "dart_type")

visibility(["//flutter/..."])

# The weights flutter_tools accepts (`_validateFonts` in
# `packages/flutter_tools/lib/src/flutter_manifest.dart`). A present weight
# outside this table is an invalid value, never silently unset.
FONT_WEIGHTS = (100, 200, 300, 400, 500, 600, 700, 800, 900)

# The styles flutter_tools accepts for one font file.
FONT_STYLES = ("normal", "italic")

FlutterFontFamilyInfo = provider(
    doc = "One `flutter_font_family` target's family and its fonts.",
    fields = {
        "family": "The family name, unprefixed (`HelloSans`).",
        "fonts": "Tuple of struct(asset_path, file, weight, style) in declaration order. `asset_path` is the encoded bundle key; `file` is that font's own file.",
    },
)

FONTS_ATTR = attr.label_list(
    doc = "Font families this target ships, as `flutter_font_family` targets. List them in `flutter_application.fonts` for the root pubspec's bare family and asset paths (`HelloSans`, `fonts/HelloSans-Regular.ttf`), or in `flutter_library.fonts` to bundle them under `packages/<package_name>/`. The FontManifest entry lists the fonts in declaration order with `weight`/`style` only when given, and each asset carries its own file. Replaces the deprecated `fonts_json`/`font_files`.",
    providers = [FlutterFontFamilyInfo],
)

def font_weight_problem(weight):
    """The flutter_tools refusal for a font `weight`, or None when it is valid.

    Args:
        weight: The declared weight value.

    Returns:
        `Invalid value <value> ((<type>)) for font -> weight.`, flutter_tools'
        wording, or None for one of `FONT_WEIGHTS`.
    """
    if type(weight) == "int" and weight in FONT_WEIGHTS:
        return None
    return "Invalid value {value} (({type})) for font -> weight.".format(
        value = dart_str(weight),
        type = dart_type(weight),
    )

def font_style_problem(style):
    """The flutter_tools refusal for a font `style`, or None when it is valid.

    Args:
        style: The declared style value.

    Returns:
        `Invalid value <value> ((<type>)) for font -> style.`, flutter_tools'
        wording, or None for `"normal"` or `"italic"`.
    """
    if type(style) == "string" and style in FONT_STYLES:
        return None
    return "Invalid value {value} (({type})) for font -> style.".format(
        value = dart_str(style),
        type = dart_type(style),
    )

def font_file_table(label, font_files_dict):
    """The decoded-path to File table a `font_files` dict declares.

    Every entry must resolve to exactly one non-directory File and name one
    distinct path. Each failure names the declaring target and the entry it
    cannot use.

    Args:
        label: The declaring rule target, for the failure.
        font_files_dict: The rule's `ctx.attr.font_files`.

    Returns:
        A dict of normalized decoded asset path to that entry's File.
    """
    path_to_file = {}
    for target, asset_path in font_files_dict.items():
        files = target[DefaultInfo].files.to_list()
        if len(files) != 1:
            fail("%s: font_files entry %s must resolve to exactly one File; got %d" % (label, target.label, len(files)))
        if files[0].is_directory:
            fail("%s: font_files entry %s must name a font file, not directory %s." % (label, target.label, files[0].short_path))
        norm = normalize_asset_uri(asset_path)
        if not norm.ok:
            fail("%s: font_files value %s uses a spelling that is not supported: %s" % (label, repr(asset_path), norm.reason))
        if norm.is_dir:
            fail("%s: font_files value %s must name a font file, not a directory." % (label, repr(asset_path)))
        if norm.decoded in path_to_file:
            fail("%s: font_files names %s twice; keep one entry per asset." % (label, norm.decoded))
        path_to_file[norm.decoded] = files[0]
    return path_to_file

def _checked_font_asset(label, family, font):
    """Validate and normalize one font map's `asset` field.

    Args:
        label: The declaring rule target, for the failure.
        family: The family name, for the failure.
        font: One raw font entry from the family's `fonts` list.

    Returns:
        The normalized `normalize_asset_uri` struct for `font["asset"]`.
    """
    if type(font) != "dict":
        fail("%s: font family '%s' font entry %s must be a map with an `asset` path." % (label, family, dart_str(font)))
    if "asset" not in font or font["asset"] == None or font["asset"] == "":
        fail("%s: font family '%s' has a font entry with no asset path." % (label, family))
    asset = font["asset"]
    if type(asset) != "string":
        fail("%s: font family '%s': Expected font asset %s ((%s)) to be a string." % (
            label,
            family,
            dart_str(asset),
            dart_type(asset),
        ))
    norm = normalize_asset_uri(asset)
    if not norm.ok:
        fail("%s: font family '%s' asset %s uses a spelling that is not supported: %s" % (label, family, repr(asset), norm.reason))
    if norm.is_dir:
        fail("%s: font family '%s' asset %s must name a font file, not a directory." % (label, family, repr(asset)))
    return norm

def _checked_font(label, family, norm, font, file):
    """One font struct after the per-key checks, paired with `file`.

    Checks every present key: `weight` must be in `FONT_WEIGHTS`, `style` must
    be in `FONT_STYLES`, and any unknown key is refused with flutter_tools'
    wording. An absent `weight` or `style` reads as None; a present `null`
    value is rejected rather than silently unset.

    Args:
        label: The declaring rule target, for the failure.
        family: The family name, for the failure.
        norm: The font asset's `normalize_asset_uri` result, already `ok`.
        font: The raw font entry dict.
        file: The File that asset path names.

    Returns:
        A struct(asset_path, file, weight, style) for the family contribution.
    """
    for key, value in font.items():
        if key == "asset":
            continue
        if key == "weight":
            problem = font_weight_problem(value)
            if problem != None:
                fail("%s: font family '%s' font %s: %s" % (label, family, norm.decoded, problem))
        elif key == "style":
            problem = font_style_problem(value)
            if problem != None:
                fail("%s: font family '%s' font %s: %s" % (label, family, norm.decoded, problem))
        else:
            fail("%s: font family '%s' font %s: Unexpected key %s ((%s)) under font." % (
                label,
                family,
                norm.decoded,
                dart_str(key),
                dart_type(value),
            ))
    return struct(
        asset_path = norm.key,
        file = file,
        weight = font.get("weight"),
        style = font.get("style"),
    )

def font_json_contribution(label, package_name, family_entry, path_to_file):
    """One pub_fonts contribution from a decoded `fonts_json` family map.

    Each declared font pairs with the file its asset path names, never with
    the file at its index. An asset with no `font_files` entry fails naming
    the target, the family and the path, so a file list shorter than the font
    list cannot build.

    Args:
        label: The declaring rule target, for the failures.
        package_name: The contribution's package name (empty sentinel for
            bare family and asset paths).
        family_entry: One decoded `{family, fonts}` map.
        path_to_file: `font_file_table` for the declaring rule.

    Returns:
        A pub_fonts contribution struct.
    """
    if type(family_entry) != "dict":
        fail("%s: fonts_json must hold font-family maps; got %s." % (label, type(family_entry)))
    for key, value in family_entry.items():
        if key != "family" and key != "fonts":
            fail("%s: fonts_json: Unexpected key %s ((%s)) under font family." % (label, dart_str(key), dart_type(value)))
    family = family_entry.get("family")
    if type(family) != "string" or not family:
        fail("%s: fonts_json family entry needs a non-empty string `family`." % label)
    font_entries = family_entry.get("fonts")
    if type(font_entries) != "list":
        fail("%s: font family '%s' `fonts` must be a list of font maps." % (label, family))
    fonts = []
    files = []
    for font in font_entries:
        norm = _checked_font_asset(label, family, font)
        file = path_to_file.get(norm.decoded)
        if file == None:
            fail("%s: font family '%s' asset %s has no font_files entry; add it to font_files or remove the font." % (label, family, norm.decoded))
        fonts.append(_checked_font(label, family, norm, font, file))
        files.append(file)
    return struct(
        package_name = package_name,
        family = family,
        fonts = tuple(fonts),
        files = tuple(files),
        origin = str(label) if type(label) == "Label" else "",
    )

def _claimed_paths(family_entry):
    """The decoded asset paths one `fonts_json` family entry declares.

    Args:
        family_entry: One decoded family map.

    Returns:
        A list of normalized decoded paths for its readable `asset` values.
    """
    if type(family_entry) != "dict":
        return []
    raw_fonts = family_entry.get("fonts", [])
    if type(raw_fonts) != "list":
        return []
    claimed = []
    for font in raw_fonts:
        asset = font.get("asset") if type(font) == "dict" else None
        if type(asset) == "string" and asset:
            norm = normalize_asset_uri(asset)
            if norm.ok and not norm.is_dir:
                claimed.append(norm.decoded)
    return claimed

def check_unclaimed_font_files(label, decoded, path_to_file):
    """Fail when a `font_files` entry is named by no family in `fonts_json`.

    Args:
        label: The declaring rule target, for the failure.
        decoded: The decoded `fonts_json` family list.
        path_to_file: `font_file_table` for the declaring rule.
    """
    claimed = {}
    families = []
    for family_entry in decoded:
        if type(family_entry) == "dict" and type(family_entry.get("family")) == "string" and family_entry.get("family"):
            families.append("'%s'" % family_entry["family"])
        for path in _claimed_paths(family_entry):
            claimed[path] = True
    family_note = " (declared families: %s)" % ", ".join(families) if families else " (no families declared)"
    for path in path_to_file:
        if path not in claimed:
            fail("%s: font_files entry %s is named by no family in fonts_json%s; remove it or add a font that uses it." % (
                label,
                path,
                family_note,
            ))

def font_family_contribution(target, package_name):
    """The pub_fonts contribution for one `flutter_font_family` target.

    Prefixing belongs to the consumer: an application passes the empty
    sentinel (bare family and asset paths), a library its `package_name`.

    Args:
        target: A `flutter_font_family` target.
        package_name: The contribution's package name (empty sentinel for
            bare family and asset paths).

    Returns:
        A pub_fonts contribution struct.
    """
    info = target[FlutterFontFamilyInfo]
    return struct(
        package_name = package_name,
        family = info.family,
        fonts = info.fonts,
        files = tuple([font.file for font in info.fonts]),
        origin = str(target.label),
    )

def font_family_contributions(targets, package_name):
    """The pub_fonts contributions for a rule's `fonts` attribute.

    Args:
        targets: The `fonts` attribute's `flutter_font_family` targets, in
            declaration order.
        package_name: The contribution's package name (empty sentinel for
            bare family and asset paths).

    Returns:
        A list of pub_fonts contribution structs.
    """
    return [font_family_contribution(target, package_name) for target in targets]

def _flutter_font_family_impl(ctx):
    """Validate one font family declaration and return `FlutterFontFamilyInfo`.

    Args:
        ctx: The `_flutter_font_family` rule context.

    Returns:
        `[DefaultInfo, FlutterFontFamilyInfo]` for the declared family.
    """
    if not ctx.attr.family:
        fail("%s: `flutter_font_family` needs a non-empty `family`." % ctx.label)
    decoded = json.decode(ctx.attr.fonts_json)
    if type(decoded) != "list" or not decoded:
        fail("%s: `flutter_font_family` needs a non-empty `fonts` list; give each font an `asset`." % ctx.label)
    contribution = font_json_contribution(
        ctx.label,
        "",
        {"family": ctx.attr.family, "fonts": decoded},
        font_file_table(ctx.label, ctx.attr.font_files),
    )
    return [
        DefaultInfo(files = depset([font.file for font in contribution.fonts])),
        FlutterFontFamilyInfo(family = ctx.attr.family, fonts = contribution.fonts),
    ]

_flutter_font_family = rule(
    implementation = _flutter_font_family_impl,
    attrs = {
        "family": attr.string(
            doc = "The family name the app asks for in `TextStyle(fontFamily:)`. Must be non-empty.",
            mandatory = True,
        ),
        "font_files": attr.label_keyed_string_dict(
            doc = "Font file label to asset path, one entry per font. The macro builds this from `fonts`; do not set it directly.",
            allow_files = True,
            mandatory = True,
        ),
        "fonts_json": attr.string(
            doc = "JSON-encoded `fonts` list, one entry per font with its `asset` and optional `weight`/`style`. The macro builds this from `fonts`; do not set it directly.",
            mandatory = True,
        ),
    },
    doc = "Internal target behind `flutter_font_family`: carries one declared family and its fonts.",
)

def flutter_font_family(name, family = "", fonts = [], **kwargs):
    """Declares one font family for `flutter_application.fonts` or `flutter_library.fonts`.

    Mirrors one `flutter: fonts:` family from `pubspec.yaml`. List the target
    in an application's `fonts` to bundle the family bare (`HelloSans`,
    `fonts/HelloSans-Regular.ttf`), as flutter_tools writes the root
    pubspec's, or in a library's `fonts` to bundle it under
    `packages/<package_name>/`.

    ```starlark
    flutter_font_family(
        name = "hello_sans",
        family = "HelloSans",
        fonts = [
            {"asset": "fonts/HelloSans-Regular.ttf"},
            {"asset": "fonts/HelloSans-Bold.ttf", "weight": 700},
        ],
    )
    ```

    Args:
        name: Name of the font-family target that other rules list in their font attributes.
        family: The family name the app asks for in `TextStyle(fontFamily:)`.
            Must be non-empty.
        fonts: A list of font maps, in `FontManifest.json` order. Each map
            names `asset`, the path of a file in the calling package, and
            optionally `weight` (one of 100, 200, ..., 900) and `style`
            (`"normal"` or `"italic"`). The list must be non-empty and every
            entry must name an asset; a wrong weight, style, or a missing
            file fails analysis naming this target, the family and the path.
        **kwargs: Other attributes forwarded to the underlying rule, such as
            `tags` or `visibility`.
    """
    font_files = {}
    if type(fonts) == "list":
        for font in fonts:
            asset = font.get("asset") if type(font) == "dict" else None
            if type(asset) == "string" and asset:
                norm = normalize_asset_uri(asset)
                if norm.ok and not norm.is_dir:
                    font_files[":" + norm.decoded] = norm.key
    _flutter_font_family(
        name = name,
        family = family if type(family) == "string" else "",
        fonts_json = json.encode(fonts),
        font_files = font_files,
        **kwargs
    )
