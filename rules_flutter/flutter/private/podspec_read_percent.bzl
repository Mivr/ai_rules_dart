"""Escape decoding and word splitting for Ruby `%` and double-quoted literals (POD-12)."""

visibility(["//flutter/..."])

def decode_double_escape(nxt):
    """Decode one escaped character `\\<nxt>` in a Ruby double-quoted string.

    Args:
        nxt: The character following the backslash.

    Returns:
        The decoded character string.
    """
    if nxt == "n":
        return "\n"
    if nxt == "t":
        return "\t"
    if nxt == "r":
        return "\r"
    return nxt

def split_percent_words(inner, open_ch, close_ch):
    """Split a `%w[...]` body on ASCII whitespace, honoring backslash escapes.

    Args:
        inner: Text between the literal's delimiters.
        open_ch: Opening delimiter character.
        close_ch: Closing delimiter character.

    Returns:
        List of word strings.
    """
    m = len(inner)
    k = 0
    words = []
    cur = []
    in_word = False
    for _ in range(m + 1):
        if k >= m:
            break
        c = inner[k:k + 1]
        if c == "\\" and k + 1 < m:
            nxt = inner[k + 1:k + 2]
            if nxt in (" ", "\t", "\n", "\r", "\\", open_ch, close_ch):
                cur.append(nxt)
            else:
                cur.append("\\" + nxt)
            in_word = True
            k += 2
        elif c in (" ", "\t", "\n", "\r"):
            if in_word:
                words.append("".join(cur))
                cur = []
                in_word = False
            k += 1
        else:
            cur.append(c)
            in_word = True
            k += 1
    if in_word:
        words.append("".join(cur))
    return words

def unescape_percent_q(inner, open_ch, close_ch, is_double):
    """Unescape the body of a `%q[...]` or `%Q[...]` string literal.

    Args:
        inner: Text between the literal's delimiters.
        open_ch: Opening delimiter character.
        close_ch: Closing delimiter character.
        is_double: True for `%Q` (double-quote escapes), false for `%q`.

    Returns:
        The unescaped string.
    """
    m = len(inner)
    k = 0
    buf = []
    for _ in range(m + 1):
        if k >= m:
            break
        c = inner[k:k + 1]
        if c == "\\" and k + 1 < m:
            nxt = inner[k + 1:k + 2]
            if is_double:
                buf.append(decode_double_escape(nxt))
            elif nxt in ("\\", open_ch, close_ch):
                buf.append(nxt)
            else:
                buf.append("\\" + nxt)
            k += 2
        else:
            buf.append(c)
            k += 1
    return "".join(buf)
