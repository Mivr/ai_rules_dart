"""Project a pub package's decoded pubspec.yaml `flutter:` block.

The pubspec is read by the caller with `yaml_to_json` from
`@rules_dart//dart/pub:yaml.bzl`, which fails naming the file on anything
that is not one YAML mapping. Booleans arrive as booleans, empty values as
None and every other scalar as a string holding its source text. This
module projects the decoded value down to the shapes rules_flutter
consumes:

- `parse_flutter_plugin_block` — `flutter.plugin` for plugin-spoke emission.
- `parse_flutter_assets_block` — `flutter.{fonts,assets,shaders,uses-material-design}`
  for the asset-bundling pipeline.

Parsing stays lenient (every readable shape loads), and `parse_flutter_assets_block`
additionally validates the section the way flutter_tools 3.47.7 `_validate`
(`packages/flutter_tools/lib/src/flutter_manifest.dart`, plus
`Plugin.validatePluginYaml` and each platform's `validate`) validates it: any
error flutter_tools reports is one refusal in `asset_errors`, and the spoke
fails the fetch on each through the single `check_asset_entry_problems` path,
naming the package, `pubspec.yaml` and the offending entry. The per-key checks
live in `flutter_manifest_validate.bzl`, which shares this module's asset and
font parsers. Shapes flutter_tools only warns on stay silently skipped.

Schema reference (Flutter's pubspec):

    flutter:
      uses-material-design: bool
      fonts:
        - family: <name>
          fonts:
            - asset: <path>
              weight: <100..900>     # optional
              style: <italic|normal> # optional
      assets:
        - <path>                     # string form
        - path: <path>               # map form (modern)
          flavors: [<flavor>, ...]
          platforms: [<platform>, ...]
      shaders:
        - <path>
      plugin:
        implements: <umbrella>
        platforms:
          <platform>:
            pluginClass: <Class>
            ...
"""

load(
    ":flutter_manifest_validate.bzl",
    "dart_str",
    "dart_type",
    "validate_flutter_section",
    "validate_pubspec_root",
)

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
# flutter.fonts / flutter.assets / flutter.shaders / flutter.uses-material-design
# ---------------------------------------------------------------------------

def _shape_problem(path, key, detail):
    """One spoke-fetch refusal for a malformed `flutter:` section shape.

    Args:
        path: The entry the problem is reported against: a real entry path,
            an indexed `key[index]` slot, or the key itself for a
            whole-section shape.
        key: `"assets"`, `"fonts"` or `"shaders"`, for the failure message.
        detail: The complaint, worded like flutter_tools where it has one.

    Returns:
        A `struct(path, key, detail)` as `check_asset_entry_problems` takes it.
    """
    return struct(path = path, key = key, detail = detail)

def _expected_list_problem(key, raw):
    """The refusal for a non-list `flutter:` section value.

    Mirrors `_computeAssetsSafe` and the `fonts` check in `_validate`
    (`packages/flutter_tools/lib/src/flutter_manifest.dart`): `Expected
    "assets" to be a list, ...`. `None` (an absent section) is valid and
    never reaches here; every other non-list shape fails the fetch.

    Args:
        key: `"assets"`, `"fonts"` or `"shaders"`.
        raw: The raw section value.

    Returns:
        The refusal struct; the caller fails the fetch on it.
    """
    return _shape_problem(
        key,
        key,
        "Expected \"{key}\" to be a list, but got {value} ({type}).".format(
            key = key,
            value = dart_str(raw),
            type = dart_type(raw),
        ),
    )

def _parse_path_entry(item, index, key, shown):
    """Split one `assets`/`shaders` list item into its path or its refusal.

    Mirrors `AssetsEntry.parseFromYamlSafe`, which serves both sections
    (`packages/flutter_tools/lib/src/flutter_manifest.dart`): null or empty
    is a `null or empty uri` refusal, a string is the entry, an empty map is
    silently no entry, a map whose `path` is not a string is `malformed`,
    and anything else has an `unexpected shape`. The returned shape records
    which reading the normalizer must use: a string reads like `Uri.parse`,
    a map reads like `Uri(pathSegments: path.split('/'))`
    (RT38-flutter:01); the caller threads it, never guesses it from the
    text.

    Args:
        item: The raw list item.
        index: Its index in the section list, for the problem path.
        key: `"assets"` or `"shaders"`, for the problem key.
        shown: The problem-path slot prefix (`"assets"`, `"shaders"`, or a
            deferred `deferred-components[i].assets` slot).

    Returns:
        A `(path, is_map, problems)` tuple: the entry path, whether it came
        from a map-form item, or None when the item is no entry, and the
        refusal structs (empty when the item is usable or silently
        skipped).
    """
    slot = "{shown}[{index}]".format(shown = shown, index = index)
    if item == None or item == "":
        return (None, False, [_shape_problem(slot, key, "Asset manifest contains a null or empty uri.")])
    if type(item) == "string":
        return (item, False, [])
    if type(item) == "dict":
        if not item.keys():
            return (None, False, [])
        path = item.get("path")
        if type(path) == "string":
            return (path, True, [])
        return (None, False, [_shape_problem(
            slot,
            key,
            "Asset manifest entry is malformed. Expected asset entry to be " +
            "either a string or a map containing a \"path\" entry. " +
            "Got {type} instead.".format(type = dart_type(path)),
        )])
    return (None, False, [_shape_problem(
        slot,
        key,
        "Assets entry had unexpected shape. Expected a string or an object. " +
        "Got {type} instead.".format(type = dart_type(item)),
    )])

# The font weights flutter_tools accepts (`_validateFonts` in
# `packages/flutter_tools/lib/src/flutter_manifest.dart`): a present `weight`
# holding anything else is an invalid value, never silently unset.
_FONT_WEIGHTS = (100, 200, 300, 400, 500, 600, 700, 800, 900)

_DIGITS = "0123456789"

def _is_digits(text):
    """Whether `text` is one or more ASCII digits."""
    if text == "":
        return False
    for ch in text.elems():
        if ch not in _DIGITS:
            return False
    return True

_HEX_DIGITS = "0123456789abcdefABCDEF"
_OCTAL_DIGITS = "01234567"

def _all_in(text, alphabet):
    """Whether `text` is one or more characters of `alphabet`."""
    if text == "":
        return False
    for ch in text.elems():
        if ch not in alphabet:
            return False
    return True

def _weight_number(value):
    """Read a decoded font `weight` as the number `package:yaml` reads in its text.

    The decoded pubspec spells `weight: 700` and `weight: "700"` both as the
    string `"700"`, so the weight is read from its text the way
    `package:yaml` (which flutter_tools reads the pubspec with) reads an
    unquoted scalar: an optional sign and digits are a decimal int, `0x`
    and hex digits a hex int, `0o` and octal digits (with an optional sign
    after the prefix, as Dart's `int.tryParse` takes it) an octal int, and
    a decimal followed by `.` and only zeros (`400.0`) a whole-number
    float. Anything else, a bool, None, a collection, or a float spelled
    with an exponent (`4e2`, which stock flutter_tools reads as a double
    too), is neither.

    Args:
        value: The decoded `weight` value.

    Returns:
        `struct(kind, number)`: `kind` is `"int"`, `"double"` or `""`, and
        `number` the whole number for the first two (else None).
    """
    if type(value) != "string":
        return struct(kind = "", number = None)
    if value.startswith("0x") and _all_in(value[2:], _HEX_DIGITS):
        return struct(kind = "int", number = int(value[2:], 16))
    if value.startswith("0o"):
        rest = value[2:]
        sign = 1
        if rest.startswith("-") or rest.startswith("+"):
            sign = -1 if rest.startswith("-") else 1
            rest = rest[1:]
        if _all_in(rest, _OCTAL_DIGITS):
            return struct(kind = "int", number = sign * int(rest, 8))
        return struct(kind = "", number = None)
    sign = 1
    text = value
    if text.startswith("-") or text.startswith("+"):
        sign = -1 if text.startswith("-") else 1
        text = text[1:]
    whole, dot, fraction = text.partition(".")
    if not _is_digits(whole):
        return struct(kind = "", number = None)
    number = sign * int(whole.lstrip("0") or "0")
    if not dot:
        return struct(kind = "int", number = number)
    if fraction.strip("0") != "":
        return struct(kind = "", number = None)
    return struct(kind = "double", number = number)

def _font_file_key_problems(item, slot):
    """The refusals for one font file entry's keys, in document order.

    Mirrors the per-key loop of `_validateFonts`
    (`packages/flutter_tools/lib/src/flutter_manifest.dart`): a present
    `weight` must be one of 100..900, a present `style` must be `normal`
    or `italic`, and any other key is `Unexpected`. Each bad key is
    reported (a non-string key, which flutter_tools reports twice, cannot
    arise: every decoded key is a string); an
    absent `weight` or `style` stays valid. The weight is read as the
    number its text spells (see `_weight_number`), so `700` and `"700"`
    both read as the int 700, as flutter_tools reads the unquoted one. A
    whole-number float `weight` (`400.0`) passes flutter_tools' validation
    (Dart `400.0 == 400` holds, so `fontWeights.contains` accepts it) but no
    build can read it (`flutter_manifest.dart:422` casts the weight with
    `as int?`), so on an entry carrying `asset` it fails saying that instead
    of quoting a validation error flutter_tools never prints. The build
    skips an entry with no `asset` before any cast
    (`flutter_manifest.dart:413-416`), so a whole-number float `weight`
    there stays silent. Every other non-member `weight` (an out-of-range
    number like `150` or `150.0`, a fractional `350.5`, a word, a bool, a
    null or a collection) keeps flutter_tools' own `Invalid value` refusal.

    Args:
        item: The raw font file mapping, with or without `asset`.
        slot: The `fonts[index]` problem path of the owning family entry.

    Returns:
        The refusal structs for `asset_errors`.
    """
    problems = []

    # The build reads a file entry's weight only when the entry carries an
    # `asset` (entries without one are skipped before any cast), so the
    # unreadable-weight refusal applies only then.
    weight_readable = type(item.get("asset")) == "string"
    for key in item.keys():
        value = item[key]
        if key == "asset":
            if type(value) != "string":
                problems.append(_shape_problem(
                    slot,
                    "fonts",
                    "Expected font asset {value} (({type})) to be a string.".format(
                        value = dart_str(value),
                        type = dart_type(value),
                    ),
                ))
        elif key == "weight":
            weight = _weight_number(value)
            if weight.kind == "double" and weight.number in _FONT_WEIGHTS:
                if weight_readable:
                    problems.append(_shape_problem(
                        slot,
                        "fonts",
                        "Font weight {value} ((double)) must be an int: flutter_tools 3.47.7 cannot read it (flutter_manifest.dart:422 casts the weight with 'as int?').".format(
                            value = dart_str(value),
                        ),
                    ))
            elif weight.kind != "int" or weight.number not in _FONT_WEIGHTS:
                problems.append(_shape_problem(
                    slot,
                    "fonts",
                    "Invalid value {value} (({type})) for font -> weight.".format(
                        value = weight.number if weight.kind == "int" else dart_str(value),
                        type = weight.kind or dart_type(value),
                    ),
                ))
        elif key == "style":
            if value != "normal" and value != "italic":
                problems.append(_shape_problem(
                    slot,
                    "fonts",
                    "Invalid value {value} (({type})) for font -> style.".format(
                        value = dart_str(value),
                        type = dart_type(value),
                    ),
                ))
        else:
            problems.append(_shape_problem(
                slot,
                "fonts",
                "Unexpected key {key} (({type})) under font.".format(
                    key = key,
                    type = dart_type(value),
                ),
            ))
    return problems

def _parse_font_files(fonts_raw, slot):
    """Parse one family's `fonts` list into font structs or refusals.

    Mirrors the inner loop of `_extractFonts` and the `weight` / `style` /
    extra-key checks of `_validateFonts`
    (`packages/flutter_tools/lib/src/flutter_manifest.dart`): a non-map
    file entry is `Expected "fonts" to be a list of maps`, every key of
    every file mapping runs the per-key checks whether or not the entry
    carries `asset` (a missing `asset` with no other problem stays
    silently skipped, a warning only), a non-string `asset` is `Expected
    font asset ... to be a string`, a present `weight` must be one of
    100..900, a present `style` must be `normal` or `italic`, and any
    other key is `Unexpected`. An absent `weight` or `style` stays valid
    and reads as None.

    Args:
        fonts_raw: The raw `fonts` list of one family entry.
        slot: The `fonts[index]` problem path of the owning family entry.

    Returns:
        A `(fonts, problems)` tuple of `struct(asset, weight, style)`
        entries and refusal structs for `asset_errors`.
    """
    fonts = []
    problems = []
    for item in fonts_raw:
        if type(item) != "dict":
            problems.append(_shape_problem(
                slot,
                "fonts",
                "Expected \"fonts\" to be a list of maps.",
            ))
            continue
        problems.extend(_font_file_key_problems(item, slot))
        asset = item.get("asset")
        if type(asset) != "string":
            continue
        weight = _weight_number(item.get("weight"))
        style = item.get("style")
        fonts.append(struct(
            asset = asset,
            weight = weight.number if weight.kind == "int" and weight.number in _FONT_WEIGHTS else None,
            style = style if style == "normal" or style == "italic" else None,
        ))
    return (fonts, problems)

def _parse_font_family(entry, index):
    """Parse one `fonts` list entry into a family struct or refusals.

    Mirrors `_validateFonts`
    (`packages/flutter_tools/lib/src/flutter_manifest.dart`): any key
    besides `family` and `fonts` is `Unexpected child ... under "fonts"`, a
    missing (null) `family` is silently skipped, a non-string one is `Font
    family must either be null or a String`; a missing or null per-family
    `fonts` stays the empty list, a non-list one is `Expected "fonts" to
    either be null or a list`.

    Args:
        entry: The raw family mapping.
        index: Its index in the `fonts` list, for the problem path.

    Returns:
        A `(family, problems)` tuple: `struct(family, fonts)` or None, and
        the refusal structs for `asset_errors`.
    """
    slot = "fonts[{index}]".format(index = index)
    problems = []
    for key in entry.keys():
        if key != "family" and key != "fonts":
            problems.append(_shape_problem(
                slot,
                "fonts",
                "Unexpected child \"{key}\" found under \"fonts\".".format(key = key),
            ))
    family = entry.get("family")
    if family == None:
        return (None, problems)
    if type(family) != "string":
        problems.append(_shape_problem(
            slot,
            "fonts",
            "Font family must either be null or a String.",
        ))
        return (None, problems)
    fonts_raw = entry.get("fonts", [])
    if fonts_raw == None:
        fonts_raw = []
    if type(fonts_raw) != "list":
        problems.append(_shape_problem(
            slot,
            "fonts",
            "Expected \"fonts\" to either be null or a list.",
        ))
        return (None, problems)
    (fonts, file_problems) = _parse_font_files(fonts_raw, slot)
    problems.extend(file_problems)
    return (struct(family = family, fonts = fonts), problems)

def _parse_fonts(raw):
    """Parse the raw `flutter.fonts` list, collecting malformed shapes.

    Mirrors the `fonts` checks in `_validate` and `_validateFonts`
    (`packages/flutter_tools/lib/src/flutter_manifest.dart`): a present
    but empty section value, a non-list section, a non-map entry, a
    non-string `family`, a non-list per-family `fonts`, a non-map font
    file entry and a non-string `asset` are each a refusal; entries
    flutter_tools only warns on stay silently skipped (a missing family;
    a file entry without an `asset` key whose other keys are clean),
    exactly as on main. When the
    first element is not a map the whole list is one refusal naming the
    value, and the remaining entries are not checked further.

    Args:
        raw: The raw `flutter.fonts` YAML value (None when absent).

    Returns:
        A `(fonts, problems)` tuple of `struct(family, fonts)` entries and
        refusal structs for `asset_errors`.
    """
    if raw == None:
        return ([], [_expected_list_problem("fonts", raw)])
    if type(raw) != "list":
        return ([], [_expected_list_problem("fonts", raw)])
    if len(raw) > 0 and type(raw[0]) != "dict":
        return ([], [_shape_problem(
            "fonts",
            "fonts",
            "Expected \"fonts\" to contain maps, but the first element is {value} ({type}).".format(
                value = dart_str(raw),
                type = dart_type(raw),
            ),
        )])
    out = []
    problems = []
    for index, entry in enumerate(raw):
        if type(entry) != "dict":
            problems.append(_shape_problem(
                "fonts[{index}]".format(index = index),
                "fonts",
                "Unexpected child {value} found under \"fonts\". Expected a map.".format(
                    value = dart_str(entry),
                ),
            ))
            continue
        (family, family_problems) = _parse_font_family(entry, index)
        problems.extend(family_problems)
        if family != None:
            out.append(family)
    return (out, problems)

# The platform names an `assets` / `shaders` entry may carry, in flutter_tools'
# `_kValidPluginPlatforms` order
# (`packages/flutter_tools/lib/src/flutter_manifest.dart`): anything else is
# an `Invalid platform(s)` refusal, worded like
# `AssetsEntry._parsePlatformsSection`.
VALID_ASSET_PLATFORMS = ("android", "ios", "web", "windows", "linux", "macos")

def _parse_condition_list(raw_value, key):
    """Validate one asset entry `flavors` / `platforms` value, flutter_tools style.

    Mirrors `AssetsEntry._parseFlavorsSection` / `_parsePlatformsSection`
    (`_parseList` in `flutter_manifest.dart`): an absent value reads as
    null and is valid; anything else must be a list of strings. A scalar
    `platforms: web` is one error, and every non-string element is
    reported, not just the first, so the caller can wrap them the way
    `parseFromYamlSafe` joins its section errors. A `platforms` list that
    parses but names anything outside `VALID_ASSET_PLATFORMS` is one
    `Invalid platform(s)` error, like `_parsePlatformsSection` reports.

    Args:
        raw_value: The value under the key (None when the key is absent).
        key: `"flavors"` or `"platforms"`, for the problem detail.

    Returns:
        A `(values, problem)` tuple: the string list (empty when the
        value errors) and "" or the newline-joined `Expected <key> to be
        a list of String, but ...` details naming the key.
    """
    if raw_value == None:
        return ([], "")
    if type(raw_value) != "list":
        return ([], "Expected {key} to be a list of String, but got {value} ({type}).".format(
            key = key,
            value = dart_str(raw_value),
            type = dart_type(raw_value),
        ))
    values = []
    bad = []
    for index, item in enumerate(raw_value):
        if type(item) != "string":
            bad.append("Expected {key} to be a list of String, but element at index {index} was a {type}.".format(
                key = key,
                index = index,
                type = dart_type(item),
            ))
        else:
            values.append(item)
    if bad:
        return ([], "\n".join(bad))
    if key == "platforms":
        unknown = []
        for value in values:
            if value not in VALID_ASSET_PLATFORMS and value not in unknown:
                unknown.append(value)
        if unknown:
            return ([], "Invalid platform(s): \"{unknown}\". Supported platforms are: \"{valid}\".".format(
                unknown = ", ".join(unknown),
                valid = ", ".join(VALID_ASSET_PLATFORMS),
            ))
    return (values, "")

def _section_error(path, section, inner):
    """Wrap a condition-list complaint the way flutter_tools wraps it.

    Mirrors `AssetsEntry.parseFromYamlSafe`
    (`packages/flutter_tools/lib/src/flutter_manifest.dart`): a bad
    `flavors` / `platforms` / `transformers` value is `Unable to parse
    assets section.\nIn {section} section of asset "{path}": {inner}`.
    """
    return "Unable to parse assets section.\nIn {section} section of asset \"{path}\": {inner}".format(
        section = section,
        path = path,
        inner = inner,
    )

def _condition_problems(path, item, cond_key):
    """Validate one asset entry `flavors` / `platforms` value as a refusal.

    Args:
        path: The entry path, for the problem path.
        item: The raw entry mapping.
        cond_key: `"flavors"` or `"platforms"`.

    Returns:
        A `(values, problems)` tuple: the string list (possibly empty) and
        the refusal structs (at most one) for `asset_errors`.
    """
    (values, detail) = _parse_condition_list(item.get(cond_key), cond_key)
    if not detail:
        return (values, [])
    return (values, [_shape_problem(
        path,
        cond_key,
        _section_error(path, cond_key, detail),
    )])

def _entry_condition_problems(path, item):
    """Validate one entry's `flavors` / `platforms` values as refusals.

    Shared by the `assets` and `shaders` parsers: flutter_tools validates
    both sections with the same `_validateAssets`
    (`packages/flutter_tools/lib/src/flutter_manifest.dart`), so a shader
    map entry whose conditions are malformed fails exactly like an asset
    entry's do, with the same wrapped `Unable to parse assets section`
    refusal. That includes a `platforms` value naming an unknown
    platform (`_parsePlatformsSection` reports `Invalid platform(s)`).

    Args:
        path: The entry path, for the problem path.
        item: The raw entry mapping.

    Returns:
        A `(flavors, platforms, problems)` tuple: the string lists (empty
        when the value errors) and the refusal structs for `asset_errors`.
    """
    (flavors, flavor_problems) = _condition_problems(path, item, "flavors")
    (platforms, platform_problems) = _condition_problems(path, item, "platforms")
    return (flavors, platforms, flavor_problems + platform_problems)

def _entry_transformer_problems(path, item):
    """Collect shape problems when an entry carries unsupported transformers."""
    if item.get("transformers") == None:
        return []
    return [_shape_problem(path, "transformers", "asset transformers are not supported by rules_flutter.")]

def _parse_assets(raw, shown):
    """Parse the raw `flutter.assets` list, collecting malformed entries.

    A list item that is neither a usable string nor a map with a string
    `path` is a refusal shaped like flutter_tools'
    `AssetsEntry.parseFromYamlSafe`
    (`packages/flutter_tools/lib/src/flutter_manifest.dart`); a map
    entry's `flavors` / `platforms` must each be a list of strings naming
    known platforms (a bad one is the wrapped `Unable to parse assets section`
    refusal), and an
    entry must not carry `transformers` (rules_flutter does not run asset
    transformers; shipping the untransformed file would silently do the
    wrong thing). Problems are collected, not failed here, so unit tests
    can assert them; the spoke fails the fetch on each (see
    `check_asset_entry_problems`) naming the package, `pubspec.yaml` and
    the entry. Any other unknown key in an entry mapping is ignored, the way
    flutter_tools ignores it. Deferred-component asset lists share this
    validator (their entries are validated only, never bundled).

    Args:
        raw: The raw `flutter.assets` YAML value (None when absent).
        shown: The problem-path slot prefix (`"assets"`, `"shaders"`, or a
            deferred `deferred-components[i].assets` slot).

    Returns:
        An `(entries, problems)` tuple: `entries` holds one
        `struct(path, is_map, flavors, platforms)` per usable entry (a
        problem entry keeps empty conditions; the fetch fails before they
        matter), and `problems` holds one `struct(path, key, detail)` per
        refusal.
    """
    if raw == None:
        return ([], [])
    if type(raw) != "list":
        return ([], [_expected_list_problem("assets", raw)])
    entries = []
    problems = []
    for index, item in enumerate(raw):
        (path, is_map, shape_problems) = _parse_path_entry(item, index, "assets", shown)
        problems.extend(shape_problems)
        if path == None:
            continue
        flavors, platforms = [], []
        if type(item) == "dict":
            (flavors, platforms, condition_problems) = _entry_condition_problems(path, item)
            problems.extend(condition_problems + _entry_transformer_problems(path, item))
        entries.append(struct(path = path, is_map = is_map, flavors = flavors, platforms = platforms))
    return (entries, problems)

def _format_flavor_list(flavors):
    """Render a `flavors` list as `["a", "b"]`, or `[]` when it is empty."""
    return "[" + ", ".join(["\"%s\"" % f for f in flavors]) + "]"

def asset_flavor_error(package_name, asset_path, flavors_a, flavors_b):
    """The fetch failure for entries for one file with different flavors.

    Mirrors flutter_tools' `_checkForFlavorConflicts`: flavor lists compare
    as sets, so an entry without flavors conflicts with one that has some.
    Names the package, the file and both flavor lists.

    Args:
        package_name: The pub package the entries come from.
        asset_path: The file both entries expand to.
        flavors_a: The first entry's `flavors` list.
        flavors_b: The conflicting entry's `flavors` list.

    Returns:
        The error string; the caller `fail()`s with it.
    """
    return (
        "flutter.pub spoke for \"{pkg}\": asset \"{path}\" lists conflicting " +
        "flavors {first} vs {second}. Entries for one file must agree on " +
        "flavors (compared as sets)."
    ).format(
        pkg = package_name,
        path = asset_path,
        first = _format_flavor_list(flavors_a),
        second = _format_flavor_list(flavors_b),
    )

def _parse_shaders(raw):
    """Parse the raw `flutter.shaders` list, collecting malformed shapes.

    Mirrors `_computeAssetsSafe`, which serves both `assets` and `shaders`
    (`packages/flutter_tools/lib/src/flutter_manifest.dart`): a non-list
    section, a null or empty entry, a non-string non-map item and a map
    whose `path` is not a string are each a refusal; an empty map is
    silently no entry, exactly as flutter_tools reads it. A map entry's
    `flavors` / `platforms` run the same condition checks an asset entry's
    do (`_entry_condition_problems`), with the same messages, and `transformers`
    is refused like an asset entry's (`_entry_transformer_problems`).
    Conditions travel with the entry so the bundler can filter it like an asset.
    A `path` entry that reads keeps its conditions; the fetch still fails on the
    problems first.

    Args:
        raw: The raw `flutter.shaders` YAML value (None when absent).

    Returns:
        A `(shaders, problems)` tuple of
        `struct(path, is_map, flavors, platforms)` entries and refusal
        structs for `asset_errors`.
    """
    if raw == None:
        return ([], [])
    if type(raw) != "list":
        return ([], [_expected_list_problem("shaders", raw)])
    out = []
    problems = []
    for index, entry in enumerate(raw):
        (path, is_map, shape_problems) = _parse_path_entry(entry, index, "shaders", "shaders")
        problems.extend(shape_problems)
        if path == None:
            continue
        flavors, platforms = [], []
        if type(entry) == "dict":
            (flavors, platforms, condition_problems) = _entry_condition_problems(path, entry)
            problems.extend(condition_problems + _entry_transformer_problems(path, entry))
        out.append(struct(path = path, is_map = is_map, flavors = flavors, platforms = platforms))
    return (out, problems)

def _deferred_assets_check(raw, shown):
    """Validate one deferred-component `assets` value, discarding its entries.

    Args:
        raw: The raw `assets` value of one `deferred-components` element.
        shown: The problem-path slot prefix for its entries.

    Returns:
        The value's asset problems (entries are validated only, never
        bundled).
    """
    return _parse_assets(raw, shown)[1]

def parse_flutter_assets_block(pubspec):
    """Parse `flutter.fonts`, `flutter.assets`, `flutter.shaders`, and `flutter.uses-material-design`.

    Args:
        pubspec: The decoded pubspec.yaml mapping.

    Returns:
        struct(
            fonts:    list[struct(family, fonts=list[struct(asset, weight, style)])],
            assets:   list[struct(path, is_map, flavors, platforms)],
            shaders:  list[struct(path, is_map, flavors, platforms)],
            uses_material_design: bool,
            asset_errors: list[struct(path, key, detail)],
        )

    `weight` and `style` on a font are None when unset. `flavors`/`platforms`
    are the modern-shape entry conditions the bundler filters on
    (`pub_asset_matches_target` checks flavor first, then platform, with the
    `tester` exception, exactly like flutter_tools' `matchesFlavor` /
    `matchesPlatform`); an unknown platform fails the spoke fetch. Asset and
    shader entries carry the same condition fields, because flutter_tools
    validates and filters both with the same asset code.
    `asset_errors` collects the entries flutter_tools would refuse: a
    `name` that is not a scalar, a `flutter.assets`
    / `flutter.shaders` / `flutter.fonts` section that is present but
    not a list (an empty `flutter.fonts` value counts), an
    asset or shader item that is neither a string nor a map with a string
    `path`, a `flutter.fonts` section that is not a list, a non-map font
    entry, a non-string `family`, a non-list per-family `fonts`, a non-map
    font file entry, a non-string font `asset`, an invalid font `weight`
    or `style` (a whole-number float `weight` on an entry carrying `asset`
    fails as unreadable by flutter_tools 3.47.7 instead; without `asset`
    it stays silent), an unexpected key in a font (checked
    whether or not the file entry carries `asset`), a `flavors` /
    `platforms` value that is not a list of strings, or a `platforms`
    value naming an unknown platform, on an asset or a shader entry, an
    entry carrying
    `transformers`, a `flutter:` section that is neither a map nor null,
    an empty `deferred-components` list (flutter_tools crashes reading
    one), and every other `flutter:` child flutter_tools `_validate` rejects
    (`uses-material-design`, `licenses`, `module`, `plugin`,
    `deferred-components`, `disable-swift-package-manager`,
    `default-flavor`, unknown children); the spoke fails the fetch on each
    (see `check_asset_entry_problems`), naming the package, `pubspec.yaml`
    and the entry.
    """
    root_problems = validate_pubspec_root(pubspec)
    raw_flutter = pubspec.get("flutter")
    if raw_flutter == None:
        flutter = {}
        flutter_problem = []
    elif type(raw_flutter) != "dict":
        flutter = {}
        flutter_problem = [_shape_problem(
            "flutter",
            "flutter",
            "Expected \"flutter\" section to be an object or null, but got {value}.".format(
                value = dart_str(raw_flutter),
            ),
        )]
    else:
        flutter = raw_flutter
        flutter_problem = []
    umd_raw = flutter.get("uses-material-design", False)
    (assets, asset_problems) = _parse_assets(flutter.get("assets"), "assets")
    if "fonts" in flutter:
        (fonts, font_problems) = _parse_fonts(flutter["fonts"])
    else:
        (fonts, font_problems) = ([], [])
    (shaders, shader_problems) = _parse_shaders(flutter.get("shaders"))
    section_problems = validate_flutter_section(flutter, _deferred_assets_check)
    return struct(
        fonts = fonts,
        assets = assets,
        shaders = shaders,
        uses_material_design = umd_raw if type(umd_raw) == "bool" else False,
        asset_errors = (
            root_problems + asset_problems + font_problems + shader_problems + flutter_problem + section_problems
        ),
    )
