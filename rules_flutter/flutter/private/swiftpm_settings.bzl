"""SwiftPM target settings, build conditions and `select()` rendering.

Parses the per-target build-setting arrays `flutter.pub` translates (see
the README section "iOS native (SwiftPM) dependencies"): `cSettings` and
`cxxSettings` (`.headerSearchPath`, `.define`), `swiftSettings`
(`.define`, `.enableUpcomingFeature`, `.enableExperimentalFeature`) and
`linkerSettings` (`.linkedFramework`, `.linkedLibrary`). Every setting
carries an optional `.when(platforms: [...])` condition limiting it to
those platforms; a `configuration:` condition (or any other condition) is
refused. `.unsafeFlags(...)` and any other setting kind are refused: flags
SwiftPM does not model would otherwise leak into the build.

The manifest parser (`swiftpm_manifest.bzl`) calls the parsers here while
folding `.target(...)` keyword arguments; the BUILD emitter
(`swiftpm_translate.bzl`, `swiftpm_clang.bzl`) calls
`swiftpm_target_setting_entries` to map the parsed settings onto
`copts`/`cxxopts`/`linkopts`/`includes` entries and
`swiftpm_render_list_attr` to render any entry list (settings and
conditional dependencies share the `struct(text, platforms)` shape) as a
Bazel list attribute with `select()`s on the target platform's OS.

Errors are bare details: the caller wraps them with the package identity
(the manifest parser with its `Package.swift` line format, the emitter
with its hub format). Every detail names the target and the offending
setting or condition.
"""

load(":swiftpm_paths.bzl", "swiftpm_join_path", "swiftpm_normalize_relative_path")

visibility(["//flutter/..."])

_SWIFTPM_SETTING_CATEGORIES = {
    "cSettings": "c",
    "cxxSettings": "cxx",
    "swiftSettings": "swift",
    "linkerSettings": "linker",
}

_SWIFTPM_SETTING_PLATFORMS = {"iOS": "ios", "macOS": "macos"}

def _swiftpm_setting_target(target_name):
    """The target prefix every setting and condition refusal carries."""
    if target_name:
        return "target " + repr(target_name)
    return "an unnamed target"

def swiftpm_parse_when_condition(target_name, value_tokens):
    """Read a `.when(...)` build condition limiting a dep or a setting.

    Only `.when(platforms: [...])` with `.iOS`/`.macOS` entries
    translates: the hub builds one library for every Apple platform and
    the emitter keeps the gated entry only when building for a listed
    platform. A `configuration:` entry (or any other condition key, such
    as `traits:`), an unknown platform, or a value that is not a
    `.when(...)` call at all is refused.

    Args:
        target_name: The target holding the condition, for messages (""
            when the manifest has not named it yet).
        value_tokens: The condition value's token list.

    Returns:
        `struct(ok, detail, value)`: `value` is None when the condition
        is absent-tautological (never: the caller only passes present
        conditions), else `struct(platforms)` with `"ios"`/`"macos"`
        entries in manifest order.
    """
    who = _swiftpm_setting_target(target_name)
    head = [(t.kind, t.text) for t in value_tokens[:3]]
    last = (value_tokens[-1].kind, value_tokens[-1].text) if value_tokens else ()
    if len(value_tokens) < 4 or head != [("punct", "."), ("word", "when"), ("punct", "(")] or last != ("punct", ")"):
        return struct(ok = False, detail = "{who}: expected a build condition (`.when(platforms: [...])`)".format(who = who), value = None)
    inner = value_tokens[3:len(value_tokens) - 1]
    parts = _swiftpm_setting_split_top(inner)
    if parts == None:
        return struct(ok = False, detail = "{who}: malformed `.when(...)` condition".format(who = who), value = None)
    keys = {}
    for part in parts:
        if len(part) < 3 or part[0].kind != "word" or part[1].kind != "punct" or part[1].text != ":":
            return struct(ok = False, detail = "{who}: expected a build condition (`.when(platforms: [...])`)".format(who = who), value = None)
        if part[0].text in keys:
            return struct(ok = False, detail = "{who}: duplicate condition argument `{key}`".format(who = who, key = part[0].text), value = None)
        keys[part[0].text] = part[2:]
    if len(keys) != 1 or "platforms" not in keys:
        for key in keys.keys():
            return struct(ok = False, detail = "{who} uses a build condition on `{key}:`, which has no Bazel translation (only `.when(platforms: [...])` conditions translate)".format(who = who, key = key), value = None)
        return struct(ok = False, detail = "{who}: expected a build condition (`.when(platforms: [...])`)".format(who = who), value = None)
    platforms = _swiftpm_setting_platform_list(who, keys["platforms"])
    if not platforms.ok:
        return struct(ok = False, detail = platforms.detail, value = None)
    return struct(ok = True, detail = "", value = struct(platforms = platforms.items))

def _swiftpm_setting_platform_list(who, value_tokens):
    """Read a `.when(platforms: [...])` platform array.

    Only `.iOS` and `.macOS` survive: the hub builds one library for
    every Apple platform, so any other platform is ignored (an entry
    gated on no listed platform at all drops out everywhere).

    Args:
        who: The target prefix for messages.
        value_tokens: The array literal's token list.

    Returns:
        `struct(ok, detail, items)`: `items` holds `"ios"`/`"macos"` in
        manifest order.
    """
    first = (value_tokens[0].kind, value_tokens[0].text) if value_tokens else ()
    last = (value_tokens[-1].kind, value_tokens[-1].text) if value_tokens else ()
    if first != ("punct", "[") or last != ("punct", "]"):
        return struct(ok = False, detail = "{who}: expected a build condition (`.when(platforms: [...])`)".format(who = who), items = [])
    parts = _swiftpm_setting_split_top(value_tokens[1:len(value_tokens) - 1])
    if parts == None:
        return struct(ok = False, detail = "{who}: malformed `.when(platforms: [...])` condition".format(who = who), items = [])
    items = []
    for part in parts:
        if len(part) == 2 and part[0].kind == "punct" and part[0].text == "." and part[1].kind == "word":
            if part[1].text in _SWIFTPM_SETTING_PLATFORMS:
                items.append(_SWIFTPM_SETTING_PLATFORMS[part[1].text])
        else:
            return struct(ok = False, detail = "{who}: expected `.when(platforms:)` entries naming platforms".format(who = who), items = [])
    return struct(ok = True, detail = "", items = items)

def _swiftpm_setting_split_top(tokens):
    """Split tokens at depth-0 commas, dropping a trailing comma.

    Args:
        tokens: The argument or element list contents.

    Returns:
        The list of token lists, or None on a leading or doubled comma.
    """
    if tokens and tokens[len(tokens) - 1].kind == "punct" and tokens[len(tokens) - 1].text == ",":
        tokens = tokens[:len(tokens) - 1]
    parts = []
    current = []
    depth = 0
    for tok in tokens:
        if tok.kind == "punct" and tok.text == "," and depth == 0:
            if not current:
                return None
            parts.append(current)
            current = []
        else:
            if tok.kind == "punct" and (tok.text == "(" or tok.text == "["):
                depth += 1
            elif tok.kind == "punct" and (tok.text == ")" or tok.text == "]"):
                depth -= 1
            current.append(tok)
    if current:
        parts.append(current)
    return parts

def _swiftpm_setting_call(who, array_name, element):
    """Read one setting element's dotted call head and argument tokens.

    Args:
        who: The target prefix for messages.
        array_name: The setting array (`cSettings`, ...), for messages.
        element: The element's token list.

    Returns:
        `struct(ok, detail, name, args)`: `name` is the dotted call name
        (`define`, `unsafeFlags`, ...) and `args` the tokens between the
        outer parens.
    """
    head = [(t.kind, t.text) for t in element[:3]]
    last = (element[-1].kind, element[-1].text) if element else ()
    if len(element) >= 4 and head[0] == ("punct", ".") and head[1][0] == "word" and head[2] == ("punct", "(") and last == ("punct", ")"):
        depth = 0
        balanced = True
        for i in range(2, len(element)):
            tok = element[i]
            if tok.kind == "punct" and (tok.text == "(" or tok.text == "["):
                depth += 1
            elif tok.kind == "punct" and (tok.text == ")" or tok.text == "]"):
                depth -= 1
                if depth == 0 and i != len(element) - 1:
                    balanced = False
        if balanced and depth == 0:
            return struct(ok = True, detail = "", name = element[1].text, args = element[3:len(element) - 1])
    return struct(ok = False, detail = "{who}: expected a `{array}` build setting (a `.name(...)` call)".format(who = who, array = array_name), name = "", args = [])

def _swiftpm_setting_string(args, index):
    """Read one positional setting argument that must be a string literal.

    Args:
        args: The call's positional and labeled argument structs.
        index: The positional index to read.

    Returns:
        `struct(ok, text)`, where `text` is the string literal value when `ok` is true.
    """
    positionals = [arg for arg in args if arg.key == ""]
    if index >= len(positionals) or len(positionals[index].value) != 1 or positionals[index].value[0].kind != "str":
        return struct(ok = False, text = "")
    return struct(ok = True, text = positionals[index].value[0].text)

def _swiftpm_setting_split_args(who, array_name, dotted, args):
    """Split a setting call's arguments into positional and labeled parts.

    Args:
        who: The target prefix for messages.
        array_name: The setting array, for messages.
        dotted: The dotted call name, for messages.
        args: The tokens between the call's parens.

    Returns:
        `struct(ok, detail, args)`: `args` holds structs with `key` (""
        for positional) and `value` tokens.
    """
    parts = _swiftpm_setting_split_top(args)
    if parts == None:
        return struct(ok = False, detail = "{who}: malformed `.{dotted}(...)` in `{array}`".format(who = who, dotted = dotted, array = array_name), args = [])
    out = []
    for part in parts:
        if len(part) >= 3 and part[0].kind == "word" and part[1].kind == "punct" and part[1].text == ":":
            out.append(struct(key = part[0].text, value = part[2:]))
        else:
            out.append(struct(key = "", value = part))
    return struct(ok = True, detail = "", args = out)

def _swiftpm_setting_condition(who, target_name, args):
    """Read the optional condition off parsed setting arguments.

    Accepts the condition as a second positional `.when(...)` argument
    (SwiftPM's `define(_:_:)` spelling) or as a labeled `condition:`
    argument; both at once is refused.

    Args:
        who: The target prefix for messages.
        target_name: The bare target name for the condition parser.
        args: The parsed argument structs.

    Returns:
        `struct(ok, detail, value)`: `value` is None when the setting is
        unconditional, else `struct(platforms)`.
    """
    whens = []
    for arg in args:
        if arg.key == "" and len(arg.value) >= 2 and (arg.value[0].kind, arg.value[0].text) == ("punct", "."):
            whens.append(arg.value)
        elif arg.key == "condition":
            whens.append(arg.value)
    if len(whens) > 1:
        return struct(ok = False, detail = "{who}: duplicate build condition".format(who = who), value = None)
    if not whens:
        return struct(ok = True, detail = "", value = None)
    return swiftpm_parse_when_condition(target_name, whens[0])

def swiftpm_parse_target_setting(target_name, array_name, element):
    """Parse one `cSettings`/`cxxSettings`/`swiftSettings`/`linkerSettings` element.

    Accepts `.headerSearchPath(path)` (in `cSettings`/`cxxSettings`),
    `.define(name)` plus `.define(name, to: value)` (no `to:` in
    `swiftSettings`), `.linkedFramework(name)` and `.linkedLibrary(name)`
    (in `linkerSettings`), `.enableUpcomingFeature(name)` and
    `.enableExperimentalFeature(name)` (in `swiftSettings`), each with an
    optional `.when(platforms: [...])` condition as a second positional
    argument or a labeled `condition:`. `.unsafeFlags(...)` and any other
    setting kind are refused.

    Args:
        target_name: The target holding the setting, for messages.
        array_name: The setting array (`cSettings`, ...).
        element: The element's token list.

    Returns:
        `struct(ok, detail, setting)`: `setting` holds `category` (`c`,
        `cxx`, `swift` or `linker`), `kind` (the dotted name), `name`,
        `value` ("" when the setting carries none), `condition` (None or
        `struct(platforms)`) and `line`.
    """
    who = _swiftpm_setting_target(target_name)
    category = _SWIFTPM_SETTING_CATEGORIES.get(array_name, "")
    if not category:
        return struct(ok = False, detail = "{who}: unknown build-setting array `{array}`".format(who = who, array = array_name), setting = None)
    head = _swiftpm_setting_call(who, array_name, element)
    if not head.ok:
        return struct(ok = False, detail = head.detail, setting = None)
    args = _swiftpm_setting_split_args(who, array_name, head.name, head.args)
    if not args.ok:
        return struct(ok = False, detail = args.detail, setting = None)
    return _swiftpm_setting_named(who, target_name, category, array_name, head.name, args.args, element)

def _swiftpm_setting_named(who, target_name, category, array_name, dotted, args, element):
    """Validate one setting call's name and arguments for its category.

    Args:
        who: The target prefix for messages.
        target_name: The bare target name for the condition parser.
        category: `c`, `cxx`, `swift` or `linker`.
        array_name: The setting array, for messages.
        dotted: The dotted call name.
        args: The parsed argument structs.
        element: The element's token list, for the line number.

    Returns:
        `struct(ok, detail, setting)` (see
        `swiftpm_parse_target_setting`).
    """
    line = element[0].line if element else 0
    if dotted == "unsafeFlags":
        return _swiftpm_setting_failure("{who} uses `.unsafeFlags(...)` in `{array}`, which has no Bazel translation".format(who = who, array = array_name))
    if category == "c" or category == "cxx":
        if dotted == "headerSearchPath":
            return _swiftpm_setting_pathed(who, target_name, category, array_name, dotted, args, line)
        if dotted == "define":
            return _swiftpm_setting_defined(who, target_name, category, array_name, dotted, args, line, True)
    elif category == "swift":
        if dotted == "define":
            return _swiftpm_setting_defined(who, target_name, "swift", array_name, dotted, args, line, False)
        if dotted == "enableUpcomingFeature" or dotted == "enableExperimentalFeature":
            return _swiftpm_setting_pathed(who, target_name, "swift", array_name, dotted, args, line)
    elif category == "linker":
        if dotted == "linkedFramework" or dotted == "linkedLibrary":
            return _swiftpm_setting_pathed(who, target_name, "linker", array_name, dotted, args, line)
    return _swiftpm_setting_failure("{who} uses `.{dotted}(...)` in `{array}`, which has no Bazel translation".format(who = who, dotted = dotted, array = array_name))

def _swiftpm_setting_failure(detail):
    """Return an error setting result struct.

    Args:
        detail: The failure detail string.

    Returns:
        A failed setting result struct.
    """
    return struct(ok = False, detail = detail, setting = None)

def _swiftpm_setting_ok(category, kind, name, value, condition, line):
    """Return a successful setting struct.

    Args:
        category: Setting category (`c`, `cxx`, `swift`, `linker`).
        kind: Setting kind (`define`, `headerSearchPath`, ...).
        name: Setting name text.
        value: Setting value string.
        condition: Condition platforms struct or None.
        line: Source line number.

    Returns:
        A setting result struct.
    """
    return struct(
        ok = True,
        detail = "",
        setting = struct(
            category = category,
            kind = kind,
            name = name,
            value = value,
            condition = condition,
            line = line,
        ),
    )

def _swiftpm_setting_pathed(who, target_name, category, array_name, dotted, args, line):
    """Validate a single-string setting (search path, feature, library).

    Besides the name string the call takes only the optional condition;
    any other labeled argument is refused.

    Args:
        who: The target prefix for messages.
        target_name: The bare target name for the condition parser.
        category: `c`, `cxx`, `swift` or `linker`.
        array_name: The setting array, for messages.
        dotted: The dotted call name.
        args: The parsed argument structs.
        line: The element's line number.

    Returns:
        `struct(ok, detail, setting)`.
    """
    for arg in args:
        if arg.key != "" and arg.key != "condition":
            return _swiftpm_setting_failure("{who}: unexpected `.{dotted}(...)` argument `{key}` in `{array}`".format(who = who, dotted = dotted, key = arg.key, array = array_name))
    name = _swiftpm_setting_string(args, 0)
    if not name.ok:
        return _swiftpm_setting_failure("{who}: `.{dotted}(...)` in `{array}` needs one string argument".format(who = who, dotted = dotted, array = array_name))
    if len([arg for arg in args if arg.key == ""]) > 2:
        return _swiftpm_setting_failure("{who}: malformed `.{dotted}(...)` in `{array}`".format(who = who, dotted = dotted, array = array_name))
    condition = _swiftpm_setting_condition(who, target_name, args)
    if not condition.ok:
        return _swiftpm_setting_failure(condition.detail)
    return _swiftpm_setting_ok(category, dotted, name.text, "", condition.value, line)

def _swiftpm_setting_defined(who, target_name, category, array_name, dotted, args, line, valued):
    """Validate a `.define(name)` / `.define(name, to: value)` setting.

    Args:
        who: The target prefix for messages.
        target_name: The bare target name for the condition parser.
        category: `c`, `cxx` or `swift`.
        array_name: The setting array, for messages.
        dotted: The dotted call name (`define`).
        args: The parsed argument structs.
        line: The element's line number.
        valued: Whether a labeled `to:` value is accepted (`cSettings`/
            `cxxSettings` only; `swiftSettings` conditions carry none).

    Returns:
        `struct(ok, detail, setting)`.
    """
    for arg in args:
        if arg.key != "" and arg.key != "condition" and arg.key != "to":
            return _swiftpm_setting_failure("{who}: unexpected `.define(...)` argument `{key}` in `{array}`".format(who = who, key = arg.key, array = array_name))
    name = _swiftpm_setting_string(args, 0)
    if not name.ok:
        return _swiftpm_setting_failure("{who}: `.define(...)` in `{array}` needs one string argument".format(who = who, array = array_name))
    value = ""
    for arg in args:
        if arg.key == "to":
            if not valued:
                return _swiftpm_setting_failure("{who}: unexpected `.define(...)` argument `to` in `{array}`".format(who = who, array = array_name))
            if len(arg.value) != 1 or arg.value[0].kind != "str":
                return _swiftpm_setting_failure("{who}: `.define(..., to: ...)` in `{array}` needs one string value".format(who = who, array = array_name))
            value = arg.value[0].text
    if len([arg for arg in args if arg.key == ""]) > 2:
        return _swiftpm_setting_failure("{who}: malformed `.define(...)` in `{array}`".format(who = who, array = array_name))
    condition = _swiftpm_setting_condition(who, target_name, args)
    if not condition.ok:
        return _swiftpm_setting_failure(condition.detail)
    return _swiftpm_setting_ok(category, dotted, name.text, value, condition.value, line)

def _swiftpm_gated_platforms(setting):
    """The `.when(platforms:)` list for one parsed setting, or None.

    Args:
        setting: The parsed setting struct (`condition` None or
            `struct(platforms)`).

    Returns:
        None when the setting is unconditional, else the platform list.
    """
    if setting.condition:
        return setting.condition.platforms
    return None

def _swiftpm_fold_clang_list(target, target_dir, settings):
    """Map one C-family setting list onto flag and private include entries.

    `headerSearchPath` is target-local in SwiftPM: it reaches the target's
    own sources only. The entries therefore stay out of the emitted
    library's `includes` (which propagates to dependents) and go to a
    private-headers helper the library reaches through
    `implementation_deps`.

    Args:
        target: The parsed target struct, for messages.
        target_dir: The repo-relative target directory.
        settings: The parsed `cSettings` or `cxxSettings` list.

    Returns:
        `struct(ok, error, flags, private_includes)`: each list holds
        `struct(text, platforms)`.
    """
    flags = []
    private_includes = []
    for setting in settings:
        entry = _swiftpm_clang_entry(target, target_dir, setting)
        if entry.error:
            return struct(ok = False, error = entry.error, flags = [], private_includes = [])
        gated = struct(text = entry.text, platforms = _swiftpm_gated_platforms(setting))
        if entry.private_include:
            private_includes.append(gated)
        else:
            flags.append(gated)
    return struct(ok = True, error = "", flags = flags, private_includes = private_includes)

def _swiftpm_fold_swift_list(target, settings, target_kind):
    """Map one `swiftSettings` list onto compiler flag entries.

    A Swift `.define(X)` is `-DX` in the target's `copts`: SwiftPM applies
    a Swift define to the declaring target only, while a `swift_library`
    `defines` entry reaches every dependent's compile.

    Args:
        target: The parsed target struct, for messages.
        settings: The parsed `swiftSettings` list.
        target_kind: `"swift"` or `"clang"`.

    Returns:
        `struct(ok, error, copts)`: each entry holds
        `struct(text, platforms)`.
    """
    copts = []
    for setting in settings:
        entry = _swiftpm_swift_entry(target, setting, target_kind)
        if entry.error:
            return struct(ok = False, error = entry.error, copts = [])
        platforms = _swiftpm_gated_platforms(setting)
        texts = ["-D" + entry.text] if setting.kind == "define" else entry.texts
        for text in texts:
            copts.append(struct(text = text, platforms = platforms))
    return struct(ok = True, error = "", copts = copts)

def _swiftpm_fold_linker_list(settings):
    """Map one `linkerSettings` list onto link option entries.

    Args:
        settings: The parsed `linkerSettings` list.

    Returns:
        The `struct(text, platforms)` entry list.
    """
    linkopts = []
    for setting in settings:
        for text in _swiftpm_linker_entry(setting):
            linkopts.append(struct(text = text, platforms = _swiftpm_gated_platforms(setting)))
    return linkopts

def swiftpm_target_setting_entries(target, target_dir, target_kind):
    """Map one target's parsed settings onto Bazel flag entries.

    `cSettings` entries become `copts` (`.define` to `-Dname` /
    `-Dname=value`, target-local so they reach `.c`, `.m` and `.mm`
    compiles without propagating to dependents) and `private_includes`
    (`.headerSearchPath`, rebased onto the target directory so the entries
    stay hermetic inside the spoke repository); `cxxSettings` likewise
    onto `cxxopts`;
    `swiftSettings` `.define` onto `-Dname` in `copts` (target-local, the
    way SwiftPM applies it) and the feature settings onto `copts`
    (`-enable-upcoming-feature` / `-enable-experimental-feature`);
    `linkerSettings` onto `linkopts` (`-framework <name>`, `-l<name>`).
    Every entry keeps its `.when(platforms:)` condition for `select()`
    rendering. A `.headerSearchPath` escaping the target directory is
    refused naming it. `cSettings`/`cxxSettings` on a Swift target and
    Swift feature settings on a C-family target are refused: there is no
    compilation they could reach.

    `private_includes` is separate from the emitted library's public
    `includes`: a `.headerSearchPath` is target-local, so the renderer
    puts it on a helper library reached through `implementation_deps`
    instead of an attribute that propagates to dependents.

    Args:
        target: The parsed target struct (`name`, `c_settings`,
            `cxx_settings`, `swift_settings`, `linker_settings`; missing
            lists read as empty).
        target_dir: The repo-relative target directory, for `-I` entries.
        target_kind: `"swift"` or `"clang"`.

    Returns:
        `struct(ok, detail, c_only, cxx, copts, linkopts,
        private_includes)`: each list holds `struct(text, platforms)` with
        `platforms` None or `["ios"]`/`["macos"]` (or both, kept as one
        entry the renderer fans out).
    """
    c_settings = getattr(target, "c_settings", [])
    cxx_settings = getattr(target, "cxx_settings", [])
    c_fold = _swiftpm_fold_clang_list(target, target_dir, c_settings)
    if not c_fold.ok:
        return _swiftpm_target_settings_failure(c_fold.error)
    cxx_fold = _swiftpm_fold_clang_list(target, target_dir, cxx_settings)
    if not cxx_fold.ok:
        return _swiftpm_target_settings_failure(cxx_fold.error)
    if (len(c_settings) + len(cxx_settings)) > 0 and target_kind == "swift":
        msg = "{who} uses C-family settings on a Swift target, which has no Bazel translation".format(who = _swiftpm_setting_target(target.name))
        return _swiftpm_target_settings_failure(msg)
    swift_fold = _swiftpm_fold_swift_list(target, getattr(target, "swift_settings", []), target_kind)
    if not swift_fold.ok:
        return _swiftpm_target_settings_failure(swift_fold.error)
    linkopts = _swiftpm_fold_linker_list(getattr(target, "linker_settings", []))
    return struct(
        ok = True,
        detail = "",
        c_only = c_fold.flags,
        cxx = cxx_fold.flags,
        copts = swift_fold.copts,
        linkopts = linkopts,
        private_includes = c_fold.private_includes + cxx_fold.private_includes,
    )

def _swiftpm_target_settings_failure(detail):
    """Return an error struct for `swiftpm_target_setting_entries`.

    Args:
        detail: The failure detail string.

    Returns:
        A failed `swiftpm_target_setting_entries` result struct.
    """
    return struct(ok = False, detail = detail, c_only = [], cxx = [], copts = [], linkopts = [], private_includes = [])

def _swiftpm_clang_entry(target, target_dir, setting):
    """Render one `cSettings`/`cxxSettings` entry as a flag or a search path.

    Both C-family option lists render the same entries; the caller sorts
    them into `copts` versus `cxxopts`.

    Args:
        target: The parsed target struct, for messages.
        target_dir: The repo-relative target directory.
        setting: The parsed setting struct.

    Returns:
        `struct(error, text, private_include)`: `private_include` when the
        entry is a header search path the target alone may use.
    """
    who = _swiftpm_setting_target(target.name)
    if setting.kind == "headerSearchPath":
        normalized = swiftpm_normalize_relative_path(setting.name)
        if not normalized.ok:
            err = "{who} uses `.headerSearchPath({path})`, which escapes the target directory".format(who = who, path = repr(setting.name))
            return struct(error = err, text = "", private_include = False)
        path = swiftpm_join_path(target_dir, normalized.path)
        return struct(error = "", text = path, private_include = True)
    text = "-D" + setting.name + ("=" + setting.value if setting.value else "")
    return struct(error = "", text = text, private_include = False)

def _swiftpm_swift_entry(target, setting, target_kind):
    """Render one `swiftSettings` entry as a define or feature flags.

    Args:
        target: The parsed target struct, for messages.
        setting: The parsed setting struct.
        target_kind: `"swift"` or `"clang"`.

    Returns:
        `struct(error, text, texts)`: `text` for `.define`, `texts` for
        the two-word feature flags.
    """
    who = _swiftpm_setting_target(target.name)
    if setting.kind == "define":
        return struct(error = "", text = setting.name, texts = [])
    if target_kind != "swift":
        err = "{who} uses `.{kind}(...)` on a C-family target, which has no Bazel translation".format(who = who, kind = setting.kind)
        return struct(error = err, text = "", texts = [])
    flag = "-enable-upcoming-feature" if setting.kind == "enableUpcomingFeature" else "-enable-experimental-feature"
    return struct(error = "", text = "", texts = [flag, setting.name])

def _swiftpm_linker_entry(setting):
    """Render one `linkerSettings` entry as link options.

    Args:
        setting: The parsed setting struct.

    Returns:
        The one or two link option strings.
    """
    if setting.kind == "linkedFramework":
        return ["-framework", setting.name]
    return ["-l" + setting.name]

def _swiftpm_partition_entries(base, entries):
    """Split gated entries into plain, iOS-only and macOS-only buckets.

    An unconditional entry, or one gated on both platforms, joins the
    plain bucket: it holds on every Apple platform the hub builds.

    Args:
        base: The unconditional item strings.
        entries: `struct(text, platforms)` items with `platforms` None or
            a platform list.

    Returns:
        `struct(plain, ios, macos)`: the three item lists.
    """
    plain = [text for text in base]
    ios = []
    macos = []
    for entry in entries:
        if entry.platforms == None or sorted(entry.platforms) == ["ios", "macos"]:
            plain.append(entry.text)
        else:
            if "ios" in entry.platforms:
                ios.append(entry.text)
            if "macos" in entry.platforms:
                macos.append(entry.text)
    return struct(plain = plain, ios = ios, macos = macos)

def _swiftpm_render_select_lines(ios, macos):
    """Render one `select()` on the target platform's OS.

    Args:
        ios: The iOS-only item strings.
        macos: The macOS-only item strings.

    Returns:
        The `select()` text lines, ending with the trailing comma the
        attribute list needs.
    """
    selects = ["    select({"]
    for os_name, items in (("ios", ios), ("macos", macos)):
        if items:
            selects.append("        \"@platforms//os:" + os_name + "\": [")
            for text in items:
                selects.append("            {item},".format(item = repr(text)))
            selects.append("        ],")
    selects.append("        \"//conditions:default\": [],")
    selects.append("    }),")
    return selects

def swiftpm_render_list_attr(attr, base, entries):
    """Render a Bazel list attribute from base items plus gated entries.

    Unconditional entries join the base list; entries gated on
    `.iOS`/`.macOS` render as one `select()` on the target platform's
    OS (`@platforms//os:ios`, `@platforms//os:macos`,
    `//conditions:default`). An entry gated on both platforms joins the
    base list: it holds on every Apple platform the hub builds.

    Args:
        attr: The attribute name (`deps`, `copts`, ...).
        base: The unconditional item strings.
        entries: `struct(text, platforms)` items with `platforms` None or
            a platform list.

    Returns:
        "" when there is nothing to render, else the attribute text.
    """
    parts = _swiftpm_partition_entries(base, entries)
    if not parts.plain and not parts.ios and not parts.macos:
        return ""
    lines = ["    {attr} = [".format(attr = attr)]
    for text in parts.plain:
        lines.append("        {item},".format(item = repr(text)))
    closing = "    ],"
    selects = _swiftpm_render_select_lines(parts.ios, parts.macos) if (parts.ios or parts.macos) else []
    if not selects:
        lines.append(closing)
        return "\n".join(lines)
    if parts.plain:
        return "\n".join(lines) + "\n" + closing[:-1] + " +\n" + "\n".join(selects)
    return "    {attr} = {first}".format(attr = attr, first = selects[0].lstrip()) + "\n" + "\n".join(selects[1:])
