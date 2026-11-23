"""Ruby lexical and literal-parsing helpers for static podspec reading (POD-12).

Tokenizes a CocoaPods `.podspec` file without evaluating Ruby: tracks physical
1-based line numbers across `#` comments, `=begin`..`=end` block comments,
backslash line continuations, multi-line strings, `%w[...]` word arrays, and
`<<TAG` / `<<-TAG` / `<<~TAG` heredocs. No recursion and no unbounded loops.
"""

load(
    ":podspec_read_percent.bzl",
    "decode_double_escape",
    "split_percent_words",
    "unescape_percent_q",
)
load(
    ":podspec_read_regex.bzl",
    "consume_regex_flags",
    "regex_may_start",
    "scan_slash_regex",
    "skip_interpolation",
)

visibility(["//flutter/..."])

_PAIRED_CLOSERS = {
    "[": "]",
    "(": ")",
    "{": "}",
    "<": ">",
}

_TWO_CHAR_OPS = (
    "+=",
    "=>",
    "==",
    "!=",
    "<=",
    ">=",
    "=~",
    "!~",
    "&&",
    "||",
    "..",
    "::",
)

def _is_ident_start(c):
    """True when `c` can start a Ruby identifier."""
    return ("a" <= c and c <= "z") or ("A" <= c and c <= "Z") or c in ("_", "@", "$")

def _is_ident_char(c):
    """True when `c` can continue a Ruby identifier."""
    return _is_ident_start(c) or ("0" <= c and c <= "9")

def _is_tag_start(c):
    """True when `c` can start an unquoted Ruby heredoc tag."""
    return ("a" <= c and c <= "z") or ("A" <= c and c <= "Z") or c == "_"

def _is_tag_char(c):
    """True when `c` can continue an unquoted Ruby heredoc tag."""
    return _is_tag_start(c) or ("0" <= c and c <= "9")

def _is_num_char(c):
    """True when `c` can continue a Ruby numeric literal."""
    return _is_ident_char(c) or c == "."

def _consume_chars(content, n, pos, pred):
    """Advance `pos` while `pred(content[pos:pos + 1])` holds."""
    j = pos
    for _ in range(n - pos + 1):
        if j >= n or not pred(content[j:j + 1]):
            break
        j += 1
    return j

def _emit_token(ctx, kind, text, start, end):
    """Append a simple token at `ctx["line"]` to `ctx["tokens"]`."""
    ctx["tokens"].append(struct(
        kind = kind,
        text = text,
        raw = ctx["content"][start:end],
        line = ctx["line"],
        start = start,
        end = end,
        interp = False,
        words = None,
    ))

def _emit_spanned_token(ctx, kind, text, span, interp = False, words = None):
    """Append a potentially multi-line literal token to `ctx["tokens"]`."""
    ctx["tokens"].append(struct(
        kind = kind,
        text = text,
        raw = ctx["content"][span.start:span.end],
        line = span.line,
        start = span.start,
        end = span.end,
        interp = interp,
        words = words,
    ))

def _mark_unterminated(ctx, what, line):
    """Record the first lexical construct that ran to end of input without closing."""
    if ctx["unterminated"] == None:
        ctx["unterminated"] = struct(what = what, line = line)

def _is_marker_line(content, n, pos, marker):
    """True when `content[pos:]` starts with `marker` followed by whitespace or EOF."""
    end = pos + len(marker)
    if content[pos:end] != marker:
        return False
    return end == n or content[end:end + 1] in (" ", "\t", "\r", "\n")

def _consume_heredoc_line(ctx):
    """Consume one physical line inside the active heredoc at the front of `ctx["heredocs"]`."""
    content = ctx["content"]
    i = ctx["i"]
    nl = content.find("\n", i)
    line_str = content[i:nl] if nl >= 0 else content[i:]
    if line_str.endswith("\r"):
        line_str = line_str[:-1]
    hdoc = ctx["heredocs"][0]
    probe = line_str.strip() if hdoc.strip else line_str
    if probe == hdoc.tag:
        ctx["heredocs"].pop(0)
    if nl >= 0:
        ctx["i"] = nl + 1
        ctx["line"] += 1
        ctx["at_bol"] = True
    else:
        ctx["i"] = ctx["n"]

def _consume_block_comment_line(ctx):
    """Consume one physical line inside a `=begin`..`=end` Ruby block comment."""
    content = ctx["content"]
    n = ctx["n"]
    i = ctx["i"]
    is_end = _is_marker_line(content, n, i, "=end")
    nl = content.find("\n", i)
    if nl >= 0:
        ctx["i"] = nl + 1
        ctx["line"] += 1
        ctx["at_bol"] = True
    else:
        ctx["i"] = n
    if is_end:
        ctx["in_block_comment"] = False

def _try_lex_heredoc(ctx):
    """Try to lex a Ruby heredoc opener (`<<TAG`, `<<-TAG`, `<<~TAG`, quoted variants)."""
    if not ctx["allow_heredoc"]:
        return False
    content = ctx["content"]
    n = ctx["n"]
    i = ctx["i"]
    if i > 0 and content[i - 1:i] == "<":
        return False
    j = i + 2
    strip_mode = False
    if j < n and content[j:j + 1] in ("-", "~"):
        strip_mode = True
        j += 1
    if j >= n:
        return False
    ch = content[j:j + 1]
    if ch in ("'", '"', "`"):
        nl = content.find("\n", j + 1)
        limit = nl if nl >= 0 else n
        end_q = content.find(ch, j + 1, limit)
        if end_q <= j + 1:
            return False
        tag = content[j + 1:end_q]
        end_pos = end_q + 1
    elif _is_tag_start(ch):
        end_pos = _consume_chars(content, n, j + 1, _is_tag_char)
        tag = content[j:end_pos]
    else:
        return False
    ctx["heredocs"].append(struct(tag = tag, strip = strip_mode, line = ctx["line"]))
    _emit_token(ctx, "other", content[i:end_pos], i, end_pos)
    ctx["i"] = end_pos
    ctx["at_bol"] = False
    ctx["allow_heredoc"] = False
    return True

def _scan_single_string(ctx):
    """Scan a single-quoted Ruby string `'...'` starting at `ctx["i"]`."""
    content = ctx["content"]
    n = ctx["n"]
    start = ctx["i"]
    start_line = ctx["line"]
    j = start + 1
    buf = []
    closed = False
    for _ in range(n - start + 1):
        if j >= n:
            break
        c = content[j:j + 1]
        if c == "\\" and j + 1 < n and content[j + 1:j + 2] in ("\\", "'"):
            buf.append(content[j + 1:j + 2])
            j += 2
        elif c == "'":
            j += 1
            closed = True
            break
        else:
            if c == "\n":
                ctx["line"] += 1
            buf.append(c)
            j += 1
    kind = "str" if closed else "other"
    if not closed:
        _mark_unterminated(ctx, "an unterminated single-quoted string", start_line)
    _emit_spanned_token(ctx, kind, "".join(buf), struct(start = start, end = j, line = start_line))
    ctx["i"] = j
    ctx["at_bol"] = False
    ctx["allow_heredoc"] = False

def _step_double_interp(ctx, content, n, j, state):
    """Advance one step inside `#{...}` interpolation within a double-quoted string."""
    c = content[j:j + 1]
    if state["inner_q"]:
        if c == "\\" and j + 1 < n and content[j + 1:j + 2] != "\n":
            return j + 2
        if c == "\n":
            ctx["line"] += 1
        elif c == state["inner_q"]:
            state["inner_q"] = ""
        return j + 1
    if c in ("'", '"'):
        state["inner_q"] = c
    elif c == "{":
        state["interp"] += 1
    elif c == "}":
        state["interp"] -= 1
    elif c == "\n":
        ctx["line"] += 1
    return j + 1

def _scan_double_string(ctx):
    """Scan a double-quoted Ruby string `\"...\"` starting at `ctx["i"]`."""
    content = ctx["content"]
    n = ctx["n"]
    start = ctx["i"]
    start_line = ctx["line"]
    j = start + 1
    buf = []
    state = {"interp": 0, "inner_q": "", "has_interp": False, "closed": False}
    for _ in range(n - start + 1):
        if j >= n:
            break
        if state["interp"] > 0:
            j = _step_double_interp(ctx, content, n, j, state)
            continue
        c = content[j:j + 1]
        if c == "\\" and j + 1 < n:
            nxt = content[j + 1:j + 2]
            if nxt == "\n":
                ctx["line"] += 1
            else:
                buf.append(decode_double_escape(nxt))
            j += 2
        elif content[j:j + 2] == "#{":
            state["has_interp"] = True
            state["interp"] = 1
            j += 2
        elif c == '"':
            j += 1
            state["closed"] = True
            break
        else:
            if c == "\n":
                ctx["line"] += 1
            buf.append(c)
            j += 1
    kind = "str" if state["closed"] else "other"
    if not state["closed"]:
        _mark_unterminated(ctx, "an unterminated double-quoted string", start_line)
    span = struct(start = start, end = j, line = start_line)
    _emit_spanned_token(ctx, kind, "".join(buf), span, interp = state["has_interp"])
    ctx["i"] = j
    ctx["at_bol"] = False
    ctx["allow_heredoc"] = False

def _scan_percent_body(ctx, mod, open_ch, close_ch):
    """Scan the delimited body of a `%` literal from `ctx["i"] + 3`."""
    content = ctx["content"]
    n = ctx["n"]
    paired = open_ch != close_ch
    interp_capable = mod in ("W", "Q", "I", "r", "x")
    j = ctx["i"] + 3
    depth = 1
    has_interp = False
    for _ in range(n - ctx["i"] + 1):
        if j >= n or depth == 0:
            break
        c = content[j:j + 1]
        if c == "\\" and j + 1 < n:
            if content[j + 1:j + 2] == "\n":
                ctx["line"] += 1
            j += 2
        elif interp_capable and content[j:j + 2] == "#{":
            has_interp = True
            body = skip_interpolation(ctx, j + 2)
            j = body.end
            if not body.closed:
                return struct(end = j, closed = False, has_interp = True)
        elif paired and c == open_ch:
            depth += 1
            j += 1
        elif c == close_ch:
            depth -= 1
            j += 1
        else:
            if c == "\n":
                ctx["line"] += 1
            j += 1
    return struct(end = j, closed = depth == 0, has_interp = has_interp)

def _try_lex_percent(ctx):
    """Try to lex a `%w[...]`, `%W[...]`, `%q[...]`, `%Q[...]`, or other `%` literal."""
    content = ctx["content"]
    n = ctx["n"]
    i = ctx["i"]
    mod = content[i + 1:i + 2]
    if mod not in ("w", "W", "q", "Q", "i", "I", "r", "x", "s") or i + 2 >= n:
        return False
    open_ch = content[i + 2:i + 3]
    if open_ch in ("", " ", "\t", "\r", "\n") or _is_tag_char(open_ch):
        return False
    close_ch = _PAIRED_CLOSERS.get(open_ch, open_ch)
    start_line = ctx["line"]
    scanned = _scan_percent_body(ctx, mod, open_ch, close_ch)
    j = scanned.end
    if not scanned.closed:
        _mark_unterminated(ctx, "an unterminated percent literal", start_line)
    elif mod == "r":
        j = consume_regex_flags(content, n, j)
    span = struct(start = i, end = j, line = start_line)
    if not scanned.closed:
        _emit_spanned_token(ctx, "other", content[i:j], span)
    elif mod in ("w", "W"):
        words = None if scanned.has_interp else split_percent_words(content[i + 3:j - 1], open_ch, close_ch)
        _emit_spanned_token(ctx, "pct_w", content[i:j], span, interp = scanned.has_interp, words = words)
    elif mod in ("q", "Q"):
        val = unescape_percent_q(content[i + 3:j - 1], open_ch, close_ch, mod == "Q")
        _emit_spanned_token(ctx, "str", val, span, interp = scanned.has_interp)
    else:
        _emit_spanned_token(ctx, "other", content[i:j], span)
    ctx["i"] = j
    ctx["at_bol"] = False
    ctx["allow_heredoc"] = False
    return True

def _scan_word_or_punct(ctx):
    """Scan an identifier, symbol, number, or operator token starting at `ctx["i"]`."""
    content = ctx["content"]
    n = ctx["n"]
    i = ctx["i"]
    c = content[i:i + 1]
    if c == ":" and i + 1 < n and _is_ident_start(content[i + 1:i + 2]):
        j = _consume_chars(content, n, i + 2, _is_ident_char)
        _emit_token(ctx, "other", content[i:j], i, j)
        ctx["i"] = j
        ctx["allow_heredoc"] = False
        return
    if _is_ident_start(c):
        j = _consume_chars(content, n, i + 1, _is_ident_char)
        if j < n and content[j:j + 1] in ("?", "!"):
            j += 1
        _emit_token(ctx, "word", content[i:j], i, j)
        ctx["i"] = j
        ctx["allow_heredoc"] = False
        return
    if "0" <= c and c <= "9":
        j = _consume_chars(content, n, i + 1, _is_num_char)
        _emit_token(ctx, "other", content[i:j], i, j)
        ctx["i"] = j
        ctx["allow_heredoc"] = False
        return
    op_len = 3 if content[i:i + 3] == "..." else (2 if content[i:i + 2] in _TWO_CHAR_OPS else 1)
    tok_str = content[i:i + op_len]
    _emit_token(ctx, "op", tok_str, i, i + op_len)
    ctx["i"] = i + op_len
    ctx["allow_heredoc"] = tok_str not in (")", "]")

def _lex_regex(ctx):
    """Lex a `/.../flags` regex literal at `ctx["i"]` as one `other` token."""
    start = ctx["i"]
    start_line = ctx["line"]
    scanned = scan_slash_regex(ctx)
    if not scanned.closed:
        _mark_unterminated(ctx, "an unterminated regex literal", start_line)
    span = struct(start = start, end = scanned.end, line = start_line)
    _emit_spanned_token(ctx, "other", ctx["content"][start:scanned.end], span)
    ctx["i"] = scanned.end
    ctx["at_bol"] = False
    ctx["allow_heredoc"] = False

def _eof_error(ctx):
    """Return `struct(what, line)` for a construct still open at end of input, or `None`."""
    if ctx["unterminated"] != None:
        return ctx["unterminated"]
    if ctx["in_block_comment"]:
        return struct(what = "an unterminated `=begin` block comment", line = ctx["block_line"])
    if ctx["heredocs"]:
        hdoc = ctx["heredocs"][0]
        return struct(what = "an unterminated heredoc `<<%s`" % hdoc.tag, line = hdoc.line)
    return None

def _step_code(ctx):
    """Advance one step in normal Ruby code state."""
    content = ctx["content"]
    n = ctx["n"]
    i = ctx["i"]
    c = content[i:i + 1]
    if c == "\\" and content[i + 1:i + 2] == "\n":
        ctx["line"] += 1
        ctx["i"] = i + 2
        ctx["at_bol"] = False
        return
    if c == "\\" and content[i + 1:i + 3] == "\r\n":
        ctx["line"] += 1
        ctx["i"] = i + 3
        ctx["at_bol"] = False
        return
    if c == "\n":
        _emit_token(ctx, "nl", "\n", i, i + 1)
        ctx["line"] += 1
        ctx["i"] = i + 1
        ctx["at_bol"] = True
        ctx["allow_heredoc"] = True
        return
    if c in (" ", "\t", "\r"):
        ctx["i"] = i + 1
        ctx["allow_heredoc"] = True
        return
    if c == "#":
        nl = content.find("\n", i + 1)
        ctx["i"] = nl if nl >= 0 else n
        return
    if c == "'":
        _scan_single_string(ctx)
        return
    if c == '"':
        _scan_double_string(ctx)
        return
    if c == "%" and _try_lex_percent(ctx):
        return
    if c == "/" and regex_may_start(ctx["tokens"], content, i):
        _lex_regex(ctx)
        return
    if content[i:i + 2] == "<<" and _try_lex_heredoc(ctx):
        return
    ctx["at_bol"] = False
    _scan_word_or_punct(ctx)

def lex_podspec(content):
    """Tokenize a `.podspec` file into a flat list of line-stamped tokens.

    Args:
        content: Full `.podspec` text string.

    Returns:
        List of token structs with `kind`, `text`, `raw`, `line`, `start`,
        `end`, `interp`, and `words`.
    """
    return lex_podspec_checked(content).tokens

def lex_podspec_checked(content):
    """Tokenize a `.podspec` file and report any construct left open at end of input.

    Args:
        content: Full `.podspec` text string.

    Returns:
        `struct(tokens, error)`: the token list (see `lex_podspec`) and either
        `None` or `struct(what, line)` naming the first unterminated string,
        regex, percent literal, heredoc, or `=begin` block comment.
    """
    n = len(content)
    ctx = {
        "allow_heredoc": True,
        "at_bol": True,
        "block_line": 0,
        "content": content,
        "heredocs": [],
        "i": 0,
        "in_block_comment": False,
        "line": 1,
        "n": n,
        "tokens": [],
        "unterminated": None,
    }
    for _ in range(n + 1):
        if ctx["i"] >= n:
            break
        if ctx["in_block_comment"]:
            _consume_block_comment_line(ctx)
        elif ctx["at_bol"] and ctx["heredocs"]:
            _consume_heredoc_line(ctx)
        elif ctx["at_bol"] and _is_marker_line(content, n, ctx["i"], "=begin"):
            ctx["in_block_comment"] = True
            ctx["block_line"] = ctx["line"]
            _consume_block_comment_line(ctx)
        else:
            _step_code(ctx)
    return struct(tokens = ctx["tokens"], error = _eof_error(ctx))

def _parse_single_literal_string(tok, allow_interpolation = False):
    """Extract a plain string literal from `tok`, or `None` if not literal."""
    if tok.kind != "str":
        return None
    if tok.interp and not allow_interpolation:
        return None
    return tok.text

def _parse_comma_string_tokens(tokens, start_idx, end_idx, allow_trailing_comma):
    """Parse `str (, str)* [, ]` from `tokens[start_idx:end_idx]`."""
    items = []
    expect_item = True
    saw_comma = False
    for k in range(start_idx, end_idx):
        tok = tokens[k]
        if expect_item:
            val = _parse_single_literal_string(tok, allow_interpolation = False)
            if val == None or val == "":
                return None
            items.append(val)
            expect_item = False
        elif tok.kind == "op" and tok.text == ",":
            saw_comma = True
            expect_item = True
        else:
            return None
    if expect_item and (not allow_trailing_comma or not saw_comma):
        return None
    return items

def parse_string_list_tokens(rhs_tokens):
    """Parse an RHS token slice as a single string, `[...]` array, bare list, or `%w[...]`.

    Args:
        rhs_tokens: Non-newline tokens forming an attribute's RHS expression.

    Returns:
        `list[str]` of literal strings, or `None` if non-literal or malformed.
    """
    m = len(rhs_tokens)
    if m == 0:
        return None
    if m == 1:
        tok = rhs_tokens[0]
        if tok.kind == "pct_w":
            if tok.words == None or "" in tok.words:
                return None
            return list(tok.words)
        val = _parse_single_literal_string(tok, allow_interpolation = False)
        if val == None or val == "":
            return None
        return [val]
    first = rhs_tokens[0]
    last = rhs_tokens[m - 1]
    if first.kind == "op" and first.text == "[" and last.kind == "op" and last.text == "]":
        if m == 2:
            return []
        return _parse_comma_string_tokens(rhs_tokens, 1, m - 1, allow_trailing_comma = True)
    return _parse_comma_string_tokens(rhs_tokens, 0, m, allow_trailing_comma = False)

def _split_top_level_commas(tokens):
    """Split a token slice on `,` at bracket/brace/paren depth 0."""
    groups = []
    cur = []
    depth = 0
    for tok in tokens:
        if tok.kind == "op" and tok.text in ("[", "{", "("):
            depth += 1
            cur.append(tok)
        elif tok.kind == "op" and tok.text in ("]", "}", ")"):
            depth = max(0, depth - 1)
            cur.append(tok)
        elif depth == 0 and tok.kind == "op" and tok.text == ",":
            if not cur:
                return None
            groups.append(cur)
            cur = []
        else:
            cur.append(tok)
    if cur:
        groups.append(cur)
    return groups

def parse_resource_bundles_tokens(rhs_tokens):
    """Parse a `resource_bundles` hash `{ key => value, ... }` from RHS tokens.

    Keys may be any string literal (including `\"#{s.module_name}_Privacy\"`).
    Values must be a single non-empty string literal or non-empty list of
    plain string literals (no interpolation).

    Args:
        rhs_tokens: Non-newline tokens forming the `resource_bundles` RHS.

    Returns:
        `list[str]` of value strings (`[]` for `{}`), or `None` if invalid.
    """
    m = len(rhs_tokens)
    if m < 2:
        return None
    if rhs_tokens[0].kind != "op" or rhs_tokens[0].text != "{":
        return None
    if rhs_tokens[m - 1].kind != "op" or rhs_tokens[m - 1].text != "}":
        return None
    if m == 2:
        return []
    entries = _split_top_level_commas(rhs_tokens[1:m - 1])
    if entries == None:
        return None
    values = []
    for entry in entries:
        if len(entry) < 3 or entry[1].kind != "op" or entry[1].text != "=>":
            return None
        key_val = _parse_single_literal_string(entry[0], allow_interpolation = True)
        if key_val == None or key_val == "":
            return None
        parsed_vals = parse_string_list_tokens(entry[2:])
        if parsed_vals == None or len(parsed_vals) == 0:
            return None
        values.extend(parsed_vals)
    return values

def format_rhs_raw(content, rhs_tokens):
    """Format the original RHS expression slice cleanly for Message 5.

    Args:
        content: Full `.podspec` text string.
        rhs_tokens: Non-newline tokens forming the RHS expression (or all
            statement tokens after `=` / `+=`, including any modifier).

    Returns:
        Trimmed single-line raw RHS string.
    """
    if not rhs_tokens:
        return ""
    if rhs_tokens[0].line == rhs_tokens[-1].line:
        return content[rhs_tokens[0].start:rhs_tokens[-1].end].strip()
    parts = []
    cur_line = rhs_tokens[0].line
    line_start = rhs_tokens[0].start
    line_end = rhs_tokens[0].end
    for tok in rhs_tokens[1:]:
        if tok.line == cur_line:
            line_end = tok.end
        else:
            parts.append(content[line_start:line_end].strip())
            cur_line = tok.line
            line_start = tok.start
            line_end = tok.end
    parts.append(content[line_start:line_end].strip())
    return " ".join(parts)
