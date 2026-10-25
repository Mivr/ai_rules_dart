"""Double-quoted escape decoding for the pubspec YAML reader.

Holds yaml.bzl's escape table and the `\\N`/`\\_`/`\\L`/`\\P`, hex and
surrogate decoding. A leaf module: it loads nothing. Loaded by the scalar
module.
"""

# Escapes allowed in double-quoted scalars, as yaml.bzl maps them: the
# single-character escapes, backslash with a space or tab (which pub reads
# as the space or tab), and the YAML line/paragraph escapes N, _, L and P.
# Any other escape, a short or non-hex hex escape, a surrogate, or a code
# point past U+10FFFF is a problem naming the line, as pub rejects it.
_ESCAPES = {
    "0": "\0",
    "a": "\a",
    "b": "\b",
    "t": "\t",
    "n": "\n",
    "v": "\v",
    "f": "\f",
    "r": "\r",
    " ": " ",
    "\t": "\t",
    '"': '"',
    "/": "/",
    "\\": "\\",
    "N": json.decode('"\\u0085"'),
    "_": json.decode('"\\u00a0"'),
    "L": json.decode('"\\u2028"'),
    "P": json.decode('"\\u2029"'),
}

HEX_DIGITS = "0123456789abcdef"

def _unescape_code_point(text, i, nxt, state, line):
    """Decodes a `\\x`, `\\u` or `\\U` escape at `i`. Returns (decoded, next index, ok).

    Fewer digits than the width needs, a non-hex digit, a surrogate, and a
    code point past U+10FFFF are problems naming the line, as pub rejects
    them; pub rejects even a well-formed surrogate pair.
    """
    width = 2 if nxt == "x" else (4 if nxt == "u" else 8)
    if i + 2 + width > len(text):
        state.problems.append("short %s escape at line %d is not supported" % (nxt, line))
        return "", len(text), False
    digits = text[i + 2:i + 2 + width]
    code_point = _parse_hex(digits)
    if code_point == None:
        state.problems.append("bad %s escape at line %d is not supported" % (nxt, line))
        return "", i + 2 + width, False
    if code_point > 0x10ffff or (code_point >= 0xd800 and code_point <= 0xdfff):
        state.problems.append("bad %s escape at line %d is not supported" % (nxt, line))
        return "", i + 2 + width, False
    return _code_point_text(code_point), i + 2 + width, True

def unescape_double(text, state, line):
    """Decodes the escapes in the body of a double-quoted scalar.

    Returns the decoded text, or None with a problem naming the line: an
    unknown escape and a malformed hex, Unicode or surrogate escape are
    rejected, as pub rejects them.


    Args:
      text: the scalar body between the quotes.
      state: the parse state collecting problems.
      line: the 1-based line number naming failures.

    Returns:
      The decoded text, or None when an escape is rejected.
    """
    out = []
    i = 0
    for _ in range(len(text) + 1):
        if i >= len(text):
            break
        ch = text[i]
        if ch != "\\" or i + 1 >= len(text):
            out.append(ch)
            i += 1
            continue
        nxt = text[i + 1]
        if nxt in _ESCAPES:
            out.append(_ESCAPES[nxt])
            i += 2
        elif nxt == "e":
            out.append(_code_point_text(0x1b))
            i += 2
        elif nxt in ["x", "u", "U"]:
            decoded, i, ok = _unescape_code_point(text, i, nxt, state, line)
            if not ok:
                return None
            out.append(decoded)
        else:
            state.problems.append("unknown escape at line %d is not supported" % line)
            return None
    return "".join(out)

def _parse_hex(text):
    if text == "":
        return None
    total = 0
    for i in range(len(text)):
        pos = HEX_DIGITS.find(text[i].lower())
        if pos < 0:
            return None
        total = total * 16 + pos
    return total

def _code_point_text(code_point):
    """The string for a Unicode code point, or None when it is out of range."""
    if code_point < 0 or code_point > 0x10ffff:
        return None
    if code_point <= 0xffff:
        return json.decode('"\\u%s"' % _hex4(code_point))
    offset = code_point - 0x10000
    high = 0xd800 + offset // 0x400
    low = 0xdc00 + offset % 0x400
    return json.decode('"\\u%s\\u%s"' % (_hex4(high), _hex4(low)))

def _hex4(value):
    out = []
    n = value
    for _ in range(4):
        out.append(HEX_DIGITS[n % 16])
        n = n // 16
    return "".join(out[::-1])

# ---------------------------------------------------------------------------
# Flow collections
# ---------------------------------------------------------------------------
