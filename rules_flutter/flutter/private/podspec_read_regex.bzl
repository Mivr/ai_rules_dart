"""Ruby regex-literal and `#{...}` interpolation scanning for the podspec lexer (POD-12).

Decides whether a `/` opens a `/.../flags` regex literal or is a division
operator from the preceding token, and scans regex bodies and interpolations
without evaluating Ruby. Scanners advance `ctx["line"]` across newlines and
report whether the construct closed before end of input.
"""

visibility(["//flutter/..."])

_VALUE_KEYWORDS = (
    "if",
    "unless",
    "elsif",
    "when",
    "while",
    "until",
    "and",
    "or",
    "not",
    "return",
    "then",
    "do",
    "else",
    "begin",
    "case",
    "yield",
)

_NO_OPERAND = (" ", "\t", "\r", "\n", "=", "")

def regex_may_start(tokens, content, i):
    """True when the `/` at `content[i]` opens a regex literal rather than dividing.

    Args:
        tokens: Tokens lexed so far (the previous token decides).
        content: Full `.podspec` text string.
        i: Index of the `/` character.

    Returns:
        `True` when Ruby expects a value expression at `i`.
    """
    if not tokens:
        return True
    prev = tokens[-1]
    if prev.kind == "nl":
        return True
    if prev.kind == "op":
        return prev.text not in (")", "]", "}")
    if prev.kind != "word":
        return False
    if prev.text in _VALUE_KEYWORDS:
        return True
    return prev.end < i and content[i + 1:i + 2] not in _NO_OPERAND

def _is_ascii_letter(c):
    """True when `c` is an ASCII letter (a regex option)."""
    return ("a" <= c and c <= "z") or ("A" <= c and c <= "Z")

def consume_regex_flags(content, n, j):
    """Advance `j` past trailing ASCII regex option letters.

    Args:
        content: Full `.podspec` text string.
        n: Length of `content`.
        j: Index just after the closing regex delimiter.

    Returns:
        Index just after the last option letter.
    """
    for _ in range(n - j + 1):
        if j >= n or not _is_ascii_letter(content[j:j + 1]):
            break
        j += 1
    return j

def _skip_interp_quote(ctx, j, quote):
    """Advance one character inside a quoted string within `#{...}`; returns `(j, quote)`."""
    content = ctx["content"]
    c = content[j:j + 1]
    if c == "\\" and j + 1 < ctx["n"]:
        if content[j + 1:j + 2] == "\n":
            ctx["line"] += 1
        return j + 2, quote
    if c == "\n":
        ctx["line"] += 1
    return j + 1, ("" if c == quote else quote)

def skip_interpolation(ctx, j):
    """Step across a `#{...}` body whose opening `#{` ends just before `j`.

    Quotes, `#` line comments and nested braces inside the interpolation do
    not close it early.

    Args:
        ctx: Lexer context dict (`content`, `n`, `line`).
        j: Index of the first character inside the interpolation.

    Returns:
        `struct(end, closed)`: index after the closing `}` (or `n`) and whether it was found.
    """
    content = ctx["content"]
    n = ctx["n"]
    depth = 1
    quote = ""
    for _ in range(n - j + 1):
        if j >= n:
            break
        c = content[j:j + 1]
        if quote:
            j, quote = _skip_interp_quote(ctx, j, quote)
            continue
        if c == "#":
            nl = content.find("\n", j)
            j = nl if nl >= 0 else n
            continue
        if c in ("'", '"'):
            quote = c
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return struct(end = j + 1, closed = True)
        elif c == "\n":
            ctx["line"] += 1
        j += 1
    return struct(end = n, closed = False)

def scan_slash_regex(ctx):
    """Scan a `/.../flags` regex literal starting at `ctx["i"]`.

    Args:
        ctx: Lexer context dict (`content`, `n`, `i`, `line`).

    Returns:
        `struct(end, closed)`: index after the trailing flags (or `n`) and whether it closed.
    """
    content = ctx["content"]
    n = ctx["n"]
    j = ctx["i"] + 1
    classes = 0
    for _ in range(n - j + 1):
        if j >= n:
            break
        c = content[j:j + 1]
        if c == "\\" and j + 1 < n:
            if content[j + 1:j + 2] == "\n":
                ctx["line"] += 1
            j += 2
        elif c == "#" and content[j + 1:j + 2] == "{":
            scanned = skip_interpolation(ctx, j + 2)
            j = scanned.end
            if not scanned.closed:
                break
        elif c == "/" and classes == 0:
            return struct(end = consume_regex_flags(content, n, j + 1), closed = True)
        else:
            if c == "[":
                classes += 1
            elif c == "]" and classes > 0:
                classes -= 1
            elif c == "\n":
                ctx["line"] += 1
            j += 1
    return struct(end = n, closed = False)
