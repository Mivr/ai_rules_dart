"""Flow collections for the pubspec YAML reader.

Holds `[...]` and `{...}` parsing, the quote-aware scan and fold of
multi-line flow text, and the scalar dispatcher, which reads a flow value
where one opens. Loaded by the fold, block and document modules and by the
`yaml_subset.bzl` entry point.
"""

load(":yaml_scalar.bzl", "OPEN_ANCHOR", "alias_name_end", "apply_child_collection_tag", "apply_key_tag", "apply_tag", "drop_tag_value", "flow_quoted_end", "flow_value_entry_problem", "is_flow_key_entry", "parse_alias", "parse_nonflow", "record_prefix_problems", "strip_value_prefix")
load(":yaml_text.bzl", "clone", "dict_key", "is_dash", "is_flow_seq_entry", "is_flow_value_entry", "is_question_entry", "quote_track", "quoted_scalar_rest", "split_key_value")

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

def _flow_key_collection_end(s, start):
    """Returns the index past the flow collection opening at `start`, else None.

    Quotes hide brackets, as pub scans them. None when the collection never
    closes or a closer mismatches its opener, as pub rejects those.
    """
    depth = []
    st = {"single": False, "double": False, "escaped": False, "at_start": True, "affix": False}
    for j in range(start, len(s)):
        ch = s[j]
        if quote_track(ch, st):
            continue
        if st["single"] or st["double"]:
            continue
        if ch in ["[", "{"]:
            depth.append(ch)
        elif ch in ["]", "}"]:
            if not depth or (ch == "]") != (depth[-1] == "["):
                return None
            depth.pop()
            if not depth:
                return j + 1
    return None

def _flow_item_end(s, start, close):
    """Returns the index of the `,` or `close` ending the flow item at `start`.

    Brackets nest and quotes hide them, as pub scans them; a `:` inside only
    separates a pair the caller already refused. None when no separator
    follows at the item depth, as pub rejects an unclosed flow.
    """
    depth = 0
    st = {"single": False, "double": False, "escaped": False, "at_start": True, "affix": False}
    for j in range(start, len(s)):
        ch = s[j]
        if quote_track(ch, st):
            continue
        if st["single"] or st["double"]:
            continue
        if ch in ["[", "{"]:
            depth += 1
        elif ch in ["]", "}"]:
            if depth == 0:
                if ch == close:
                    return j
                return None
            depth -= 1
        elif ch == "," and depth == 0:
            return j
    return None

def _flow_key_token(s, i, close):
    """Reads one flow map key token with glued colons. Returns (start, token, next_i).

    A colon glued into a plain key stays content, as pub scans it, so the key
    runs on to a separating colon, a comma or the close; a quoted key pairs
    at once, as pub reads `"a":1` as one pair.
    """
    tok_start = i
    token, i = _flow_token(s, i, [":", close, ","])
    for _ in range(len(s) + 1):
        if s[i:i + 1] != ":" or s[i + 1:i + 2] in [" ", "\t", "\n", "\r", ",", "[", "{", close]:
            break
        if len(token) > 1 and token[:1] in ["'", '"'] and token[-1:] == token[:1]:
            break
        more, i = _flow_token(s, i + 1, [":", close, ","])
        if more == "":
            break
        token += ":" + more
    return tok_start, token, i

def _flow_key_collection(s, i, tok_start, frame, state, line):
    """Reads a collection where a flow map key's colon belongs. Returns (next_i, ok).

    A null key naming the line reads, as pub keys on the collection (`{[x]}`,
    `{? [x]}`, `{&a [x]: b}`) or rejects the pair (`{a [b]: c}`), and parsing
    continues past the collection, which the reader keeps no key for. False
    when the collection never closes, as pub rejects it.
    """
    end = _flow_key_collection_end(s, i)
    if end == None:
        return i, False
    _anchor, _tag, _crest, bad = strip_value_prefix(s[tok_start:i])
    record_prefix_problems(bad, state, line)
    state.problems.append("collection key inside flow at line %d is not supported" % line)
    frame["key"] = dict_key(None)
    i = _skip_flow_space(s, end)
    if i >= len(s) or s[i] != ":":
        _flow_add(frame, None, state, line)
        return i, True
    frame["state"] = "value"
    return i + 1, True

def _flow_key_explicit(token, s, i, tok_start, frame, anchors, state, line):
    """Reads a flow map key token as an explicit key or plain key. Sets the frame key.

    A `? ` or `?` tab marker opens an explicit key, as pub opens it: the rest
    reads as the key, so `{? b: c}` pairs `b` with `c` and `{? &a b: c}`
    binds the anchor, while a bare `?` before the close, a comma or a
    separated colon reads a null key, as pub reads `{?}`, `{? }` and
    `{? : c}`. A `?` glued to a colon stays content, as pub reads `{?:}`
    and `{?: c}` with a `?` key, and so does a `?` glued to anything else,
    as pub reads `{?b: c}`. An anchor or tag before the marker and a second
    marker inside are problems naming the line, as pub rejects them, and
    read a null key so parsing continues past them.
    """
    anchor, tag, rest, bad = strip_value_prefix(token)
    if rest == "?":
        if anchor != None or tag != None:
            record_prefix_problems(bad, state, line)
            state.problems.append("explicit key with anchor or tag at line %d is not supported" % line)
            frame["key"] = dict_key(None)
        elif s[i:i + 1] == ":" and s[tok_start:i] == "?":
            frame["key"] = _flow_key_value(token, anchors, state, line)
        else:
            frame["key"] = dict_key(None)
    elif rest.startswith("? ") or rest.startswith("?\t"):
        if anchor != None or tag != None:
            record_prefix_problems(bad, state, line)
            state.problems.append("explicit key with anchor or tag at line %d is not supported" % line)
            frame["key"] = dict_key(None)
        else:
            content = rest[2:]
            _canchor, _ctag, ccrest, _cbad = strip_value_prefix(content)
            if ccrest == "?" or ccrest.startswith("? ") or ccrest.startswith("?\t"):
                state.problems.append("nested explicit key at line %d is not supported" % line)
                frame["key"] = dict_key(None)
            else:
                frame["key"] = _flow_key_value(content, anchors, state, line)
    else:
        frame["key"] = _flow_key_value(token, anchors, state, line)

def _flow_key_step(s, i, frame, anchors, state, line):
    """Reads one flow map key up to its colon. Returns (next_i, ok).

    A key token that runs to `,` or the close, as an anchor or tag word with
    a glued colon does, reads with a null value, as pub reads it; a colon
    glued into a plain key stays content too, while a spaced colon later
    still pairs, and a quoted key pairs at its glued colon, as pub reads
    them. A colon followed by `[` or `{` separates at once, as pub opens
    the collection there, so `{a:[b]}` pairs `a` with `["b"]`.

    A `[` or `{` collection where the colon belongs, a `- ` entry and an
    explicit marker each read through their own step, and anything else
    pairs at a spaced colon or fails, as pub reads it.
    """
    tok_start, token, i = _flow_key_token(s, i, frame["close"])
    if s[i:i + 1] in ["[", "{"]:
        return _flow_key_collection(s, i, tok_start, frame, state, line)
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
    _flow_key_explicit(token, s, i, tok_start, frame, anchors, state, line)
    i = _skip_flow_space(s, i)
    if i >= len(s) or s[i] != ":":
        _flow_add(frame, None, state, line)
        return i, True
    frame["state"] = "value"
    return i + 1, True

def _flow_item_pair(token, next_i, s, frame, anchors, state, line):
    """Reads one `?` explicit pair item. Returns (next_i, ok).

    A collection as the pair key reads a null item naming the line, as pub
    keys on it (`[? [x]]`), and parsing continues past the pair, which the
    reader keeps no key for. An anchor or tag before the marker, a second
    marker inside and a `- ` entry inside are problems naming the line, as
    pub rejects them, and read null so parsing continues past them, while a
    plain explicit key reads one pair, as pub reads `[? a]`, `[? a: b]` and
    `[?]`.
    """
    _qanchor, _qtag, qrest, _qbad = strip_value_prefix(token)
    after = _skip_flow_space(s, next_i)
    if s[after:after + 1] in ["[", "{"]:
        stop = _flow_item_end(s, after, frame["close"])
        if stop == None:
            return next_i, False
        state.problems.append("collection key inside flow at line %d is not supported" % line)
        _flow_add(frame, None, state, line)
        return stop, True
    content = "" if qrest == "?" else qrest[2:]
    _canchor, _ctag, ccrest, _cbad = strip_value_prefix(content)
    if _qanchor != None or _qtag != None:
        state.problems.append("explicit key with anchor or tag at line %d is not supported" % line)
        _flow_add(frame, None, state, line)
    elif is_dash(ccrest):
        state.problems.append("block entry inside flow at line %d is not supported" % line)
        _flow_add(frame, None, state, line)
    elif ccrest == "?" or ccrest.startswith("? ") or ccrest.startswith("?\t"):
        state.problems.append("nested explicit key at line %d is not supported" % line)
        _flow_add(frame, None, state, line)
    else:
        ckey, cval, found = _flow_pair_split(content)
        if not found:
            ckey = content
            cval = ""
        _flow_add(frame, _flow_pair(ckey, cval, None, None, anchors, state, line), state, line)
    return next_i, True

def _flow_item_step(s, i, frame, anchors, stack, state, line):
    """Reads one nested collection or scalar flow token. Returns (next_i, ok).

    A map value that is itself a pair fails, as pub expects `,` or `}` after
    a flow mapping value; a pair as a sequence item still reads, as pub
    reads it. An empty map value reads null, as pub reads `{k:}` and
    `{k:, j: 1}`; an empty key or item still fails, as pub rejects `{,}`
    and `[ , ]`. A `? ` or `?` tab item reads through its own step, as pub
    reads `[? a]`, `[? a: b]` and `[?]`.
    """
    if s[i] in ["[", "{"]:
        stack.append(_flow_frame(s[i]))
        return i + 1, True
    if s[i] in ["&", "!"]:
        nested, next_i = _flow_prefixed_collection(s, i, anchors, stack, state, line)
        if nested:
            return next_i, True
    token, next_i = _flow_token(s, i, [",", frame["close"]])
    if token == "":
        if frame["kind"] == "map" and frame["state"] == "value":
            _flow_add(frame, None, state, line)
            return next_i, True
        return next_i, False
    if not _flow_scalar_ok(token):
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
        _qanchor, _qtag, qrest, _qbad = strip_value_prefix(token)
        if qrest == "?" or qrest.startswith("? ") or qrest.startswith("?\t"):
            return _flow_item_pair(token, next_i, s, frame, anchors, state, line)
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
    pub scans it, even glued to an opener or a comma. A close steps through
    its own step: the single-line form never reaches the close, as the
    comment eats it and the flow fails unclosed. A flow frame is a dict
    {kind, close, value, state, key}. The frame's
    `state` is "item" or "value" where a value may start, "after" once a
    value is complete, and "key" where a map key is read. Duplicate map keys
    are recorded on `parse_state` with `line`.

    Args:
      text: the flow collection text.
      anchors: the anchor names bound so far.
      parse_state: the parse state collecting problems and duplicate keys.
      line: the 1-based line number naming failures.

    Returns:
      The parsed collection, or None.
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

        if ch == frame["close"]:
            done, value, i = _flow_close_frame(s, i, stack, frame, anchors, parse_state, line)
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

def _flow_close_frame(s, i, stack, frame, anchors, state, line):
    """Steps the close at `s[i]`. Returns (done, value, next_i).

    A close where a map value starts reads an empty value first, as pub
    reads `{k: # c\n}` with null.
    """
    if frame["state"] == "value":
        _flow_add(frame, None, state, line)
    return _flow_close_step(stack, s, i, frame, anchors, state, line)

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
    hash stays in the word instead of ending the token. An unquoted `[` or
    `{` ends the token without consuming it, as pub opens a collection
    there: the token reads as the scalar before it and the opener fails
    downstream, as pub rejects `[a[b]` and `{a[b: c}`. Returns (stripped token,
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
        if not st["single"] and not st["double"] and ch in ["[", "{"]:
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

    Args:
      text: the text after a key, dash or flow separator.
      anchors: the anchor names bound so far.
      state: the parse state collecting problems.
      line: the 1-based line number naming failures.
      record_prefix: whether to record prefix shape problems; the fold passes False
      for a head its caller already split.

    Returns:
      The parsed value.
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
        rest = quoted_scalar_rest(s)
        if rest != None and rest.strip(" \t").startswith("#"):
            # A `#` comment past a leading quoted scalar ends the block
            # value, glued or spaced, as pub ends the scalar there; any
            # other trailing text still fails downstream, as pub rejects it.
            s = s[:len(s) - len(rest)]
        value = parse_nonflow(s, anchors, state, line)
    if tag != None:
        value = apply_tag(tag, s, value, state, line)
    if anchor:
        anchors[anchor] = clone(value)
    return value
