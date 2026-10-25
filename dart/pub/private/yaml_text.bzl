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
    return _find_colon(text, {"braces": 0, "brackets": 0})

def _find_colon(text, counts):
    """Scans for a separating colon, optionally tracking brackets.

    `counts` carries the brace and bracket depth, or None to read brackets
    as content; quotes hide the colon either way, as pub scans them, and a
    `#` comment ends the scan either way, as pub strips it before reading
    the line as a key or a value. The comment starts at the line start,
    after a space or tab, or glued past a closing quote, as pub ends the
    scalar there. A quote opens only where a scalar starts, so an apostrophe
    in a plain scalar never hides a colon; its close is quote-aware, so an
    escaped quote never ends the scalar early.

    Args:
      text: the line to scan.
      counts: the bracket depths, or None.

    Returns:
      The index of the first separating colon, or -1.
    """
    if ":" not in text:
        return -1
    st = {"single": False, "double": False, "escaped": False, "at_start": True, "affix": False}
    if counts == None:
        counts = {"braces": 0, "brackets": 0}
        track = False
    else:
        track = True
    close_pos = -1
    for i in range(len(text)):
        found, close_pos = _find_colon_char(text, i, st, track, counts, close_pos)
        if found != None:
            return found
    return -1

def _find_colon_char(text, i, st, track, counts, close_pos):
    """Scans the character at `i` for a separating colon.

    Returns (found, close_pos): `found` is the colon index or -1 to stop
    the scan with, or None to keep scanning; `close_pos` is the updated
    glued-quote position, as a `#` past a closing quote ends the scan.
    Quotes hide the colon, as pub scans them, and a `#` comment ends the
    scan, as pub strips it before reading the line as a key or a value.
    """
    ch = text[i]
    was_open = st["single"] or st["double"]
    if quote_track(ch, st):
        if not was_open and (st["single"] or st["double"]):
            close_pos = quoted_end_at(text, ch, i + 1)
        return None, close_pos
    if st["single"] or st["double"]:
        return None, close_pos
    if ch == "#":
        if i == 0 or text[i - 1] in [" ", "\t"] or i - 1 == close_pos:
            return -1, close_pos
        return None, close_pos
    if ch == ":" and (not track or (counts["braces"] == 0 and counts["brackets"] == 0)) and (i + 1 == len(text) or text[i + 1] in [" ", "\t"]):
        return i, close_pos
    if track:
        _sep_track(ch, text[i + 1:i + 2], st, counts)
    else:
        _sep_track(ch, text[i + 1:i + 2], st, None)
    return None, close_pos

def _block_affix_rest(text):
    """Skips leading `&anchor` and `!tag` words. Returns the rest."""
    s = text
    for _ in range(4):
        if not (s.startswith("&") or s.startswith("!")):
            break
        i = 0
        for _ in range(len(s)):
            if s[i] in [" ", "\t"]:
                break
            i += 1
        s = s[i:].lstrip(" \t")
    return s

def find_block_colon(text):
    """Returns the index of the first block `: ` in `text`, or -1.

    Brackets past the first character are content, as pub scans a block
    plain scalar, so `te[st: 1` splits; a leading `[` or `{` keeps bracket
    tracking, as the line opens a flow node whose inner colons do not
    count. Anchor and tag prefixes are skipped first, quotes hide the
    colon either way, and a trailing colon counts, as pub scans them.

    Args:
      text: the line to scan.

    Returns:
      The index of the first block colon, or -1.
    """
    if _block_affix_rest(text)[:1] in ["[", "{"]:
        return find_top_colon(text)
    return _find_colon(text, None)

def split_block_key_value(text):
    """Splits `key: value` at the block colon. Returns (key, value, found).

    Args:
      text: the `key: value` line to split.

    Returns:
      The (key, value, found) triple.
    """
    c = find_block_colon(text)
    if c < 0:
        return "", "", False
    return text[:c].strip(), text[c + 1:].strip(), True

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

def is_block_collection_key(text):
    """Returns whether `text` opens a block entry with a list or map key.

    Anchor and tag prefixes are skipped first, as pub still reads `[a]: v`
    under them; quotes hide brackets, as pub scans them. After the matching
    close a separating colon (`: `, a tab, a carriage return or the end of
    the line) marks the collection a key, as pub reads `[a]: v`,
    `&a [x]: v` and `{a: b}: v`; anything else, as in `{a:b}` or `[a], b`,
    reads as before.

    Args:
      text: the block entry line to test.

    Returns:
      Whether the line keys on a flow collection.
    """
    rest = _block_affix_rest(text)
    if rest[:1] not in ["[", "{"]:
        return False
    st = {"single": False, "double": False, "escaped": False, "at_start": True, "affix": False}
    counts = {"braces": 0, "brackets": 0}
    for i in range(len(rest)):
        ch = rest[i]
        if quote_track(ch, st):
            continue
        if st["single"] or st["double"]:
            continue
        _depth_track(ch, counts)
        if ch in ["]", "}"] and counts["braces"] == 0 and counts["brackets"] == 0:
            after = rest[i + 1:].strip(" \t")
            return after == ":" or after.startswith(": ") or after.startswith(":\t") or after.startswith(":\r") or after.endswith(":") or after.endswith(":\r")
    return False

def is_quoted(text):
    return len(text) >= 2 and ((text[0] == '"' and text[-1] == '"') or (text[0] == "'" and text[-1] == "'"))

def is_unknown_directive(line):
    """Returns whether `line` is an unknown `%` directive line, as pub only warns about it.

    The `%` sits at column 0 with a glued name that is neither empty nor a
    known directive (`YAML`, `TAG`), as pub rejects those where it rejects
    them. An indented `%` line is no directive, as pub reads it as content.

    Args:
      line: the raw source line.

    Returns:
      Whether the line is an unknown directive.
    """
    if not line.startswith("%"):
        return False
    word = line[1:].replace("\t", " ").split(" ")[0]
    return word != "" and word != "YAML" and word != "TAG"

def quoted_scalar_rest(s):
    """Returns the text past the leading quoted scalar in `s`, or None.

    `s` must open with `'` or `"`: the close is quote-aware, so `''`
    inside single quotes is one escaped quote and a backslash escapes the
    next character in double quotes, as pub reads them. A `#` comment glued
    past the close stays in the rest, so the caller reads the scalar
    without it, as pub ends the scalar there. None when `s` opens with no
    closing quote, or opens with no quote at all.

    Args:
      s: the scalar text opening with a quote.

    Returns:
      The text after the closing quote, or None.
    """
    if s[:1] not in ["'", '"']:
        return None
    end = quoted_end_at(s, s[0], 1)
    if end < 0:
        return None
    return s[end + 1:]

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

def is_block_mapping_start(text):
    """Returns whether `text` opens a block mapping entry in block context.

    Brackets past the first character are content, as pub scans a block
    plain scalar, so `te[st: 1` opens one; a leading `[` or `{` still hides
    inner colons, as the line opens a flow node.
    """
    return text.startswith("? ") or text.startswith(": ") or find_block_colon(text) >= 0

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
    if text[:1] == "?":
        # A `?` glued to text with no colon is a key missing its colon, as
        # pub rejects it there; a true marker returned above, and a colon
        # form never reaches here, as the block walk places it as a key.
        state.problems.append("key without colon at line %d is not supported: %r" % (idx + 1, text))
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
