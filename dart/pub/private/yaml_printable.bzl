"""Non-printable character, control, and indicator checks for the pubspec YAML reader.

Holds scalar printable checks (C0, C1, DEL, U+FFFE, U+FFFF and surrogates),
anchor and tag prefix splitting, and block entry indicator validations.
Loaded by the scalar, block and flow modules.
"""

load(":yaml_text.bzl", "is_dash", "is_question_entry")

# Control characters package:yaml refuses in a plain scalar, written as
# octal escapes so the source stays ASCII: the C0 controls except tab, LF
# and CR, which structure lines, plus DEL. Tab, LF and CR stay content, as
# pub reads them.
_REFUSED_CONTROLS = (
    "\000\001\002\003\004\005\006\007\010\013\014\016\017\020\021\022\023" +
    "\024\025\026\027\030\031\032\033\034\035\036\037\177"
)

def _is_c1_control(b1, b2):
    """Returns whether two bytes encode a raw C1 control code (U+0080..U+009F except U+0085)."""
    if b1 != "\302":
        return False
    return "\200" <= b2 and b2 <= "\237" and b2 != "\205"

def _is_unprintable_utf8(s, i, n):
    """Returns 'control', 'non-printable', or None for the character starting at `i` in `s`."""
    ch = s[i]
    if ch in _REFUSED_CONTROLS:
        return "control"
    if ch == "\302" and i + 1 < n:
        if _is_c1_control(ch, s[i + 1]):
            return "control"
    elif ch == "\357" and i + 2 < n:
        if s[i + 1] == "\277" and s[i + 2] in ["\276", "\277"]:
            return "non-printable"
    elif ch == "\355" and i + 2 < n:
        if "\240" <= s[i + 1] and s[i + 1] <= "\277" and "\200" <= s[i + 2] and s[i + 2] <= "\277":
            return "non-printable"
    return None

def check_scalar_unprintable(s, state, line):
    """Checks whether a plain scalar holds disallowed control or non-printable characters.

    YAML 1.2 excludes C0 controls (except tab, LF, CR), DEL, C1 controls
    (except NEL U+0085), U+FFFE, U+FFFF and UTF-16 surrogates from plain
    scalars.

    Args:
      s: the scalar text.
      state: the parse state collecting problems.
      line: the 1-based line number naming failures.

    Returns:
      True when a problem was found and recorded, False otherwise.
    """
    n = len(s)
    for i in range(n):
        kind = _is_unprintable_utf8(s, i, n)
        if kind == "control":
            state.problems.append("control character at line %d is not supported" % line)
            return True
        if kind == "non-printable":
            state.problems.append("non-printable character at line %d is not supported" % line)
            return True
    return False

def strip_value_prefix(s):
    """Splits leading `&anchor` and `!tag` words. Returns (anchor, tag, rest, bad).

    At most one anchor and one tag read, in either order, as pub reads
    them; `bad` is "" or the first rejected shape: an empty anchor name, a
    repeated anchor or a repeated tag. A `!` word alone is a non-specific
    tag, as pub reads it.

    Args:
      s: the text starting with the value.

    Returns:
      The (anchor, tag, rest, bad) tuple, where bad is "" or the first rejected shape.
    """
    anchor = None
    tag = None
    bad = ""
    rest = s
    for _ in range(4):
        if rest == "":
            break
        if rest.startswith("&"):
            word, rest = _split_prefix_word(rest)
            anchor, bad = _strip_anchor_word(word, anchor, bad)
        elif rest.startswith("!"):
            word, rest = _split_prefix_word(rest)
            tag, bad = _strip_tag_word(word, tag, bad)
        else:
            break
    return (anchor, tag, rest, bad)

def _strip_anchor_word(word, anchor, bad):
    """Reads an `&name` word. Returns (anchor, bad).

    An empty name and a repeated anchor are the first rejected shape, as
    pub reads at most one anchor.
    """
    name = word[1:]
    if name == "":
        if bad == "":
            bad = "empty-anchor"
    elif anchor != None:
        if bad == "":
            bad = "repeat-anchor"
    else:
        anchor = name
    return (anchor, bad)

def _strip_tag_word(word, tag, bad):
    """Reads a `!tag` word. Returns (tag, bad).

    A repeated tag is the first rejected shape, as pub reads at most one.
    """
    if tag != None:
        if bad == "":
            bad = "repeat-tag"
    else:
        tag = word
    return (tag, bad)

def _split_prefix_word(s):
    """Splits a leading `&`/`!` word at the first space or tab. Returns (word, rest)."""
    for i in range(len(s)):
        if s[i] in [" ", "\t"]:
            return s[:i], s[i + 1:].lstrip(" \t")
    return s, ""

def record_prefix_problems(bad, state, line):
    """Records a rejected anchor or tag prefix naming the line, as pub rejects it.

    Args:
      bad: the first rejected prefix shape, or "".
      state: the parse state collecting problems.
      line: the 1-based line number naming failures.
    """
    if bad == "empty-anchor":
        state.problems.append("empty anchor at line %d is not supported" % line)
    elif bad == "repeat-anchor":
        state.problems.append("repeated anchor at line %d is not supported" % line)
    elif bad == "repeat-tag":
        state.problems.append("repeated tag at line %d is not supported" % line)

def has_explicit_key_affix(text):
    """Returns whether `text` contains an explicit-key indicator after an anchor or tag.

    Args:
      text: the line text to test.

    Returns:
      True when an explicit-key indicator follows an anchor or tag.
    """
    if not (text.startswith("&") or text.startswith("!")):
        return False
    anchor, tag, rest, _bad = strip_value_prefix(text)
    return (anchor != None or tag != None) and is_question_entry(rest)

def block_value_entry_problem(rest, state, line):
    """Records a block entry where a same-line mapping value starts. Returns True when one fails.

    A `- ` entry fails, as pub rejects a block sequence where a value
    starts, and a `? ` marker fails, as pub rejects an explicit key there;
    the anchor and tag prefixes are already stripped, as pub still rejects
    the entry under them. A `: `, `:\\t` or trailing colon inside a plain
    value fails, as pub rejects a mapping value inside a plain scalar, even
    past mid-scalar quotes or brackets; quoted, flow, block-scalar and alias
    values read as before, as pub reads them.

    Args:
      rest: the remaining value text after prefixes.
      state: the parse state collecting problems.
      line: the 1-based line number naming failures.

    Returns:
      True when an invalid block entry was found and recorded.
    """
    if is_dash(rest):
        state.problems.append("block sequence entry at line %d is not supported" % line)
        return True
    if is_question_entry(rest):
        state.problems.append("explicit key at line %d is not supported" % line)
        return True
    if rest[:1] in ["", "\"", "'", "[", "{", "|", ">", "*"]:
        return False
    if ": " in rest or ":\t" in rest or ":\r" in rest or rest.endswith(":") or rest.endswith(":\r"):
        state.problems.append("mapping value at line %d is not supported" % line)
        return True
    return False
