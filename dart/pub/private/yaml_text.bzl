"""Line shapes for the pubspec YAML reader.

Holds indentation and quote/bracket tracking, comment and colon scans, the
`key: value` split and the small line predicates (dashes, flow entries,
markers). Loaded by every other parser module.
"""

load(":yaml_chars.bzl", "is_marker_line")

# The bytes that are never blanks to pub, written as octal escapes so the
# source stays ASCII: vertical tab, form feed and U+001C to U+001F. Only
# space and tab separate tokens outside quotes and comments; these fail
# wherever a blank may sit, while NEL, NBSP and U+3000 stay content.
_BAD_BLANKS = "\013\014\034\035\036\037"

def indent_width(raw):
    """Counts the leading spaces and tabs, each as one column, as yaml.bzl does."""
    return len(raw) - len(raw.lstrip(" \t"))

def spaces_width(raw):
    """Counts the leading spaces, stopping at a tab, which never indents."""
    return len(raw) - len(raw.lstrip(" "))

def quote_track(ch, st):
    """Tracks quote state for `ch`, updating `st` in place. Returns whether `ch` was consumed.

    `st` carries single, double, escaped, at_start and affix. A quote opens
    only where a scalar starts, so an apostrophe in a plain scalar stays
    content; a backslash escapes the next character in double quotes.


    Args:
      ch: the character to track.
      st: the quote state updated in place.

    Returns:
      Whether `ch` was consumed.
    """
    if st["escaped"]:
        st["escaped"] = False
        return True
    if st["double"] and ch == "\\":
        st["escaped"] = True
        return True
    if ch == "'" and not st["double"]:
        if st["single"]:
            st["single"] = False
            st["at_start"] = False
        elif st["at_start"]:
            st["single"] = True
        st["affix"] = False
        return True
    if ch == '"' and not st["single"]:
        if st["double"]:
            st["double"] = False
            st["at_start"] = False
        elif st["at_start"]:
            st["double"] = True
        st["affix"] = False
        return True
    return False

def _depth_track(ch, counts):
    """Counts one bracket character into `counts`, doing nothing when None.

    `counts` carries the brace and bracket depth.
    """
    if counts == None:
        return
    if ch == "{":
        counts["braces"] += 1
    elif ch == "}":
        counts["braces"] -= 1
    elif ch == "[":
        counts["brackets"] += 1
    elif ch == "]":
        counts["brackets"] -= 1

def _depth_top(counts):
    """Returns whether `counts` is None or both depths are zero."""
    return counts == None or (counts["braces"] == 0 and counts["brackets"] == 0)

def _sep_track(ch, nxt, st, counts):
    """Tracks scalar-start state for a character outside quotes.

    `st` carries at_start and affix; `counts`, when not None, carries the
    brace and bracket depth. A `-` or `:` starts a fresh scalar with
    separation after it, as do `[`, `{` and `,`; an `&` or `!` word does once
    a space ends it. A nested colon changes nothing.
    """
    if ch in ["&", "!"]:
        st["affix"] = True
        st["at_start"] = False
    elif ch in ["[", "{", ","]:
        _depth_track(ch, counts)
        st["at_start"] = True
        st["affix"] = False
    elif ch in ["}", "]"]:
        _depth_track(ch, counts)
    elif ch == ":" and nxt in [" ", "\t", ""] and _depth_top(counts):
        st["at_start"] = True
        st["affix"] = False
    elif ch == "-" and nxt in [" ", "\t", ""]:
        st["at_start"] = True
        st["affix"] = False
    elif ch in [" ", "\t"]:
        if st["affix"]:
            st["affix"] = False
            st["at_start"] = True
    elif ch == ":":
        st["at_start"] = False
        st["affix"] = False
    else:
        st["at_start"] = False
        st["affix"] = False

def strip_trailing_comment(text):
    """Removes a trailing `#` comment, ignoring `#` inside quotes.

    A quote opens only where a scalar starts (the line start, or after `[`,
    `{`, `,`, a separating colon, a `- ` dash or an anchor or tag word), so
    an apostrophe in a plain scalar never hides a comment.


    Args:
      text: the line to strip.

    Returns:
      The line without its trailing comment.
    """
    if "#" not in text:
        return text.rstrip()
    st = {"single": False, "double": False, "escaped": False, "at_start": True, "affix": False}
    for i in range(len(text)):
        ch = text[i]
        if quote_track(ch, st):
            continue
        if ch == "#":
            if not st["single"] and not st["double"]:
                if i == 0 or text[i - 1] in [" ", "\t"]:
                    return text[:i].rstrip()
            continue
        _sep_track(ch, text[i + 1:i + 2], st, None)
    return text.rstrip()

def bad_blank_index(text):
    """Returns the index of the first bad blank outside quotes and comments, or -1.

    The walk mirrors `strip_trailing_comment`: a quote opens only where a scalar
    starts, so an apostrophe in a plain scalar never shields a blank, and a
    `#` at the start or after a space or tab opens a comment hiding the
    rest, as pub scans them.


    Args:
      text: the line to scan.

    Returns:
      The index of the first bad blank, or -1.
    """
    st = {"single": False, "double": False, "escaped": False, "at_start": True, "affix": False}
    for i in range(len(text)):
        ch = text[i]
        if quote_track(ch, st):
            continue
        if st["single"] or st["double"]:
            continue
        if ch in _BAD_BLANKS:
            return i
        if ch == "#":
            if i == 0 or text[i - 1] in [" ", "\t"]:
                return -1
            continue
        _sep_track(ch, text[i + 1:i + 2], st, None)
    return -1

def find_top_colon(text):
    """Returns the index of the first top-level `: ` in `text`, or -1.

    A colon inside quotes or brackets does not count, and a trailing colon
    does. A quote opens only where a scalar starts, so an apostrophe in a
    plain scalar never hides a colon.


    Args:
      text: the line to scan.

    Returns:
      The index of the first top-level colon, or -1.
    """
    if ":" not in text:
        return -1
    st = {"single": False, "double": False, "escaped": False, "at_start": True, "affix": False}
    counts = {"braces": 0, "brackets": 0}
    for i in range(len(text)):
        ch = text[i]
        if quote_track(ch, st):
            continue
        if st["single"] or st["double"]:
            continue
        if ch == ":" and counts["braces"] == 0 and counts["brackets"] == 0 and (i + 1 == len(text) or text[i + 1] in [" ", "\t"]):
            return i
        _sep_track(ch, text[i + 1:i + 2], st, counts)
    return -1

def split_key_value(text):
    """Splits `key: value` at the top-level colon. Returns (key, value, found).

    Args:
      text: the `key: value` line to split.

    Returns:
      The (key, value, found) triple.
    """
    c = find_top_colon(text)
    if c < 0:
        return "", "", False
    return text[:c].strip(), text[c + 1:].strip(), True

def is_quoted(text):
    return len(text) >= 2 and ((text[0] == '"' and text[-1] == '"') or (text[0] == "'" and text[-1] == "'"))

# ---------------------------------------------------------------------------
# Scalars
# ---------------------------------------------------------------------------

def is_dash(text):
    """Returns whether `text` opens a block sequence entry.

    A dash opens an entry with a space or a tab after it, as pub reads
    `-\tx` as `x`.
    """
    return text == "-" or text.startswith("- ") or text.startswith("-\t")

def is_question_entry(text):
    """Returns whether `text` is an explicit-key marker, as pub rejects it where a value starts.

    A bare `?`, or `?` with a space or a tab after it, opens an explicit
    key; `?a` stays a plain scalar, as pub reads it.
    """
    return text == "?" or text.startswith("? ") or text.startswith("?\t")

def _is_dash_pair(text):
    """Returns whether `text` pairs a bare dash key with a spaced colon, as pub reads `[-: 1]`."""
    return len(text) > 2 and text[0] == "-" and text[1] == ":" and text[2] in [" ", "\t"]

def is_flow_value_entry(text):
    """Returns whether `text` is a block entry where a flow value starts, as pub rejects it.

    A `- ` entry, a `-: ` pair and a `?` marker all fail as a flow mapping
    value or pair value; `-:x` without a space stays a plain scalar, as pub
    reads it.
    """
    return is_dash(text) or _is_dash_pair(text) or is_question_entry(text)

def is_flow_seq_entry(token):
    """Returns whether a flow sequence item token is a block entry, as pub rejects it.

    A `- ` entry fails, as does an explicit `?` key holding an entry; a
    `-: ` pair reads as a one-pair mapping and a `?` key reads, as pub
    reads them.


    Args:
      token: the flow sequence item token.

    Returns:
      Whether the token is a block entry.
    """
    if is_dash(token):
        return True
    for prefix in ["? ", "?\t"]:
        if token.startswith(prefix) and is_flow_value_entry(token[2:]):
            return True
    return False

def is_mapping_start(text):
    """Returns whether `text` opens a block mapping entry."""
    return text.startswith("? ") or text.startswith(": ") or find_top_colon(text) >= 0

def is_compact_seq(pending, indent, text):
    """Returns whether `text` is a compact entry of a pending mapping key."""
    return type(pending["parent"]) == "dict" and indent == pending["indent"] and is_dash(text)

def is_explicit_key_text(text):
    """Returns whether `text` is an explicit-key line: `? key` or `: value`.

    A bare `?` or `:` counts too. Without a following space, tab or
    end-of-line the mark is a plain scalar, not an explicit key.


    Args:
      text: the line to test.

    Returns:
      Whether `text` is an explicit-key line.
    """
    if text == "?" or text == ":":
        return True
    if len(text) < 2:
        return False
    return text[0] in ["?", ":"] and text[1] in [" ", "\t"]

def dict_key(value):
    """Converts a parsed value to a dict key, as yaml.bzl does.

    Args:
      value: the parsed value.

    Returns:
      The value as a dict key.
    """
    t = type(value)
    if t in ["string", "int", "float", "bool", "NoneType"]:
        return value
    if t in ["list", "dict"]:
        return json.encode(value)
    return str(value)

# ---------------------------------------------------------------------------
# Block scalars
# ---------------------------------------------------------------------------

def clone(value):
    """A shallow copy of a container, as yaml.bzl makes for aliases.

    Args:
      value: the value to copy.

    Returns:
      A shallow copy of a list or dict value, or the value itself.
    """
    t = type(value)
    if t == "list":
        return list(value)
    if t == "dict":
        return dict(value)
    return value

def quoted_end_at(s, quote, i):
    """Returns the index of the `quote` closing at or after `i`, or -1.

    `''` inside single quotes is one escaped quote and a backslash escapes
    the next character in double quotes, as pub reads them. Returns -1 when
    the quote never closes.


    Args:
      s: the text to scan.
      quote: the closing quote to find.
      i: the index to start at.

    Returns:
      The index of the closing quote, or -1.
    """
    for _ in range(len(s) + 1):
        if i >= len(s):
            return -1
        ch = s[i]
        if quote == '"' and ch == "\\":
            i += 2
            continue
        if ch == quote:
            if quote == "'" and s[i + 1:i + 2] == "'":
                i += 2
                continue
            return i
        i += 1
    return -1

def record_unreadable(state, idx, text):
    """Records a skipped line when strict. Lenient parsing ignores it.

    An explicit key is never skipped silently: it is not supported, so it is
    always a problem naming the line, in strict and lenient modes alike.


    Args:
      state: the parse state collecting problems.
      idx: the 0-based index of the skipped line.
      text: the skipped line text.
    """
    if is_explicit_key_text(text):
        state.problems.append("explicit key at line %d is not supported: %r" % (idx + 1, text))
        return
    if state.strict_lines:
        state.problems.append("unreadable line %d: %r" % (idx + 1, text))

def block_line_text(raw):
    """Returns (indent, comment-stripped text) of a block line, or (None, None) when it carries no content.

    Args:
      raw: the raw source line.

    Returns:
      The (indent, comment-stripped text) pair, or (None, None) when the line carries
      no content.
    """
    stripped = raw.strip()
    if not stripped or stripped.startswith("#") or stripped.startswith("%") or is_marker_line(raw, "---") or is_marker_line(raw, "..."):
        return None, None
    indent = indent_width(raw)
    text = strip_trailing_comment(raw[indent:])
    if text == "":
        return None, None
    return indent, text

def flow_head_text(value_text):
    """Strips anchor and tag prefixes from `value_text`, returning the value head.

    Args:
      value_text: the scalar text with anchor and tag prefixes.

    Returns:
      The value head.
    """
    s = value_text.strip()
    for _ in range(4):
        if not s:
            break
        if s.startswith("&") or s.startswith("!"):
            parts = s.split(" ", 1)
            s = parts[1].strip() if len(parts) > 1 else ""
        else:
            break
    return s
