"""Low-level line-oriented scanner and token parsing for CocoaPods `Podfile.lock`.

CocoaPods writes a deterministic, line-oriented YAML subset. This scanner provides
pure, bounded line inspection: checking indentation tabs, detecting flow syntax
and anchors, counting indentation, and parsing pod entry and dependency lines.
"""

visibility(["//flutter/..."])

_FLOW_OR_ANCHOR_CHARS = ("[", "]", "{", "}", "&", "*")

def make_refusal(label, line_num, detail):
    """Format a standard refusal error naming the label and 1-based line.

    Args:
        label: The file label string.
        line_num: 1-based line number.
        detail: The specific error message.

    Returns:
        Formatted error string `"<label> (Podfile.lock line <n>): <detail>."`.
    """
    return "{label} (Podfile.lock line {line}): {detail}.".format(
        label = label,
        line = line_num,
        detail = detail,
    )

def has_indent_tab(line):
    """Whether `line` has a tab character in its leading indentation.

    Args:
        line: The raw line string.

    Returns:
        True if any character before the first non-space character is a tab,
        or if a blank line contains a tab.
    """
    for i in range(len(line)):
        c = line[i]
        if c == "\t":
            return True
        if c != " ":
            return False
    return False

def starts_with_flow_or_anchor(stripped):
    """Whether `stripped` itself begins with flow syntax or an anchor/alias.

    Args:
        stripped: The line content stripped of leading and trailing whitespace.

    Returns:
        True if `stripped` starts with `[`, `]`, `{`, `}`, `&`, or `*`.
    """
    return bool(stripped) and stripped[0] in _FLOW_OR_ANCHOR_CHARS

def _mapping_value_has_flow(text):
    """Whether `text` is a mapping whose value starts with flow or anchor syntax."""
    sep = find_mapping_separator(text)
    if not sep.has_kv or not sep.val:
        return False
    val = sep.val.lstrip()
    return starts_with_flow_or_anchor(val)

def has_flow_or_anchor(stripped):
    """Whether `stripped` starts a key or value with flow syntax or an anchor.

    Args:
        stripped: The line content stripped of leading and trailing whitespace.

    Returns:
        True if flow syntax (`[`, `]`, `{`, `}`) or anchor/alias (`&`, `*`)
        appears where a key or value begins.
    """
    if starts_with_flow_or_anchor(stripped):
        return True
    if stripped.startswith("-") and len(stripped) > 1 and stripped[1] in (" ", "\t"):
        item = stripped[2:].lstrip()
        if not item:
            return False
        return starts_with_flow_or_anchor(item) or _mapping_value_has_flow(item)
    return _mapping_value_has_flow(stripped)

def count_indent(line):
    """Count leading spaces of `line`.

    Args:
        line: The line string.

    Returns:
        Number of leading spaces.
    """
    count = 0
    for i in range(len(line)):
        if line[i] == " ":
            count += 1
        else:
            break
    return count

def unquote(scalar):
    """Strip enclosing quotes from `scalar` if present.

    Args:
        scalar: The scalar string.

    Returns:
        The scalar without its enclosing quotes, or unchanged when it is not quoted.
    """
    s = scalar.strip()
    if len(s) >= 2:
        if (s[0] == '"' and s[-1] == '"') or (s[0] == "'" and s[-1] == "'"):
            return s[1:-1]
    return s

def _unquote_strict(scalar):
    """Unquote a scalar, rejecting unbalanced or internal quotes.

    Args:
        scalar: Stripped scalar text.

    Returns:
        `struct(ok, text)`, where `text` is the unquoted scalar when `ok` is true.
    """
    if not scalar:
        return struct(ok = False, text = "")
    if scalar[0] in ('"', "'") or scalar[-1] in ('"', "'"):
        quote = scalar[0]
        if len(scalar) < 2 or quote not in ('"', "'") or scalar[-1] != quote:
            return struct(ok = False, text = "")
        inner = scalar[1:-1]
        if inner.find(quote) != -1:
            return struct(ok = False, text = "")
        return struct(ok = True, text = inner)
    if scalar.find('"') != -1 or scalar.find("'") != -1:
        return struct(ok = False, text = "")
    return struct(ok = True, text = scalar)

def _split_quoted_key(s, quote):
    """Split a mapping line whose key starts with `quote`."""
    close_q = s.find(quote, 1)
    if close_q == -1:
        return struct(has_kv = False, key = s, val = "")
    key = s[1:close_q]
    after = s[close_q + 1:].lstrip()
    if after == ":" or (len(after) >= 2 and after[0] == ":" and after[1] in (" ", "\t")):
        return struct(has_kv = True, key = key, val = after[1:].strip())
    return struct(has_kv = False, key = s, val = "")

def find_mapping_separator(s):
    """Find the key and value of a YAML mapping in `s`.

    In YAML, a mapping separator ':' is either followed by whitespace or is
    at the end of the line. A colon inside a URL (e.g. 'https://...') is
    not followed by whitespace, so it is part of the scalar, not a separator.
    For symbol keys (e.g. ':path:'), the leading colon is part of the key.

    Args:
        s: The stripped content string.

    Returns:
        `struct(has_kv, key, val)`: `has_kv` is True if a separator was found,
        `key` is the string before the separator, `val` is the string after.
    """
    if not s:
        return struct(has_kv = False, key = "", val = "")
    if s[0] in ('"', "'"):
        return _split_quoted_key(s, s[0])
    start_pos = 1 if s.startswith(":") else 0
    n = len(s)
    for i in range(start_pos, n):
        if s[i] == ":" and (i == n - 1 or s[i + 1] in (" ", "\t")):
            return struct(has_kv = True, key = s[:i].strip(), val = s[i + 1:].strip())
    return struct(has_kv = False, key = s.strip(), val = "")

def parse_mapping_line(stripped):
    """Parse a YAML mapping line into mapping flag, key, kind and value.

    Args:
        stripped: A mapping line stripped of indentation.

    Returns:
        `struct(has_kv, key, is_symbol, kind, value)`.
    """
    sep = find_mapping_separator(stripped)
    key = unquote(sep.key)
    is_symbol = key.startswith(":")
    kind = key[1:] if is_symbol else key
    return struct(
        has_kv = sep.has_kv,
        key = key,
        is_symbol = is_symbol,
        kind = kind,
        value = unquote(sep.val),
    )

def _is_valid_pod_token(token, allow_spaces = False):
    """Whether `token` is non-empty and free of delimiter characters."""
    if not token or token.startswith("-"):
        return False
    bad_chars = ("(", ")", ":", '"', "'", "\t") if allow_spaces else (" ", "\t", "(", ")", ":", '"', "'")
    for ch in bad_chars:
        if token.find(ch) != -1:
            return False
    return True

def parse_pods_entry(stripped):
    """Parse a `- <name> (<version>)` or `- <name> (<version>):` entry line.

    Either form may be bare or quoted (`- "<name> (<version>)"`,
    `- "<name> (<version>)":`).

    Args:
        stripped: The line text stripped of leading indentation.

    Returns:
        `struct(ok, name, version, has_colon)` where `ok` is True on success,
        False if the line is not a valid entry.
    """
    if not stripped.startswith("- "):
        return struct(ok = False, name = "", version = "", has_colon = False)
    rest = stripped[2:].strip()
    has_colon = rest.endswith(":")
    if has_colon:
        rest = rest[:-1].strip()
    unquoted = _unquote_strict(rest)
    if not unquoted.ok or not unquoted.text.endswith(")"):
        return struct(ok = False, name = "", version = "", has_colon = False)
    inner = unquoted.text
    open_paren = inner.rfind(" (")
    if open_paren <= 0:
        return struct(ok = False, name = "", version = "", has_colon = False)
    name = inner[:open_paren]
    version = inner[open_paren + 2:-1]
    if not _is_valid_pod_token(name) or not _is_valid_pod_token(version):
        return struct(ok = False, name = "", version = "", has_colon = False)
    return struct(ok = True, name = name, version = version, has_colon = has_colon)

def parse_pods_dep(stripped):
    """Parse a `- <name>` or `- <name> (<requirement>)` dependency line.

    Args:
        stripped: The line text stripped of leading indentation.

    Returns:
        `struct(ok, name, requirement)` where `ok` is True on success, False
        if the line is not a valid dependency line.
    """
    if not stripped.startswith("- "):
        return struct(ok = False, name = "", requirement = "")
    unquoted = _unquote_strict(stripped[2:].strip())
    if not unquoted.ok:
        return struct(ok = False, name = "", requirement = "")
    rest = unquoted.text
    if rest.endswith(")"):
        open_paren = rest.rfind(" (")
        if open_paren <= 0:
            return struct(ok = False, name = "", requirement = "")
        name = rest[:open_paren]
        req = rest[open_paren + 2:-1].strip()
        if not _is_valid_pod_token(name) or not _is_valid_pod_token(req, allow_spaces = True):
            return struct(ok = False, name = "", requirement = "")
        return struct(ok = True, name = name, requirement = req)
    if not _is_valid_pod_token(rest):
        return struct(ok = False, name = "", requirement = "")
    return struct(ok = True, name = rest, requirement = "")
