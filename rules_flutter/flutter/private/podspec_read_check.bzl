"""Fail-closed syntax checks for the static podspec reader (POD-12).

A `.podspec` that ends inside an unterminated string, regex, heredoc, block
comment, bracket, or block would otherwise be read as a truncated statement
and silently skip every later attribute and refusal.
"""

visibility(["//flutter/..."])

_CLOSERS = {")": "(", "]": "[", "}": "{"}

def podspec_syntax_error(plugin, podspec_path, line, what):
    """Format the diagnostic for syntax left open at the end of a podspec.

    Args:
        plugin: Plugin name string.
        podspec_path: Repository-relative podspec path string.
        line: 1-based line number where the construct opened.
        what: Description of the construct, e.g. `"an unterminated heredoc"`.

    Returns:
        Formatted error message string.
    """
    return (
        'Flutter plugin "%s": %s:%d has %s that is not closed before the end of the file, ' % (
            plugin,
            podspec_path,
            line,
            what,
        ) + "so rules_flutter cannot read the rest of the podspec. " +
        "Fix the podspec or replace the plugin's BUILD file with an overlay (flutter.plugin_overlays)."
    )

def _first_unclosed_bracket(tokens):
    """Return the earliest `(`, `[`, or `{` token never closed, or `None`."""
    stack = []
    for tok in tokens:
        if tok.kind != "op":
            continue
        if tok.text in ("(", "[", "{"):
            stack.append(tok)
        elif tok.text in _CLOSERS and stack and stack[-1].text == _CLOSERS[tok.text]:
            stack.pop()
    return stack[0] if stack else None

def checked_podspec_tokens(lexed, plugin, podspec_path):
    """Return the lexed tokens, failing on unterminated lexemes or unclosed brackets.

    Args:
        lexed: `struct(tokens, error)` from `lex_podspec_checked`.
        plugin: Plugin name string.
        podspec_path: Repository-relative podspec path string.

    Returns:
        The token list when the podspec is lexically complete.
    """
    if lexed.error != None:
        fail(podspec_syntax_error(plugin, podspec_path, lexed.error.line, lexed.error.what))
    open_tok = _first_unclosed_bracket(lexed.tokens)
    if open_tok != None:
        fail(podspec_syntax_error(plugin, podspec_path, open_tok.line, "an unclosed `%s` bracket" % open_tok.text))
    return lexed.tokens
