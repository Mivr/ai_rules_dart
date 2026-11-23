"""Top-level string constants for SwiftPM `Package.swift` manifests.

`swiftpm_manifest.bzl` lexes a manifest and calls
`fold_manifest_constants` before it refuses a top-level `let`/`var`. Three
literal declaration forms fold: `let <id> = "<value>"`, `let <id>: Version =
"<value>"` and `let <id>: String = "<value>"`. The fold walks the manifest's
statements in file order, so a use sees only constants declared before it. It
replaces a bare identifier used as an argument value and a whole `\\(<id>)`
inside a string literal with the constant's source text, and drops the folded
declaration statements so the parser never sees them.

The statement splitter lives here too: the parser and the fold must agree on
where a statement ends, and one implementation avoids a load cycle between
them.
"""

visibility(["//flutter/..."])

_SWIFTPM_NON_VALUE_WORDS = {
    "else": True,
    "false": True,
    "func": True,
    "if": True,
    "import": True,
    "let": True,
    "nil": True,
    "package": True,
    "return": True,
    "true": True,
    "var": True,
}

_SWIFTPM_CONSTANT_TYPES = {
    "String": True,
    "Version": True,
}

def swiftpm_split_statements(tokens):
    """Split tokens into top-level statements.

    Statements end at a newline or `;` at paren/bracket depth 0. Empty
    statements are dropped. Depth never goes negative: a stray closer just
    stays in its statement, which the dispatcher refuses.

    Args:
        tokens: The lexed token list.

    Returns:
        A list of token lists.
    """
    statements = []
    current = []
    depth = 0
    for tok in tokens:
        if tok.kind == "nl" or (tok.kind == "punct" and tok.text == ";"):
            if depth == 0:
                if current:
                    statements.append(current)
                    current = []
            else:
                current.append(tok)
        else:
            if tok.kind == "punct" and (tok.text == "(" or tok.text == "["):
                depth += 1
            elif tok.kind == "punct" and (tok.text == ")" or tok.text == "]") and depth > 0:
                depth -= 1
            current.append(tok)
    if current:
        statements.append(current)
    return statements

def _swiftpm_const_fail(identity, line, detail):
    """The fetch failure for one fold refusal, in the parser's message shape.

    Args:
        identity: The SwiftPM package identity.
        line: The 1-based line number.
        detail: What was found and why it is unsupported.

    Returns:
        The error string; the caller `fail()`s with it.
    """
    return "SwiftPM package {identity} (Package.swift line {line}): {detail}.".format(
        identity = repr(identity),
        line = line,
        detail = detail,
    )

def _swiftpm_before_use_error(identity, line, ident):
    """The refusal for a constant use before its declaration.

    Args:
        identity: The SwiftPM package identity.
        line: The 1-based line number of the use.
        ident: The identifier that is not a constant yet.

    Returns:
        The error string; the caller `fail()`s with it.
    """
    detail = "`{ident}` is used before its declaration: a constant must be declared before use".format(ident = ident)
    return _swiftpm_const_fail(identity, line, detail)

def _swiftpm_unknown_use_error(identity, line, ident):
    """The refusal for a bare identifier that names no constant.

    Args:
        identity: The SwiftPM package identity.
        line: The 1-based line number of the use.
        ident: The identifier that is not a declared constant.

    Returns:
        The error string; the caller `fail()`s with it.
    """
    detail = "`{ident}` is not a constant declared before use: expected one string literal, and a constant must be declared before use".format(ident = ident)
    return _swiftpm_const_fail(identity, line, detail)

def _swiftpm_is_ident_start(c):
    """True when `c` can open a Swift identifier.

    Args:
        c: A single character.

    Returns:
        True for letters and `_`.
    """
    return ("a" <= c and c <= "z") or ("A" <= c and c <= "Z") or c == "_"

def _swiftpm_is_ident_char(c):
    """True when `c` can continue a Swift identifier.

    Args:
        c: A single character.

    Returns:
        True for letters, digits and `_`.
    """
    return _swiftpm_is_ident_start(c) or ("0" <= c and c <= "9")

def _swiftpm_is_identifier(text):
    """True when `text` is one bare Swift identifier.

    Args:
        text: The candidate text.

    Returns:
        True for a non-empty run of identifier characters starting with a
        letter or `_`.
    """
    if not text or not _swiftpm_is_ident_start(text[0]):
        return False
    for i in range(1, len(text)):
        if not _swiftpm_is_ident_char(text[i]):
            return False
    return True

def _swiftpm_declaration(seg):
    """Read one top-level statement as a foldable string constant.

    Only the three literal forms fold; a `var`, a declaration of another
    type, a computed value, an array or an interpolated string is not a
    constant and stays for the parser to refuse.

    Args:
        seg: The statement's token list.

    Returns:
        `struct(is_decl, name, value, line)`: `is_decl` is False for every
        statement outside the three forms.
    """
    if not seg or seg[0].kind != "word" or seg[0].text != "let" or len(seg) < 4:
        return struct(is_decl = False, name = "", value = "", line = 0)
    if seg[1].kind != "word" or seg[1].text == "package":
        return struct(is_decl = False, name = "", value = "", line = 0)
    value = None
    if len(seg) == 4 and seg[2].kind == "punct" and seg[2].text == "=":
        value = seg[3]
    elif len(seg) == 6 and seg[2].kind == "punct" and seg[2].text == ":":
        typed = seg[3].kind == "word" and seg[3].text in _SWIFTPM_CONSTANT_TYPES
        if typed and seg[4].kind == "punct" and seg[4].text == "=":
            value = seg[5]
    if value == None or value.kind != "str" or value.interp:
        return struct(is_decl = False, name = "", value = "", line = 0)
    return struct(is_decl = True, name = seg[1].text, value = value.text, line = seg[0].line)

def _swiftpm_is_value_use(tokens, index):
    """True when token `index` is a bare identifier in an argument value.

    A value follows an argument label (`url: someUrl`), a comma, an opening
    bracket or an opening paren, and ends at a comma, a closer or the
    statement's end; a newline inside a call or array does not change that.
    Labels, call heads, member accesses, type annotations and operators are
    not values, so a constant with the same spelling never replaces them.

    Args:
        tokens: The statement's token list.
        index: The token position to test.

    Returns:
        True when the token is a word that can stand for a string value.
    """
    tok = tokens[index]
    if tok.kind != "word" or tok.text in _SWIFTPM_NON_VALUE_WORDS or index == 0:
        return False
    prev_index = index - 1
    for _ in range(index + 1):
        if prev_index < 0 or tokens[prev_index].kind != "nl":
            break
        prev_index -= 1
    if prev_index < 0:
        return False
    prev = tokens[prev_index]
    if prev.kind != "punct" or (prev.text != ":" and prev.text != "," and prev.text != "[" and prev.text != "("):
        return False
    next_index = index + 1
    for _ in range(len(tokens) - index):
        if next_index >= len(tokens) or tokens[next_index].kind != "nl":
            break
        next_index += 1
    if next_index >= len(tokens):
        return True
    nxt = tokens[next_index]
    return nxt.kind == "punct" and (nxt.text == "," or nxt.text == ")" or nxt.text == "]" or nxt.text == "}")

def _swiftpm_is_interp_marker(text, start):
    """True when the `\\(` at `start` opens an interpolation.

    A backslash escaped by another backslash is literal text, so only an
    even run of backslashes before the marker makes it interpolation.

    Args:
        text: The string token's content.
        start: The index of the marker's backslash.

    Returns:
        True for a real interpolation marker.
    """
    count = 0
    i = start - 1
    for _ in range(start + 1):
        if i < 0 or text[i] != "\\":
            break
        count += 1
        i -= 1
    return count % 2 == 0

def _swiftpm_fold_interpolation(identity, tok, constants, declared):
    """Fold the whole `\\(<id>)` interpolations in one string token.

    A simple `\\(<id>)` whose constant is already declared is replaced by
    the constant's source text. An identifier declared later fails naming
    the line; any other interpolation (an expression, a member access, an
    unknown name) is left for the parser's existing refusal.

    Args:
        identity: The SwiftPM package identity, for messages.
        tok: The string token.
        constants: The constants declared before this statement.
        declared: Every constant name the file declares, for later-use
            messages.

    Returns:
        `struct(ok, error, tok)`: the token keeps `interp = True` when an
        interpolation remains.
    """
    if not tok.interp:
        return struct(ok = True, error = "", tok = tok)
    text = tok.text
    out = ""
    pos = 0
    search = 0
    changed = False
    for _ in range(len(text) + 1):
        start = text.find("\\(", search)
        if start < 0:
            break
        if not _swiftpm_is_interp_marker(text, start):
            search = start + 2
            continue
        close = text.find(")", start + 2)
        if close < 0:
            return struct(ok = True, error = "", tok = tok)
        ident = text[start + 2:close]
        if not _swiftpm_is_identifier(ident):
            return struct(ok = True, error = "", tok = tok)
        if ident in constants:
            out += text[pos:start] + constants[ident].value
            pos = close + 1
            search = pos
            changed = True
            continue
        if ident in declared:
            return struct(ok = False, error = _swiftpm_before_use_error(identity, tok.line, ident), tok = None)
        return struct(ok = True, error = "", tok = tok)
    if not changed:
        return struct(ok = True, error = "", tok = tok)
    out += text[pos:]
    return struct(ok = True, error = "", tok = struct(kind = "str", text = out, line = tok.line, interp = False))

def _swiftpm_fold_statement(identity, seg, constants, declared):
    """Substitute the constants a statement may use.

    The declaration name of a top-level `let`/`var` is never a use. Every
    other bare identifier in a value position and every string
    interpolation folds against the constants declared before the
    statement.

    Args:
        identity: The SwiftPM package identity, for messages.
        seg: The statement's token list.
        constants: The constants declared before this statement.
        declared: Every constant name the file declares, for later-use
            messages.

    Returns:
        `struct(ok, error, tokens)`.
    """
    for tok in seg:
        if tok.kind == "directive":
            return struct(ok = True, error = "", tokens = seg)
    if seg and seg[0].kind == "word" and (seg[0].text == "let" or seg[0].text == "var"):
        if len(seg) > 1 and seg[1].kind == "word" and seg[1].text != "package":
            return struct(ok = True, error = "", tokens = seg)
    out = []
    for i in range(len(seg)):
        tok = seg[i]
        if tok.kind == "str" and tok.interp:
            folded = _swiftpm_fold_interpolation(identity, tok, constants, declared)
            if not folded.ok:
                return struct(ok = False, error = folded.error, tokens = [])
            out.append(folded.tok)
            continue
        if _swiftpm_is_value_use(seg, i):
            if tok.text in constants:
                out.append(struct(kind = "str", text = constants[tok.text].value, line = tok.line, interp = False))
                continue
            if tok.text in declared:
                return struct(ok = False, error = _swiftpm_before_use_error(identity, tok.line, tok.text), tokens = [])
            return struct(ok = False, error = _swiftpm_unknown_use_error(identity, tok.line, tok.text), tokens = [])
        out.append(tok)
    return struct(ok = True, error = "", tokens = out)

def fold_manifest_constants(identity, tokens):
    """Fold a manifest's top-level string constants into its uses.

    Args:
        identity: The SwiftPM package identity, for messages.
        tokens: The lexed token list.

    Returns:
        `struct(ok, error, tokens)`: on success `tokens` holds the manifest
        without its folded declaration statements and with every folded use
        replaced; on failure `error` names the identity, `Package.swift`,
        the line and the offending identifier.
    """
    statements = swiftpm_split_statements(tokens)

    # Names only, so a use can name a constant declared later; values still
    # fold in file order and a use never sees a later value.
    declared = {}
    for seg in statements:
        decl = _swiftpm_declaration(seg)
        if decl.is_decl:
            declared[decl.name] = True
    constants = {}
    out = []
    for seg in statements:
        decl = _swiftpm_declaration(seg)
        if decl.is_decl:
            constants[decl.name] = struct(value = decl.value, line = decl.line)
            continue
        folded = _swiftpm_fold_statement(identity, seg, constants, declared)
        if not folded.ok:
            return struct(ok = False, error = folded.error, tokens = [])
        if folded.tokens:
            out.extend(folded.tokens)
            last = folded.tokens[len(folded.tokens) - 1]
            out.append(struct(kind = "nl", text = "\n", line = last.line, interp = False))
    return struct(ok = True, error = "", tokens = out)
