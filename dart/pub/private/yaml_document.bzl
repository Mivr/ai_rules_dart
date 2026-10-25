"""Document structure for the pubspec YAML reader.

Holds markers, directives, the first-document walk and the block container
walk. Loaded by the `yaml_subset.bzl` entry point.
"""

load(":yaml_block.bzl", "close_block_containers", "drop_affix", "drop_pending_value", "emit_dangling", "init_block_root", "map_line", "record_dangling", "resolve_affix_root", "resolve_pending", "seq_line", "take_lone_line")
load(":yaml_chars.bzl", "BOM", "is_bom_only_line", "is_clean_marker_line")
load(":yaml_scalar.bzl", "strip_value_prefix")
load(":yaml_text.bzl", "bad_blank_index", "block_line_text", "clone", "indent_width", "is_dash", "is_question_entry", "is_unknown_directive", "record_unreadable", "split_block_key_value", "strip_trailing_comment")

def first_content(lines):
    """Returns the first line with block content as struct(index, text).

    Blank lines, `#` comments, `%` directives and document markers carry no
    block content. Returns index -1 and text "" when no line has content.

    Args:
      lines: the document lines.

    Returns:
      The first line with block content as struct(index, text).
    """
    for i in range(len(lines)):
        _indent, text = block_line_text(lines[i])
        if text != None:
            return struct(index = i, text = text)
    return struct(index = -1, text = "")

def allows_flow_doc(lines, index):
    """Returns whether a flow document may open at `index`.

    Every line before `index` must be blank or a comment: a `%` line (from
    inline marker text) means the bracket does not open a flow document, as
    pub rejects `%` text there.

    Args:
      lines: the document lines.
      index: the 0-based index where a flow document may open.

    Returns:
      Whether a flow document may open there.
    """
    for i in range(index):
        stripped = lines[i].strip()
        if stripped != "" and not stripped.startswith("#"):
            return False
    return True

def flow_doc_problem(lines):
    """The problem for a flow-looking document that reads as no collection.

    The fold succeeded but the folded text is not one complete collection:
    pub rejects these shapes (an unclosed collection, text or a comment past
    the closing bracket), so the reader fails closed naming the last content
    line instead of reading an empty document.

    Args:
      lines: the document lines.

    Returns:
      The problem text.
    """
    last = 1
    for i in range(len(lines)):
        _indent, text = block_line_text(lines[i])
        if text != None:
            last = i + 1
    return "flow document ending at line %d is not supported" % last

def _doc_content_line(line):
    """Returns whether `line` counts as document content."""
    stripped = line.strip()
    return stripped != "" and not stripped.startswith("#") and not stripped.startswith("%")

def _doc_tail_content(line):
    """Returns whether `line` is content after the document ended.

    Blank and `#` comment lines are not content; anything else, including a
    `%` line, ends the single document, as the lock tail check reads it.
    """
    stripped = line.strip()
    return stripped != "" and not stripped.startswith("#")

def _doc_dash_line(line, idx, current, doc, state):
    """Handles a column-0 `---` line. Returns whether collection stops.

    Only `---` followed by a space, a tab or the end of the line reaches
    here; anything glued to the marker (`---x: 1`) is an ordinary line, as
    pub reads it as a key. Inline text after the marker reads as the
    document, unless it starts a block mapping or sequence, which fails
    naming the line, as pub rejects it.
    """
    if is_clean_marker_line(line, "---"):
        if doc["ended"] or doc["content"] or doc["marker"]:
            state.problems.append("second document marker (---) at line %d" % idx)
            return True

        # A `---` after directives still starts the document, as pub reads
        # `%YAML 1.1\n---\nkey: 1`: the directives were already processed,
        # so the marker only clears the pending directive state, leaving a
        # blank so later lines keep their numbers.
        current.append("")
        doc["marker"] = True
        doc["pending"] = False
        return False
    if line[3:4] in [" ", "\t"]:
        if doc["ended"] or doc["content"]:
            state.problems.append("second document marker (---) at line %d" % idx)
            return True
        problem = _marker_rest_problem(line[3:], idx)
        if problem != None:
            state.problems.append(problem)
        current.append(line[3:].strip())
        doc["content"] = True
        doc["pending"] = False
        return False
    if doc["ended"] or doc["content"]:
        state.problems.append("second document marker (---) at line %d" % idx)
        return True
    if doc["pending"]:
        state.problems.append("directive without document start at line %d" % idx)
        doc["pending"] = False
    current.append(line)
    doc["content"] = True
    return False

def _doc_dots_line(line, idx, current, doc, state):
    """Handles a column-0 `...` marker. Returns whether collection stops.

    Only `...` followed by a space, a tab or the end of the line reaches
    here; text glued to the marker (`...x`, `....: 2`) is an ordinary line,
    as pub reads `...x` as content failing for its missing colon and
    `....: 2` as a key. A clean marker ends the document, while inline
    text after it reads, as pub reads `... text` as "text".
    """
    if is_clean_marker_line(line, "..."):
        if doc["pending"]:
            state.problems.append("directive without document start at line %d" % idx)
            doc["pending"] = False
        doc["ended"] = True
        return False
    text = line[3:].strip()
    if doc["ended"] or doc["content"]:
        state.problems.append("content after document end (...) at line %d" % idx)
        return True
    if text.startswith("%"):
        # Inline `%` text after `...` is no content, as pub rejects it there.
        state.problems.append("directive after document marker at line %d is not supported" % idx)
        return False
    if doc["pending"]:
        state.problems.append("directive without document start at line %d" % idx)
        doc["pending"] = False
    current.append(text)
    doc["content"] = True
    return False

def _marker_rest_problem(rest, idx):
    """The problem for inline text after a `---` marker, else None.

    A block mapping or sequence that starts on the marker line fails, as pub
    rejects it there, while a scalar or a flow collection reads. Anchor and
    tag prefixes do not shield the entry, as pub still rejects
    `--- &x a: 1`; an alias or a block scalar header reads as before. A
    `te[st: 1` mapping fails too, as pub rejects it there, and so does a
    list or map key, as pub rejects `--- [a]: v` without it. Inline `%`
    text fails too, as pub rejects `--- %foo` there.
    """
    _anchor, _tag, s, _bad = strip_value_prefix(strip_trailing_comment(rest).strip())
    if s.startswith("%"):
        # Inline `%` text after `---` is no document, as pub rejects it there.
        return "directive after document marker at line %d is not supported" % idx
    if is_dash(s):
        return "Block sequence entries are not allowed here at line %d" % idx
    if is_question_entry(s):
        return "Mapping keys are not allowed here at line %d" % idx
    _dict_key, _value, found = split_block_key_value(s)
    if found:
        return "Mapping values are not allowed here at line %d" % idx
    return None

def _collect_percent_line(line, idx, current, doc, state):
    """Collects a column-0 `%` line. Returns False, as collection never stops here.

    Every raw line keeps its collected slot, so later lines keep their
    numbers: a pre-content directive stays verbatim for the block walk,
    which reads past it, as pub reads past it. An unknown directive reads
    past before any content and after the document end, as pub only warns
    about it; past content it stays verbatim, as an open flow folds past
    it and the block walk places it. A known directive processes before
    any content or marker through `_directive_line`, and fails past them,
    as pub rejects directives after the document or its start.
    """
    if is_unknown_directive(line):
        current.append(line)
        return False
    if not doc["content"] and not doc["marker"]:
        _directive_line(line, idx, doc, state)
        current.append(line)
        return False
    if doc["content"]:
        state.problems.append("directive after document content at line %d is not supported" % idx)
    else:
        state.problems.append("directive after document start at line %d is not supported" % idx)
    current.append("")
    return False

def _collect_doc_line(line, idx, current, doc, state):
    """Collects one raw line into the first document. Returns True when collection stops here."""
    if line.startswith("---") and line[3:4] in ["", " ", "\t"]:
        return _doc_dash_line(line, idx, current, doc, state)
    if line.startswith("...") and line[3:4] in ["", " ", "\t"]:
        return _doc_dots_line(line, idx, current, doc, state)
    if doc["ended"]:
        if line.startswith("%"):
            if not is_unknown_directive(line) and getattr(state, "refuse_tail_directives", False):
                # A known trailing directive is invalid, as pub rejects it there.
                state.problems.append("directive after document end (...) at line %d" % idx)
                current.append("")
                return False

            # Otherwise the directive reads past: an unknown one, as pub
            # only warns about it, or a known one in a lock, as before.
            current.append("")
            return False
        if _doc_tail_content(line):
            state.problems.append("content after document end (...) at line %d" % idx)
            return True
        return False
    if line.startswith("%"):
        return _collect_percent_line(line, idx, current, doc, state)
    if not doc["content"] and not doc["marker"] and line.strip().startswith("%"):
        state.problems.append("indented directive at line %d" % idx)
        current.append(line)
        return False
    current.append(line)
    if _doc_content_line(line):
        if doc["pending"]:
            state.problems.append("directive without document start at line %d" % idx)
            doc["pending"] = False
        doc["content"] = True
    return False

def first_document_lines(content, state):
    """Returns the lines of the first document with its `%TAG` prefixes.

    Returns (lines, tag_prefixes, dropped_marker), where lines splits as
    yaml.bzl splits them, tag_prefixes maps each declared `%TAG` handle to
    its prefix, and dropped_marker tells whether a pre-content `---` was
    consumed. Every raw line keeps its collected slot: a processed
    directive and a consumed marker each leave a blank, so later lines keep
    their numbers.
    One stream carries one document, as pub reads it: a second column-0
    `---` line is a problem naming its line, even before any content and
    even with only comments after it, and so is any content after a
    column-0 `...` line, naming the content's line. A marker is the three
    characters followed by a space, a tab or the end of the line: text
    glued to it is an ordinary line, as pub reads `---x: 1` as a key and
    `...x` as content. A `---` before any
    content starts the document, unless a directive precedes it, in which
    case it is kept as an ordinary line; inline text after a pre-content
    marker reads as the document, as pub reads `--- foo` as "foo" and
    `... text` as "text". A trailing `...` alone stays allowed.

    Args:
      content: the file content.
      state: the parse state collecting problems.

    Returns:
      The (lines, tag_prefixes, dropped_marker) triple: the first document lines, each
      declared `%TAG` handle with its prefix, and whether a pre-content `---` was
      consumed. A consumed marker leaves a blank slot, so later lines keep
      their numbers.
    """
    normalized = content.replace("\r\n", "\n").replace("\r", "\n")
    current = []
    doc = {"content": False, "marker": False, "ended": False, "pending": False, "yaml": False, "tags": {}}
    raw_lines = normalized.split("\n")
    idx = 0
    for line in raw_lines:
        idx += 1
        if _collect_doc_line(line, idx, current, doc, state):
            return current, doc["tags"], doc["marker"]
    if doc["pending"]:
        state.problems.append("directive without document start at line %d" % len(raw_lines))
    return current, doc["tags"], doc["marker"]

def _yaml_version_ok(version):
    """Returns whether a `%YAML` version reads as pub reads it: major 1 with minor 1 or more.

    Oracle (package:yaml 3.1.4): `1.1` through `1.10` read (`1.3` with a
    warning only), while `1.0`, `0.9` and `2.0` fail as incompatible, and
    anything not shaped `digits.digits` fails as malformed.
    """
    parts = version.split(".")
    if len(parts) != 2:
        return False
    for part in parts:
        if not part or part.strip("0123456789") != "":
            return False
    return int(parts[0]) == 1 and int(parts[1]) >= 1

def _tag_handle_ok(handle):
    """Returns whether a `%TAG` handle reads as pub reads it: `!`, `!!` or `!name!`.

    Oracle: `!` and `!a!` read, while `!a` fails expecting `!`.
    """
    if handle == "!":
        return True
    if len(handle) < 2 or not handle.startswith("!") or not handle.endswith("!") or "#" in handle:
        return False
    for ch in handle[1:-1].elems():
        if ch == "!":
            return False
    return True

def _directive_comment_cut(text):
    """Cuts a `%TAG` line at a `#` comment, which starts only after whitespace.

    A `#` glued to the prefix is no comment: pub rejects `%TAG ! t:x#c`
    expecting whitespace, while `%TAG ! t:x # c` reads.
    """
    for i in range(len(text)):
        if text[i] == "#" and text[i - 1] in [" ", "\t"]:
            return text[:i]
    return text

def _directive_words(text):
    """Splits directive text on spaces and tabs, dropping empty words."""
    return [w for w in text.replace("\t", " ").split(" ") if w != ""]

def _directive_line(line, idx, doc, state):
    """Processes a column-0 `%` line before any content, marker or end.

    A duplicate `%YAML` fails, as does a second `%TAG` with the same
    handle; a `%YAML` whose version is missing, malformed or incompatible
    fails, as does a `%TAG` without a valid handle and prefix; an unknown
    directive reads on, as pub only warns about it. A valid `%TAG` records
    its handle prefix, so later uses resolve through it. A bad directive sets no
    state: the document is already rejected by its problem.
    """
    text = line.strip()
    tokens = _directive_words(text)
    name = tokens[0][1:]
    if name == "":
        state.problems.append("invalid directive at line %d" % idx)
        return
    if name == "YAML":
        parts = _directive_words(text.split("#")[0])
        if len(parts) != 2 or not _yaml_version_ok(parts[1]):
            state.problems.append("invalid YAML directive at line %d" % idx)
            return
        if doc["yaml"]:
            state.problems.append("duplicate YAML directive at line %d" % idx)
            return
        doc["yaml"] = True
        doc["pending"] = True
        return
    if name == "TAG":
        parts = _directive_words(_directive_comment_cut(text))
        if len(parts) != 3 or not _tag_handle_ok(parts[1]) or "#" in parts[2]:
            state.problems.append("invalid TAG directive at line %d" % idx)
            return
        if parts[1] in doc["tags"]:
            state.problems.append("duplicate TAG directive at line %d" % idx)
            return
        doc["tags"][parts[1]] = parts[2]
        doc["pending"] = True
        return

# ---------------------------------------------------------------------------
# Block structure
# ---------------------------------------------------------------------------

def _block_skip_line(raw, idx, first_line, state):
    """Consumes a non-content line. Returns True when the line is skipped.

    A bare mark line is blank-like at column 0, as pub skips it, and a
    problem naming the line anywhere else, as pub rejects it. A tab never
    indents: a line starting with a tab, and a content line with a tab in
    its leading whitespace, are problems naming the line, as pub rejects
    them, except on the file's first line, where they are separation
    before the first token, as pub reads them. Only space and tab are
    blanks: a vertical tab, form feed or U+001C to U+001F outside quotes
    and comments is a problem naming the line, as pub rejects it.
    """
    if BOM in raw and is_bom_only_line(raw):
        if indent_width(raw) > 0:
            state.problems.append("byte-order mark at line %d is not supported" % (idx + 1))
        return True
    if not (idx == 0 and first_line) and (raw.startswith("\t") or (raw.strip(" \t") != "" and "\t" in raw[:indent_width(raw)])):
        state.problems.append("tab indentation at line %d is not supported" % (idx + 1))
        return True
    if bad_blank_index(raw) >= 0:
        state.problems.append("control character at line %d is not supported" % (idx + 1))
        return True
    return False

def _later_doc_content(lines, start):
    """Returns the 1-based line of the next content line at or past `start`, or 0.

    Blank, `#` comment, `%` directive and clean document marker lines are
    no content: only a line the block walk would place counts, as only past
    one does pub read a second document.
    """
    for n in range(start, len(lines)):
        stripped = lines[n].strip()
        if stripped == "" or stripped.startswith("#") or stripped.startswith("%"):
            continue
        if is_clean_marker_line(lines[n], "---") or is_clean_marker_line(lines[n], "..."):
            continue
        return n + 1
    return 0

def _block_directive_line(lines, idx, saw_content, state):
    """Consumes a column-0 `%` line. Returns the next index.

    Only pre-content directives and unknown ones reach the block walk:
    known ones past content fail at collection. Before any content the
    line reads past, as pub reads past it (a known one was already
    processed at collection, and pub only warns about an unknown one).
    Past content a trailing directive reads past, as pub only warns about
    it, while one with content after it fails naming that line, as pub
    reads a second document there.
    """
    if not saw_content:
        return idx + 1
    later = _later_doc_content(lines, idx + 1)
    if later > 0:
        state.problems.append("content after directive at line %d is not supported" % later)
    return idx + 1

def parse_block(lines, state, first_line):
    """Parses the block-structured lines of one document into a value.

    `first_line` tells whether lines[0] is the file's first line: there
    tabs and spaces before the first token are separation, not indentation,
    as pub reads them. A consumed pre-content `---` leaves a blank slot, so
    every later line keeps its number; only an unshifted first line, one
    with no consumed marker before it, is exempt.

    An open container is a frame, a dict {kind, indent, value, entry}. `kind`
    is "map" or "seq", `indent` is the column its entries must be nested
    beyond, and `entry` is the column of its first entry, which later entries
    must match. A compact sequence frame also carries `compact` True.

    `pending` describes a key or dash whose value is on the following lines:
    a dash at its own column becomes a compact sequence, a deeper mapping or
    sequence line becomes the child container, and deeper scalar lines fold
    into the value with single spaces. A lone anchor/tag line merges into the
    pending slot, or waits as the `affix` for the root node, as pub applies
    it to the next line; in an open container with no pending slot the line
    waits as `lone` for the problem the next line reports, as pub names that
    line. `state` collects duplicate-key and
    (when strict) unreadable-line problems.

    Args:
      lines: the block-structured lines of one document.
      state: the parse state collecting problems.
      first_line: whether lines[0] is the file's first line.

    Returns:
      The parsed value.
    """
    anchors = {}
    root = None
    stack = []
    pending = None
    lone = {"text": None, "line": 0}
    affix = {"anchor": None, "tag": None, "tag_line": 0}
    saw_content = False
    idx = 0
    for _ in range(len(lines) + 1):
        if idx >= len(lines):
            break
        raw = lines[idx]
        if _block_skip_line(raw, idx, first_line, state):
            idx += 1
            continue
        indent, text = block_line_text(raw)
        if indent == None:
            if raw.startswith("%"):
                idx = _block_directive_line(lines, idx, saw_content, state)
                continue
            if saw_content and raw.strip().startswith("%"):
                # An indented `%` line after content is no directive: pub
                # rejects it, so it is a problem naming the line.
                record_unreadable(state, idx, raw.strip())
            idx += 1
            continue
        saw_content = True
        cursor = struct(lines = lines, idx = idx, indent = indent, text = text)
        root, pending, idx, done = _block_dispatch_line(cursor, struct(anchors = anchors, stack = stack, state = state, lone = lone, affix = affix), root, pending)
        if done:
            continue
    if pending != None:
        drop_pending_value(pending, anchors, state)
    drop_affix(affix, anchors, state)
    if lone["text"] != None:
        state.problems.append("unreadable line %d: %r" % (lone["line"], lone["text"]))
    for _ in range(len(stack) + 1):
        if not stack:
            break
        top = stack.pop()
        if top.get("anchor", None) != None:
            anchors[top["anchor"]] = clone(top["value"])
    return root

def _block_dispatch_line(cursor, env, root, pending):
    """Parses one content line into the open containers. Returns (root, pending, idx, done).

    `cursor` carries the line as {lines, idx, indent, text}; `env` carries
    {anchors, stack, state} plus the `lone` dangling line and the `affix`
    root properties. `done` tells the caller to continue with the
    next line: the pending value resolved without a container line to
    place, the root scalar read, or the line stayed orphaned.
    """
    lines, idx, indent, text = cursor.lines, cursor.idx, cursor.indent, cursor.text
    anchors, stack, state = env.anchors, env.stack, env.state
    close_block_containers(stack, indent, text, anchors)
    emit_dangling(env.lone, state, idx)
    if pending != None:
        if take_lone_line(pending, text, idx + 1, anchors, state):
            return (root, pending, idx + 1, True)
        idx, skip = resolve_pending(pending, struct(lines = lines, idx = idx, indent = indent, text = text), struct(anchors = anchors, stack = stack, state = state))
        pending = None
        if skip:
            return (root, pending, idx, True)
    if root == None and not stack:
        if take_lone_line(env.affix, text, idx + 1, anchors, state):
            return (root, pending, idx + 1, True)
        if env.affix["anchor"] != None or env.affix["tag"] != None:
            root, idx = resolve_affix_root(env.affix, lines, idx, indent, text, anchors, stack, state)
            if not stack:
                return (root, pending, idx, True)
        else:
            root, is_scalar = init_block_root(text, indent, anchors, stack, state, idx + 1)
            if is_scalar:
                return (root, pending, idx + 1, True)
    if not stack:
        record_unreadable(state, idx, text)
        return (root, pending, idx + 1, True)
    if record_dangling(env.lone, text, idx + 1):
        return (root, pending, idx + 1, True)
    frame = stack[-1]
    if frame["kind"] == "map":
        idx, pending = map_line(lines, idx, indent, text, frame, anchors, state)
    else:
        idx, pending = seq_line(lines, idx, indent, text, frame, anchors, stack, state)
    return (root, pending, idx, False)
