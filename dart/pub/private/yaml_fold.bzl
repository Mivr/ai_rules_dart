"""Folded continued scalars for the pubspec YAML reader.

Holds the quote-aware pass that folds a scalar started on a `key:` or `-`
line with its deeper continuation lines. Loaded by the block module.
"""

load(":yaml_chars.bzl", "BOM")
load(":yaml_flow.bzl", "parse_scalar")
load(":yaml_flow_scan.bzl", "flow_fold_lines", "flow_scan_start", "flow_scan_text")
load(":yaml_text.bzl", "bad_blank_index", "block_line_text", "find_block_colon", "flow_head_text", "indent_width", "is_block_mapping_start", "is_dash", "is_explicit_key_text", "is_question_entry", "is_quoted", "quoted_end_at", "quoted_scalar_rest", "record_unreadable")

def _block_quote_single(core, i, st):
    """Steps an index inside single quotes. Returns the next index.

    `''` is one escaped quote; any other `'` closes, as in
    `_flow_scan_quoted`.
    """
    if core[i] != "'":
        return i + 1
    if i + 1 < len(core) and core[i + 1] == "'":
        return i + 2
    st["single"] = False
    st["closed"] += 1
    return i + 1

def _block_quote_double(core, i, st):
    """Steps an index inside double quotes. Returns the next index.

    A backslash escapes the next character, as in `_flow_scan_quoted`.
    """
    if core[i] == "\\":
        st["escaped"] = True
    elif core[i] == '"':
        st["double"] = False
        st["closed"] += 1
    return i + 1

def _block_quote_plain(core, i, st):
    """Steps an index outside quotes. Returns the next index.

    A quote opens only where a scalar starts, as in `_flow_scan_open`, so
    an apostrophe in a plain scalar never opens one.
    """
    ch = core[i]
    if ch == "'" or ch == '"':
        if not st["plain"]:
            st["opened"] += 1
            if ch == "'":
                st["single"] = True
            else:
                st["double"] = True
    elif ch not in [" ", "\t"]:
        st["plain"] = True
    return i + 1

def _block_quote_char(core, i, st):
    """Steps one quote-counting character. Returns the next index."""
    if st["escaped"]:
        st["escaped"] = False
        return i + 1
    if st["single"]:
        return _block_quote_single(core, i, st)
    if st["double"]:
        return _block_quote_double(core, i, st)
    return _block_quote_plain(core, i, st)

def _block_head_quotes(core):
    """Counts the quotes `core` opens and closes. Returns (opened, closed)."""
    st = {"single": False, "double": False, "escaped": False, "plain": False, "opened": 0, "closed": 0}
    i = 0
    for _ in range(len(core) + 1):
        if i >= len(core):
            break
        i = _block_quote_char(core, i, st)
    return (st["opened"], st["closed"])

def _block_fail_text(lines, fail, head_idx, entry_text):
    """The display text for a block scalar problem at 0-based `fail`.

    A problem on the head line names the whole entry, as the quoted-scalar
    collection did; any other problem names its own line's text.
    """
    if fail == head_idx and entry_text:
        return entry_text
    _indent, text = block_line_text(lines[fail])
    if text != None:
        return text
    return lines[fail].strip()

def _block_dash_colon(rest):
    """Returns whether a `- ` continuation's `rest` carries a mapping colon.

    The check is quote-unaware on purpose: pub reads `- 'k: v'` after an
    open scalar as an entry line, rejecting the scalar, even though the
    colon sits inside quotes.
    """
    return ": " in rest or ":\t" in rest or rest.endswith(":")

def _flow_fresh_res():
    """A fresh per-line scan result for `flow_scan_text`."""
    return {"kept": [], "plain_comment": False, "pct_flag": False, "stopped": False, "skip": False}

def _block_fold_begin(head, core, scan):
    """Initializes one block fold. Returns the mutable fold dict.

    `head` carries the head line as {text, raw, idx, entry}: `text` is the
    same-line value after `key:` or `- `, comment-free as `block_line_text`
    strips it, or "" when the value starts on a later line; `raw` is the
    same slice with its comment intact, "" when pending; `idx` is the head's
    0-based line and `entry` the whole entry for head problems.

    The head scans through the quote-aware pass, and a head comment poisons
    the scalar when the head has content, ending it as pub ends it; a head
    comment with no content yet poisons nothing, as pub reads past it. Anchor
    and tag prefixes are stripped before scanning, so a quote after `&a `
    still opens, and re-attached before parsing, so `&a one` folding with
    `two` reads the anchor `one two`.
    """
    if core:
        prefix = head["text"][:len(head["text"]) - len(core)]
    elif head["text"]:
        prefix = head["text"] + " "
    else:
        prefix = ""
    if core:
        flow_scan_text(core, scan, _flow_fresh_res())
    poison = False
    if head["raw"] and core != "":
        probe = flow_scan_start()
        raw_res = _flow_fresh_res()
        flow_scan_text(head["raw"], probe, raw_res)
        poison = raw_res["plain_comment"] or (raw_res["stopped"] and not raw_res["pct_flag"])
    opened, closed = _block_head_quotes(core)
    head_complete = core != "" and core[:1] in ["'", '"'] and not scan["single"] and not scan["double"]
    items = [(head["idx"] + 1, core)] if core != "" else []
    return {"prefix": prefix, "poison": poison, "opened": opened, "closed": closed, "head_complete": head_complete, "seen": core != "", "items": items, "consumed": 0, "bom": False, "tab": False}

def _block_fold_quoted(raw, idx, scan, fold):
    """Takes a line inside open quotes at any indent. Returns the fail line, or -1.

    Inside quotes every line is content, as pub reads it, including
    markers, entries and `%` lines. But the line that closes the quote ends
    the scalar: text glued after its closing quote is a problem naming this
    line, as pub rejects it, and so is a `%` past the close, as pub rejects
    a directive there; a `#` comment past the close stays allowed, as the
    scan already stops before it and pub reads the scalar.
    """
    fold["items"].append((idx + 1, raw))
    quote = "'" if scan["single"] else '"'
    res = _flow_fresh_res()
    flow_scan_text(raw.lstrip(" \t"), scan, res)
    fold["consumed"] += 1
    fold["seen"] = True
    if res["pct_flag"]:
        return idx
    kept = "".join(res["kept"])
    end = quoted_end_at(kept, quote, 0)
    if end >= 0 and kept[end + 1:].strip() != "":
        return idx
    return -1

def _block_fold_decide(text, indent, fold, question_stops):
    """Decides whether a deeper plain line continues the scalar. Returns the action.

    A `:` line never continues a scalar: pub rejects it where an entry
    belongs, so ending the scalar fails closed downstream. A `?` marker
    without a colon folds into an open scalar except in a nested mapping,
    where it opens an explicit key; a `?` glued to text is a plain scalar
    start, as pub reads it, so only a true marker is decided here and any
    other `?` line falls through to the mapping checks below. A `- ` line
    without a colon folds into an open scalar at any depth, while one with
    a colon ends it. A mapping start or explicit key text ends it. A `[`,
    `{`, or `,` in a line past its first character is content, as the block
    scanner does not track it, so `te[st` and `a, b` fold, while `--- {a:b}`
    and `{a:b}` forms still break, as the leading-`[{` check preserves
    tracking.
    """
    if text == ":" or text[:2] == ": " or text[:2] == ":\t":
        return "break"
    if is_question_entry(text):
        if find_block_colon(text) >= 0 or not fold["seen"] or question_stops:
            return "break"
        return "take"
    if text[:1] == "?":
        # A `?` glued to text starts a plain scalar, as pub reads it, but
        # only past the key's column: at the key's column the line is a
        # key missing its colon, as pub rejects it there, so it breaks to
        # fail downstream.
        if indent <= fold["head_indent"]:
            return "break"

        # Deeper glued lines fall through to the mapping checks: a colon
        # form still breaks, as pub reads it as a nested mapping.

    if is_dash(text):
        if not fold["seen"] or text == "-":
            return "break"
        if _block_dash_colon(text[1:]):
            return "break"
        return "take"
    if is_block_mapping_start(text) or is_explicit_key_text(text):
        return "break"
    return "take"

def _block_fold_plain(raw, scan, fold, question_stops):
    """Decides one deeper plain line. Returns (action, kept).

    Checked against package:yaml 3.1.4 loader comment handling: a
    continuation line ending with a comment keeps the text before the `#`,
    as pub keeps it, so a second such line keeps its own text too, and any
    line after is unreadable, as pub rejects it. Once a comment has
    poisoned the scalar nothing else folds: a later line breaks, as pub
    rejects it, even a comment-only line, which the block walk then skips
    silently. A `#` only matters outside quotes, as the quote-aware scan
    decides, and a `#` without a preceding space ends the scalar only for
    an anonymous nested sequence or a space before it, as the block
    scanner decides. An indented `%` line is content once the scalar is
    open, as pub folds it, and a problem where pub rejects it otherwise.
    The take-or-break decision reads through its own step.
    """
    text = raw.lstrip(" \t")
    res = _flow_fresh_res()
    flow_scan_text(text, scan, res)
    if res["pct_flag"]:
        return ("take" if fold["seen"] else "fail", "")
    if fold["poison"]:
        return ("break", "")
    action = _block_fold_decide(text, indent_width(raw), fold, question_stops)
    if res["plain_comment"] or res["stopped"]:
        if action == "take" and res["plain_comment"]:
            kept = "".join(res["kept"]).strip(" \t")
            if kept != "":
                return ("take_kept", kept)
        return ("comment", "")
    return (action, "")

def _block_fold_blank(raw, idx, scan, fold):
    """Folds a blank continuation line. Returns True when it fails.

    A blank-looking line with a bad blank survives as raw: the fold reports
    it naming the line, as pub rejects it, instead of folding it as blank.
    """
    if raw.startswith("\t") and not (scan["single"] or scan["double"]):
        fold["tab"] = True
        return True
    if not fold["poison"]:
        if bad_blank_index(raw) >= 0:
            fold["items"].append((idx + 1, raw))
        else:
            fold["items"].append((idx + 1, ""))
    return False

def _block_fold_line(raw, idx, parent_indent, scan, fold, question_stops, state):
    """Processes one unfolding continuation line. Returns "more", "fail" or "stop"."""
    if indent_width(raw) <= parent_indent:
        return "stop"
    if raw.startswith("\t"):
        fold["tab"] = True
        return "fail"
    if BOM in raw:
        state.problems.append("byte-order mark at line %d is not supported" % (idx + 1))
        fold["bom"] = True
        return "fail"
    action, kept = _block_fold_plain(raw, scan, fold, question_stops)
    if action == "take":
        fold["items"].append((idx + 1, raw))
        fold["consumed"] += 1
        fold["seen"] = True
        return "more"
    if action == "take_kept":
        fold["items"].append((idx + 1, kept))
        fold["consumed"] += 1
        fold["seen"] = True
        fold["poison"] = True
        return "more"
    if action == "comment":
        if fold["seen"]:
            fold["poison"] = True
        return "more"
    if action == "fail":
        return "fail"
    return "stop"

def _block_fold_gather(lines, start, parent_indent, scan, fold, question_stops, state):
    """Gathers a scalar's continuation lines. Returns (next index, fail).

    `fail` is the 0-based failing line, or -1: a line starting with a tab is
    a problem naming the line, as pub rejects it, while a line with spaces
    before its tab folds, as pub folds it. Text glued after the closing
    quote's line is a problem naming that line too, as pub rejects it. A byte-order mark outside
    quotes is an always-on problem naming its own line, as pub rejects it;
    inside quotes every line stays content.
    """
    idx = start
    fail = -1
    for _ in range(len(lines) + 1):
        if idx >= len(lines):
            break
        raw = lines[idx]
        if raw.strip() == "":
            if _block_fold_blank(raw, idx, scan, fold):
                fail = idx
                break
            idx += 1
            continue
        if scan["single"] or scan["double"]:
            fail = _block_fold_quoted(raw, idx, scan, fold)
            if fail >= 0:
                break
            idx += 1
            continue
        outcome = _block_fold_line(raw, idx, parent_indent, scan, fold, question_stops, state)
        if outcome == "fail":
            fail = idx
            break
        if outcome == "stop":
            break
        idx += 1
    return (idx, fail)

def _glued_comment_tail(core):
    """Returns whether `core` closes a quote with only a `#` comment after it.

    A `#` comment glued past the closing quote ends the head, as pub ends
    the scalar there; any other trailing text fails downstream, as pub
    rejects it, and a head that opens with no closing quote fails too.
    """
    rest = quoted_scalar_rest(core)
    return rest != None and rest[:1] == "#"

def _block_fold_percent_item(item):
    """Returns whether `item` is an indented `%` line that reads as content.

    The scan flags a `%` outside quotes and plain scalars, but an indented
    `%` continuation past an open scalar is content, as pub folds it: only
    a column-0 `%` is a directive. The gatherer took the raw line, so the
    fold splices its kept text back in.
    """
    return item[1][:1] in [" ", "\t"] and item[1].lstrip(" \t").startswith("%")

def _block_fold_percent_kept(raw):
    """Returns the kept text of an indented `%` continuation, as pub folds it.

    The scalar is open past the head, so the scan runs seeded open: the
    `%` is content, while a `#` after separation still comments the line,
    as pub reads `  %foo # c` as `%foo`.
    """
    scan = flow_scan_start()
    scan["plain"] = True
    res = _flow_fresh_res()
    flow_scan_text(raw.lstrip(" \t"), scan, res)
    return "".join(res["kept"]).rstrip()

def _splice_join(out, kept):
    """Joins one kept line onto `out` with one space, as the fold joins them.

    A flagged `%` line never leaves quotes open, so the join past one is
    always the space join; the blank join stays, as blank runs fold to it.
    """
    if out != "" and not out.endswith("\n"):
        return out + " " + kept
    return out + kept

def _block_fold_spliced(items):
    """Folds `items` around indented `%` lines. Returns (folded, problem).

    Each run between the flagged lines folds through a fresh scan, as the
    single fold would fold it, and the flagged lines splice their kept
    text back in. A problem in any run fails, as the single fold fails it.
    """
    out = ""
    run = []
    first = True
    for item in items:
        if _block_fold_percent_item(item):
            folded, problem = flow_fold_lines(run, flow_scan_start(), first)
            if problem != None:
                return "", problem
            if folded != "":
                out = _splice_join(out, folded)
            out = _splice_join(out, _block_fold_percent_kept(item[1]))
            run = []
            first = False
        else:
            run.append(item)
    folded, problem = flow_fold_lines(run, flow_scan_start(), first)
    if problem != None:
        return "", problem
    if folded != "":
        out = _splice_join(out, folded)
    return out, None

def _block_fold_finish(fold, core, lines, idx, head, anchors, state, scan):
    """Folds and validates the gathered lines. Returns (value, next, read).

    When read is False, value is None and a problem names the failing line.
    Text after a same-line closing quote, a second quoted scalar on the head
    line, and a continuation of an alias are problems naming the head line,
    as pub rejects them; a `#` comment glued past the closing quote ends
    the head, as pub ends the scalar there.
    """
    items = fold["items"]
    for _ in range(len(items) + 1):
        if not items or items[-1][1] != "":
            break
        items.pop()
    folded, problem = flow_fold_lines(items, flow_scan_start(), True)
    if problem != None and problem[0] == "directive":
        # An indented `%` continuation past an open scalar reads, as pub
        # folds it: splice its kept text back into the fold. Any other
        # flagged line fails below, as pub rejects it there.
        spliced, spliced_problem = _block_fold_spliced(items)
        if spliced_problem == None:
            folded, problem = spliced, None
    if problem != None:
        line = problem[1] - 1
        if problem[0] == "control":
            state.problems.append("control character at line %d is not supported" % problem[1])
        else:
            record_unreadable(state, line, _block_fail_text(lines, line, head["idx"], head["entry"]))
        return None, idx, False
    if scan["single"] or scan["double"]:
        record_unreadable(state, head["idx"], head["entry"] or head["text"])
        return None, idx, False
    quoted_ok = is_quoted(core) or _glued_comment_tail(core)
    if fold["head_complete"] and (fold["opened"] != 1 or fold["closed"] != 1 or fold["consumed"] > 0 or not quoted_ok):
        record_unreadable(state, head["idx"], head["entry"] or head["text"])
        return None, idx, False
    if core[:1] == "*" and fold["consumed"] > 0:
        record_unreadable(state, head["idx"], head["entry"] or head["text"])
        return None, idx, False
    return parse_scalar(fold["prefix"] + folded, anchors, state, head["idx"] + 1, fold["prefix"] == ""), idx, True

def block_fold_scalar(lines, start, parent_indent, head, question_stops, anchors, state):
    """Folds a block scalar head with its continuation lines. Returns (value, next index, read).

    `head` carries the head line as {text, raw, idx, entry}; see
    `_block_fold_begin`. The head folds with its deeper lines through the
    same quote-aware pass the flow fold uses (`flow_scan_text` with
    `flow_fold_lines`), so a break folds to one space, blanks fold
    quote-aware, and comments and `%` behave as pub reads them. A line
    starting with a tab is a problem naming the line, while a deeper line
    with spaces before its tab folds, as pub reads them.


    Args:
      lines: the document lines.
      start: the 0-based index of the first continuation line.
      parent_indent: the column continuations must be nested beyond.
      head: the head line as {text, raw, idx, entry}.
      question_stops: whether a `?` line ends the scalar instead of folding into it.
      anchors: the anchor names bound so far.
      state: the parse state collecting problems.

    Returns:
      The (value, next index, read) triple: the folded value, the 0-based index to
      resume at, and whether a value was read.
    """
    core = flow_head_text(head["text"])
    if core[:1] in ["[", "{"]:
        # A flow collection closed on its own line reads within that line,
        # as before: deeper lines are placed downstream, and a broken flow
        # stays an unreadable flow value naming the line.
        return parse_scalar(head["text"], anchors, state, head["idx"] + 1), start, True
    scan = flow_scan_start()
    fold = _block_fold_begin(head, core, scan)

    # The oracle rule for a `?`-glued line compares against the key's
    # column, which is the parent indent: the head line itself may be the
    # first continuation (a pending key passes its value line as the
    # head), so the head's own width would misread a deeper line as
    # sitting at the head's column. The gatherer stops lines at or above
    # the parent column first; the decider keeps the comparison so a
    # caller that skips that check still fails closed.
    fold["head_indent"] = parent_indent
    idx, fail = _block_fold_gather(lines, start, parent_indent, scan, fold, question_stops, state)
    if fail >= 0:
        if not fold["bom"]:
            if fold["tab"]:
                state.problems.append("tab indentation at line %d is not supported" % (fail + 1))
            else:
                record_unreadable(state, fail, _block_fail_text(lines, fail, head["idx"], head["entry"]))
        return None, idx + 1, False
    return _block_fold_finish(fold, core, lines, idx, head, anchors, state, scan)
