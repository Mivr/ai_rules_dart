"""Scalars, typing and tags for the pubspec YAML reader.

Holds plain, quoted and typed scalars: value prefixes, aliases, numbers,
the tag table and tag application. Loaded by the flow, block and document
modules.
"""

load(":yaml_chars.bzl", "BOM")
load(":yaml_escape.bzl", "HEX_DIGITS", "unescape_double")
load(":yaml_printable.bzl", _check_scalar_unprintable = "check_scalar_unprintable", _record_prefix_problems = "record_prefix_problems", _strip_value_prefix = "strip_value_prefix")
load(":yaml_text.bzl", "clone", "is_dash", "is_flow_value_entry", "is_quoted", "quoted_end_at")

check_scalar_unprintable = _check_scalar_unprintable
record_prefix_problems = _record_prefix_problems
strip_value_prefix = _strip_value_prefix

_YAML_TAG_PREFIX = "tag:yaml.org,2002:"

# An anchor name whose collection is still open: an alias to it fails
# closed instead of reading a partial value, as pub rejects self-reference.
OPEN_ANCHOR = struct(open = True)

def parse_nonflow(s, anchors, state, line):
    """Parses an alias, a quoted scalar or a plain scalar.

    A byte-order mark in a plain scalar is a problem naming the line, as pub
    rejects it; quoted scalars keep it as content, as pub reads them. A plain
    scalar starting with `@` or a backtick is a problem naming the line, as
    pub rejects its reserved indicator, and so is one holding a control
    character (including raw C1 controls except U+0085), U+FFFE, U+FFFF or an
    encoded surrogate anywhere, as pub refuses them; quoted scalars keep them
    as content, as pub reads them. A tab inside a plain scalar stays content,
    as pub reads it. Text glued after a quoted scalar's closing quote is a
    problem naming the line, as pub rejects it: nothing but the closing
    quote itself may end the scalar, since a comment never reaches here, as
    block lines strip it first.

    Args:
      s: the scalar text.
      anchors: the anchor names bound so far.
      state: the parse state collecting problems.
      line: the 1-based line number naming failures.

    Returns:
      The parsed value.
    """
    if s.startswith("*"):
        return parse_alias(s, anchors, state, line)
    if s[:1] in ["'", '"']:
        end = flow_quoted_end(s)
        if end >= 0 and s[end + 1:].strip() != "":
            state.problems.append("trailing text after quoted scalar at line %d is not supported" % line)
            return None
        if is_quoted(s):
            if s[0] == '"':
                return unescape_double(s[1:-1], state, line)
            return s[1:-1].replace("''", "'")
    if BOM in s:
        state.problems.append("byte-order mark at line %d is not supported" % line)
        return None
    if s[:1] in ["@", "`"]:
        state.problems.append("reserved indicator at line %d is not supported" % line)
        return None
    if check_scalar_unprintable(s, state, line):
        return None

    if s == "":
        # A consumed anchor or tag prefix with no value reads as the empty
        # text, as read before; a bare "" never reaches here, as
        # `parse_scalar` reads it as None first.
        return ""
    if s in ["null", "Null", "NULL", "~"]:
        return None
    if s in ["true", "True", "TRUE"]:
        return True
    if s in ["false", "False", "FALSE"]:
        return False
    return _parse_plain_number(s)

def parse_alias(s, anchors, state, line):
    """Parses an alias at the start of `s`, or returns None with a problem.

    Text after the alias name is a problem naming the line, as pub rejects
    it; a comment never reaches here, as block lines strip it first.

    Args:
      s: the text starting with the alias.
      anchors: the anchor names bound so far.
      state: the parse state collecting problems.
      line: the 1-based line number naming failures.

    Returns:
      The aliased value, or None with a problem.
    """
    end = alias_name_end(s)
    ok, value = resolve_alias(s[1:end], anchors, state, line)
    if not ok:
        return None
    if s[end:].strip() != "":
        state.problems.append("trailing text after alias at line %d is not supported" % line)
        return None
    return value

def resolve_alias(name, anchors, state, line):
    """Resolves an alias `name`. Returns (ok, value).

    An empty, undefined or self-referential alias is an always-on problem
    naming the line, as pub rejects it; a use after its collection closes
    reads the value cloned shallowly, as yaml.bzl copies it.

    Args:
      name: the alias name.
      anchors: the anchor names bound so far.
      state: the parse state collecting problems.
      line: the 1-based line number naming failures.

    Returns:
      The (ok, value) pair.
    """
    if name == "":
        state.problems.append("empty alias at line %d is not supported" % line)
        return (False, None)
    if name not in anchors:
        state.problems.append("undefined alias %r at line %d" % (name, line))
        return (False, None)
    value = anchors[name]
    if value == OPEN_ANCHOR:
        state.problems.append("self-referential alias %r at line %d is not supported" % (name, line))
        return (False, None)
    return (True, clone(value))

def alias_name_end(s):
    """Returns the end index of the alias name in `s`, which starts with `*`.

    The name runs to whitespace or `,[]{}`, as pub scans it, so a glued
    colon or hash is part of the name.

    Args:
      s: the text starting with `*`.

    Returns:
      The end index of the alias name.
    """
    i = 1
    for _ in range(len(s) + 1):
        if i >= len(s) or s[i] in [" ", "\t", "\r", "\n", ",", "[", "]", "{", "}"]:
            break
        i += 1
    return i

def split_value_text(value_text, anchors, state, line):
    """Splits a same-line value into (anchor, tag, rest, failed).

    Shape problems are recorded naming the line, as pub rejects them: an
    alias after an anchor or tag reads `None`, and the anchor binds `None`
    too, so parsing continues past it. Otherwise `rest` is the value after
    the prefix, "" when the value is on the following lines.

    Args:
      value_text: the same-line value text.
      anchors: the anchor names bound so far.
      state: the parse state collecting problems.
      line: the 1-based line number naming failures.

    Returns:
      The (anchor, tag, rest, failed) tuple.
    """
    anchor, tag, rest, bad = strip_value_prefix(value_text)
    record_prefix_problems(bad, state, line)
    if anchor != None and rest.startswith("*"):
        state.problems.append("alias after anchor at line %d is not supported" % line)
        anchors[anchor] = None
        return None, None, "", True
    if tag != None and rest.startswith("*"):
        state.problems.append("alias after tag at line %d is not supported" % line)
        return None, None, "", True
    if rest == ":" or (rest.startswith(":") and len(rest) > 1 and rest[1] in [" ", "\t", "\r"]):
        # A mapping value indicator where a value starts is rejected, as pub
        # rejects it; a colon glued to content stays a plain scalar.
        state.problems.append("mapping value at line %d is not supported" % line)
        return None, None, "", True
    return anchor, tag, rest, False

def _parse_plain_dotted(s):
    """Parses a dot-led plain scalar as a double or inf/nan, or returns `s`.

    A dot glued to a digit, or a sign glued to a dot, reads the exact `.inf`
    and `.nan` casings then double; anything else stays a string, as pub
    reads it.

    Args:
      s: the plain scalar text starting with a dot or a sign glued to a dot.

    Returns:
      The double or inf/nan, or `s` unchanged.
    """
    first = s[0]
    if (first == "." and s[1].isdigit()) or (first in ["-", "+"] and s[1] == "."):
        if len(s) == 5 and s in ["+.inf", "+.Inf", "+.INF", "-.inf", "-.Inf", "-.INF"]:
            return float("-inf") if first == "-" else float("inf")
        return _parse_double_or_text(s)
    if len(s) == 4 and first == ".":
        if s in [".inf", ".Inf", ".INF"]:
            return float("inf")
        if s in [".nan", ".NaN", ".NAN"]:
            return float("nan")
    return s

def _parse_plain_based(s, second):
    """Parses a `0`-led plain scalar with a based prefix. Returns (routed, value).

    A lowercase `0x` or `0o` prefix reads as hex or octal, else the scalar
    stays a string; any other second character is not routed, as pub reads
    them. A `_` separator never reads, as neither Dart conversion accepts
    it.
    """
    if second == "x":
        parsed = _parse_based_int(s, 16)
        return True, (parsed if parsed != None else s)
    if second == "o":
        parsed = _parse_based_int(s, 8)
        return True, (parsed if parsed != None else s)
    return False, s

def _parse_plain_number(s):
    """Parses an untagged plain scalar as an int or a double, or returns `s`.

    Mirrors package:yaml number parsing (loader.dart `_parseNumberValue`
    reading both): a lone digit reads as an int; a `0`-led scalar reads
    through its own based step; a digit start, or a sign glued to a digit,
    reads through int then double; a dot glued to a digit, or a sign glued
    to a dot, reads through its own step; anything else stays a string. A
    `_` separator never reads, as neither Dart conversion accepts it.

    Args:
      s: the plain scalar text, never "".

    Returns:
      The int, the double, or `s` unchanged.
    """
    if len(s) == 1:
        return int(s) if s.isdigit() else s
    first = s[0]
    second = s[1]
    if first == "0":
        routed, value = _parse_plain_based(s, second)
        if routed:
            return value
    if first.isdigit() or (first in ["-", "+"] and second.isdigit()):
        if _is_int_digits(s):
            parsed = _capped_decimal_int(s)
            if parsed != None:
                return parsed
        return _parse_double_or_text(s)
    if first == "." or (first in ["-", "+"] and second == "."):
        return _parse_plain_dotted(s)
    return s

def _parse_double_or_text(s):
    """The double named by float-shaped `s`, or `s` unchanged.

    Mirrors the double.tryParse fallback in package:yaml number parsing: an
    optional sign, a mantissa of digits with at most one point, and an
    optional exponent with an optional sign and digits. Either side of the
    point may be empty, as pub reads `1.` and `.5`; anything else stays a
    string, as pub reads it.

    Args:
      s: the scalar text starting with a digit, a sign glued to a digit, a
        dot glued to a digit or a sign glued to a dot.

    Returns:
      The double, or `s` unchanged.
    """
    sign = s[:1] if s[:1] in ["-", "+"] else ""
    text = s[1:] if sign != "" else s
    mantissa = text
    exponent = ""
    e = text.lower().find("e")
    if e >= 0:
        mantissa = text[:e]
        exponent = text[e + 1:]
        digits = exponent[1:] if exponent[:1] in ["-", "+"] else exponent
        if digits == "" or not digits.isdigit():
            return s
        exponent = "e" + exponent
    if mantissa == "":
        return s
    if mantissa.count(".") == 1:
        whole, frac = mantissa.split(".")
        if whole != "" and not whole.isdigit():
            return s
        if frac != "" and not frac.isdigit():
            return s
        if whole == "" and frac == "":
            return s
        if whole == "" or frac == "":
            return _safe_float(_canonical_dotted_float(sign + whole, frac) + exponent)
    elif not mantissa.isdigit():
        return s
    return _safe_float(s)

def _parse_int_text(text):
    """The integer named by a `!!int` value, or None.

    Mirrors package:yaml number parsing with floats disallowed: trailing
    padding reads through int.tryParse while a leading space never reaches
    it, as pub reads them. Only a lowercase `0x` or `0o` prefix reads as hex
    or octal, a `_` separator never reads, and a decimal past the int64 range
    fails, as pub reads them.
    """
    s = _rstrip_scalar_ws(text)
    if s == "":
        return None
    if len(s) == 1:
        return int(s) if s.isdigit() else None
    if s[0] == "0" and s[1] == "x":
        return _parse_based_int(s, 16)
    if s[0] == "0" and s[1] == "o":
        return _parse_based_int(s, 8)
    if s[0].isdigit() or (s[0] in ["-", "+"] and s[1].isdigit()):
        if _is_int_digits(s):
            return _capped_decimal_int(s)
        return None
    return None

def _parse_based_int(text, base):
    """Parses `0x` (base 16) or `0o` (base 8) digits, or returns None.

    Only a lowercase prefix routes here and digits may be either case, as pub
    reads them (int.tryParse); a `_` separator is not a digit, as pub reads
    it. A hex value wraps modulo 2^64 into the signed range and past
    2^64-1 fails, while an octal past 2^63-1 fails, as pub reads them. An
    octal sign reads, as the radix-8 conversion takes it, but the magnitude
    still caps at 2^63-1, as pub reads it; a hex sign never routes here,
    as pub reads it.
    """
    s = text.lower()[2:]
    neg = False
    if base == 8 and s[:1] in ["-", "+"]:
        neg = s[:1] == "-"
        s = s[1:]
    if s == "":
        return None
    total = 0
    for ch in s.elems():
        pos = HEX_DIGITS.find(ch)
        if pos < 0 or pos >= base:
            return None
        total = total * base + pos
        if total > _UINT64_MAX or (base == 8 and total > _INT64_MAX):
            return None
    if base == 16 and total >= _INT64_SPAN:
        total -= _UINT64_SPAN
    return -total if neg else total

def _capped_decimal_int(s):
    """The decimal int named by int-shaped `s`, or None past the int64 range.

    The magnitude is compared as text so no unbounded conversion reads a
    value pub refuses, as pub reads it (int.tryParse).
    """
    neg = s[:1] == "-"
    digits = s[1:] if s[:1] in ["-", "+"] else s
    digits = digits.lstrip("0")
    if digits == "":
        return 0
    if len(digits) > 19:
        return None
    if len(digits) == 19:
        limit = _INT64_MIN_TEXT if neg else _INT64_MAX_TEXT
        if digits > limit:
            return None
    return int(s)

def _canonical_dotted_float(whole, frac):
    """Rewrites a dotted mantissa with digits on one side into `d.d` shape."""
    body = whole[1:] if whole[:1] in ["-", "+"] else whole
    if body == "":
        body = "0"
    if frac == "":
        frac = "0"
    if whole[:1] == "-":
        return "-" + body + "." + frac
    return body + "." + frac

def _is_dotted_mantissa(whole, frac):
    """True for a dotted mantissa with digits on at least one side of the point.

    Either side may be empty and the whole side may be a bare sign, as pub
    reads `1.`, `.5` and `+.5` through double.tryParse; both sides empty is
    not a number, as pub reads it.
    """
    body = whole[1:] if whole[:1] in ["-", "+"] else whole
    if body != "" and not body.isdigit():
        return False
    if frac != "" and not frac.isdigit():
        return False
    return body != "" or frac != ""

def _rstrip_scalar_ws(text):
    """Removes trailing spaces, tabs and line breaks from a scalar text.

    `double.tryParse` and `int.tryParse` tolerate that padding, so a tagged
    scalar with trailing padding converts as pub converts it; a leading space
    never reaches either, as pub rejects it before parsing.
    """
    end = len(text)
    for _ in range(len(text)):
        if end <= 0 or text[end - 1] not in [" ", "\t", "\n", "\r"]:
            break
        end -= 1
    return text[:end]

def _is_int_digits(text):
    """True for `123`, `+123` and `-123`."""
    return text.isdigit() or (len(text) > 1 and text[0] in ["-", "+"] and text[1:].isdigit())

# The int64 and uint64 bounds bounding number parsing, as pub parses into
# 64-bit integers (package:yaml 3.1.4 with the pinned SDK 3.13.5).
_INT64_MAX_TEXT = "9223372036854775807"
_INT64_MIN_TEXT = "9223372036854775808"
_INT64_MAX = 9223372036854775807
_UINT64_MAX = 18446744073709551615
_INT64_SPAN = 9223372036854775808
_UINT64_SPAN = 18446744073709551616

def _parse_scientific_float(text):
    """Parses `1e3`, `1.5E-3`, `1.e5` and `.5e5`, or returns None.

    The mantissa is an int shape or a dotted shape with digits on at least
    one side of the point, as pub reads it (double.tryParse); a `_`
    separator is not a digit, as pub reads it.
    """
    s = text.lower()
    e = s.find("e")
    if e < 0:
        return None
    left = s[:e]
    right = s[e + 1:]
    if right == "":
        return None
    if right[0] in ["+", "-"]:
        if len(right) == 1 or not right[1:].isdigit():
            return None
    elif not right.isdigit():
        return None
    if _is_int_digits(left):
        return _safe_float(text[1:] if text[:1] == "+" else text)
    if left.count(".") == 1:
        whole, frac = left.split(".")
        if _is_dotted_mantissa(whole, frac):
            return _safe_float(text[1:] if text[:1] == "+" else text)
    return None

def _parse_double_text(s):
    """The float named by stripped float-shaped `s`, or None.

    An int shape, a scientific shape and a dotted shape with digits on at
    least one side of the point read, as pub reads them (double.tryParse).
    """
    if _is_int_digits(s):
        return _safe_float(s[1:] if s[:1] == "+" else s)
    scientific = _parse_scientific_float(s)
    if scientific != None:
        return scientific
    if s.count(".") == 1:
        whole, frac = s.split(".")
        if _is_dotted_mantissa(whole, frac):
            return _safe_float(_canonical_dotted_float(whole, frac))
    return None

def _parse_float_text(text):
    """The float named by a `!!float` value, or None.

    Mirrors package:yaml number parsing with integers disallowed: a lone
    character fails as pub crashes on it, an int-shaped or padded scalar
    reads through double.tryParse, and only the exact `.inf` and `.nan`
    casings read, as pub reads them.
    """
    if len(text) < 2:
        return None
    first = text[0]
    second = text[1]
    if first.isdigit() or (first in ["-", "+"] and second.isdigit()):
        return _parse_double_text(_rstrip_scalar_ws(text))
    if (first == "." and second.isdigit()) or (first in ["-", "+"] and second == "."):
        if len(text) == 5:
            if text in ["+.inf", "+.Inf", "+.INF"]:
                return float("inf")
            if text in ["-.inf", "-.Inf", "-.INF"]:
                return float("-inf")
        return _parse_double_text(_rstrip_scalar_ws(text))
    if len(text) == 4 and first == ".":
        if text in [".inf", ".Inf", ".INF"]:
            return float("inf")
        if text in [".nan", ".NaN", ".NAN"]:
            return float("nan")
    return None

def _float_parts(text):
    """Splits a validated float text into (negative, adjusted, digits).

    `text` has a validated shape: an optional sign, digits with at most one
    point, and an optional `e` exponent with an optional sign and digits.
    `adjusted` is the base-10 exponent of the first significant digit and
    `digits` are the significant digits without the point, "" for a zero
    mantissa.
    """
    s = text
    neg = False
    if s[:1] in ["-", "+"]:
        neg = s[:1] == "-"
        s = s[1:]
    exp = 0
    e = s.lower().find("e")
    if e >= 0:
        exp = int(s[e + 1:])
        s = s[:e]
    dot = s.find(".")
    if dot < 0:
        intpart, frac = s, ""
    else:
        intpart, frac = s[:dot], s[dot + 1:]
    intpart = intpart.lstrip("0")
    if intpart != "":
        return (neg, exp + len(intpart) - 1, intpart + frac)
    rest = frac.lstrip("0")
    if rest == "":
        return (neg, 0, "")
    return (neg, exp - (len(frac) - len(rest)) - 1, rest)

def _float_over_max(digits):
    """Returns whether significant `digits` past 1e308 exceed the double range.

    Called only for an adjusted exponent of 308, so the value sits in
    [1e308, 1e309): it overflows past the leading digits of DBL_MAX
    (1.7976931348623157e308), or past equal leading digits with any nonzero
    digit after them.
    """
    head = (digits + "00000000000000000")[:17]
    if head != "17976931348623157":
        return head > "17976931348623157"
    for ch in digits[17:].elems():
        if ch != "0":
            return True
    return False

def _safe_float(text):
    """Converts a validated float text, overflowing to infinity as pub reads it.

    Starlark `float()` fails on magnitudes past the double range, while pub
    reads them as infinity, so the magnitude is compared first and only a
    finite value reaches `float()`: the returned double is exactly the one a
    direct conversion gives. Underflow reaches `float()`, which rounds to zero.
    """
    neg, adjusted, digits = _float_parts(text)
    if digits == "":
        return -0.0 if neg else 0.0
    if adjusted > 308 or (adjusted == 308 and _float_over_max(digits)):
        return float("-inf") if neg else float("inf")
    return float(text)

# ---------------------------------------------------------------------------
# Double-quoted escapes
# ---------------------------------------------------------------------------

def undefined_tag_problem(word, line):
    """The problem for a `!!` tag with no node to convert, as pub reports it.

    The display is the full tag URI, as pub names it; a verbatim tag shows
    its inner text.

    Args:
      word: the tag word.
      line: the 1-based line number naming failures.

    Returns:
      The problem text.
    """
    if word.startswith("!<") and word.endswith(">"):
        display = word[2:-1]
    elif word.startswith("!!"):
        display = _YAML_TAG_PREFIX + word[2:]
    else:
        display = word
    return "Undefined tag: %s at line %d" % (display, line)

def apply_child_collection_tag(word, value, state, line):
    """Applies a pending or flow-close tag to a collection child. Returns the value.

    A `!!seq` or `!!map` tag reads a matching collection as the same-line
    tags do; any other `!!` tag on a collection is a problem
    naming the tag's line, as pub rejects it, and a named handle or
    verbatim tag is an undefined-handle problem, while a local tag rides
    through as the same-line tags do. A problem still reads the child
    untagged, so parsing continues past it.

    Args:
      word: the tag word, or None.
      value: the collection child.
      state: the parse state collecting problems.
      line: the 1-based line number naming failures.

    Returns:
      The value.
    """
    if word == None:
        return value
    word = resolve_handle(word, state, line)
    if word == None:
        return value
    if is_unknown_tag_handle(word):
        state.problems.append("Undefined tag handle at line %d" % line)
        return value
    if word.startswith("!!") or word.startswith("!<"):
        name = tag_name(word)
        if (name == "seq" and type(value) == "list") or (name == "map" and type(value) == "dict"):
            return value
        kind = "sequence" if type(value) == "list" else "mapping"
        state.problems.append("Invalid tag for %s at line %d" % (kind, line))
        return value
    return value

def drop_tag_value(word, line, state):
    """Reads a tag closed with no node. Returns the value.

    A dropped `!!str` or local tag reads an empty scalar, as pub reads it,
    and a dropped `!!null` reads null; a dropped `!!bool` is an invalid bool
    problem, a dropped `!!int` or `!!float` is a problem naming the line, as
    pub crashes on it, a dropped named handle or verbatim tag is an
    undefined-handle problem, and any other dropped `!!` tag is an undefined
    tag problem, as pub reports them.

    Args:
      word: the tag word, or None.
      line: the 1-based line number naming failures.
      state: the parse state collecting problems.

    Returns:
      The value.
    """
    if word == None:
        return None
    word = resolve_handle(word, state, line)
    if word == None:
        return None
    if is_unknown_tag_handle(word):
        state.problems.append("Undefined tag handle at line %d" % line)
        return None
    name = tag_name(word)
    if name == "str" or (word.startswith("!") and not word.startswith("!!") and not word.startswith("!<")):
        return ""
    if name == "null":
        return None
    if name == "bool":
        state.problems.append("Invalid bool scalar at line %d" % line)
        return None
    if name in ["int", "float"]:
        state.problems.append("tag %s with no value at line %d is not supported" % (word, line))
        return None
    state.problems.append(undefined_tag_problem(word, line))
    return None

def apply_key_tag(word, key, raw, state, line):
    """Applies a flow key tag. Returns the key.

    A named handle or verbatim tag is an undefined-handle problem, and a
    `!!` tag with no scalar to convert is an undefined tag problem, naming
    the tag's line, as pub reports them; any other `!!` tag converts the key
    as the same-line tags do, and a local tag reads a string key as is and
    any other key as its raw text, as pub reads them. A problem still reads
    the key untagged, so parsing continues past it.

    Args:
      word: the tag word.
      key: the parsed key.
      raw: the raw key text.
      state: the parse state collecting problems.
      line: the 1-based line number naming failures.

    Returns:
      The key.
    """
    word = resolve_handle(word, state, line)
    if word == None:
        return key
    if is_unknown_tag_handle(word):
        state.problems.append("Undefined tag handle at line %d" % line)
        return key
    if word.startswith("!!"):
        name = tag_name(word)
        if name not in ["str", "int", "float", "bool", "null", "seq", "map"]:
            state.problems.append(undefined_tag_problem(word, line))
            return key
        if name in ["seq", "map"]:
            return key
        return apply_tag(word, raw, key, state, line)
    if type(key) == "string":
        return apply_tag(word, raw, key, state, line)
    return raw

def _apply_int_tag(value, raw, state, line):
    """Applies a `!!int` tag. Returns the value, or None with a problem naming the line.

    Pub parses the scalar text rather than the resolved value, so an int
    node converts through its raw text: `!!int 12` reads 12 while `!!int
    1_000`, `!!int 0x10` with a separator, or `!!int 0X1F` fail, as pub reads
    them. A quoted scalar converts through its content, as pub reads it;
    anything else is an invalid int scalar problem naming the line, as pub
    rejects it.
    """
    text = None
    if type(value) == "string":
        text = value
    elif type(value) == "int" and type(raw) == "string":
        text = raw
    if text != None:
        parsed = _parse_int_text(text)
        if parsed != None:
            return parsed
        state.problems.append("Invalid int scalar at line %d" % line)
        return None
    if type(value) == "int":
        return value
    state.problems.append("Invalid int scalar at line %d" % line)
    return None

def _apply_float_tag(value, raw, state, line):
    """Applies a `!!float` tag. Returns the value, or None with a problem naming the line.

    A float reads as is; pub parses any other scalar's text rather than its
    resolved value, so an int node converts through its raw text: `!!float
    12` reads 12.0 while `!!float 0x10` or `!!float 1_000` fail, as pub reads
    them. A quoted scalar converts through its content, as pub reads it;
    anything else is an invalid float scalar problem naming the line, as pub
    rejects it (package:yaml crashes on it).
    """
    if type(value) == "float":
        return value
    text = None
    if type(value) == "string":
        text = value
    elif type(value) == "int" and type(raw) == "string":
        text = raw
    if text != None:
        parsed = _parse_float_text(text)
        if parsed != None:
            return parsed
    state.problems.append("Invalid float scalar at line %d" % line)
    return None

def apply_bool_tag(value, raw, state, line):
    """Applies a `!!bool` tag. Returns the value, or None with a problem naming the line.

    Only `true`, `True`, `TRUE`, `false`, `False` and `FALSE` convert, as
    pub reads them; anything else is an invalid bool scalar problem naming
    the line, as pub rejects it. A resolved bool reads through its raw
    spelling, so a wider untagged spelling still fails here as pub fails it.

    Args:
      value: the parsed value.
      raw: the raw scalar text.
      state: the parse state collecting problems.
      line: the 1-based line number naming failures.

    Returns:
      The value, or None with a problem.
    """
    if type(value) == "string":
        text = value
    elif type(value) == "bool" and type(raw) == "string":
        text = raw.strip()
    else:
        text = ""
    if text in ["true", "True", "TRUE", "false", "False", "FALSE"]:
        return text.lower() == "true"
    state.problems.append("Invalid bool scalar at line %d" % line)
    return None

def resolve_handle(word, state, line):
    """Resolves a tag word through `%TAG` handle prefixes. Returns the word.

    A `!!` or `!name!` handle the directives remapped resolves to its prefix
    plus the suffix: when that is a standard `tag:yaml.org,2002:` scalar or
    collection tag the word becomes its `!!` form and parsing continues, as
    pub reads it, while any other resolved tag is an undefined-tag problem
    naming the use line, as pub rejects it. A `%TAG` remap of the `!` handle
    changes no use: a local or non-specific tag still reads as without it,
    as pub reads them. A problem returns None.

    Args:
      word: the tag word.
      state: the parse state collecting problems.
      line: the 1-based line number naming failures.

    Returns:
      The resolved word, or None with a problem.
    """
    if word == None or state.tag_prefixes == {}:
        return word
    if not word.startswith("!") or word.startswith("!<"):
        return word
    handle = "!"
    suffix = word[1:]
    if word.startswith("!!"):
        handle = "!!"
        suffix = word[2:]
    else:
        for i in range(1, len(word)):
            if word[i] == "!":
                handle = word[:i + 1]
                suffix = word[i + 1:]
                break
    if handle == "!" or handle not in state.tag_prefixes:
        return word
    resolved = state.tag_prefixes[handle] + suffix
    if resolved.startswith(_YAML_TAG_PREFIX):
        short = resolved[len(_YAML_TAG_PREFIX):]
        if short in ["str", "int", "float", "bool", "null", "seq", "map"]:
            return "!!" + short
    state.problems.append("Undefined tag: %s at line %d" % (resolved, line))
    return None

def is_unknown_tag_handle(tag):
    """Whether `tag` is a named handle or a verbatim tag.

    A `!` alone is the non-specific tag and `!!x` the default handle, which
    resolve below. A verbatim tag never resolves, as pub rejects it with an
    undefined tag handle, and any other `!` word with a second `!` is a
    named handle pub rejects the same way; any other `!` word is a local
    tag, which reads below.

    Args:
      tag: the tag word.

    Returns:
      Whether the tag is a named handle or a verbatim tag.
    """
    if tag == "!" or tag.startswith("!!"):
        return False
    if tag.startswith("!<"):
        return True
    return tag.startswith("!") and "!" in tag[1:]

def _apply_collection_tag(name, tag, value, state, line):
    """Tells whether a `!!seq` or `!!map` tag is decided. Returns True when done.

    A matching collection reads, and any other non-collection node fails as
    an undefined tag, as pub reports them. A non-matching collection is left
    for the invalid-tag failure below. A problem still reads the value
    untagged.
    """
    want = "list" if name == "seq" else "dict"
    if type(value) == want:
        return True
    if type(value) != "list" and type(value) != "dict":
        state.problems.append(undefined_tag_problem(tag, line))
        return True
    return False

def _apply_scalar_tag(name, tag, raw, value, state, line):
    """Applies a scalar type tag. Returns the value.

    Conversions fail naming the line where the value does not resolve, as
    pub rejects them; an unknown name is an undefined tag. A problem still
    reads the value untagged, so parsing continues past it.
    """
    if name == "str":
        return value if type(value) == "string" else raw
    if name == "int":
        return _apply_int_tag(value, raw, state, line)
    if name == "float":
        return _apply_float_tag(value, raw, state, line)
    if name == "bool":
        return apply_bool_tag(value, raw, state, line)
    if name == "null":
        if value == None or value == "":
            return None
        state.problems.append("Invalid null scalar at line %d" % line)
        return None
    state.problems.append(undefined_tag_problem(tag, line))
    return value

def apply_tag(tag, raw, value, state, line):
    """Applies a tag to a parsed value. Returns the value.

    A named handle or verbatim tag is an undefined handle problem naming
    the line, as pub rejects it. A local or non-specific (`!`) tag reads a
    scalar as its string and a collection as is, as pub reads them. A
    `!!seq` or `!!map` tag reads a matching collection, fails another
    collection as an invalid tag for its kind, and fails any other node as
    an undefined tag; a scalar type tag fails a collection as an invalid tag
    for its kind, as pub reports them. A problem still reads the value
    untagged, so parsing continues past it. Scalar conversions fail naming
    the line where the value does not resolve, as pub rejects them.

    Args:
      tag: the tag word.
      raw: the raw scalar text.
      value: the parsed value.
      state: the parse state collecting problems.
      line: the 1-based line number naming failures.

    Returns:
      The value.
    """
    tag = resolve_handle(tag, state, line)
    if tag == None:
        return value
    if is_unknown_tag_handle(tag):
        state.problems.append("Undefined tag handle at line %d" % line)
        return value
    if not tag.startswith("!!"):
        if type(value) == "list" or type(value) == "dict":
            return value
        return value if type(value) == "string" else raw
    name = tag_name(tag)
    if name == None:
        return value
    if name == "seq" or name == "map":
        if _apply_collection_tag(name, tag, value, state, line):
            return value
    if type(value) == "list" or type(value) == "dict":
        kind = "sequence" if type(value) == "list" else "mapping"
        state.problems.append("Invalid tag for %s at line %d" % (kind, line))
        return value
    return _apply_scalar_tag(name, tag, raw, value, state, line)

def tag_name(tag):
    """The short name of a tag written as `!!x`, `!x` or `!<tag:yaml.org,2002:x>`.

    Args:
      tag: the tag word.

    Returns:
      The short tag name, or None.
    """
    if tag.startswith("!<") and tag.endswith(">"):
        uri = tag[2:-1]
        return uri[len(_YAML_TAG_PREFIX):] if uri.startswith(_YAML_TAG_PREFIX) else None
    if tag.startswith("!!"):
        return tag[2:]
    if tag.startswith("!") and len(tag) > 1 and tag.count("!") == 1:
        return tag[1:]
    return None

def flow_quoted_end(s):
    """Returns the index of the quote closing the scalar at `s[0]`, or -1.

    `s` starts with `'` or `"`. `''` inside single quotes is one escaped
    quote and a backslash escapes the next character in double quotes, as
    pub reads them. Returns -1 when the quote never closes.
    """
    return quoted_end_at(s, s[0], 1)

def is_flow_key_entry(token, raw, next_ch):
    """Returns whether a flow map key token is a block entry, as pub rejects it.

    A `- ` entry fails unless a bare dash pairs at once with its colon, as
    pub reads `{-: 1}` but rejects `{ - : 1}`; an anchored or tagged dash
    fails even so, as pub rejects `{&x - : 1}`. An explicit `?` key holding
    an entry fails too, while a plain `?` key reads, as pub reads it.

    Args:
      token: the scanned flow map key token.
      raw: the raw source span of the token.
      next_ch: the character following the token.

    Returns:
      Whether the token is a block entry.
    """
    _anchor, _tag, rest, _bad = strip_value_prefix(token)
    if is_dash(rest):
        return rest != "-" or _anchor != None or _tag != None or raw != "-" or next_ch != ":"
    for prefix in ["? ", "?\t"]:
        if rest.startswith(prefix) and is_flow_value_entry(rest[2:]):
            return True
    return False

def flow_value_entry_problem(value_text, state, line):
    """Records a block entry where a flow pair value starts. Returns True when one fails.

    The anchor and tag prefixes are stripped first, as pub still rejects
    the entry under them.

    Args:
      value_text: the flow pair value text.
      state: the parse state collecting problems.
      line: the 1-based line number naming failures.

    Returns:
      True when one fails.
    """
    _anchor, _tag, rest, _bad = strip_value_prefix(value_text)
    if is_flow_value_entry(rest):
        state.problems.append("block entry inside flow at line %d is not supported" % line)
        return True
    return False
