"""Fail-closed validation of a pub package's `flutter:` section, mirroring flutter_tools.

flutter_tools 3.47.7 validates every package's pubspec with `_validate` in
`packages/flutter_tools/lib/src/flutter_manifest.dart` (and what it calls:
`_validateFlutter`, `_validateFonts`, `_computeAssetsSafe`,
`_validateDeferredComponents`, `_parseList`, and `Plugin.validatePluginYaml`
in `plugins.dart` with each platform's `validate` in `platform_plugins.dart`).
Any error it reports stops an app's build ("Please correct the pubspec.yaml
file"); for a dependency package its assets, fonts and licenses are dropped.

`parse_flutter_assets_block` in `flutter_pubspec.bzl` parses the section
leniently, so this module re-checks the parsed value with the same checks and
returns one refusal per error. The spoke fails the fetch on each through the
single `asset_errors` / `check_asset_entry_problems` path, naming the package,
`pubspec.yaml` and the offending line. Refusal details reuse flutter_tools'
wording, including its Dart value and type spellings (`null`, `true`, `Null`,
`String`, `YamlList`, `YamlMap`). Shapes flutter_tools only warns on (a font
family without `family`, an empty map asset entry, and a font file entry
without `asset` whose other keys are clean) stay silent. An empty
`deferred-components` list is refused:
flutter_tools 3.47.7 crashes reading one, so it cannot build.
"""

visibility(["//flutter/..."])

def _refusal(path, key, detail, line):
    """One `asset_errors` refusal for a malformed `flutter:` section shape.

    Args:
        path: The entry the problem is reported against: a real entry path,
            an indexed `key[index]` slot, or the key itself for a
            whole-section shape.
        key: The section key (`"assets"`, `"fonts"`, `"plugin"`, ...), for
            the failure message.
        detail: The complaint, worded like flutter_tools where it has one.
        line: The 1-based `pubspec.yaml` line of the offending key or entry.

    Returns:
        A `struct(path, key, detail, line)` as `check_asset_entry_problems`
        takes it.
    """
    return struct(path = path, key = key, detail = detail, line = line)

def _dart_scalar(value):
    """Render one scalar `value` the way Dart string interpolation renders it.

    An empty value reads `null` (not `None`) and booleans read
    `true`/`false`; strings read as themselves and anything else falls
    back to `str`, which already matches Dart for ints.

    Args:
        value: The parsed YAML scalar to render.

    Returns:
        The Dart-style rendering for refusal details.
    """
    if type(value) == "bool":
        return "true" if value else "false"
    if value == None:
        return "null"
    if type(value) == "string":
        return value
    return str(value)

def _dart_shallow(value):
    """Render `value` with one collection level over scalars.

    Starlark forbids recursion, so nesting deeper than one collection
    level renders its leaves with `str`. Pubspec refusal details only
    ever nest one level (a list of maps or scalars).

    Args:
        value: The parsed YAML value to render.

    Returns:
        The Dart-style rendering for refusal details.
    """
    if type(value) == "list":
        return "[" + ", ".join([_dart_scalar(item) for item in value]) + "]"
    if type(value) == "dict":
        return "{" + ", ".join([
            _dart_scalar(k) + ": " + _dart_scalar(v)
            for k, v in value.items()
        ]) + "}"
    return _dart_scalar(value)

def dart_str(value):
    """Render `value` the way Dart string interpolation renders it.

    flutter_tools interpolates values into its errors with `$value`, so an
    empty value reads `null` (not `None`), booleans read `true`/`false`,
    and collections read `[a, b]` / `{a: b}` without Starlark's quotes.

    Args:
        value: The parsed YAML value to render.

    Returns:
        The Dart-style rendering for refusal details.
    """
    if type(value) == "list":
        return "[" + ", ".join([_dart_shallow(item) for item in value]) + "]"
    if type(value) == "dict":
        return "{" + ", ".join([
            _dart_shallow(k) + ": " + _dart_shallow(v)
            for k, v in value.items()
        ]) + "}"
    return _dart_scalar(value)

def dart_type(value):
    """The Dart `runtimeType` name flutter_tools prints for `value`.

    The YAML values flutter_tools interpolates are `YamlMap`/`YamlList`
    instances, so a map reads `YamlMap` (not `dict`), a list `YamlList`, a
    string `String`, an empty value `Null` and a float `double`; ints and
    bools already read the same.

    Args:
        value: The parsed YAML value to name the type of.

    Returns:
        The Dart type name for refusal details.
    """
    t = type(value)
    if t == "NoneType":
        return "Null"
    if t == "string":
        return "String"
    if t == "list":
        return "YamlList"
    if t == "dict":
        return "YamlMap"
    if t == "float":
        return "double"
    return t

# ---------------------------------------------------------------------------
# Line numbers
# ---------------------------------------------------------------------------

def _indent_of(line):
    """The leading-whitespace width of `line` (spaces and tabs count one)."""
    width = 0
    for ch in line.elems():
        if ch == " " or ch == "\t":
            width += 1
        else:
            break
    return width

def _is_real_line(text):
    """True when stripped `text` carries YAML content (not blank or a comment)."""
    return text != "" and not text.startswith("#")

def _key_head(text):
    """The mapping key a stripped line declares, or "" when it declares none.

    `assets: foo`, `assets:` and `assets : foo` all declare `assets`; a quoted
    `'assets': foo` declares `assets` too. A list item (`- family: F`) or a
    scalar declares nothing: the head before the colon never equals the key.
    """
    idx = text.find(":")
    if idx < 0:
        return ""
    head = text[:idx].strip()
    if len(head) >= 2 and head[0] == head[-1] and (head[0] == '"' or head[0] == "'"):
        head = head[1:-1]
    return head

def _is_dash_line(text):
    """True when stripped `text` opens a block-sequence item (`-` or `- ...`)."""
    return text == "-" or text.startswith("- ")

def _span_end(lines, start, parent_indent, in_item):
    """First index at or after `start` outside the block nested under `parent_indent`.

    A block opened by a key (or item) at `parent_indent` runs until the next
    content line at or above that indent, or `len(lines)` at the end. A `-`
    line at the key's own column is the key's compact sequence (see
    `parse_pubspec_document`), so outside an item scope it belongs to the key
    instead of ending the span.

    Args:
        lines: The pubspec text split on newlines.
        start: First index the span may cover.
        parent_indent: Indent of the key or item line that opened the block.
        in_item: True when the scope was opened by a list item: a `-` line at
            the same indent is the next item and ends the span.

    Returns:
        The first index past the block.
    """
    for i in range(start, len(lines)):
        text = lines[i].strip()
        if not _is_real_line(text):
            continue
        indent = _indent_of(lines[i])
        if indent > parent_indent:
            continue
        if not in_item and indent == parent_indent and _is_dash_line(text):
            continue
        return i
    return len(lines)

def _child_key_line(lines, start, end, parent_indent, key):
    """Line index of `key:` in `[start, end)` nested under `parent_indent`, or -1.

    The shallowest match wins (a deeper same-named key belongs to a nested
    map), then the first. A value written in flow on the key's own line keeps
    the key's line: there is nothing deeper to find.
    """
    best = -1
    best_indent = 0
    for i in range(start, end):
        text = lines[i].strip()
        if not _is_real_line(text):
            continue
        indent = _indent_of(lines[i])
        if indent <= parent_indent:
            continue
        if _key_head(text) != key:
            continue
        if best == -1 or indent < best_indent:
            best = i
            best_indent = indent
    return best

def _list_item_line(lines, start, end, parent_indent, index):
    """Line index of the `index`th block-sequence item in `[start, end)`, or -1.

    Items sit at the shallowest `-` indent in the span (a compact sequence sits
    at its key's own column; deeper `-` lines belong to nested lists). No item
    means the sequence is written in flow (`fonts: [1]`), so the caller falls
    back to the key's own line.
    """
    seq_indent = -1
    for i in range(start, end):
        text = lines[i].strip()
        if not _is_real_line(text):
            continue
        indent = _indent_of(lines[i])
        if indent < parent_indent:
            continue
        if _is_dash_line(text):
            if seq_indent == -1 or indent < seq_indent:
                seq_indent = indent
    if seq_indent == -1:
        return -1
    seen = 0
    for i in range(start, end):
        text = lines[i].strip()
        if not _is_real_line(text):
            continue
        if _indent_of(lines[i]) != seq_indent:
            continue
        if _is_dash_line(text):
            if seen == index:
                return i
            seen += 1
    return -1

def _flutter_section_line(lines):
    """Line index of the top-level `flutter:` key, or -1 when absent.

    The file's first line may carry a byte-order mark before `flutter:`.
    U+FEFF encodes as the three bytes EF BB BF, and Starlark strings are
    byte-indexed, so a line-0 head that matches past three leading bytes
    still counts: without this every lookup under a BOM-led `flutter:`
    misses and each refusal falls back to line 1.
    """
    for i in range(len(lines)):
        text = lines[i].strip()
        if not _is_real_line(text):
            continue
        if _indent_of(lines[i]) == 0:
            head = _key_head(text)
            if head == "flutter":
                return i
            if i == 0 and head[3:] == "flutter":
                return i
    return -1

def _key_head_candidates(key):
    """The YAML head spellings a parsed mapping `key` may be written with.

    A string key reads back as written (quotes are stripped by `_key_head`
    before comparing); a boolean key may use any case (`true`, `True`,
    `TRUE`), an empty key `null` or `~`, and an int key an optional `+`
    sign. Comparing lowercased covers the remaining case spellings.

    Args:
        key: The parsed mapping key to find the head line of.

    Returns:
        The candidate head spellings to match.
    """
    if type(key) == "string":
        return [key]
    if type(key) == "bool":
        spell = "true" if key else "false"
        return [spell, spell.capitalize(), spell.upper()]
    if key == None:
        return ["null", "Null", "NULL", "~"]
    if type(key) == "int" and key >= 0:
        return [str(key), "+" + str(key)]
    return [str(key)]

def _raw_head_line(lines, start, end, parent_indent, top, key):
    """Line index of the `key:` head in `[start, end)`, or -1 when missing.

    Like `_child_key_line`, but matches the raw head text instead of a known
    string key, so a non-string key (which no locator can name) still
    resolves to its own line. The shallowest match wins, then the first; a
    quoted string key sharing the spelling wins over a deeper same-spelled
    head only when it sits shallower.

    Args:
        lines: The pubspec text split on newlines.
        start: First index the head may sit at.
        end: First index past the searched span.
        parent_indent: Indent of the key opening the span; only deeper
            lines match, unless `top` skips the span check.
        top: True to match only column-0 lines (a pubspec root key).
        key: The parsed mapping key to find the head line of.

    Returns:
        The matching line index, or -1.
    """
    lowered = [candidate.lower() for candidate in _key_head_candidates(key)]
    best = -1
    best_indent = 0
    for i in range(start, end):
        text = lines[i].strip()
        if not _is_real_line(text):
            continue
        indent = _indent_of(lines[i])
        if top:
            if indent != 0:
                continue
        elif indent <= parent_indent:
            continue
        if _key_head(text).lower() not in lowered:
            continue
        if best == -1 or indent < best_indent:
            best = i
            best_indent = indent
    return best

def _root_key_line(lines, key):
    """The 1-based line of the top-level `key:`, or 1 when missing."""
    found = _raw_head_line(lines, 0, len(lines), -1, True, key)
    return found + 1 if found != -1 else 1

def item_key_line(lines, locator, key):
    """The 1-based line of `key:` inside the map `locator` names.

    A key no locator step can name (a non-string key, which reads as a
    list index) still resolves to its own head line: the search covers
    the item's span only, so a same-spelled head elsewhere never wins.
    A value written in flow on the item's own line, or a missing head,
    resolves to the item's line.

    Args:
        lines: The pubspec text split on newlines.
        locator: The path to the map holding the key.
        key: The parsed mapping key to find the head line of.

    Returns:
        The 1-based line number, always at least 1.
    """
    item = flutter_line_of(lines, locator)
    indent = _indent_of(lines[item - 1])
    end = _span_end(lines, item, indent, True)
    found = _raw_head_line(lines, item, end, indent, False, key)
    return found + 1 if found != -1 else item

def flutter_line_of(lines, locator):
    """The 1-based `pubspec.yaml` line of the entry `locator` names.

    `locator` starts at `"flutter"` and alternates child keys and list
    indices, e.g. `["flutter", "fonts", 0, "fonts", 1, "weight"]`. Each step
    descends into the key's (or item's) block; a step with nothing deeper to
    find (a value in flow, a missing key, a short list) resolves to the
    deepest line found so far. A non-string mapping key (an int, bool or
    float a locator step cannot name, e.g. `42: x` in a font family) still
    resolves to its own head line: inside a list item the scope is a map, so
    a non-string step searches the raw head text instead of counting list
    items. The answer is therefore always the closest named line: the key
    holding a flow collection, the item holding an inline map, the section
    key, or `flutter:` itself.

    Args:
        lines: The pubspec text split on newlines.
        locator: The `["flutter", key-or-index, ...]` path to the entry.

    Returns:
        The 1-based line number, always at least 1.
    """
    section = _flutter_section_line(lines)
    if section == -1:
        return 1
    if len(locator) <= 1:
        return section + 1
    line = section + 1
    indent = _indent_of(lines[section])
    start = section + 1
    in_item = False
    for step in locator[1:]:
        end = _span_end(lines, start, indent, in_item)
        if type(step) == "string":
            found = _child_key_line(lines, start, end, indent, step)
        elif in_item:
            found = _raw_head_line(lines, start, end, indent, False, step)
        else:
            found = _list_item_line(lines, start, end, indent, step)
        if found == -1:
            return line
        line = found + 1
        indent = _indent_of(lines[found])
        start = found + 1
        in_item = type(step) != "string"
    return line

# ---------------------------------------------------------------------------
# Pubspec root: non-string keys and a non-string name
# ---------------------------------------------------------------------------

def validate_pubspec_root(pubspec, lines):
    """The refusals for the pubspec root shapes `_validate` reports.

    Mirrors the root loop in `_validate` (`flutter_manifest.dart`): a
    non-string root key is `Expected YAML key to be a string, but got ...`
    (with no type, unlike the `flutter:`-level message), and a present
    `name` that is not a string is `Expected "name" to be a string, ...`.
    Any other root key stays allowed. Each refusal names the offending
    key's own line. A non-mapping root never reaches here: the YAML
    parser fails it first, naming the package and line 1.

    Args:
        pubspec: The parsed pubspec mapping ({} when the document is empty).
        lines: The pubspec text split on newlines.

    Returns:
        The refusal structs for `asset_errors`, in document order.
    """
    problems = []
    for key in pubspec.keys():
        if type(key) != "string":
            problems.append(_refusal(
                dart_str(key),
                "flutter",
                "Expected YAML key to be a string, but got {key}.".format(
                    key = dart_str(key),
                ),
                _root_key_line(lines, key),
            ))
        elif key == "name":
            value = pubspec["name"]
            if type(value) != "string":
                problems.append(_refusal(
                    "name",
                    "flutter",
                    "Expected \"name\" to be a string, but got {value}.".format(
                        value = dart_str(value),
                    ),
                    _root_key_line(lines, "name"),
                ))
    return problems

# ---------------------------------------------------------------------------
# Scalar flags: uses-material-design, default-flavor, disable-swift-package-manager
# ---------------------------------------------------------------------------

def _uses_material_design_problem(flutter, lines):
    """The refusal when `uses-material-design` is present but not a bool.

    Mirrors the `uses-material-design` case in `_validateFlutter`
    (`flutter_manifest.dart`): a string `"yes"` or an empty value reads as
    false today, silently dropping the material icons, where flutter_tools
    refuses the package.
    """
    value = flutter["uses-material-design"]
    if type(value) == "bool":
        return []
    return [_refusal(
        "uses-material-design",
        "uses-material-design",
        "Expected \"uses-material-design\" to be a bool, but got {value} ({type}).".format(
            value = dart_str(value),
            type = dart_type(value),
        ),
        flutter_line_of(lines, ["flutter", "uses-material-design"]),
    )]

def _default_flavor_problem(flutter, lines):
    """The refusal when `default-flavor` is present but not a string.

    Mirrors the `default-flavor` case in `_validateFlutter`
    (`flutter_manifest.dart`).
    """
    value = flutter["default-flavor"]
    if type(value) == "string":
        return []
    return [_refusal(
        "default-flavor",
        "default-flavor",
        "Expected \"default-flavor\" to be a string, but got {value} ({type}).".format(
            value = dart_str(value),
            type = dart_type(value),
        ),
        flutter_line_of(lines, ["flutter", "default-flavor"]),
    )]

def _moved_swift_package_manager_problem(lines):
    """The refusal for any `disable-swift-package-manager` entry.

    Mirrors the `disable-swift-package-manager` case in `_validateFlutter`
    (`flutter_manifest.dart`): the key moved under `config`, so its presence
    at any value (even empty) is an error carrying the migration.
    """
    return _refusal(
        "disable-swift-package-manager",
        "disable-swift-package-manager",
        "The \"disable-swift-package-manager\" configuration has moved. In your pubspec.yaml:\n" +
        "# Before\n" +
        "flutter:\n" +
        "  disable-swift-package-manager: true\n" +
        "\n" +
        "# After\n" +
        "flutter:\n" +
        "  config:\n" +
        "    enable-swift-package-manager: false\n",
        flutter_line_of(lines, ["flutter", "disable-swift-package-manager"]),
    )

# ---------------------------------------------------------------------------
# Unknown children and non-string keys
# ---------------------------------------------------------------------------

def _unexpected_child_problem(key, lines):
    """The refusal for an unknown `key` directly under `flutter:`.

    Mirrors the `default` case in `_validateFlutter`
    (`flutter_manifest.dart`).
    """
    return _refusal(
        key,
        key,
        "Unexpected child \"{key}\" found under \"flutter\".".format(key = key),
        flutter_line_of(lines, ["flutter", key]),
    )

def _non_string_key_problem(key, value, lines):
    """The refusal for a non-string `key` directly under `flutter:`.

    Mirrors the non-string-key case in `_validateFlutter`
    (`flutter_manifest.dart`): the detail prints the key and its value's
    type, and the line is the key's own, found by a raw-head search over
    the section's span (a non-string key cannot be named by a locator),
    falling back to the section's line when the head is missing.
    """
    section = _flutter_section_line(lines)
    if section == -1:
        line = 1
    else:
        indent = _indent_of(lines[section])
        end = _span_end(lines, section + 1, indent, False)
        found = _raw_head_line(lines, section + 1, end, indent, False, key)
        line = found + 1 if found != -1 else section + 1
    return _refusal(
        "flutter",
        "flutter",
        "Expected YAML key to be a string, but got {key} ({type}).".format(
            key = dart_str(key),
            type = dart_type(value),
        ),
        line,
    )

# ---------------------------------------------------------------------------
# licenses
# ---------------------------------------------------------------------------

def _licenses_problems(flutter, lines):
    """The refusals for a malformed `flutter.licenses` value.

    Mirrors the `licenses` case in `_validateFlutter` (`_parseList` in
    `flutter_manifest.dart`): only an absent value is valid without checks;
    a present value (even an empty one) must be a list of file paths, and
    every non-string element is reported, not just the first.
    """
    if "licenses" not in flutter:
        return []
    raw = flutter["licenses"]
    locator = ["flutter", "licenses"]
    if type(raw) != "list":
        return [_refusal(
            "licenses",
            "licenses",
            "Expected \"licenses\" to be a list of files, but got {value} ({type}).".format(
                value = dart_str(raw),
                type = dart_type(raw),
            ),
            flutter_line_of(lines, locator),
        )]
    problems = []
    for index, item in enumerate(raw):
        if type(item) != "string":
            problems.append(_refusal(
                "licenses[{index}]".format(index = index),
                "licenses",
                "Expected \"licenses\" to be a list of files, but element at index {index} was a {type}.".format(
                    index = index,
                    type = dart_type(item),
                ),
                flutter_line_of(lines, locator + [index]),
            ))
    return problems

# ---------------------------------------------------------------------------
# module
# ---------------------------------------------------------------------------

def _module_problems(flutter, lines):
    """The refusals for a malformed `flutter.module` value.

    Mirrors the `module` case in `_validateFlutter`
    (`flutter_manifest.dart`): only an absent value is valid without
    checks; a present value (even an empty one) must be a map, and
    `androidX` must be a bool, `androidPackage` a string and
    `iosBundleIdentifier` a string when set. Each check is independent, so
    all are reported.
    """
    if "module" not in flutter:
        return []
    raw = flutter["module"]
    locator = ["flutter", "module"]
    if type(raw) != "dict":
        return [_refusal(
            "module",
            "module",
            "Expected \"module\" to be an object, but got {value} ({type}).".format(
                value = dart_str(raw),
                type = dart_type(raw),
            ),
            flutter_line_of(lines, locator),
        )]
    problems = []
    android_x = raw.get("androidX")
    if android_x != None and type(android_x) != "bool":
        problems.append(_refusal(
            "module",
            "module",
            "The \"androidX\" value must be a bool if set.",
            flutter_line_of(lines, locator + ["androidX"]),
        ))
    android_package = raw.get("androidPackage")
    if android_package != None and type(android_package) != "string":
        problems.append(_refusal(
            "module",
            "module",
            "The \"androidPackage\" value must be a string if set.",
            flutter_line_of(lines, locator + ["androidPackage"]),
        ))
    bundle_id = raw.get("iosBundleIdentifier")
    if bundle_id != None and type(bundle_id) != "string":
        problems.append(_refusal(
            "module",
            "module",
            "The \"iosBundleIdentifier\" section must be a string if set.",
            flutter_line_of(lines, locator + ["iosBundleIdentifier"]),
        ))
    return problems

# ---------------------------------------------------------------------------
# plugin
# ---------------------------------------------------------------------------

# Keys of the legacy plugin format (plugins.dart `validatePluginYaml`).
_OLD_PLUGIN_KEYS = ("androidPackage", "iosPrefix", "pluginClass")

# Platforms `_validateMultiPlatformYaml` (plugins.dart) validates. `web` is
# deliberately absent: flutter_tools does not validate it there.
_VALIDATED_PLUGIN_PLATFORMS = ("android", "ios", "linux", "macos", "windows")

def _is_plugin_identifier(value):
    """True when `value` is a valid plugin class or package identifier.

    Mirrors `_pluginIdentifierPattern` (`^[a-zA-Z_$][a-zA-Z0-9_$]*` dot-joined,
    in `platform_plugins.dart`): plugin `class`/`package` values are
    interpolated verbatim into the generated registrant, so each dot-separated
    part must start with a letter, `_` or `$` and continue with those or
    digits. Starlark has no regex, so the pattern is checked by hand.
    """
    if type(value) != "string" or value == "":
        return False
    for part in value.split("."):
        if part == "":
            return False
        if part[0] not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_$":
            return False
        for ch in part.elems():
            if ch not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789$":
                return False
    return True

def _platform_entry_invalid(info, platform):
    """True when a `flutter.plugin.platforms.<platform>` map is invalid.

    Mirrors each platform's `validate` in `platform_plugins.dart`: an entry
    must declare an implementation (a native `package` plus `pluginClass` on
    Android, a `pluginClass` elsewhere, or a `dartPluginClass`, `ffiPlugin`,
    `sharedDarwinSource` on darwin, or `default_package` anywhere), and every
    identifier present must match the plugin identifier pattern.
    """
    package = info.get("package")
    plugin_class = info.get("pluginClass")
    dart_class = info.get("dartPluginClass")
    ffi = info.get("ffiPlugin") == True
    default = type(info.get("default_package")) == "string"
    if platform == "android":
        declared = (type(package) == "string" and type(plugin_class) == "string")
        declared = declared or type(dart_class) == "string" or ffi or default
    elif platform == "ios" or platform == "macos":
        declared = type(plugin_class) == "string" or type(dart_class) == "string"
        declared = declared or ffi or info.get("sharedDarwinSource") == True or default
    else:
        declared = type(plugin_class) == "string" or type(dart_class) == "string"
        declared = declared or ffi or default
    if not declared:
        return True
    if platform == "android" and type(package) == "string" and not _is_plugin_identifier(package):
        return True
    if type(plugin_class) == "string" and not _is_plugin_identifier(plugin_class):
        return True
    if type(dart_class) == "string" and not _is_plugin_identifier(dart_class):
        return True
    return False

def _multi_platform_problems(plugin, lines, locator):
    """The refusals for a malformed new-format `flutter.plugin` value.

    Mirrors `_validateMultiPlatformYaml` (plugins.dart): `platforms` must be
    a map (an empty one is valid), and each validated platform entry must be
    a map the platform accepts (an entry carrying `default_package` is valid
    whatever else it holds). Unknown platforms and `web` are ignored.
    """
    platforms = plugin.get("platforms")
    if type(platforms) != "dict":
        if platforms == None:
            detail = "Invalid \"platforms\" specification."
        else:
            detail = "flutter.plugin.platforms should be a map with the platform name as the key"
        return [_refusal(
            "plugin",
            "plugin",
            detail,
            flutter_line_of(lines, locator + ["platforms"]),
        )]
    problems = []
    for platform in _VALIDATED_PLUGIN_PLATFORMS:
        if platform not in platforms:
            continue
        info = platforms[platform]
        if type(info) != "dict" or ("default_package" not in info and _platform_entry_invalid(info, platform)):
            problems.append(_refusal(
                "plugin",
                "plugin",
                "Invalid \"{platform}\" plugin specification.".format(platform = platform),
                flutter_line_of(lines, locator + ["platforms", platform]),
            ))
    return problems

def _legacy_plugin_problems(plugin, lines, locator):
    """The refusals for a malformed legacy-format `flutter.plugin` value.

    Mirrors `_validateLegacyYaml` (plugins.dart): each legacy key must be a
    string or null when present.
    """
    checks = (
        ("androidPackage", "The \"androidPackage\" must either be null or a string."),
        ("iosPrefix", "The \"iosPrefix\" must either be null or a string."),
        ("pluginClass", "The \"pluginClass\" must either be null or a string."),
    )
    problems = []
    for key, detail in checks:
        value = plugin.get(key)
        if value != None and type(value) != "string":
            problems.append(_refusal(
                "plugin",
                "plugin",
                detail,
                flutter_line_of(lines, locator + [key]),
            ))
    return problems

def _plugin_problems(flutter, lines):
    """The refusals for a malformed `flutter.plugin` value.

    Mirrors the `plugin` case in `_validateFlutter` (`flutter_manifest.dart`)
    and `Plugin.validatePluginYaml` (plugins.dart): the value must be a map
    (an empty `plugin: {}` carries neither format and fails), the old
    `androidPackage`/`iosPrefix`/`pluginClass` keys cannot combine with
    `platforms`, and each format validates as above. Extra keys beside a
    valid `platforms` map are ignored, as flutter_tools ignores them.
    """
    if "plugin" not in flutter:
        return []
    locator = ["flutter", "plugin"]
    value = flutter["plugin"]
    if type(value) != "dict":
        return [_refusal(
            "plugin",
            "plugin",
            "Expected \"plugin\" to be an object, but got {value} ({type}).".format(
                value = dart_str(value),
                type = dart_type(value),
            ),
            flutter_line_of(lines, locator),
        )]
    uses_old = False
    for key in _OLD_PLUGIN_KEYS:
        if key in value:
            uses_old = True
    uses_new = "platforms" in value
    if uses_old and uses_new:
        return [_refusal(
            "plugin",
            "plugin",
            "The flutter.plugin.platforms key cannot be used in combination with the old " +
            "flutter.plugin.{androidPackage,iosPrefix,pluginClass} keys. " +
            "See: https://flutter.dev/to/pubspec-plugin-platforms",
            flutter_line_of(lines, locator),
        )]
    if not uses_old and not uses_new:
        return [_refusal(
            "plugin",
            "plugin",
            "Cannot find the `flutter.plugin.platforms` key in the `pubspec.yaml` file. " +
            "An instruction to format the `pubspec.yaml` can be found here: " +
            "https://flutter.dev/to/pubspec-plugin-platforms",
            flutter_line_of(lines, locator),
        )]
    if uses_new:
        return _multi_platform_problems(value, lines, locator)
    return _legacy_plugin_problems(value, lines, locator)

# ---------------------------------------------------------------------------
# deferred-components
# ---------------------------------------------------------------------------

def _libraries_problems(libraries, index, lines, locator):
    """The refusals for a malformed deferred-component `libraries` value.

    Mirrors the `libraries` check in `_validateDeferredComponents`
    (`flutter_manifest.dart`): a present value (even an empty one) must be a
    list of strings.
    """
    context = "\"libraries\" key in the element at index {index} of \"deferred-components\"".format(
        index = index,
    )
    if type(libraries) != "list":
        return [_refusal(
            "deferred-components",
            "deferred-components",
            "Expected {context} to be a list of String, but got {value} ({type}).".format(
                context = context,
                value = dart_str(libraries),
                type = dart_type(libraries),
            ),
            flutter_line_of(lines, locator),
        )]
    problems = []
    for position, item in enumerate(libraries):
        if type(item) != "string":
            problems.append(_refusal(
                "deferred-components",
                "deferred-components",
                "Expected {context} to be a list of String, but element at index {position} was a {type}.".format(
                    context = context,
                    position = position,
                    type = dart_type(item),
                ),
                flutter_line_of(lines, locator + [position]),
            ))
    return problems

def _deferred_problems(flutter, scope):
    """The refusals for a malformed `flutter.deferred-components` value.

    Mirrors `_validateDeferredComponents` (`flutter_manifest.dart`): only
    an absent or empty (null) value is valid without checks. An empty list
    is one refusal: flutter_tools 3.47.7 crashes reading it instead of
    reporting an error, so no package with one can build. Any other
    non-list value, or a list whose first element is not a map, is one
    refusal naming the whole value. Each map element needs a string `name`,
    a string list `libraries` when the key is present at all, and valid
    `assets` when present (checked by the caller's asset validator, which
    shares the top-level asset rules; the entries are validated only,
    never bundled).

    Args:
        flutter: The parsed `flutter:` mapping.
        scope: A `struct(lines, check_assets)`: the pubspec text split on
            newlines, and a `check_assets(raw, locator, shown)` callable
            returning that value's asset problems (it lives with the asset
            parser so this module never loads it back).

    Returns:
        The refusal structs for `asset_errors`.
    """
    if "deferred-components" not in flutter:
        return []
    raw = flutter["deferred-components"]
    if raw == None:
        return []
    locator = ["flutter", "deferred-components"]
    if type(raw) != "list" or len(raw) == 0 or type(raw[0]) != "dict":
        if type(raw) == "list" and len(raw) == 0:
            detail = (
                "\"deferred-components\" must not be empty: flutter_tools " +
                "crashes reading an empty list, so it cannot build."
            )
        else:
            detail = "Expected \"deferred-components\" to be a list, but got {value} ({type}).".format(
                value = dart_str(raw),
                type = dart_type(raw),
            )
        return [_refusal(
            "deferred-components",
            "deferred-components",
            detail,
            flutter_line_of(scope.lines, locator),
        )]
    problems = []
    for index, element in enumerate(raw):
        elocator = locator + [index]
        if type(element) != "dict":
            problems.append(_refusal(
                "deferred-components[{index}]".format(index = index),
                "deferred-components",
                "Expected the {index} element in \"deferred-components\" to be a map, but got {value} ({type}).".format(
                    index = index,
                    value = dart_str(element),
                    type = dart_type(element),
                ),
                flutter_line_of(scope.lines, elocator),
            ))
            continue
        if type(element.get("name")) != "string":
            problems.append(_refusal(
                "deferred-components[{index}]".format(index = index),
                "deferred-components",
                "Expected the {index} element in \"deferred-components\" to have required key \"name\" of type String".format(
                    index = index,
                ),
                flutter_line_of(scope.lines, elocator + ["name"]),
            ))
        if "libraries" in element:
            problems.extend(_libraries_problems(
                element["libraries"],
                index,
                scope.lines,
                elocator + ["libraries"],
            ))
        if "assets" in element:
            problems.extend(scope.check_assets(
                element["assets"],
                elocator + ["assets"],
                "deferred-components[{index}].assets".format(index = index),
            ))
    return problems

# ---------------------------------------------------------------------------
# Section entry point
# ---------------------------------------------------------------------------

# flutter_tools 3.47.7 check catalog. Every check below mirrors the cited
# function or case; line numbers are for the pinned 3.47.7 sources (the
# oracle in `.referee-runs/ft-manifest-oracle-3.47.7` carries verbatim
# copies). `FM` is `packages/flutter_tools/lib/src/flutter_manifest.dart`:
#
# - pubspec root keys, `name`, `flutter` null/scalar/map: `_validate`, FM:488
#   (non-string root key FM:494, `name` FM:499, `flutter` FM:503)
# - non-string `flutter:` key: `_validateFlutter`, FM:530 (key check FM:537)
# - `uses-material-design`: FM:542; `assets`/`shaders`: FM:548/550 through
#   `_validateAssets` FM:684 and `_computeAssetsSafe` FM:693
# - `fonts` section shape (non-list, empty, first-non-map): FM:552;
#   family and file entries: `_validateFonts` FM:726 (`asset` FM:758,
#   `weight` FM:764, `style` FM:770)
# - `licenses`: FM:566 through `_parseList` FM:627
# - `module`: FM:569; `plugin` shape: FM:587; `generate`/`config` skipped:
#   FM:596/598; `deferred-components`: FM:601 through
#   `_validateDeferredComponents` FM:651 (empty-list crash FM:653)
# - `disable-swift-package-manager` migration: FM:603;
#   `default-flavor`: FM:615; unknown children: FM `default`
# - plugin formats: `Plugin.validatePluginYaml` plugins.dart:276 (old/new
#   mix and neither-format errors), `_validateMultiPlatformYaml`
#   plugins.dart:311, `_validateLegacyYaml` plugins.dart:351, and each
#   platform's `validate` in platform_plugins.dart (android:163, ios:344,
#   macos:456, windows:582, linux:688)
# - asset entry shapes: `AssetsEntry.parseFromYamlSafe` FM:825; `flavors`
#   and `platforms` lists: `_parseFlavorsSection` FM:897 and
#   `_parsePlatformsSection` FM:909 through `_parseList` FM:627
#
# Deliberate divergences: an empty `deferred-components` list is refused
# (flutter_tools crashes instead of reporting); multi-error sections stay
# one refusal per offending key or entry (with that key's or entry's
# line) rather than one joined error per entry; unknown asset `platforms`
# still fail at the spoke's platform check.

def validate_flutter_section(flutter, scope):
    """Validate one parsed `flutter:` mapping the way flutter_tools does.

    Dispatches per key in document order over the checks above. `assets`,
    `shaders` and `fonts` shapes are validated by the asset parser (which
    shares this module's line finder), and `generate` and `config` carry no
    checks in flutter_tools, so those keys contribute nothing here.

    Args:
        flutter: The parsed `flutter:` mapping ({} when absent).
        scope: A `struct(lines, check_assets)` as `_deferred_problems`
            takes it.

    Returns:
        The refusal structs for `asset_errors`, in document order.
    """
    problems = []
    for key in flutter.keys():
        if type(key) != "string":
            problems.append(_non_string_key_problem(key, flutter[key], scope.lines))
        elif key == "uses-material-design":
            problems.extend(_uses_material_design_problem(flutter, scope.lines))
        elif key == "licenses":
            problems.extend(_licenses_problems(flutter, scope.lines))
        elif key == "module":
            problems.extend(_module_problems(flutter, scope.lines))
        elif key == "plugin":
            problems.extend(_plugin_problems(flutter, scope.lines))
        elif key == "deferred-components":
            problems.extend(_deferred_problems(flutter, scope))
        elif key == "disable-swift-package-manager":
            problems.append(_moved_swift_package_manager_problem(scope.lines))
        elif key == "default-flavor":
            problems.extend(_default_flavor_problem(flutter, scope.lines))
        elif key == "assets" or key == "shaders" or key == "fonts":
            pass
        elif key == "generate" or key == "config":
            pass
        else:
            problems.append(_unexpected_child_problem(key, scope.lines))
    return problems
