"""Block containers for the pubspec YAML reader.

Holds mapping and sequence lines: pending keys and dashes, lone anchors
and tags, pending scalar tags, unclosed flow heads and folded flow heads.
Loaded by the document module.
"""

load(":yaml_block_scalar.bzl", "parse_block_scalar")
load(":yaml_chars.bzl", "is_marker_line")
load(":yaml_flow.bzl", "parse_flow", "parse_scalar")
load(":yaml_flow_scan.bzl", "flow_fold_lines", "flow_fold_problem", "flow_scan_start")
load(":yaml_fold.bzl", "block_fold_scalar")
load(":yaml_scalar.bzl", "OPEN_ANCHOR", "apply_bool_tag", "apply_child_collection_tag", "apply_tag", "drop_tag_value", "is_unknown_tag_handle", "resolve_alias", "resolve_handle", "split_value_text", "strip_value_prefix", "tag_name", "undefined_tag_problem")
load(":yaml_text.bzl", "bad_blank_index", "block_line_text", "clone", "dict_key", "find_block_colon", "flow_head_text", "is_block_collection_key", "is_block_mapping_start", "is_compact_seq", "is_dash", "is_explicit_key_text", "is_mapping_start", "is_question_entry", "is_unknown_directive", "record_unreadable", "split_block_key_value")

def close_block_containers(stack, indent, text, anchors):
    """Pops the containers that the line at `indent` is not nested into.

    A compact sequence keeps its entries at its key's own column, so a dash
    at the entry column stays inside it while any other line closes it. A
    container that closes with an open anchor binds its value then, as pub
    reads an alias after the collection closes; rebinding replaces any
    older binding.

    Args:
      stack: the open container frames.
      indent: the column of the current line.
      text: the current line text.
      anchors: the anchor names bound so far.
    """
    for _ in range(len(stack)):
        if not stack or indent > stack[-1]["indent"]:
            break
        top = stack[-1]
        if top.get("compact", False) and top.get("entry", None) == indent and is_dash(text):
            break
        if top.get("anchor", None) != None:
            anchors[top["anchor"]] = clone(top["value"])
        stack.pop()

def drop_pending_value(pending, anchors, state):
    """Reads a pending key or dash closed with no child. Returns the value.

    The slot and a pending anchor read the dropped value, so parsing
    continues past it.

    Args:
      pending: the pending key or dash.
      anchors: the anchor names bound so far.
      state: the parse state collecting problems.

    Returns:
      The value.
    """
    value = drop_tag_value(pending["tag"], pending.get("tag_line", pending["line"]), state)
    pending["parent"][pending["slot"]] = value
    if pending["anchor"] != None:
        anchors[pending["anchor"]] = value
    return value

def _attach_pending_child(pending, indent, text, anchors, stack, state):
    """Attaches the child container after a finished pending header line.

    A pending anchor marks the child open at attach: an alias read while
    the child is still open fails closed as a self-reference, as pub
    rejects it, and the anchor binds the child when the child closes. A
    pending `!!seq` or `!!map` tag reads a matching child as the same-line
    tags do. Rebinding replaces any older binding.
    """
    if indent > pending["indent"]:
        child = _new_block(text)
        value = apply_child_collection_tag(pending["tag"], child, state, pending.get("tag_line", pending["line"]))
        pending["parent"][pending["slot"]] = value
        if pending["anchor"] != None:
            anchors[pending["anchor"]] = OPEN_ANCHOR
        stack.append({
            "kind": "seq" if type(value) == "list" else "map",
            "indent": pending["indent"],
            "value": value,
            "entry": None,
            "compact": False,
            "anchor": pending["anchor"],
        })

def _attach_compact_seq(pending, anchors, stack, state):
    """Attaches a compact sequence at its key's own column.

    A pending anchor marks the sequence open at attach, with the same
    self-reference rule as `_attach_pending_child`, and a pending tag reads
    it as the same-line tags do.
    """
    seq = apply_child_collection_tag(pending["tag"], [], state, pending.get("tag_line", pending["line"]))
    pending["parent"][pending["slot"]] = seq
    if pending["anchor"] != None:
        anchors[pending["anchor"]] = OPEN_ANCHOR
    stack.append({
        "kind": "seq",
        "indent": pending["indent"],
        "value": seq,
        "entry": None,
        "compact": True,
        "anchor": pending["anchor"],
    })

def _consume_pending_scalar(cursor, pending, env):
    """Folds a scalar starting after `key:` with single spaces. Returns next index.

    A pending tag reads the folded child as it reads an attached one: a
    flow child follows the collection rule, and any other child follows the
    scalar rule with the head line as the raw text, as pub reads them.
    """
    lines = cursor.lines
    idx = cursor.idx
    anchors = env.anchors
    state = env.state
    parent = pending["parent"]
    parent_indent = pending["indent"]
    _indent0, text0 = block_line_text(lines[idx])
    if text0 != None and _unclosed_flow_head(text0, anchors) != None:
        return _consume_pending_flow(lines, idx, parent_indent, text0, pending, anchors, state)
    value, next_idx, _read = block_fold_scalar(lines, idx, parent_indent, {"text": "", "raw": "", "idx": idx, "entry": ""}, type(parent) == "dict" and parent_indent > 0, anchors, state)
    _store_pending_value(pending, value, text0, anchors, state)
    return next_idx

def _consume_pending_flow(lines, idx, parent_indent, text0, pending, anchors, state):
    """Folds a pending flow head with its deeper lines. Returns next index.

    When the fold reads as one flow collection as pub reads it, the value is
    that collection. A close dedented to the key's column or past it reads
    too, as pub closes it there: the extended lines fold shortest-first, so
    a sibling past the close never joins it. An unknown column-0 `%` line
    reads past, as pub only warns about it; any other `%` outside quotes
    and plain scalars refuses the flow naming the line, as pub rejects a
    known or indented directive there. A head that never closes refuses
    naming its opening line in strict mode, as pub rejects it there, and
    reads None leniently, as an unreadable flow value does.
    """
    raws, next_idx = _pending_flow_raws(lines, idx, parent_indent)
    folded, problem = flow_fold_lines(raws, flow_scan_start(), True)
    if problem == None and _folded_flow_ok(folded, anchors):
        # The folded lines read as one flow collection, as pub reads
        # them: keep the value, as revisions before the span check did.
        value = parse_scalar(folded, anchors, state, idx + 1)
        _store_pending_value(pending, value, "", anchors, state)
        return next_idx
    if problem == None or problem[0] == "plain-comment":
        # The close may sit past the bounded lines, dedented to the
        # key's column or past it, as pub closes it there.
        full = raws + _extended_flow_raws(lines, next_idx)
        count, folded, xproblem = _spanning_prefix(full, anchors)
        if count > 0:
            value = parse_scalar(folded, anchors, state, idx + 1)
            _store_pending_value(pending, value, "", anchors, state)
            return full[count - 1][0]
        if xproblem != None and xproblem[0] == "directive":
            problem = xproblem
    if problem != None and problem[0] == "directive":
        state.problems.append(flow_fold_problem("directive", problem[1]))
        resume = _flow_resume_index(raws + _extended_flow_raws(lines, next_idx), anchors)
        return resume if resume != None else next_idx
    if problem != None:
        state.problems.append(flow_fold_problem(problem[0], problem[1]))
    else:
        state.problems.append(_span_flow_problem(idx + 1))
    end = _spanning_flow_end(lines, idx + 1, parent_indent, text0, anchors)
    return end if end != None else next_idx

def _store_pending_value(pending, value, raw, anchors, state):
    """Stores a folded pending child, reading it through a pending tag.

    A collection child follows the collection rule; any other child follows
    the scalar rule with `raw` as the raw text, as pub reads them. A pending
    anchor binds the stored value, replacing any older binding.
    """
    if pending["tag"] != None:
        if type(value) in ["list", "dict"]:
            value = apply_child_collection_tag(pending["tag"], value, state, pending.get("tag_line", pending["line"]))
        else:
            value = _apply_pending_scalar_tag(pending["tag"], value, raw, state, pending.get("tag_line", pending["line"]))
    pending["parent"][pending["slot"]] = value
    if pending["anchor"] != None:
        anchors[pending["anchor"]] = clone(value)

def _lone_affix(text):
    """Splits a lone anchor/tag property line. Returns (anchor, tag).

    Returns (None, None) unless the line holds only `&anchor` and `!tag`
    words, as pub applies such a line to the node starting on the next
    line; a line with anything else, or a rejected prefix, reads as before.
    """
    anchor, tag, rest, bad = strip_value_prefix(text)
    if rest != "" or bad != "" or (anchor == None and tag == None):
        return None, None
    return anchor, tag

def _merge_affix(slot, anchor, tag, line, anchors, state):
    """Merges lone-line properties into a pending slot. Returns True when merged.

    `slot` is a pending key/dash dict or the root affix dict, each carrying
    anchor and tag. A merged tag records its own line, as pub names the tag's
    line. A repeated anchor or tag is an always-on problem naming the new
    line, as pub rejects two of either on one node, and the first properties
    win, so parsing continues past it.
    """
    if anchor != None and slot["anchor"] != None:
        state.problems.append("repeated anchor at line %d is not supported" % line)
        return False
    if tag != None and slot["tag"] != None:
        state.problems.append("repeated tag at line %d is not supported" % line)
        return False
    if anchor != None:
        slot["anchor"] = anchor
        anchors[anchor] = OPEN_ANCHOR
    if tag != None:
        slot["tag"] = tag
        slot["tag_line"] = line
    return True

def take_lone_line(slot, text, line, anchors, state):
    """Merges a lone property line into a pending slot. Returns True when taken.

    A repeated anchor or tag still counts as taken: the line is skipped after
    its problem, as pub rejects it, and the slot keeps its first properties.

    Args:
      slot: the pending slot merging the properties.
      text: the lone property line.
      line: the 1-based line number naming failures.
      anchors: the anchor names bound so far.
      state: the parse state collecting problems.

    Returns:
      True when taken.
    """
    anchor, tag = _lone_affix(text)
    if anchor == None and tag == None:
        return False
    _merge_affix(slot, anchor, tag, line, anchors, state)
    return True

def record_dangling(lone, text, line):
    """Keeps a lone property line an open container cannot take. Returns True when kept.

    The line reads like a key there, as pub parses it, so the open container
    keeps the line for the problem the next line reports.

    Args:
      lone: the dangling-line keeper.
      text: the lone property line.
      line: the 1-based line number naming failures.

    Returns:
      True when kept.
    """
    anchor, tag = _lone_affix(text)
    if anchor == None and tag == None:
        return False
    lone["text"] = text
    lone["line"] = line
    return True

def emit_dangling(lone, state, idx):
    """Reports a lone property line the previous line could not place.

    The problem names the line where parsing breaks, as pub names the line
    after the lone line, quoting the lone line it could not place; that line
    still reads, so parsing continues past it.
    """
    if lone["text"] != None:
        state.problems.append("unreadable line %d: %r" % (idx + 1, lone["text"]))
        lone["text"] = None

def drop_affix(affix, anchors, state):
    """Reads a root affix closed with no node.

    A dropped tag reads as a dropped pending tag does, naming the tag's own
    line, and a pending anchor binds the dropped value, as pub binds it to
    the empty node, so parsing continues past it.
    """
    value = drop_tag_value(affix["tag"], affix["tag_line"], state)
    if affix["anchor"] != None:
        anchors[affix["anchor"]] = value

def resolve_affix_root(affix, lines, idx, indent, text, anchors, stack, state):
    """Creates the root node a lone anchor/tag line applies to. Returns (root, next index).

    A block scalar header reads as under a same-line key, as pub reads it;
    any other line reads as without the affix, then takes it. A tag reads a
    collection as the same-line tags do and a scalar as a pending tag does,
    naming the tag's own line, as pub names it; an anchor binds the closed
    value, marking an open block collection so an alias inside it fails
    closed, as pub rejects it. A flow collection reads closed where a scalar
    reads, as a folded pending value does, so the anchor binds it at once.
    Rebinding replaces any older binding.

    Args:
      affix: the waiting anchor and tag properties.
      lines: the document lines.
      idx: the 0-based index of the affix line.
      indent: the column of the affix line.
      text: the affix line text.
      anchors: the anchor names bound so far.
      stack: the open container frames.
      state: the parse state collecting problems.

    Returns:
      The (root, next index) pair.
    """
    line = idx + 1
    if text.startswith("|") or text.startswith(">"):
        parsed, next_idx, _ok = parse_block_scalar(lines, idx + 1, indent, indent, text, idx, text, state)
        root = _apply_pending_scalar_tag(affix["tag"], parsed, parsed, state, affix["tag_line"])
        if affix["anchor"] != None:
            anchors[affix["anchor"]] = clone(root)
    else:
        root, is_scalar = init_block_root(text, indent, anchors, stack, state, line)
        if type(root) == "list" or type(root) == "dict":
            root = apply_child_collection_tag(affix["tag"], root, state, affix["tag_line"])
        else:
            root = _apply_pending_scalar_tag(affix["tag"], root, text, state, affix["tag_line"])
        if affix["anchor"] != None:
            if (type(root) == "list" or type(root) == "dict") and not is_scalar:
                anchors[affix["anchor"]] = OPEN_ANCHOR
                stack[-1]["anchor"] = affix["anchor"]
            else:
                anchors[affix["anchor"]] = clone(root)
        next_idx = idx + 1 if is_scalar else idx
    affix["anchor"] = None
    affix["tag"] = None
    return root, next_idx

def resolve_pending(pending, cursor, env):
    """Resolves a pending key or dash against the current line.

    Returns (next index, consumed): consumed is True when deeper scalar lines
    were folded into the pending value and the caller must continue.

    Args:
      pending: the pending key or dash.
      cursor: the current line as {lines, idx, indent, text}.
      env: the parse environment as {anchors, stack, state}.

    Returns:
      The (next index, consumed) pair: consumed is True when deeper scalar lines were
      folded into the pending value and the caller must continue.
    """
    indent = cursor.indent
    text = cursor.text
    if is_compact_seq(pending, indent, text):
        _attach_compact_seq(pending, env.anchors, env.stack, env.state)
        return cursor.idx, False
    if indent > pending["indent"]:
        if is_dash(text) or is_block_mapping_start(text):
            _attach_pending_child(pending, indent, text, env.anchors, env.stack, env.state)
            return cursor.idx, False
        next_idx = _consume_pending_scalar(struct(lines = cursor.lines, idx = cursor.idx), pending, struct(anchors = env.anchors, state = env.state))
        return next_idx, True
    drop_pending_value(pending, env.anchors, env.state)
    return cursor.idx, False

def init_block_root(text, indent, anchors, stack, state, line):
    """Creates the root container or scalar. Returns (root, is_scalar).

    Args:
      text: the line text.
      indent: the column of the line.
      anchors: the anchor names bound so far.
      stack: the open container frames.
      state: the parse state collecting problems.
      line: the 1-based line number naming failures.

    Returns:
      The (root, is_scalar) pair.
    """
    if is_dash(text):
        root = []
        stack.append({"kind": "seq", "indent": indent - 1, "value": root, "entry": None, "compact": False})
        return root, False
    if find_block_colon(text) >= 0 or is_block_collection_key(text) or text.startswith("? "):
        root = {}
        stack.append({"kind": "map", "indent": indent - 1, "value": root, "entry": None, "compact": False})
        return root, False
    return parse_scalar(text, anchors, state, line), True

def _flow_span_end(lines, start, parent_indent, head):
    """Returns the index after a spanning flow's closing line, or None.

    Joins `head` with the lines after `start` that stay nested deeper than
    `parent_indent`; when the joined text parses as one flow collection, the
    flow spans lines. A column-0 document marker ends the search.
    """
    parts = [head]
    idx = start
    for _ in range(len(lines) + 1):
        if idx >= len(lines):
            break
        raw = lines[idx]
        indent, text = block_line_text(raw)
        if indent == None:
            if is_marker_line(raw, "---") or is_marker_line(raw, "..."):
                break
            idx += 1
            continue
        if indent <= parent_indent:
            break
        parts.append(text)
        idx += 1
        probe = struct(problems = [], strict_lines = False, tag_prefixes = {})
        if parse_flow("\n".join(parts), {}, probe, 0) != None:
            return idx
    return None

def _spanning_flow_end(lines, start, parent_indent, value_text, anchors):
    """Returns the index after the closing line when `value_text` opens a flow collection that closes on a later line, else None."""
    head = _unclosed_flow_head(value_text, anchors)
    if head == None:
        return None
    return _flow_span_end(lines, start, parent_indent, head)

def _span_end_or_close(lines, start, parent_indent, value_text, anchors):
    """Returns the index past a spanning flow, or None.

    A flow that opens on the head line and closes on a later line spans
    lines, as pub spans it; the close may dedent to a bare `]` or `}` line,
    as pub closes it there, since the fold never reaches a dedented line.
    Otherwise None and the caller reads the head itself.
    """
    end = _spanning_flow_end(lines, start, parent_indent, value_text, anchors)
    if end != None:
        return end
    if _unclosed_flow_head(value_text, anchors) == None or start >= len(lines):
        return None
    _indent, text = block_line_text(lines[start])
    if text != None and text.strip() in ["]", "}"]:
        return start + 1
    return None

def _span_flow_problem(line):
    """The problem for a flow collection that opens at 1-based `line` and never reads as one value."""
    return "flow collection starting at line %d is not supported" % line

def _map_store(mapping, key, value, next_idx, line, state):
    """Stores a mapping value, recording a duplicate key. Returns (next index, None)."""
    if _is_duplicate(mapping, key, line, state):
        return next_idx, None
    mapping[key] = value
    return next_idx, None

def _map_flow_value(lines, idx, indent, text, value_text, anchors, state, line):
    """Reads a same-line flow value that may span lines. Returns (value, next index, done).

    When `value_text` opens a flow collection, the raw head line folds with
    its deeper lines; done is True with the collection, or with None and the
    next index past the span when the fold does not read. Otherwise done is
    False and the caller reads `value_text` itself.
    """
    head = lines[idx][indent + find_block_colon(text) + 1:]
    value, next_idx, read = _folded_head_flow(head, line, lines, idx, indent, anchors, state)
    if read:
        return value, next_idx, True
    end = _span_end_or_close(lines, idx + 1, indent, value_text, anchors)
    if end != None:
        state.problems.append(_span_flow_problem(line))
        return None, end, True
    return None, idx + 1, False

def map_line(lines, idx, indent, text, frame, anchors, state):
    """Reads one line of a block mapping. Returns (next index, pending).

    Args:
      lines: the document lines.
      idx: the 0-based index of the line being read.
      indent: the column of the line.
      text: the line text.
      frame: the mapping frame.
      anchors: the anchor names bound so far.
      state: the parse state collecting problems.

    Returns:
      The (next index, pending) pair: pending is the key awaiting its value, or None.
    """
    if is_explicit_key_text(text):
        # Explicit keys are not supported (see the module docstring). They fail
        # naming the line even where an entry is not expected, so a `:`
        # continuation of a plain scalar fails closed instead of vanishing.
        record_unreadable(state, idx, text)
        return idx + 1, None
    if not _entry_indent_ok(frame, indent):
        record_unreadable(state, idx, text)
        return idx + 1, None
    if is_dash(text):
        # A sequence entry never belongs to a mapping; it is unreadable here
        # rather than a key named "- ...".
        record_unreadable(state, idx, text)
        return idx + 1, None
    key_text, value_text, ok = split_block_key_value(text)
    if not ok:
        if is_block_collection_key(text):
            state.problems.append("collection key at line %d is not supported" % (idx + 1))
        else:
            record_unreadable(state, idx, text)
        return idx + 1, None
    if key_text == "":
        record_unreadable(state, idx, text)
        return idx + 1, None

    line = idx + 1
    mapping = frame["value"]
    key = _map_key_value(text, key_text, anchors, state, line)
    anchor, tag, rest, failed = split_value_text(value_text, anchors, state, line)
    if failed:
        return _map_store(mapping, key, None, idx + 1, line, state)
    if _block_value_entry_problem(rest, state, line):
        return _map_store(mapping, key, None, idx + 1, line, state)
    if rest == "":
        if _is_duplicate(mapping, key, line, state):
            return idx + 1, None
        mapping[key] = None
        pending = {"parent": mapping, "slot": key, "indent": indent, "anchor": anchor, "tag": tag, "line": line}
        if anchor != None:
            anchors[anchor] = OPEN_ANCHOR
        return idx + 1, pending

    if rest.startswith("|") or rest.startswith(">"):
        parsed, next_idx, _ok = parse_block_scalar(lines, idx + 1, indent, indent, rest, idx, text, state)
        value = _apply_pending_scalar_tag(tag, parsed, parsed, state, line)
        if anchor != None:
            anchors[anchor] = clone(value)
        return _map_store(mapping, key, value, next_idx, line, state)

    flow_value, flow_next, flow_done = _map_flow_value(lines, idx, indent, text, value_text, anchors, state, line)
    if flow_done:
        return _map_store(mapping, key, flow_value, flow_next, line, state)

    raw_head = lines[idx][indent + find_block_colon(text) + 1:]
    value, next_idx, _read = block_fold_scalar(lines, idx + 1, indent, {"text": value_text, "raw": raw_head, "idx": idx, "entry": text}, indent > 0, anchors, state)
    return _map_store(mapping, key, value, next_idx, line, state)

def _seq_dash_map(lines, idx, indent, text, items, anchors, stack, state):
    """Reads a `- key: value` line, starting a mapping for the sequence item. Returns (next index, pending).

    A pending value nests past the key's own column, as pub reads it, so a
    dash at the key's column or shallower is a sibling, not a child. Later
    keys must sit at the key's own column, as pub rejects them anywhere
    else, so the frame records it up front instead of adopting the first
    continuation's column. The same-line value folds only past that column
    too, as pub ends it there: a `- ` or plain continuation at the key's
    column or shallower never folds into it, as pub rejects it.
    """
    line = idx + 1
    rest = text[1:].strip()
    if is_block_collection_key(rest):
        state.problems.append("collection key at line %d is not supported" % line)
        items.append(None)
        return idx + 1, None
    key_text, value_text, _ok = split_block_key_value(rest)
    item = {}
    key = _map_key_value(rest, key_text, anchors, state, line)
    after_dash = lines[idx][indent + 1:]
    gap = len(after_dash) - len(after_dash.lstrip(" \t"))
    key_indent = indent + 1 + gap
    head = after_dash[gap + find_block_colon(rest) + 1:]
    anchor, tag, rest_value, failed = split_value_text(value_text, anchors, state, line)
    if failed:
        item[key] = None
        items.append(item)
        stack.append({"kind": "map", "indent": indent, "value": item, "entry": key_indent})
        return idx + 1, None
    if _block_value_entry_problem(rest_value, state, line):
        item[key] = None
        items.append(item)
        stack.append({"kind": "map", "indent": indent, "value": item, "entry": key_indent})
        return idx + 1, None
    if rest_value.startswith("|") or rest_value.startswith(">"):
        # A block scalar after `- key:` reads as pub reads it; an
        # indentation indicator counts from the key's own column.
        parsed, next_idx, _ok = parse_block_scalar(lines, idx + 1, indent, key_indent, rest_value, idx, text, state)
        value = _apply_pending_scalar_tag(tag, parsed, parsed, state, line)
        if anchor != None:
            anchors[anchor] = clone(value)
        item[key] = value
        items.append(item)
        stack.append({"kind": "map", "indent": indent, "value": item, "entry": key_indent})
        return next_idx, None
    flow_value, flow_next, flow_read = _folded_head_flow(head, line, lines, idx, indent, anchors, state)
    if flow_read:
        item[key] = flow_value
        items.append(item)
        stack.append({"kind": "map", "indent": indent, "value": item, "entry": key_indent})
        return flow_next, None
    end = _span_end_or_close(lines, idx + 1, indent, value_text, anchors)
    if end != None:
        state.problems.append(_span_flow_problem(line))
        item[key] = None
        items.append(item)
        stack.append({"kind": "map", "indent": indent, "value": item, "entry": key_indent})
        return end, None
    if rest_value == "":
        items.append(item)
        stack.append({"kind": "map", "indent": indent, "value": item, "entry": key_indent})
        pending = {"parent": item, "slot": key, "indent": key_indent, "anchor": anchor, "tag": tag, "line": line}
        if anchor != None:
            anchors[anchor] = OPEN_ANCHOR
        return idx + 1, pending
    value, next_idx, _read = block_fold_scalar(lines, idx + 1, key_indent, {"text": value_text, "raw": head, "idx": idx, "entry": text}, True, anchors, state)
    item[key] = value
    items.append(item)
    stack.append({"kind": "map", "indent": indent, "value": item, "entry": key_indent})
    return next_idx, None

def _seq_question_item(rest_value, anchor, tag, text, items, anchors, state, idx):
    """Reads a `- ? ...` line as one pair item. Returns (next index, None).

    `- ?` reads one null pair, `- ? a` pairs `a` with null and `- ? "a"`
    pairs the quoted key, as pub reads them, with an anchor in the content
    bound as a same-line anchor binds it. An anchor or tag before the
    marker fails, as pub rejects `- &a ? b`, and content holding a nested
    mapping or a collection fails too, as pub keys it on a map or list the
    reader keeps no key for; both name the line, as pub rejects them, and
    read null so parsing continues past them.
    """
    line = idx + 1
    content = "" if rest_value == "?" else rest_value[2:].strip(" \t")
    if anchor != None or tag != None:
        state.problems.append("explicit key with anchor or tag at line %d is not supported" % line)
        items.append(None)
        return idx + 1, None
    _canchor, _ctag, crest, _cbad = strip_value_prefix(content)
    if find_block_colon(content) >= 0 or crest[:1] in ["[", "{"]:
        state.problems.append("compound explicit key at line %d is not supported" % line)
        items.append(None)
        return idx + 1, None
    item = {}
    item[_map_key_value(text, content, anchors, state, line)] = None
    items.append(item)
    return idx + 1, None

def seq_line(lines, idx, indent, text, frame, anchors, stack, state):
    """Reads one line of a block sequence. Returns (next index, pending).

    Args:
      lines: the document lines.
      idx: the 0-based index of the line being read.
      indent: the column of the line.
      text: the line text.
      frame: the sequence frame.
      anchors: the anchor names bound so far.
      stack: the open container frames.
      state: the parse state collecting problems.

    Returns:
      The (next index, pending) pair: pending is the dash awaiting its value, or None.
    """
    if not _entry_indent_ok(frame, indent):
        if frame["kind"] == "seq" and frame.get("nested_refused", False) and indent > frame["indent"]:
            # Lines stranded inside a refused nested sequence fail as part
            # of it, as pub reads them there; anything else reads as before.
            state.problems.append("nested sequence at line %d is not supported" % (idx + 1))
        else:
            record_unreadable(state, idx, text)
        return idx + 1, None
    if not is_dash(text):
        record_unreadable(state, idx, text)
        return idx + 1, None

    line = idx + 1
    items = frame["value"]
    rest = text[1:].strip()
    anchor, tag, rest_value, failed = split_value_text(rest, anchors, state, line)
    if failed:
        items.append(None)
        return idx + 1, None
    if rest_value == "":
        items.append(None)
        pending = {"parent": items, "slot": len(items) - 1, "indent": indent, "anchor": anchor, "tag": tag, "line": line}
        if anchor != None:
            anchors[anchor] = OPEN_ANCHOR
        return idx + 1, pending

    if is_dash(rest_value):
        # A `- ` entry under a dash nests a sequence, as pub nests it; the
        # reader keeps no nested block sequences, so it fails naming the
        # line, and deeper lines strand as part of it (see `seq_line`).
        state.problems.append("nested sequence at line %d is not supported" % line)
        items.append(None)
        frame["nested_refused"] = True
        return idx + 1, None
    if rest_value == "?" or rest_value.startswith("? ") or rest_value.startswith("?\t"):
        return _seq_question_item(rest_value, anchor, tag, text, items, anchors, state, idx)
    if is_block_collection_key(rest_value):
        state.problems.append("collection key at line %d is not supported" % line)
        items.append(None)
        return idx + 1, None

    if find_block_colon(rest) >= 0:
        # `- key: value` starts a mapping whose first entry is on this line.
        return _seq_dash_map(lines, idx, indent, text, items, anchors, stack, state)

    if rest_value.startswith("|") or rest_value.startswith(">"):
        parsed, next_idx, _ok = parse_block_scalar(lines, idx + 1, indent, indent, rest_value, idx, text, state)
        value = _apply_pending_scalar_tag(tag, parsed, parsed, state, line)
        if anchor != None:
            anchors[anchor] = clone(value)
        items.append(value)
        return next_idx, None

    after_dash = lines[idx][indent + 1:]
    gap = len(after_dash) - len(after_dash.lstrip(" \t"))
    head = after_dash[gap + find_block_colon(rest) + 1:]
    flow_value, flow_next, flow_read = _folded_head_flow(head, line, lines, idx, indent, anchors, state)
    if flow_read:
        items.append(flow_value)
        return flow_next, None
    end = _span_end_or_close(lines, idx + 1, indent, rest, anchors)
    if end != None:
        state.problems.append(_span_flow_problem(line))
        items.append(None)
        return end, None
    value, next_idx, _read = block_fold_scalar(lines, idx + 1, indent, {"text": rest, "raw": after_dash, "idx": idx, "entry": text}, False, anchors, state)
    items.append(value)
    return next_idx, None

def _new_block(text):
    """The container for a child block, chosen by the first line of the block."""
    return [] if is_dash(text) else {}

def _entry_indent_ok(frame, indent):
    """Records the column of a container's first entry, then checks `indent`."""
    if frame["entry"] == None:
        frame["entry"] = indent
        return True
    return frame["entry"] == indent

def _is_duplicate(mapping, key, line, state):
    """Records a duplicate-key problem when `key` is taken. Returns whether it is."""
    if key not in mapping:
        return False
    state.problems.append("duplicate key %r at line %d" % (key, line))
    return True

def _folded_head_flow(head_raw, head_line, lines, idx, parent_indent, anchors, state):
    """Folds a same-line flow head with its deeper lines. Returns (value, next index, read).

    `head_raw` is the raw value text on `lines[idx]` at 1-based `head_line`,
    comment intact; deeper content lines come from `_pending_flow_raws`.
    When the fold reads as one flow collection as pub reads it, value is
    that collection. A close dedented to the key's column or past it reads
    too, as pub closes it there: the extended lines fold shortest-first, so
    a sibling past the close never joins it. An unknown column-0 `%` line
    reads past, as pub only warns about it; any other `%` outside quotes
    and plain scalars refuses the flow naming the line, as pub rejects a
    known or indented directive there. A head that never closes refuses
    naming its opening line in strict mode, as pub rejects it there, and
    reads None leniently, as an unreadable flow value does. Every caller
    already split the head's prefixes, so the parse reads them without
    recording again.
    """
    if _unclosed_flow_head(head_raw, anchors) == None:
        return None, idx + 1, False
    raws, next_idx = _pending_flow_raws(lines, idx + 1, parent_indent)
    items = [(head_line, head_raw)] + raws
    folded, problem = flow_fold_lines(items, flow_scan_start(), True)
    if problem == None and _folded_flow_ok(folded, anchors):
        return parse_scalar(folded, anchors, state, head_line, False), next_idx, True
    full = items + _extended_flow_raws(lines, next_idx)
    count, folded, problem = _spanning_prefix(full, anchors)
    if count > 0:
        return parse_scalar(folded, anchors, state, head_line, False), full[count - 1][0], True
    if problem != None and problem[0] == "directive":
        if not state.strict_lines:
            return None, next_idx, False
        state.problems.append(flow_fold_problem("directive", problem[1]))
        resume = _flow_resume_index(full, anchors)
        return None, (resume if resume != None else next_idx), True
    if not state.strict_lines:
        return None, next_idx, False
    state.problems.append(_span_flow_problem(head_line))
    return None, next_idx, True

def _extended_flow_raws(lines, start):
    """Collects the raw lines past `start` a spanning flow may close on. Returns items.

    Each item is a (1-based line, raw line) pair. Unlike `_pending_flow_raws`
    no indent or entry rule stops the walk, as pub closes the flow wherever
    its brackets balance; only a column-0 document marker or the end of the
    file does, as pub ends the flow there. The fold decides every line, as
    pub scans it.
    """
    items = []
    idx = start
    for _ in range(len(lines) + 1):
        if idx >= len(lines):
            break
        raw = lines[idx]
        if is_marker_line(raw, "---") or is_marker_line(raw, "..."):
            break
        items.append((idx + 1, raw))
        idx += 1
    return items

def _spanning_prefix(items, anchors):
    """Probes leading runs of `items` for one flow collection. Returns (count, folded, problem).

    The shortest run that folds without a problem and parses as one flow
    collection wins, as pub closes the flow at the first point its token
    stream completes; a later sibling never joins it. An unknown column-0
    `%` line is no run member, as pub only warns about it and reads past
    it, so the probe skips those items while still consuming them. A
    "control" problem, or a `%` anywhere else (a known directive, an
    indented one, or one opening a scalar mid-line), stops the search with
    (0, "", problem), as pub rejects the flow there; a plain-scalar comment
    or an unparsable fold continues it, as a later line may close. `count`
    spans the consumed original items through the close, so the caller
    resumes past any skipped directive. `anchors` resolves aliases while
    probing, read-only.
    """
    kept = [(0, items[0])] + [(n, items[n]) for n in range(1, len(items)) if not is_unknown_directive(items[n][1])]
    for k in range(1, len(kept) + 1):
        folded, problem = flow_fold_lines([item for _n, item in kept[:k]], flow_scan_start(), True)
        if problem != None:
            if problem[0] in ["control", "directive"]:
                return 0, "", problem
            continue
        if _folded_flow_ok(folded, anchors):
            return kept[k - 1][0] + 1, folded, None
    return 0, "", None

def _flow_resume_index(items, anchors):
    """Returns the 0-based index past a refused flow's close, or None.

    Unknown column-0 `%` lines are skipped only to find the close, as pub
    warns about them and reads past them; the refusal itself stands, as pub
    rejects a known or indented directive there. None when no leading run
    closes, and the caller resumes where the bounded walk ended.
    """
    kept = [items[0]] + [item for item in items[1:] if not is_unknown_directive(item[1])]
    count, _folded, _problem = _spanning_prefix(kept, anchors)
    if count > 0:
        return kept[count - 1][0]
    return None

def _folded_flow_ok(joined, anchors):
    """Returns whether the folded `joined` text reads as one flow collection.

    Anchor and tag prefixes are stripped first, so `&a [x,` folding with `y]`
    probes as `[x, y]`, the value pub reads. `anchors` resolves aliases while
    probing, read-only.
    """
    head = flow_head_text(joined)
    if head[:1] not in ["[", "{"]:
        return False
    probe = struct(problems = [], strict_lines = False, tag_prefixes = {})
    return parse_flow(head, anchors, probe, 0) != None

def _pending_flow_raws(lines, idx, parent_indent):
    """Collects the raw lines a value after `key:` or `-` folds with. Returns (items, next index).

    Each item is a (1-based line, raw line) pair, with "" for each blank
    line. Lines without block content (such as `#` comment lines) are kept raw: inside quotes they are scalar
    content, as pub reads them, and the quote-aware fold decides. A dedent
    or a line that opens an entry ends the fold.
    """
    items = []
    next_idx = idx
    for _ in range(len(lines) + 1):
        if next_idx >= len(lines):
            break
        raw = lines[next_idx]
        if not raw.strip():
            if bad_blank_index(raw) >= 0:
                # A blank-looking line with a bad blank survives as raw, as
                # in `_block_fold_gather`: the fold reports it naming the
                # line, as pub rejects it.
                items.append((next_idx + 1, raw))
            else:
                items.append((next_idx + 1, ""))
            next_idx += 1
            continue
        indent, text = block_line_text(raw)
        if indent == None:
            items.append((next_idx + 1, raw))
            next_idx += 1
            continue
        if indent <= parent_indent:
            break
        if is_dash(text) or text.startswith("? ") or text.startswith(": ") or is_mapping_start(text):
            break
        items.append((next_idx + 1, raw))
        next_idx += 1
    return items, next_idx

def _map_key_value(text, key_text, anchors, state, line):
    """Reads a block mapping or dash key, failing a glued alias key closed.

    A colon glued to an alias (`*x: 2`) joins the alias name, as pub scans
    it, and never reads as a pair, as pub rejects it; an unresolvable name
    reports its alias problem, and a resolvable one is still a problem
    naming the line. A block scalar header (`|`, `>` with any indicators)
    never reads as a key, as pub rejects a block scalar there; anything
    starting with `|` or `>` is one, since a plain scalar never starts with
    a reserved indicator, as pub scans it. A flow collection key (`[` or
    `{` past anchor and tag prefixes) fails too, as pub keys it on a list
    or map the reader keeps no key for; a quoted one reads as before, as
    pub reads it. Any other key reads as before.
    """
    if key_text.startswith("*") and text[len(key_text):len(key_text) + 1] == ":":
        ok, _value = resolve_alias(key_text[1:] + ":", anchors, state, line)
        if not ok:
            return None
        state.problems.append("glued alias key at line %d is not supported" % line)
        return None
    _anchor, _tag, key_rest, _bad = strip_value_prefix(key_text)
    if key_rest[:1] in ["|", ">"]:
        state.problems.append("block scalar as key at line %d is not supported" % line)
        return None
    if key_rest[:1] in ["[", "{"]:
        state.problems.append("collection key at line %d is not supported" % line)
        return None
    return dict_key(parse_scalar(key_text, anchors, state, line))

def _block_value_entry_problem(rest, state, line):
    """Records a block entry where a same-line mapping value starts. Returns True when one fails.

    A `- ` entry fails, as pub rejects a block sequence where a value
    starts, and a `? ` marker fails, as pub rejects an explicit key there;
    the anchor and tag prefixes are already stripped, as pub still rejects
    the entry under them. A `: `, `:\\t` or trailing colon inside a plain
    value fails, as pub rejects a mapping value inside a plain scalar, even
    past mid-scalar quotes or brackets; quoted, flow, block-scalar and alias
    values read as before, as pub reads them.
    """
    if is_dash(rest):
        state.problems.append("block sequence entry at line %d is not supported" % line)
        return True
    if is_question_entry(rest):
        state.problems.append("explicit key at line %d is not supported" % line)
        return True
    if rest[:1] in ["", "\"", "'", "[", "{", "|", ">", "*"]:
        return False
    if ": " in rest or ":\t" in rest or ":\r" in rest or rest.endswith(":") or rest.endswith(":\r"):
        state.problems.append("mapping value at line %d is not supported" % line)
        return True
    return False

def _apply_pending_scalar_tag(word, value, raw, state, line):
    """Applies a pending tag to a folded scalar child. Returns the value.

    Scalar type tags convert as the same-line tags do, through the shared
    bool, null, int, float and str readers, as pub reads them. A `!!seq` or
    `!!map` tag, or any other `!!` tag, has no scalar to convert and is an
    undefined tag problem naming the tag's line, as pub reports it; a named
    handle or verbatim tag is an undefined-handle problem, while a local tag
    reads a scalar as its string, as pub reads them. A problem still reads
    the child untagged, so parsing continues past it.
    """
    if word == None:
        return value
    word = resolve_handle(word, state, line)
    if word == None:
        return value
    if is_unknown_tag_handle(word):
        state.problems.append("Undefined tag handle at line %d" % line)
        return value
    if word.startswith("!!"):
        name = tag_name(word)
        if name == "bool":
            return apply_bool_tag(value, raw, state, line)
        if name == "null":
            if value == None or value == "":
                return None
            state.problems.append("Invalid null scalar at line %d" % line)
            return None
        if name in ["str", "int", "float"]:
            return apply_tag(word, raw, value, state, line)
        state.problems.append(undefined_tag_problem(word, line))
        return value
    if type(value) == "list" or type(value) == "dict":
        return value
    return value if type(value) == "string" else raw

def _unclosed_flow_head(value_text, anchors):
    """Returns the flow text when it opens a collection that never closes on this line, else None.

    `anchors` resolves aliases while probing, read-only.
    """
    head = flow_head_text(value_text)
    if head[:1] not in ["[", "{"]:
        return None
    probe = struct(problems = [], strict_lines = False, tag_prefixes = {})
    if parse_flow(head, anchors, probe, 0) != None:
        return None
    return head
