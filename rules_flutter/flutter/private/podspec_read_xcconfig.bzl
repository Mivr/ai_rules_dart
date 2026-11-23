"""Static `GCC_PREPROCESSOR_DEFINITIONS` reading for CocoaPods `.podspec` xcconfig hashes.

Reads the `pod_target_xcconfig` and `xcconfig` declarations of a podspec token
stream (no Ruby evaluation) and splices the resulting defines into a rendered
spoke `BUILD` file as `plugin_defines`. A value holding Ruby interpolation is
skipped whole: dynamic defines come from `flutter.pub(ios_plugin_defines = ...)`.
"""

load(":flutter_apple_plugin_defines.bzl", "dedupe_plugin_defines")
load(":starlark_literal.bzl", "decode_starlark_escapes", "starlark_string_literal")

visibility(["//flutter/..."])

_DEFINES_KEY = "GCC_PREPROCESSOR_DEFINITIONS"
_XCCONFIG_ATTRS = ("pod_target_xcconfig", "xcconfig")
_PLUGIN_DEFINES_MARKER = "    plugin_defines = "
_ACTIVE_SCOPES = {"ios": ("", "ios"), "macos": ("", "osx", "macos")}

def _is_op(tok, text):
    """True when `tok` is the operator token `text`."""
    return tok.kind == "op" and tok.text == text

def _split_commas(tokens):
    """Split `tokens` on top-level commas, dropping empty groups."""
    groups = []
    cur = []
    depth = 0
    for tok in tokens:
        if tok.kind == "op" and tok.text in ("[", "{", "("):
            depth += 1
        elif tok.kind == "op" and tok.text in ("]", "}", ")"):
            depth -= 1
        if depth == 0 and _is_op(tok, ","):
            groups.append(cur)
            cur = []
        else:
            cur.append(tok)
    groups.append(cur)
    return [g for g in groups if g]

def _is_define_name(name):
    """True when `name` is a C identifier."""
    if not name or name[0].isdigit():
        return False
    return all([c.isalnum() or c == "_" for c in name.elems()])

def split_xcconfig_words(text):
    """Split an xcconfig value on unquoted whitespace, keeping each token verbatim.

    Single quotes, double quotes and backslash escapes keep whitespace inside a
    token; a token with an unterminated quote is dropped.

    Args:
        text: The literal xcconfig value string.

    Returns:
        The token strings, quotes and backslashes preserved.
    """
    words = []
    cur = []
    quote = ""
    idx = 0
    for _ in range(len(text) + 1):
        if idx >= len(text):
            break
        c = text[idx]
        if quote == "'":
            quote = "" if c == "'" else quote
        elif c == "\\" and idx + 1 < len(text):
            cur.append(c)
            idx += 1
            c = text[idx]
        elif quote:
            quote = "" if c == quote else quote
        elif c in ("'", '"'):
            quote = c
        elif c.isspace():
            if cur:
                words.append("".join(cur))
            cur = []
            idx += 1
            continue
        cur.append(c)
        idx += 1
    if cur and not quote:
        words.append("".join(cur))
    return words

def xcconfig_value_defines(text):
    """The `NAME` / `NAME=VALUE` define entries of one literal xcconfig value string.

    Args:
        text: The literal `GCC_PREPROCESSOR_DEFINITIONS` string.

    Returns:
        The valid entries in order; `$(inherited)`, `${inherited}` and tokens
        that are not static preprocessor definitions are skipped.
    """
    entries = []
    for word in split_xcconfig_words(text):
        if word in ("$(inherited)", "${inherited}") or "#{" in word:
            continue
        entry = word[2:] if word.startswith("-D") else word
        if _is_define_name(entry.partition("=")[0]):
            entries.append(entry)
    return entries

def _literal_strings(value_tokens):
    """The static literal strings of an xcconfig value expression (string, array, `%w`)."""
    if len(value_tokens) == 1:
        tok = value_tokens[0]
        if tok.kind == "pct_w" and tok.words != None:
            return list(tok.words)
        if tok.kind == "str" and not tok.interp:
            return [tok.text]
        return []
    if len(value_tokens) >= 2 and _is_op(value_tokens[0], "[") and _is_op(value_tokens[-1], "]"):
        strings = []
        for group in _split_commas(value_tokens[1:-1]):
            if len(group) == 1 and group[0].kind == "str" and not group[0].interp:
                strings.append(group[0].text)
        return strings
    return []

def _hash_defines(tokens):
    """Defines from the `'GCC_PREPROCESSOR_DEFINITIONS' => value` entries of hash body `tokens`."""
    defines = []
    for entry in _split_commas(tokens):
        key = entry[0]
        if len(entry) < 3 or key.kind != "str" or key.interp or key.text != _DEFINES_KEY:
            continue
        if not _is_op(entry[1], "=>"):
            continue
        for text in _literal_strings(entry[2:]):
            defines.extend(xcconfig_value_defines(text))
    return defines

def xcconfig_hash_defines(rhs_tokens):
    """Defines from a `{ ... }` xcconfig hash literal; `[]` for any other expression.

    Args:
        rhs_tokens: Non-newline tokens of the attribute's right-hand side.

    Returns:
        The define entries in declaration order.
    """
    if len(rhs_tokens) >= 2 and _is_op(rhs_tokens[0], "{") and _is_op(rhs_tokens[-1], "}"):
        return _hash_defines(rhs_tokens[1:-1])
    return []

def xcconfig_merge_defines(stmt, platform):
    """Defines from `<recv>[.<scope>].<xcconfig>.merge[!](<hash>)`, or `[]`.

    Args:
        stmt: The statement's non-newline tokens.
        platform: The active Apple platform, `"ios"` or `"macos"`.

    Returns:
        The define entries in declaration order.
    """
    if len(stmt) < 7 or stmt[0].kind != "word" or not _is_op(stmt[1], "."):
        return []
    pos = 2
    scope = ""
    if stmt[pos].kind == "word" and stmt[pos].text not in _XCCONFIG_ATTRS and _is_op(stmt[pos + 1], "."):
        scope = stmt[pos].text
        pos += 2
    if pos + 4 >= len(stmt) or stmt[pos].text not in _XCCONFIG_ATTRS or not _is_op(stmt[pos + 1], "."):
        return []
    if stmt[pos + 2].text not in ("merge", "merge!") or scope not in _ACTIVE_SCOPES[platform]:
        return []
    pos += 3
    if pos >= len(stmt) - 1 or not _is_op(stmt[pos], "(") or not _is_op(stmt[-1], ")"):
        return []
    args = stmt[pos + 1:-1]
    if len(args) >= 2 and _is_op(args[0], "{") and _is_op(args[-1], "}"):
        args = args[1:-1]
    return _hash_defines(args)

def _parse_defines_list(line):
    """Parse the string items of one rendered `plugin_defines = [...]` attribute line."""
    items = []
    idx = line.find("[") + 1
    for _ in range(len(line) + 1):
        start = -1
        for pos in range(idx, len(line)):
            if line[pos] in ('"', "'"):
                start = pos
                break
        if start < 0:
            break
        quote = line[start]
        end = start + 1
        for _ in range(len(line)):
            if end >= len(line) or line[end] == quote:
                break
            end += 2 if line[end] == "\\" else 1
        items.append(decode_starlark_escapes(line[start + 1:end]).text)
        idx = end + 1
    return items

def splice_podspec_defines(block, defines):
    """Merge podspec `defines` into one target block's single `plugin_defines` attribute.

    Existing entries (rendered from `ios_plugin_defines`) override podspec
    entries of the same macro name and stay in the one attribute.

    Args:
        block: The target's attribute text, without a trailing newline.
        defines: The podspec `GCC_PREPROCESSOR_DEFINITIONS` entries.

    Returns:
        The block text; unchanged when `defines` is empty.
    """
    if not defines:
        return block
    start = block.find(_PLUGIN_DEFINES_MARKER)
    if start > 0 and block[start - 1] != "\n":
        start = -1
    end = block.find("\n", start) if start >= 0 else -1
    if start < 0:
        return block + "\n" + _PLUGIN_DEFINES_MARKER + starlark_string_literal(defines) + ","
    if end < 0:
        end = len(block)
    existing = _parse_defines_list(block[start:end])
    merged = dedupe_plugin_defines(defines + existing)
    return block[:start] + _PLUGIN_DEFINES_MARKER + starlark_string_literal(merged) + "," + block[end:]

def active_podspec_defines(apple, platform):
    """The podspec `defines` of one Apple platform from a `detect_apple_podspecs`-style struct.

    Args:
        apple: A struct that may carry `ios_podspec` / `macos_podspec`.
        platform: `"ios"` or `"macos"`.

    Returns:
        The define entries, `[]` when the platform has no podspec.
    """
    podspec = getattr(apple, platform + "_podspec", None)
    return list(getattr(podspec, "defines", [])) if podspec else []
