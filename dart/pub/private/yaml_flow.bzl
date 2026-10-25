"""Flow collections for the pubspec YAML reader.

Holds `[...]` and `{...}` parsing, the quote-aware scan and fold of
multi-line flow text, and the scalar dispatcher, which reads a flow value
where one opens. Loaded by the fold, block and document modules and by the
`yaml_subset.bzl` entry point.
"""

load(":yaml_scalar.bzl", "OPEN_ANCHOR", "alias_name_end", "apply_child_collection_tag", "apply_key_tag", "apply_tag", "drop_tag_value", "flow_quoted_end", "flow_value_entry_problem", "is_flow_key_entry", "parse_alias", "parse_nonflow", "record_prefix_problems", "strip_value_prefix")
load(":yaml_text.bzl", "bad_blank_index", "clone", "dict_key", "is_dash", "is_flow_seq_entry", "is_flow_value_entry", "is_question_entry", "quote_track", "split_key_value")

_FLOW_SPACE = " \t\n\r"

def _flow_close_step(stack, s, i, frame, anchors, state, line):
    """Pops a closed flow frame. Returns (done, value, next_i).

    A frame anchor binds the closed collection, replacing any older
    binding, and a frame tag reads it as a pending tag reads an attached
    child, as pub reads them.
    """
    stack.pop()
    value = frame["value"]
    if frame["tag"] != None:
        value = apply_child_collection_tag(frame["tag"], value, state, line)
    if frame["anchor"] != None:
        anchors[frame["anchor"]] = clone(value)
    i += 1
    if not stack:
        rest = s[i:].lstrip(_FLOW_SPACE)
        if rest == "" or rest.startswith("#"):
            return True, value, i
        return True, None, i
    _flow_add(stack[-1], value, state, line)
    return False, None, i

def _flow_key_step(s, i, frame, anchors, state, line):
    """Reads one flow map key up to its colon. Returns (next_i, ok).

    A key token that runs to `,` or the close, as an anchor or tag word with
    a glued colon does, reads with a null value, as pub reads it; a colon
    glued into a plain key stays content too, while a spaced colon later
    still pairs, and a quoted key pairs at its glued colon, as pub reads
    them.
    """
    tok_start = i
    token, i = _flow_token(s, i, [":", frame["close"], ","])
    for _ in range(len(s) + 1):
        # A colon glued into a plain key stays content, as pub scans it, so
        # the key runs on to a separating colon, a comma or the close; a
        # quoted key pairs at once, as pub reads `"a":1` as one pair.
        if s[i:i + 1] != ":" or s[i + 1:i + 2] in [" ", "\t", "\n", "\r", ",", frame["close"]]:
            break
        if len(token) > 1 and token[:1] in ["'", '"'] and token[-1:] == token[:1]:
            break
        more, i = _flow_token(s, i + 1, [":", frame["close"], ","])
        if more == "":
            break
        token += ":" + more
    if token == "" or not _flow_scalar_ok(token):
        return i, False
    if is_flow_key_entry(token, s[tok_start:i], s[i:i + 1]):
        state.problems.append("block entry inside flow at line %d is not supported" % line)
        frame["key"] = dict_key(None)
        i = _skip_flow_space(s, i)
        if i >= len(s) or s[i] != ":":
            _flow_add(frame, None, state, line)
            return i, True
        frame["state"] = "value"
        return i + 1, True
    frame["key"] = _flow_key_value(token, anchors, state, line)
    i = _skip_flow_space(s, i)
    if i >= len(s) or s[i] != ":":
        _flow_add(frame, None, state, line)
        return i, True
    frame["state"] = "value"
    return i + 1, True

def _flow_item_step(s, i, frame, anchors, stack, state, line):
    """Reads one nested collection or scalar flow token. Returns (next_i, ok).

    A map value that is itself a pair fails, as pub expects `,` or `}` after
    a flow mapping value; a pair as a sequence item still reads, as pub
    reads it.
    """
    if s[i] in ["[", "{"]:
        stack.append(_flow_frame(s[i]))
        return i + 1, True
    if s[i] in ["&", "!"]:
        nested, next_i = _flow_prefixed_collection(s, i, anchors, stack, state, line)
        if nested:
            return next_i, True
    token, next_i = _flow_token(s, i, [",", frame["close"]])
    if token == "" or not _flow_scalar_ok(token):
        return next_i, False
    if frame["kind"] == "map":
        _ianchor, _itag, irest, _ibad = strip_value_prefix(token)
        entry = is_flow_value_entry(irest)
        if not entry:
            _vkey, _vvalue, nested = _flow_pair_split(irest)
            if nested:
                state.problems.append("While parsing a flow mapping, expected ',' or '}' at line %d" % line)
                _flow_add(frame, None, state, line)
                return next_i, True
    else:
        entry = is_flow_seq_entry(token)
    if entry:
        state.problems.append("block entry inside flow at line %d is not supported" % line)
        _flow_add(frame, None, state, line)
        return next_i, True
    _flow_add(frame, _flow_scalar_value(token, anchors, state, line), state, line)
    return next_i, True

def _flow_comment_end(s, i):
    """Returns the index after the `#` comment starting at `s[i]`.

    A `#` where a flow token starts is a comment running to the end of the
    line, as pub scans it, even glued to `[`, `{` or `,`; a `#` glued into
    a token stays content, as the tokenizer never stops for it. The flow
    left open fails downstream as an unclosed one does.
    """
    nl = s.find("\n", i)
    return len(s) if nl < 0 else nl + 1

def _flow_after_comma(frame, ch):
    """Reads the `,` after a completed flow value. Returns whether one follows.

    After the comma a mapping reads a key and a sequence reads an item.
    """
    if ch != ",":
        return False
    frame["state"] = "key" if frame["kind"] == "map" else "item"
    return True

def parse_flow(text, anchors, parse_state, line):
    """Parses the flow collection that starts `text`, or returns None.

    A `#` where a token starts opens a comment to the end of the line, as
    pub scans it, even glued to an opener or a comma. A flow frame is a dict {kind, close, value, state, key}. The frame's
    `state` is "item" or "value" where a value may start, "after" once a
    value is complete, and "key" where a map key is read. Duplicate map keys
    are recorded on `parse_state` with `line`.
    """
    s = text.strip()
    stack = [_flow_frame(s[:1])]
    i = 1
    for _ in range(len(s) + 1):
        i = _skip_flow_space(s, i)
        if i >= len(s):
            return None
        if s[i] == "#":
            i = _flow_comment_end(s, i)
            continue
        frame = stack[-1]
        ch = s[i]
        state = frame["state"]

        if ch == frame["close"] and state != "value":
            done, value, i = _flow_close_step(stack, s, i, frame, anchors, parse_state, line)
            if done:
                return value
            continue

        if state == "after":
            if not _flow_after_comma(frame, ch):
                return None
            i += 1
            continue

        if state == "key":
            i, ok = _flow_key_step(s, i, frame, anchors, parse_state, line)
            if not ok:
                return None
            continue

        i, ok = _flow_item_step(s, i, frame, anchors, stack, parse_state, line)
        if not ok:
            return None
    return None

def _flow_frame(opener, anchor = None, tag = None):
    """A flow frame, optionally carrying an anchor and tag for its collection."""
    if opener == "[":
        return {"kind": "seq", "close": "]", "value": [], "state": "item", "key": None, "anchor": anchor, "tag": tag}
    return {"kind": "map", "close": "}", "value": {}, "state": "key", "key": None, "anchor": anchor, "tag": tag}

def _flow_add(frame, value, parse_state, line):
    """Stores a completed value and expects `,` or the close.

    A duplicate map key is recorded on the parse state instead of being
    resolved silently; the first value wins.
    """
    if frame["kind"] == "seq":
        frame["value"].append(value)
    elif frame["key"] in frame["value"]:
        parse_state.problems.append("duplicate key %r in flow mapping at line %d" % (frame["key"], line))
    else:
        frame["value"][frame["key"]] = value
    frame["state"] = "after"

def _flow_block_scalar_problem(rest, state, line):
    """Records a block scalar header where a flow value starts. Returns True when one fails.

    A `|` or `>` where a flow item, pair value or key starts fails, as pub
    rejects a block scalar there; the anchor and tag prefixes are already
    stripped, as pub still rejects it under them. A `|` or `>` past the
    first character stays content, as pub reads it.
    """
    if rest[:1] in ["|", ">"]:
        state.problems.append("block scalar inside flow at line %d is not supported" % line)
        return True
    return False

def _flow_alias_token(token, anchors, state, line):
    """Value of a flow item token starting with `*`.

    A glued colon or hash joins the alias name, as pub scans it, so only a
    name without a colon followed by a spaced colon pairs with a value, as
    pub reads it.
    """
    end = alias_name_end(token)
    if ":" not in token[1:end] and token[end:].strip().startswith(":"):
        key_text, value_text, _ok = _flow_pair_split(token)
        return _flow_pair(key_text, value_text, None, None, anchors, state, line)
    return parse_alias(token, anchors, state, line)

def _flow_lone_colon_pair(tag, anchor, rest, anchors, state, line):
    """Value of a flow item where the value starts with `:`.

    A colon where the value starts pairs the anchor or tag on its own with
    the value, as pub reads it. A problem still reads `None`, so parsing
    continues past it.
    """
    key = drop_tag_value(tag, line, state) if tag != None else None
    if anchor != None:
        anchors[anchor] = clone(key)
    value_text = rest[1:].strip()
    if value_text == "" or flow_value_entry_problem(value_text, state, line):
        value = None
    else:
        value = _flow_atom(value_text, anchors, state, line)
    pair = {}
    pair[dict_key(key)] = value
    return pair

def _flow_scalar_value(token, anchors, state, line):
    """Value of a flow item token with alias, anchor or tag prefixes.

    A token starting with `*` is always an alias: a glued colon or hash
    joins the alias name, as pub scans it, so only a name without a colon
    followed by a spaced colon pairs with a value, as pub reads it. Any
    other token strips one anchor and tag first: an alias after them is a
    problem naming the line, as pub rejects it, as is a `- ` entry or `?`
    marker after them, while a `-: ` pair reads on; a colon where the value
    starts pairs the anchor or tag on its own with the value, as pub reads
    it; any other `:` pair reads with the tag on a string key and the anchor
    on the key, as pub reads them. A problem still reads `None`, so parsing
    continues past it.
    """
    if token.startswith("*"):
        return _flow_alias_token(token, anchors, state, line)
    anchor, tag, rest, bad = strip_value_prefix(token)
    record_prefix_problems(bad, state, line)
    if anchor != None and rest.startswith("*"):
        state.problems.append("alias after anchor at line %d is not supported" % line)
        anchors[anchor] = None
        return None
    if tag != None and rest.startswith("*"):
        state.problems.append("alias after tag at line %d is not supported" % line)
        return None
    if (anchor != None or tag != None) and (is_dash(rest) or is_question_entry(rest)):
        state.problems.append("block entry inside flow at line %d is not supported" % line)
        if anchor != None:
            anchors[anchor] = None
        return None
    if _flow_block_scalar_problem(rest, state, line):
        if anchor != None:
            anchors[anchor] = None
        return None
    if rest.startswith(":"):
        return _flow_lone_colon_pair(tag, anchor, rest, anchors, state, line)
    if rest == "":
        return _flow_bare_affix(anchor, tag, state, line, anchors)
    key_text, value_text, is_pair = _flow_pair_split(rest)
    if is_pair:
        return _flow_pair(key_text, value_text, anchor, tag, anchors, state, line)
    value = parse_nonflow(rest, anchors, state, line)
    if tag != None:
        value = apply_tag(tag, rest, value, state, line)
    if anchor != None:
        anchors[anchor] = clone(value)
    return value

def _flow_bare_affix(anchor, tag, state, line, anchors):
    """Value of a flow item that is only an anchor and/or tag.

    With no node the anchor binds `None` and the tag reads as a dropped
    pending tag does, as pub reads them.
    """
    value = drop_tag_value(tag, line, state)
    if anchor != None:
        anchors[anchor] = clone(value)
    return value

def _flow_atom(text, anchors, state, line):
    """Value of a flow pair key or value, which nests no further pair.

    An alias after an anchor or tag is a problem naming the line, as pub
    rejects it, and a pair inside is one too, as pub rejects that as well; a
    bare anchor or tag reads as it does on its own. A problem still reads
    `None`, so parsing continues past it.
    """
    if text.startswith("*"):
        return parse_alias(text, anchors, state, line)
    anchor, tag, rest, bad = strip_value_prefix(text)
    record_prefix_problems(bad, state, line)
    if anchor != None and rest.startswith("*"):
        state.problems.append("alias after anchor at line %d is not supported" % line)
        anchors[anchor] = None
        return None
    if tag != None and rest.startswith("*"):
        state.problems.append("alias after tag at line %d is not supported" % line)
        return None
    if rest == "":
        return _flow_bare_affix(anchor, tag, state, line, anchors)
    _key_text, _value_text, is_pair = _flow_pair_split(rest)
    if is_pair:
        state.problems.append("mapping value at line %d is not supported" % line)
        if anchor != None:
            anchors[anchor] = None
        return None
    if _flow_block_scalar_problem(rest, state, line):
        if anchor != None:
            anchors[anchor] = None
        return None
    value = parse_nonflow(rest, anchors, state, line)
    if tag != None:
        value = apply_tag(tag, rest, value, state, line)
    if anchor != None:
        anchors[anchor] = clone(value)
    return value

def _flow_pair(key_text, value_text, anchor, tag, anchors, state, line):
    """Value of a flow pair after alias, anchor or tag prefixes.

    The key and value nest no further pair, as pub rejects that; the tag
    reads a string key as the same-line tags do and a key of any other type
    drops it, and the anchor binds the key, as pub reads them.
    """
    key = _flow_atom(key_text, anchors, state, line)
    if flow_value_entry_problem(value_text, state, line):
        value = None
    else:
        value = _flow_atom(value_text, anchors, state, line)
    if tag != None:
        key = apply_key_tag(tag, key, key_text, state, line)
    if anchor != None:
        anchors[anchor] = clone(key)
    pair = {}
    pair[dict_key(key)] = value
    return pair

def _flow_key_value(token, anchors, state, line):
    """Value of a flow map key token with alias, anchor or tag prefixes.

    A glued colon or hash joins an alias, anchor or tag word, as pub scans
    it, so a bare word reads the key after it and a bare anchor reads a null
    key, as pub reads them. An alias after an anchor or tag is a problem
    naming the line, as pub rejects it. A tag reads a string key as the
    same-line tags do and drops off a key of any other type, and an anchor
    binds the key, as pub reads them. A problem still reads `None`, so
    parsing continues past it.
    """
    if token.startswith("*"):
        return parse_alias(token, anchors, state, line)
    anchor, tag, rest, bad = strip_value_prefix(token)
    record_prefix_problems(bad, state, line)
    if anchor != None and rest.startswith("*"):
        state.problems.append("alias after anchor at line %d is not supported" % line)
        anchors[anchor] = None
        return None
    if tag != None and rest.startswith("*"):
        state.problems.append("alias after tag at line %d is not supported" % line)
        return None
    if rest == "":
        key = drop_tag_value(tag, line, state) if tag != None else None
        if anchor != None:
            anchors[anchor] = clone(key)
        return dict_key(key)
    if _flow_block_scalar_problem(rest, state, line):
        if anchor != None:
            anchors[anchor] = None
        return dict_key(None)
    key = parse_nonflow(rest, anchors, state, line)
    if tag != None:
        key = apply_key_tag(tag, key, rest, state, line)
    if anchor != None:
        anchors[anchor] = clone(key)
    return dict_key(key)

def _flow_prefix_word(word, anchor, tag, bad):
    """Reads an anchor or tag word before a flow collection. Returns (anchor, tag, bad).

    An empty anchor, a repeated anchor and a repeated tag are the first
    rejected shape, as pub reads at most one of each.
    """
    if word.startswith("&"):
        if word == "&":
            if bad == "":
                bad = "empty-anchor"
        elif anchor != None:
            if bad == "":
                bad = "repeat-anchor"
        else:
            anchor = word[1:]
    elif tag != None:
        if bad == "":
            bad = "repeat-tag"
    else:
        tag = word
    return (anchor, tag, bad)

def _flow_prefixed_collection(s, i, anchors, stack, state, line):
    """Pushes the flow collection an anchor or tag prefix opens. Returns (pushed, next_i).

    Words run to whitespace or `,[]{}`, as alias names do, so a glued colon
    or hash stays in the word. The anchor marks the collection open, so an
    alias inside it fails closed as a self-reference, as pub rejects it.
    When no `[` or `{` follows the words the token reads as a scalar
    instead, and the caller tokenizes it.
    """
    anchor = None
    tag = None
    bad = ""
    j = i
    for _ in range(5):
        end = j + alias_name_end(s[j:])
        word = s[j:end]
        if not word.startswith("&") and not word.startswith("!"):
            break
        anchor, tag, bad = _flow_prefix_word(word, anchor, tag, bad)
        j = end + len(s[end:]) - len(s[end:].lstrip(" \t"))
    if j >= len(s) or s[j] not in ["[", "{"]:
        return False, i
    record_prefix_problems(bad, state, line)
    if anchor != None:
        anchors[anchor] = OPEN_ANCHOR
    stack.append(_flow_frame(s[j], anchor, tag))
    return True, j + 1

def _flow_scalar_ok(token):
    """Returns whether a flow scalar token is shaped as pub reads it.

    A token starting with `%` is a directive pub rejects anywhere but a
    line start. A token starting with a quote must be exactly one quoted
    scalar: text glued after its closing quote (`"a" "b"`) is a second value
    pub rejects, while a colon glued after it (`"a":1`) is a pair the token
    splitter handles. Anything else reads as one scalar here.
    """
    if token == "" or token[:1] == "%":
        return False
    if token[:1] not in ["'", '"']:
        return True
    end = flow_quoted_end(token)
    if end < 0:
        return False
    rest = token[end + 1:].strip()
    return rest == "" or rest.startswith(":")

def _flow_pair_split(token):
    """Splits a flow `key: value` token. Returns (key, value, found).

    Besides a top-level `: ` split, a quoted key followed at once by a colon
    (`"a":1`) is one pair, as pub reads it; a colon glued into a plain
    scalar (`a:b`) is not.
    """
    key_text, value_text, ok = split_key_value(token)
    if ok:
        return key_text, value_text, True
    if len(token) < 3 or token[:1] not in ["'", '"']:
        return "", "", False
    end = flow_quoted_end(token)
    if end < 0:
        return "", "", False
    rest = token[end + 1:].strip()
    if not rest.startswith(":"):
        return "", "", False
    return token[:end + 1], rest[1:].strip(), True

def _flow_token(s, start, stops):
    """Reads one flow token from `start` up to a stop character.

    Quotes are tracked so that stop characters inside them do not end the
    token: a quote opens only where the scalar starts, so an apostrophe in a
    plain scalar such as `don't` stays content, and `''` inside single
    quotes is one escaped quote, as pub reads it. An alias, anchor or tag
    word runs to whitespace or `,[]{}`, as pub scans it, so a glued colon or
    hash stays in the word instead of ending the token. Returns (stripped token,
    index of the stop character).
    """
    i = start
    if s[i:i + 1] in ["*", "&", "!"]:
        i = start + alias_name_end(s[start:])
    st = {"single": False, "double": False, "escaped": False, "at_start": True, "affix": False}
    for _ in range(len(s) + 1):
        if i >= len(s):
            break
        ch = s[i]
        if st["single"] and ch == "'" and s[i + 1:i + 2] == "'":
            i += 2
            continue
        if quote_track(ch, st):
            i += 1
            continue
        if not st["single"] and not st["double"] and ch in stops:
            break
        if ch not in [" ", "\t"]:
            st["at_start"] = False
        i += 1
    return s[start:i].strip(), i

def _skip_flow_space(s, i):
    return i + len(s[i:]) - len(s[i:].lstrip(_FLOW_SPACE))

def parse_scalar(text, anchors, state, line, record_prefix = True):
    """Parses the text after a key, dash or flow separator into a value.

    Leading `&anchor` and `!tag` words are consumed first, split on spaces
    and tabs, at most one of each in either order: an empty anchor, a second
    anchor or tag word, and an alias as the anchored or tagged value are
    problems naming the line, as pub rejects them. An anchor records a
    shallow copy of the value under its name once the value closes; while a
    same-line flow collection reads, the anchor marks it open so an alias
    inside it fails closed. A flow collection that cannot be read is a
    strict-lines problem; lenient parsing reads it as None. The fold sets
    `record_prefix` False for a head its caller already split, so one shape
    reads as one problem.
    """
    s = text.strip()
    if s == "":
        return None
    anchor, tag, s, bad = strip_value_prefix(s)
    if record_prefix:
        record_prefix_problems(bad, state, line)
    if anchor != None and s.startswith("*"):
        state.problems.append("alias after anchor at line %d is not supported" % line)
        return None
    if tag != None and s.startswith("*"):
        state.problems.append("alias after tag at line %d is not supported" % line)
        return None
    if s == ":" or (s.startswith(":") and len(s) > 1 and s[1] in [" ", "\t", "\r"]):
        # A mapping value indicator where a value starts is rejected, as pub
        # rejects it; a colon glued to content stays a plain scalar.
        state.problems.append("mapping value at line %d is not supported" % line)
        return None
    if s[:1] in ["]", "}", ","]:
        # A flow-closing indicator where a block value starts is rejected, as
        # pub rejects it; past the first character it stays content, as pub
        # reads it.
        state.problems.append("flow indicator at line %d is not supported" % line)
        return None

    if s[:1] in ["[", "{"]:
        if anchor != None:
            anchors[anchor] = OPEN_ANCHOR
        value = parse_flow(s, anchors, state, line)
        if value == None and state.strict_lines:
            state.problems.append("unreadable flow value at line %d: %r" % (line, s))
    else:
        value = parse_nonflow(s, anchors, state, line)
    if tag != None:
        value = apply_tag(tag, s, value, state, line)
    if anchor:
        anchors[anchor] = clone(value)
    return value

def flow_scan_start():
    """A fresh quote-aware scan state for one folded flow."""
    return {"single": False, "double": False, "escaped": False, "plain": False, "have": False, "depth": 0}

def _flow_scan_sep(scan):
    """A separator ends any plain scalar and opens a fresh value slot."""
    scan["plain"] = False
    scan["have"] = False

def _flow_scan_quoted(ch, nxt, scan, res):
    """Scans one character inside a quoted scalar, updating `scan` and `res`.

    `''` inside single quotes is one escaped quote; a backslash escapes the
    next character in double quotes, across lines too. Anything else,
    including `#`, brackets and the other quote kind, is content.
    """
    if scan["single"]:
        if ch == "'":
            if nxt == "'":
                res["kept"].append(ch)
                res["kept"].append(nxt)
                res["skip"] = True
            else:
                scan["single"] = False
                scan["have"] = True
                res["kept"].append(ch)
        else:
            res["kept"].append(ch)
    elif ch == "\\":
        scan["escaped"] = True
        res["kept"].append(ch)
    elif ch == '"':
        scan["double"] = False
        scan["have"] = True
        res["kept"].append(ch)
    else:
        res["kept"].append(ch)

def _flow_scan_hash(ch, prev, scan, res):
    """Handles `#` outside quotes: a comment, or content pub reads as one.

    Between tokens a `#` starts a comment that runs to the end of the line,
    whether the value before it is complete or not: pub reads `["red" # c,
    green]` as two values and only fails where the comment swallows a token
    the flow needs. In a plain scalar `#` is a comment after separation (or
    at the line start) and content otherwise, so an apostrophe line such as
    `don't` never opens a quote. Past the closing bracket a `#` after
    separation is a trailing comment.
    """
    if scan["plain"]:
        if prev in [" ", "\t"]:
            res["plain_comment"] = True
            res["stopped"] = True
        else:
            res["kept"].append(ch)
    else:
        res["stopped"] = True

def _flow_scan_struct(ch, nxt, scan, res):
    """Scans one bracket, separator or value character outside quotes."""
    if ch in ["[", "{"]:
        scan["depth"] += 1
        _flow_scan_sep(scan)
    elif ch in ["]", "}"]:
        if scan["depth"] > 0:
            scan["depth"] -= 1
        _flow_scan_sep(scan)
        scan["have"] = True
    elif ch == ",":
        _flow_scan_sep(scan)
    elif ch == ":" and (nxt in [" ", "\t"] or nxt == ""):
        _flow_scan_sep(scan)
    else:
        scan["plain"] = True
        scan["have"] = True
    res["kept"].append(ch)

def _flow_scan_open(ch, nxt, prev, scan, res):
    """Scans one character where a scalar may start. Returns the new previous character."""
    if ch == "'" and not scan["plain"]:
        scan["single"] = True
        res["kept"].append(ch)
    elif ch == '"' and not scan["plain"]:
        scan["double"] = True
        res["kept"].append(ch)
    elif ch == "#":
        _flow_scan_hash(ch, prev, scan, res)
        if res["stopped"]:
            return prev
    elif ch == "%" and not scan["plain"]:
        res["pct_flag"] = True
        res["stopped"] = True
        return prev
    elif ch in [" ", "\t"]:
        res["kept"].append(ch)
    else:
        _flow_scan_struct(ch, nxt, scan, res)
    return ch

def flow_scan_text(text, scan, res):
    """Scans one fold line, updating `scan` and collecting into `res`.

    `res` holds the kept characters and the line flags: `plain_comment`
    when a comment starts inside a plain scalar, `pct_flag` on a `%`
    outside quotes and plain scalars. A quote opens only where a scalar
    starts. Scanning stops at a comment or a flag; the caller fails closed
    on the flags.
    """
    prev = " "
    for i in range(len(text) + 1):
        if i >= len(text) or res["stopped"]:
            break
        ch = text[i]
        if res["skip"]:
            res["skip"] = False
            prev = ch
            continue
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if scan["escaped"]:
            scan["escaped"] = False
            res["kept"].append(ch)
            prev = ch
        elif scan["single"] or scan["double"]:
            _flow_scan_quoted(ch, nxt, scan, res)
            prev = ch
        else:
            prev = _flow_scan_open(ch, nxt, prev, scan, res)

def _flow_fold_join(out, kept, cont):
    """Joins one kept line onto `out`: directly after a backslash continuation, else with one space."""
    if cont:
        return out + kept
    if out != "" and not out.endswith("\n"):
        return out + " " + kept
    return out + kept

def _flow_fold_backslash(out, kept, trailing, scan):
    """Folds a quoted line's end into `out`. Returns (out, mode).

    `kept` is the rstripped scanned line and `trailing` its trailing
    whitespace. A `\\` at the line's end inside double quotes continues the
    scalar: the backslash is dropped and the next line joins directly.
    Elsewhere a backslash is an ordinary character, as pub keeps it, and
    the break folds to one space. A `\\` with trailing space stays literal
    in both, as pub keeps it, and the next line joins with one space.
    `mode` is "direct" or "space".
    """
    if not scan["single"] and not scan["double"]:
        return out, "space"
    bs = 0
    for _ in range(len(kept) + 1):
        if bs < len(kept) and kept[len(kept) - 1 - bs] == "\\":
            bs += 1
        else:
            break
    if bs == 0 or bs % 2 == 0:
        return out, "space"
    if trailing != "":
        if scan["double"]:
            return out[:len(out) - 1] + trailing[:1], "space"
        return out, "space"
    if scan["double"]:
        scan["escaped"] = False
        return out[:len(out) - 1], "direct"
    return out, "space"

def _flow_fold_blank(scan, st):
    """Folds one blank line into `st`, ending any backslash continuation."""
    if st["cont"]:
        st["cont"] = False
        st["out"] += "\n"
        return
    if scan["single"] or scan["double"]:
        st["out"] += "\n"
    elif st["out"] != "" and not st["out"].endswith("\n"):
        st["out"] += "\n"

def _flow_fold_closer(kept):
    """Whether a content line after a plain-scalar comment closes the collection."""
    first = kept[:1]
    if first in [",", "]", "}"]:
        return True
    return first == ":" and (len(kept) == 1 or kept[1:2] in [" ", "\t"])

def _flow_fold_kept(scan, st, res, raw_kept, line):
    """Folds one scanned content line into `st`. Returns a problem pair, or None."""
    kept = raw_kept.rstrip()
    if kept == "":
        if res["plain_comment"]:
            st["comment_pending"] = True
            st["pending_line"] = line
        return None
    if st["comment_pending"] and not _flow_fold_closer(kept):
        return ("plain-comment", st["pending_line"])
    st["comment_pending"] = res["plain_comment"]
    if res["plain_comment"]:
        st["pending_line"] = line
    st["out"] = _flow_fold_join(st["out"], kept, st["cont"])
    st["cont"] = False
    trailing = raw_kept[len(kept):]
    out, mode = _flow_fold_backslash(st["out"], kept, trailing, scan)
    st["out"] = out
    if mode == "direct":
        st["cont"] = True
    return None

def _flow_fold_control(item, n, skip_first, scan):
    """Returns the item's line when it hides a bad blank outside quotes, else 0.

    The head item reads through its own line's check, so folds skip it; any
    other line trips on a vertical tab, form feed or U+001C to U+001F
    outside quotes and comments, as pub rejects them. A line inside open
    quotes stays content, as pub reads it.
    """
    if n == 0 and skip_first:
        return 0
    if scan["single"] or scan["double"]:
        return 0
    if bad_blank_index(item[1]) < 0:
        return 0
    return item[0]

def flow_fold_lines(items, scan, skip_first):
    """Folds raw flow lines as pub folds them. Returns (folded, problem).

    `items` holds (1-based line, raw line) pairs with "" for blank lines,
    except blank-looking lines with a bad blank, which survive as raw;
    leading indentation is dropped. `skip_first` skips the head item, which
    reads through its own line's check, while a flow document checks every
    line. A bad blank outside quotes and comments is a ("control", line)
    problem, as pub rejects it. A break between content lines is one
    space, except after a double-quoted backslash continuation, which joins
    with no space; a blank line after a continuation, and each blank line
    inside quotes, is one "\\n", while outside quotes a blank run is one
    "\\n". A `#` outside
    quotes is a comment to the end of the line, whether the value before it
    is complete or not: pub only fails where the comment swallows a token
    the flow needs. A comment that ends a line inside a plain scalar poisons
    the fold: the next content must close the collection (`,`, `]`, `}` or
    a separating `:`) or pub rejects the flow. `problem` is None, or a
    (kind, line) pair the caller reports.
    """
    st = {"out": "", "cont": False, "comment_pending": False, "pending_line": 0}
    for n in range(len(items)):
        item = items[n]
        line = item[0]
        bad_line = _flow_fold_control(item, n, skip_first, scan)
        if bad_line:
            return "", ("control", bad_line)
        content = item[1].lstrip(" \t")
        if content.strip() == "":
            _flow_fold_blank(scan, st)
            continue
        res = {"kept": [], "plain_comment": False, "pct_flag": False, "stopped": False, "skip": False}
        flow_scan_text(content, scan, res)
        if res["pct_flag"]:
            return "", ("directive", line)
        problem = _flow_fold_kept(scan, st, res, "".join(res["kept"]), line)
        if problem != None:
            return "", problem
    return st["out"], None

def flow_fold_problem(kind, line):
    """The problem for a folded-flow line this reader cannot spell as pub reads it."""
    if kind == "control":
        return "control character at line %d is not supported" % line
    if kind == "plain-comment":
        return "comment inside a plain scalar of a flow that spans lines at line %d is not supported" % line
    if kind == "directive":
        return "\"%%\" directive in a flow that spans lines at line %d is not supported" % line
    return "flow collection that spans lines starting at line %d is not supported" % line
