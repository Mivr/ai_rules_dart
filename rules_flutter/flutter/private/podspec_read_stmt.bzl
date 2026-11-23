"""Statement and block-header token scanning for the static podspec reader (POD-12)."""

visibility(["//flutter/..."])

_CONT_OPS = (
    "=",
    "+=",
    ",",
    "=>",
    "+",
    "-",
    "*",
    "&&",
    "||",
    ".",
    "?",
    ":",
)

_CLAUSE_CLOSERS = ("end", "else", "elsif", "when", "rescue", "ensure")

END_OPENERS = (
    "if",
    "unless",
    "case",
    "begin",
    "while",
    "until",
    "for",
    "def",
    "class",
    "module",
)

def _after_dot(prev):
    """True when the preceding non-newline token is `.` or `::`."""
    return prev != None and prev.kind == "op" and prev.text in (".", "::")

def _consume_block_params(tokens, n, idx):
    """Advance past optional `| param1, param2 |` block parameter list at `idx`."""
    if idx >= n or tokens[idx].kind != "op" or tokens[idx].text != "|":
        return idx
    j = idx + 1
    for _ in range(n - idx):
        if j >= n or tokens[j].kind == "nl":
            return j
        if tokens[j].kind == "op" and tokens[j].text == "|":
            return j + 1
        j += 1
    return j

def _classify_header_token(t, prev, stop_on_do):
    """Return `"cont"`, `"after"`, `"do"`, `"before"`, or `""` for header token `t`."""
    if t.kind == "nl":
        if prev != None and prev.kind == "op" and prev.text in _CONT_OPS:
            return "cont"
        return "after"
    if t.kind == "op" and t.text == ";":
        return "after"
    if t.kind == "op" and t.text == "}":
        return "before"
    if t.kind == "word" and not _after_dot(prev):
        if t.text == "then":
            return "after"
        if stop_on_do and t.text == "do":
            return "do"
        if t.text == "end":
            return "before"
    return ""

def skip_condition_header(tokens, n, idx, stop_on_do):
    """Advance past an `if`/`unless`/`elsif`/`case`/`when`/`def` header to its body.

    Args:
        tokens: lexed podspec tokens.
        n: number of tokens.
        idx: index of the header keyword token.
        stop_on_do: whether a top-level `do` ends the header.

    Returns:
        Index of the first token of the body.
    """
    j = idx + 1
    depth = 0
    prev = None
    for _ in range(n - idx):
        if j >= n:
            break
        t = tokens[j]
        if depth == 0:
            action = _classify_header_token(t, prev, stop_on_do)
            if action == "cont":
                j += 1
                continue
            if action == "after":
                return j + 1
            if action == "do":
                return _consume_block_params(tokens, n, j + 1)
            if action == "before":
                return j
        depth = _update_bracket_depth(t, True, depth)
        if t.kind != "nl":
            prev = t
        j += 1
    return j

def _update_bracket_depth(t, assign_seen, depth):
    """Compute updated bracket/brace/paren nesting depth for token `t`."""
    if t.kind != "op":
        return depth
    if t.text in ("(", "[") or (t.text == "{" and (assign_seen or depth > 0)):
        return depth + 1
    if t.text in (")", "]") or (t.text == "}" and depth > 0):
        return max(0, depth - 1)
    return depth

def _is_modifier_keyword(t, prev, stmt_len, assign_pos, modifier_pos):
    """True when `t` starts a trailing `if` or `unless` modifier after an RHS value."""
    if modifier_pos >= 0 or stmt_len <= assign_pos + 1:
        return False
    if t.kind != "word" or t.text not in ("if", "unless") or _after_dot(prev):
        return False
    return not (prev != None and prev.kind == "op" and prev.text in _CONT_OPS)

def _is_block_opener_token(t, prev):
    """True when `t` opens a `do` or `{` block before any `=` assignment."""
    if t.kind == "word" and t.text == "do" and not _after_dot(prev):
        return True
    return t.kind == "op" and t.text == "{"

def _is_stmt_terminator(t, prev):
    """Return `"after"` (`NL`/`;`), `"before"` (`end`/`else`/`}`), `"cont"`, or `""`."""
    if t.kind == "nl":
        if prev != None and prev.kind == "op" and prev.text in _CONT_OPS:
            return "cont"
        return "after"
    if t.kind == "op" and t.text == ";":
        return "after"
    if t.kind == "word" and t.text in _CLAUSE_CLOSERS and not _after_dot(prev):
        return "before"
    if t.kind == "op" and t.text == "}":
        return "before"
    return ""

def _update_rhs_state(t, prev, state):
    """Update `assign_pos`, `rhs_end`, and `mod_pos` at bracket depth 0."""
    stmt_len = len(state["stmt"])
    if state["rhs_end"] > 0:
        if t.kind == "word" and not _after_dot(prev):
            if t.text in END_OPENERS or t.text == "do":
                state["rhs_end"] += 1
            elif t.text == "end":
                state["rhs_end"] -= 1
        return
    if state["assign_pos"] < 0:
        if t.kind == "op" and t.text in ("=", "+="):
            state["assign_pos"] = stmt_len
        return
    if stmt_len == state["assign_pos"] + 1 and t.kind == "word" and t.text in END_OPENERS and not _after_dot(prev):
        state["rhs_end"] = 1
        state["rhs_line"] = t.line
    elif t.kind == "word" and t.text == "do" and not _after_dot(prev):
        state["rhs_end"] = 1
        state["rhs_line"] = t.line
    elif _is_modifier_keyword(t, prev, stmt_len, state["assign_pos"], state["mod_pos"]):
        state["mod_pos"] = stmt_len

def _trimmed_stmt_tokens(state):
    """Return accumulated statement tokens with any trailing `if`/`unless` modifier removed."""
    mod_pos = state["mod_pos"]
    return state["stmt"][:mod_pos] if mod_pos >= 0 else state["stmt"]

def _finished_statement(state, next_idx):
    """Build a finished-statement result struct from accumulated `state`.

    `open_line` is non-zero only when input ended inside an RHS `if`/`do`/... block.
    """
    return struct(
        is_block = False,
        tokens = _trimmed_stmt_tokens(state),
        next_idx = next_idx,
        open_line = state["rhs_line"] if state["rhs_end"] > 0 else 0,
    )

def _boundary_action(t, prev, state, tokens, n, j):
    """Classify a depth-0, pre-assignment statement token, or `None` to keep scanning.

    Returns `struct(kind = "cont")` to drop the token and keep scanning, or
    `struct(kind = "done", result = ...)` to finish a statement or open a
    `do`/`{` block. `None` means the token belongs in the statement being
    accumulated.
    """
    term = _is_stmt_terminator(t, prev)
    if term == "cont":
        return struct(kind = "cont")
    if term == "after":
        return struct(kind = "done", result = _finished_statement(state, j + 1))
    if term == "before":
        return struct(kind = "done", result = _finished_statement(state, j))
    if state["assign_pos"] < 0 and _is_block_opener_token(t, prev):
        closer = "end" if t.text == "do" else "}"
        next_j = _consume_block_params(tokens, n, j + 1)
        return struct(kind = "done", result = struct(
            is_block = True,
            header = state["stmt"],
            closer = closer,
            next_idx = next_j,
        ))
    return None

def read_statement_or_block_open(tokens, n, idx):
    """Scan one statement or `do`/`{` block header starting at `tokens[idx]`.

    Args:
        tokens: lexed podspec tokens.
        n: number of tokens.
        idx: index of the first token of the statement.

    Returns:
        The scanned statement or block-open result.
    """
    state = {"stmt": [], "assign_pos": -1, "rhs_end": 0, "mod_pos": -1, "rhs_line": 0}
    depth = 0
    prev = None
    j = idx
    for _ in range(n - idx + 1):
        if j >= n:
            break
        t = tokens[j]
        if depth == 0 and state["rhs_end"] == 0:
            action = _boundary_action(t, prev, state, tokens, n, j)
            if action != None:
                if action.kind == "cont":
                    j += 1
                    continue
                return action.result
        if depth == 0:
            _update_rhs_state(t, prev, state)
        depth = _update_bracket_depth(t, state["assign_pos"] >= 0, depth)
        if t.kind != "nl":
            state["stmt"].append(t)
            prev = t
        j += 1
    return _finished_statement(state, j)
