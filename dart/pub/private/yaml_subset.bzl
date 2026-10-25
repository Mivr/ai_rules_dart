"""A YAML parser for the subset that pubspec.yaml and pubspec.lock files use.

`parse_document(content)` returns the value of the first document in
`content`. It builds the same Starlark values that `yaml.bzl` builds (dict,
list, string, int, float, bool, None), in the same insertion order, so the
projections in `dart/pub/yaml_parser.bzl` return what they returned with
yaml.bzl. Scalar typing follows yaml.bzl exactly (`1.10` is a float, `true` a
bool, `~` None, `0x1F` an int), because `str()` of those values reaches the
lock-file output.

Starlark has no recursion and no `while`, so the parser keeps an explicit
stack of open containers and runs bounded `for` loops. Like pub's own YAML
loader, it fails on duplicate keys in any mapping (block or flow, at any
depth), naming the key and the line: a silently resolved duplicate would pin
the wrong source or version. Any line it cannot place, including a `- ` line
where a mapping entry is expected and an unreadable flow value, is a problem
naming its 1-based line. Two unsupported forms are always problems, in
strict and lenient modes alike, so no read returns partial data for them: a
flow collection that spans lines without folding to one value, and an
explicit key (`? key` with `: value`, including a `:` line that continues a
plain scalar). A flow whose lines fold with single spaces to one flow
collection is read as pub reads it, whether it starts on its key's line, on
the line after `key:` or `-`, or not. A `?` line that continues a plain
scalar folds into it outside a nested mapping, as pub folds it; in a
nested mapping it opens an explicit key. `parse_document` fails on the first problem instead
of returning partial data. `document_problems` with strict lines reports every
such problem so lock files can fail closed; without strict lines it reports
duplicate keys and the unsupported forms. A leading byte-order mark is
stripped, as pub accepts it.

Supported:
- block mappings and sequences nested by indentation, including `- key: v`
  items, children that start on the lines after `key:` or `-`, and compact
  sequences where `- ` entries sit at their key's own column
- `#` comments, `%` directive lines before any content (skipped), and `---`
  and `...` document markers at column 0 only: an indented marker is never
  a marker, so one inside a `|` or `>` block scalar stays scalar content.
  A `%` line after content is a problem naming the line, as pub rejects it.
- plain, single-quoted and double-quoted scalars, with yaml.bzl's escapes,
  including scalars that start on the line after `key:` or continue on
  deeper lines, which fold through the same quote-aware pass as flow lines
- flow collections `[...]` and `{...}`, nested; on a line of their own they
  are read within that line, a document that starts with one may span
  lines (JSON documents), and one that starts after `key:` or `-` folds
  its deeper lines and reads as one value when the folded text parses.
  Folding follows pub through one quote-aware pass over the raw lines: a
  break between content lines is one space, indentation is dropped, a
  blank line is one "\n" inside quotes while a blank run outside quotes
  is one "\n", and comment-only lines are skipped outside quotes. A quote
  opens only where a scalar starts, so an apostrophe in a plain scalar
  never opens one and `''` in single quotes is one escaped quote; `#`
  outside quotes starts a comment to the end of the line, whether the
  value before it is complete or not, so pub only fails where the comment
  swallows a token the flow needs; a backslash at a double-quoted line's
  end continues the scalar with no space while elsewhere a backslash is
  an ordinary character, and a backslash with trailing space in double
  quotes is an escaped space (the backslash is dropped) plus the folded
  space, while in single quotes the backslash stays literal. Block scalars
  after `key:` or `-` fold through this same pass; see below. A comment that ends a line
  inside a plain scalar and a `%` outside quotes and plain scalars are not
  supported, and fail naming the line.
- block scalars `|` and `>` with chomping and indentation indicators
- plain, quoted, typed and anchored scalars continued on more-indented
  lines, folded through the same quote-aware pass: a break between content
  lines is one space, quotes close at any indent, and indented markers read
  as content. A `?` line without a colon folds into an open scalar except
  in a nested mapping, where it opens an explicit key; a `- ` line without
  a colon folds into an open scalar at any depth, while one with a colon
  ends it. A comment-only or trailing-comment line ends a plain scalar
  silently; text after a same-line closing quote, a tab-indented line and
  a `%` line where pub rejects it are problems naming the line. These
  shapes read as package:yaml 3.1.4 reads them.
- anchors and aliases, copied shallowly as yaml.bzl copies them
- the tags !!str, !!int, !!float, !!bool, !!null, !!seq and !!map

Divergences from yaml.bzl. None occurs in the pubspec corpus used for parity
testing, so the projections are unaffected on real pubspec files:
- explicit keys (`? key` with `: value`) are not supported; yaml.bzl reads
  both. They fail naming the line, even a `:` line that continues a plain
  scalar: pub rejects that line, while yaml.bzl folds it, so failing closed
  matches pub. Reading and failing closed changed for the forms an older
  revision misread: a `:` continuation (folded before), a `%`-leading flow
  scalar (read as plain before), a flow-looking document that reads as no
  collection (read as empty before), text after a same-line closing quote
  (kept before), a `%` line at a scalar's start or after content (folded or
  skipped before), a tab-indented continuation (folded before), a stray
  line after a comment-ended scalar (folded before), and an indented marker
  after a same-line scalar (reported before, pub folds it into the scalar).
- flow collections that span lines are not supported, unless the folded
  lines read as one flow collection as pub reads them; yaml.bzl reads all
  spanning flows. The supported fold matches pub on the oracle-checked
  shapes (plain, single- and double-quoted scalars, flow mapping values,
  blank and comment-only lines between the folded lines, backslash
  continuations, `#` lines and ` # ` text inside quotes, comments after
  complete values, and `---` content lines); a comment that ends a line
  inside a plain scalar and a `%` outside quotes and plain scalars fail
  naming the line instead of misreading.
- merge keys (`<<`) are ordinary keys; yaml.bzl merges them into the mapping.
  YAML 1.2 defines no merge keys.
- `%TAG` handles are ignored, so a tag written through one reads as untagged;
  yaml.bzl resolves it. Other unknown tags read as untagged in both.
- duplicate mapping keys fail; yaml.bzl's default non-strict mode silently
  keeps the first scalar and replaces a nested block with a later one.
"""

# Escapes allowed in double-quoted scalars, as yaml.bzl maps them.
_ESCAPES = {
    "0": "\0",
    "a": "\a",
    "b": "\b",
    "t": "\t",
    "n": "\n",
    "v": "\v",
    "f": "\f",
    "r": "\r",
    " ": " ",
    '"': '"',
    "/": "/",
    "\\": "\\",
}

_HEX_DIGITS = "0123456789abcdef"

# A leading UTF-8 byte-order mark (U+FEFF), written as octal escapes so the
# source stays ASCII. Pub accepts it; without stripping, the first key would
# carry it and a lock would read as missing `packages`.
_BOM = "\357\273\277"

_FLOW_SPACE = " \t\n\r"

_YAML_TAG_PREFIX = "tag:yaml.org,2002:"

# ---------------------------------------------------------------------------
# Documents
# ---------------------------------------------------------------------------

def parse_document(content):
    """Returns the value of the first YAML document in `content`.

    Fails on the first problem: duplicate keys, lines the parser cannot
    place, and unreadable flow values, each naming its 1-based line. It
    never returns partial data.

    Args:
        content: The text of a YAML stream. A leading byte-order mark is
            stripped, as pub accepts it.

    Returns:
        The document's value, or None when the document is empty.
    """
    value, problems = _parse_document(content, True)
    if problems:
        fail(problems[0])
    return value

def document_value_and_problems(content, strict_lines = False):
    """Parses one document without failing. Returns (value, problems).

    Args:
        content: The text of a YAML stream.
        strict_lines: Also report lines the parser cannot place.

    Returns:
        A tuple of the document value and the problem list.
    """
    return _parse_document(content, strict_lines)

def document_problems(content, strict_lines = False):
    """Reports duplicate keys and, with strict lines, skipped lines.

    Duplicate keys are always reported, as are the unsupported forms: a
    spanning flow that does not fold, an explicit key, and a flow-looking
    document that reads as no collection. Other lines the parser cannot
    place (wrong indentation, lines without a colon, a `- ` line where a
    mapping entry is expected, unreadable flow values) are reported only
    with strict lines, for lock files that must fail closed. Blank lines,
    comments, directives and document markers are never problems.

    Args:
        content: The text of a YAML stream.
        strict_lines: Also report lines the parser cannot place.

    Returns:
        The list of problem messages, empty when the document is clean.
    """
    _value, problems = _parse_document(content, strict_lines)
    return problems

def _parse_document(content, strict_lines):
    """Parses one document. Returns (value, problems) without failing."""
    state = struct(problems = [], strict_lines = strict_lines)
    lines = _first_document_lines(_strip_bom(content))
    first = _first_content(lines)
    if first.text[:1] in ["{", "["] and _allows_flow_doc(lines, first.index):
        items = []
        for i in range(len(lines)):
            items.append((i + 1, lines[i]))
        folded, problem = _flow_fold_lines(items, _flow_scan_start())
        if problem != None:
            state.problems.append(_flow_fold_problem(problem[0], problem[1]))
            return None, state.problems
        value = _parse_flow(folded, {}, state, 1)
        if value == None:
            state.problems.append(_flow_doc_problem(lines))
            return None, state.problems
        return value, state.problems
    return _parse_block(lines, state), state.problems

def _first_content(lines):
    """Returns the first line with block content as struct(index, text).

    Blank lines, `#` comments, `%` directives and document markers carry no
    block content. Returns index -1 and text "" when no line has content.
    """
    for i in range(len(lines)):
        _indent, text = _block_line_text(lines[i])
        if text != None:
            return struct(index = i, text = text)
    return struct(index = -1, text = "")

def _allows_flow_doc(lines, index):
    """Returns whether a flow document may open at `index`.

    Every line before `index` must be blank or a comment: a `%` directive or
    a kept `---` line means the bracket opens a block value, as pub reads it
    there.
    """
    for i in range(index):
        stripped = lines[i].strip()
        if stripped != "" and not stripped.startswith("#"):
            return False
    return True

def _flow_doc_problem(lines):
    """The problem for a flow-looking document that reads as no collection.

    The fold succeeded but the folded text is not one complete collection:
    pub rejects these shapes (an unclosed collection, text or a comment past
    the closing bracket), so the reader fails closed naming the last content
    line instead of reading an empty document.
    """
    last = 1
    for i in range(len(lines)):
        _indent, text = _block_line_text(lines[i])
        if text != None:
            last = i + 1
    return "flow document ending at line %d is not supported" % last

def _strip_bom(content):
    """Strips a leading UTF-8 byte-order mark, which pub accepts."""
    if content.startswith(_BOM):
        return content[len(_BOM):]
    return content

def _is_marker_line(raw, marker):
    """Returns whether `raw` is a document marker: the marker at column 0 with only whitespace after it.

    An indented marker is never a document marker: inside a `|` or `>`
    block scalar it is content, and elsewhere it is an ordinary line.
    """
    if not raw.startswith(marker):
        return False
    return raw[len(marker):].strip() == ""

def _first_document_lines(content):
    """Returns the lines of the first document, split as yaml.bzl splits them.

    A column-0 `---` line ends the first document once content has been seen.
    A column-0 `...` line ends it at any point. A `---` before any content is
    dropped, unless a directive precedes it, in which case it is kept as an
    ordinary line.
    """
    normalized = content.replace("\r\n", "\n").replace("\r", "\n")
    current = []
    saw_content = False
    for line in normalized.split("\n"):
        stripped = line.strip()
        if _is_marker_line(line, "---"):
            if saw_content:
                return current
            if _has_directive(current):
                current.append(line)
                saw_content = True
            continue
        if _is_marker_line(line, "..."):
            return current
        current.append(line)
        if stripped and not stripped.startswith("#") and not stripped.startswith("%"):
            saw_content = True
    return current

def _has_directive(lines):
    for line in lines:
        if line.strip().startswith("%"):
            return True
    return False

# ---------------------------------------------------------------------------
# Block structure
# ---------------------------------------------------------------------------

def _block_line_text(raw):
    """Returns (indent, comment-stripped text) of a block line, or (None, None) when it carries no content."""
    stripped = raw.strip()
    if not stripped or stripped.startswith("#") or stripped.startswith("%") or _is_marker_line(raw, "---") or _is_marker_line(raw, "..."):
        return None, None
    indent = _indent_width(raw)
    text = _strip_comment(raw[indent:])
    if text == "":
        return None, None
    return indent, text

def _is_dash(text):
    """Returns whether `text` opens a block sequence entry."""
    return text == "-" or text.startswith("- ")

def _is_mapping_start(text):
    """Returns whether `text` opens a block mapping entry."""
    return text.startswith("? ") or text.startswith(": ") or _find_colon(text) >= 0

def _is_compact_seq(pending, indent, text):
    """Returns whether `text` is a compact entry of a pending mapping key."""
    return type(pending["parent"]) == "dict" and indent == pending["indent"] and _is_dash(text)

def _close_block_containers(stack, indent, text):
    """Pops the containers that the line at `indent` is not nested into.

    A compact sequence keeps its entries at its key's own column, so a dash
    at the entry column stays inside it while any other line closes it.
    """
    for _ in range(len(stack)):
        if not stack or indent > stack[-1]["indent"]:
            break
        top = stack[-1]
        if top.get("compact", False) and top.get("entry", None) == indent and _is_dash(text):
            break
        stack.pop()

def _attach_pending_child(pending, indent, text, anchors, stack):
    """Attaches the child container for a pending key or dash."""
    if indent > pending["indent"]:
        child = _new_block(text)
        pending["parent"][pending["slot"]] = child
        if pending["anchor"] != None:
            anchors[pending["anchor"]] = child
        stack.append({
            "kind": "seq" if type(child) == "list" else "map",
            "indent": pending["indent"],
            "value": child,
            "entry": None,
            "compact": False,
        })

def _attach_compact_seq(pending, anchors, stack):
    """Attaches a compact sequence at its key's own column."""
    seq = []
    pending["parent"][pending["slot"]] = seq
    if pending["anchor"] != None:
        anchors[pending["anchor"]] = seq
    stack.append({
        "kind": "seq",
        "indent": pending["indent"],
        "value": seq,
        "entry": None,
        "compact": True,
    })

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
            items.append((next_idx + 1, ""))
            next_idx += 1
            continue
        indent, text = _block_line_text(raw)
        if indent == None:
            items.append((next_idx + 1, raw))
            next_idx += 1
            continue
        if indent <= parent_indent:
            break
        if _is_dash(text) or text.startswith("? ") or text.startswith(": ") or _is_mapping_start(text):
            break
        items.append((next_idx + 1, raw))
        next_idx += 1
    return items, next_idx

def _block_head_quotes(core):
    """Counts the quotes `core` opens and closes. Returns (opened, closed).

    A quote opens only where a scalar starts, as in `_flow_scan_open`, so an
    apostrophe in a plain scalar never opens one; `''` in single quotes is
    one escaped quote and a backslash escapes the next character in double
    quotes, as in `_flow_scan_quoted`.
    """
    single = False
    double = False
    escaped = False
    plain = False
    opened = 0
    closed = 0
    i = 0
    for _ in range(len(core) + 1):
        if i >= len(core):
            break
        ch = core[i]
        nxt = core[i + 1] if i + 1 < len(core) else ""
        if escaped:
            escaped = False
        elif single:
            if ch == "'":
                if nxt == "'":
                    i += 1
                else:
                    single = False
                    closed += 1
        elif double:
            if ch == "\\":
                escaped = True
            elif ch == '"':
                double = False
                closed += 1
        elif ch == "'" or ch == '"':
            if not plain:
                opened += 1
                if ch == "'":
                    single = True
                else:
                    double = True
        elif ch not in [" ", "\t"]:
            plain = True
        i += 1
    return (opened, closed)

def _block_fail_text(lines, fail, head_idx, entry_text):
    """The display text for a block scalar problem at 0-based `fail`.

    A problem on the head line names the whole entry, as the quoted-scalar
    collection did; any other problem names its own line's text.
    """
    if fail == head_idx and entry_text:
        return entry_text
    _indent, text = _block_line_text(lines[fail])
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

def _block_fold_scalar(lines, start, parent_indent, head_text, raw_head, head_idx, entry_text, question_stops, anchors, state):
    """Folds a block scalar head with its continuation lines. Returns (value, next index, read).

    `head_text` is the same-line value after `key:` or `- `, comment-free as
    `_block_line_text` strips it, or "" when the value starts on a later
    line; `raw_head` is the same slice with its comment intact, "" when
    pending. `head_idx` is the head's 0-based line, `entry_text` the whole
    entry for head problems, and `question_stops` whether a `?` line ends
    the scalar instead of folding into it. When read is False, value is None
    and a problem names the failing line.

    The head folds with its deeper lines through the same quote-aware pass
    the flow fold uses (`_flow_scan_text` with `_flow_fold_lines`), so a
    break folds to one space, blanks fold quote-aware, and comments and `%`
    behave as pub reads them. Anchor and tag prefixes are stripped before
    scanning, so a quote after `&a ` still opens, and re-attached before
    parsing, so `&a one` folding with `two` reads the anchor `one two`.
    Checked against package:yaml 3.1.4, a `?` line without a colon folds
    into an open scalar except in a nested mapping, where it opens an
    explicit key; a `- ` line without a colon folds into an open scalar at
    any depth, while one with a colon ends it. A comment-only or
    trailing-comment line ends a plain scalar silently; a tab-indented line
    is a problem naming the line. Text after a same-line closing quote, a
    second quoted scalar on the head line, and a continuation of an alias
    are problems naming the head line, as pub rejects them.
    """
    core = _flow_head_text(head_text)
    if core[:1] in ["[", "{"]:
        # A flow collection closed on its own line reads within that line,
        # as before: deeper lines are placed downstream, and a broken flow
        # stays an unreadable flow value naming the line.
        return _parse_scalar(head_text, anchors, state, head_idx + 1), start, True
    if core:
        prefix = head_text[:len(head_text) - len(core)]
    elif head_text:
        prefix = head_text + " "
    else:
        prefix = ""
    scan = _flow_scan_start()
    if core:
        _flow_scan_text(core, scan, {"kept": [], "plain_comment": False, "pct_flag": False, "stopped": False, "skip": False})
    poison = False
    if raw_head:
        probe = _flow_scan_start()
        raw_res = {"kept": [], "plain_comment": False, "pct_flag": False, "stopped": False, "skip": False}
        _flow_scan_text(raw_head, probe, raw_res)
        poison = raw_res["plain_comment"] or (raw_res["stopped"] and not raw_res["pct_flag"])
    opened, closed = _block_head_quotes(core)
    head_complete = core != "" and core[:1] in ["'", '"'] and not scan["single"] and not scan["double"]
    seen = core != ""
    items = [(head_idx + 1, head_text)] if head_text != "" else []
    consumed = 0
    idx = start
    fail = -1
    for _ in range(len(lines) + 1):
        if idx >= len(lines):
            break
        raw = lines[idx]
        if raw.strip() == "":
            if not poison:
                items.append((idx + 1, ""))
            idx += 1
            continue
        if scan["single"] or scan["double"]:
            # Inside quotes every line is content at any indent, as pub
            # reads it, including markers, entries and `%` lines.
            items.append((idx + 1, raw))
            res = {"kept": [], "plain_comment": False, "pct_flag": False, "stopped": False, "skip": False}
            _flow_scan_text(raw.lstrip(" \t"), scan, res)
            consumed += 1
            seen = True
            idx += 1
            continue
        indent = _indent_width(raw)
        if indent <= parent_indent:
            break
        if "\t" in raw[:indent]:
            fail = idx
            break
        text = raw.lstrip(" \t")
        res = {"kept": [], "plain_comment": False, "pct_flag": False, "stopped": False, "skip": False}
        _flow_scan_text(text, scan, res)
        if res["pct_flag"]:
            # An indented `%` line is content once the scalar is open, as
            # pub folds it, and a problem where pub rejects it otherwise.
            if not seen:
                fail = idx
                break
            items.append((idx + 1, raw))
            consumed += 1
            seen = True
            idx += 1
            continue
        if res["plain_comment"] or res["stopped"]:
            # A comment-only or trailing-comment line ends a plain scalar,
            # as pub ends it. The comment line itself is silent, as pub
            # places it: it is consumed, and what follows the comments is
            # placed downstream.
            poison = True
            idx += 1
            continue
        if poison:
            break
        if text == ":" or text[:2] == ": " or text[:2] == ":\t":
            # A `:` line never continues a scalar: pub rejects it where an
            # entry belongs, so ending the scalar fails closed downstream.
            break
        if text[:1] == "?":
            # A `?` line without a colon folds into an open scalar, as pub
            # folds it, except in a nested mapping, where it opens an
            # explicit key instead.
            if _find_colon(text) >= 0 or not seen or question_stops:
                break
        elif _is_dash(text):
            if not seen or text == "-":
                break
            if _block_dash_colon(text[1:]):
                break
        elif _is_mapping_start(text) or _is_explicit_key_text(text):
            break
        items.append((idx + 1, raw))
        consumed += 1
        seen = True
        idx += 1
    if fail >= 0:
        _record_unreadable(state, fail, _block_fail_text(lines, fail, head_idx, entry_text))
        return None, idx + 1, False
    for _ in range(len(items) + 1):
        if not items or items[-1][1] != "":
            break
        items.pop()
    folded, problem = _flow_fold_lines(items, _flow_scan_start())
    if problem != None:
        line = problem[1] - 1
        _record_unreadable(state, line, _block_fail_text(lines, line, head_idx, entry_text))
        return None, idx, False
    if scan["single"] or scan["double"]:
        _record_unreadable(state, head_idx, entry_text or head_text)
        return None, idx, False
    if head_complete and (opened != 1 or closed != 1 or not _is_quoted(core) or consumed > 0):
        _record_unreadable(state, head_idx, entry_text or head_text)
        return None, idx, False
    if core[:1] == "*" and consumed > 0:
        _record_unreadable(state, head_idx, entry_text or head_text)
        return None, idx, False
    return _parse_scalar(prefix + folded, anchors, state, head_idx + 1), idx, True

def _flow_scan_start():
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

def _flow_scan_text(text, scan, res):
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

def _flow_fold_lines(items, scan):
    """Folds raw flow lines as pub folds them. Returns (folded, problem).

    `items` holds (1-based line, raw line) pairs with "" for blank lines;
    leading indentation is dropped. A break between content lines is one
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
    for item in items:
        line = item[0]
        content = item[1].lstrip(" \t")
        if content.strip() == "":
            _flow_fold_blank(scan, st)
            continue
        res = {"kept": [], "plain_comment": False, "pct_flag": False, "stopped": False, "skip": False}
        _flow_scan_text(content, scan, res)
        if res["pct_flag"]:
            return "", ("directive", line)
        problem = _flow_fold_kept(scan, st, res, "".join(res["kept"]), line)
        if problem != None:
            return "", problem
    return st["out"], None

def _flow_fold_problem(kind, line):
    """The problem for a folded-flow line this reader cannot spell as pub reads it."""
    if kind == "plain-comment":
        return "comment inside a plain scalar of a flow that spans lines at line %d is not supported" % line
    if kind == "directive":
        return "\"%%\" directive in a flow that spans lines at line %d is not supported" % line
    return "flow collection that spans lines starting at line %d is not supported" % line

def _folded_head_flow(head_raw, head_line, lines, idx, parent_indent, anchors, state):
    """Folds a same-line flow head with its deeper lines. Returns (value, next index, read).

    `head_raw` is the raw value text on `lines[idx]` at 1-based `head_line`,
    comment intact; deeper content lines come from `_pending_flow_raws`.
    When the fold reads as one flow collection as pub reads it, value is
    that collection. Otherwise read is False and the caller fails the span
    as today.
    """
    if _unclosed_flow_head(head_raw, anchors) == None:
        return None, idx + 1, False
    raws, next_idx = _pending_flow_raws(lines, idx + 1, parent_indent)
    items = [(head_line, head_raw)] + raws
    folded, problem = _flow_fold_lines(items, _flow_scan_start())
    if problem != None or not _folded_flow_ok(folded, anchors):
        return None, next_idx, False
    return _parse_scalar(folded, anchors, state, head_line), next_idx, True

def _folded_flow_ok(joined, anchors):
    """Returns whether the folded `joined` text reads as one flow collection.

    Anchor and tag prefixes are stripped first, so `&a [x,` folding with `y]`
    probes as `[x, y]`, the value pub reads. `anchors` resolves aliases while
    probing, read-only.
    """
    head = _flow_head_text(joined)
    if head[:1] not in ["[", "{"]:
        return False
    probe = struct(problems = [], strict_lines = False)
    return _parse_flow(head, anchors, probe, 0) != None

def _consume_pending_scalar(cursor, pending, env):
    """Folds a scalar starting after `key:` with single spaces. Returns next index."""
    lines = cursor.lines
    idx = cursor.idx
    anchors = env.anchors
    state = env.state
    parent = pending["parent"]
    slot = pending["slot"]
    parent_indent = pending["indent"]
    _indent0, text0 = _block_line_text(lines[idx])
    if text0 != None and _unclosed_flow_head(text0, anchors) != None:
        raws, next_idx = _pending_flow_raws(lines, idx, parent_indent)
        folded, problem = _flow_fold_lines(raws, _flow_scan_start())
        if problem == None and _folded_flow_ok(folded, anchors):
            # The folded lines read as one flow collection, as pub reads
            # them: keep the value, as revisions before the span check did.
            value = _parse_scalar(folded, anchors, state, idx + 1)
            parent[slot] = value
            if pending["anchor"] != None:
                anchors[pending["anchor"]] = _clone(value)
            return next_idx
        if problem != None:
            state.problems.append(_flow_fold_problem(problem[0], problem[1]))
        else:
            state.problems.append(_span_flow_problem(idx + 1))
        end = _spanning_flow_end(lines, idx + 1, parent_indent, text0, anchors)
        return end if end != None else next_idx
    value, next_idx, _read = _block_fold_scalar(lines, idx, parent_indent, "", "", idx, "", type(parent) == "dict" and parent_indent > 0, anchors, state)
    parent[slot] = value
    if pending["anchor"] != None:
        anchors[pending["anchor"]] = _clone(value)
    return next_idx

def _resolve_pending(pending, cursor, env):
    """Resolves a pending key or dash against the current line.

    Returns (next index, consumed): consumed is True when deeper scalar lines
    were folded into the pending value and the caller must continue.
    """
    indent = cursor.indent
    text = cursor.text
    if _is_compact_seq(pending, indent, text):
        _attach_compact_seq(pending, env.anchors, env.stack)
        return cursor.idx, False
    if indent > pending["indent"]:
        if _is_dash(text) or _is_mapping_start(text):
            _attach_pending_child(pending, indent, text, env.anchors, env.stack)
            return cursor.idx, False
        next_idx = _consume_pending_scalar(struct(lines = cursor.lines, idx = cursor.idx), pending, struct(anchors = env.anchors, state = env.state))
        return next_idx, True
    return cursor.idx, False

def _init_block_root(text, indent, anchors, stack, state, line):
    """Creates the root container or scalar. Returns (root, is_scalar)."""
    if _is_dash(text):
        root = []
        stack.append({"kind": "seq", "indent": indent - 1, "value": root, "entry": None, "compact": False})
        return root, False
    if _find_colon(text) >= 0 or text.startswith("? "):
        root = {}
        stack.append({"kind": "map", "indent": indent - 1, "value": root, "entry": None, "compact": False})
        return root, False
    return _parse_scalar(text, anchors, state, line), True

def _parse_block(lines, state):
    """Parses the block-structured lines of one document into a value.

    An open container is a frame, a dict {kind, indent, value, entry}. `kind`
    is "map" or "seq", `indent` is the column its entries must be nested
    beyond, and `entry` is the column of its first entry, which later entries
    must match. A compact sequence frame also carries `compact` True.

    `pending` describes a key or dash whose value is on the following lines:
    a dash at its own column becomes a compact sequence, a deeper mapping or
    sequence line becomes the child container, and deeper scalar lines fold
    into the value with single spaces. `state` collects duplicate-key and
    (when strict) unreadable-line problems.
    """
    anchors = {}
    root = None
    stack = []
    pending = None
    saw_content = False
    idx = 0
    for _ in range(len(lines) + 1):
        if idx >= len(lines):
            break
        raw = lines[idx]
        indent, text = _block_line_text(raw)
        if indent == None:
            if saw_content and raw.strip().startswith("%"):
                # A `%` line after content is no directive: pub rejects it,
                # so it is a problem naming the line, as the oracle reads it.
                _record_unreadable(state, idx, raw.strip())
            idx += 1
            continue
        saw_content = True

        # Close the containers that this line is not indented into.
        _close_block_containers(stack, indent, text)

        if pending != None:
            idx, skip = _resolve_pending(pending, struct(lines = lines, idx = idx, indent = indent, text = text), struct(anchors = anchors, stack = stack, state = state))
            pending = None
            if skip:
                continue

        if root == None and not stack:
            root, is_scalar = _init_block_root(text, indent, anchors, stack, state, idx + 1)
            if is_scalar:
                idx += 1
                continue

        if not stack:
            _record_unreadable(state, idx, text)
            idx += 1
            continue

        frame = stack[-1]
        if frame["kind"] == "map":
            idx, pending = _map_line(lines, idx, indent, text, frame, anchors, state)
        else:
            idx, pending = _seq_line(lines, idx, indent, text, frame, anchors, stack, state)
    return root

def _flow_head_text(value_text):
    """Strips anchor and tag prefixes from `value_text`, returning the value head."""
    s = value_text.strip()
    for _ in range(4):
        if not s:
            break
        if s.startswith("&") or s.startswith("!"):
            parts = s.split(" ", 1)
            s = parts[1].strip() if len(parts) > 1 else ""
        else:
            break
    return s

def _unclosed_flow_head(value_text, anchors):
    """Returns the flow text when it opens a collection that never closes on this line, else None.

    `anchors` resolves aliases while probing, read-only.
    """
    head = _flow_head_text(value_text)
    if head[:1] not in ["[", "{"]:
        return None
    probe = struct(problems = [], strict_lines = False)
    if _parse_flow(head, anchors, probe, 0) != None:
        return None
    return head

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
        indent, text = _block_line_text(raw)
        if indent == None:
            if _is_marker_line(raw, "---") or _is_marker_line(raw, "..."):
                break
            idx += 1
            continue
        if indent <= parent_indent:
            break
        parts.append(text)
        idx += 1
        probe = struct(problems = [], strict_lines = False)
        if _parse_flow("\n".join(parts), {}, probe, 0) != None:
            return idx
    return None

def _spanning_flow_end(lines, start, parent_indent, value_text, anchors):
    """Returns the index after the closing line when `value_text` opens a flow collection that closes on a later line, else None."""
    head = _unclosed_flow_head(value_text, anchors)
    if head == None:
        return None
    return _flow_span_end(lines, start, parent_indent, head)

def _span_flow_problem(line):
    """The problem for a flow collection that opens at 1-based `line` and spans lines."""
    return "flow collection that spans lines starting at line %d is not supported" % line

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
    head = lines[idx][indent + _find_colon(text) + 1:]
    value, next_idx, read = _folded_head_flow(head, line, lines, idx, indent, anchors, state)
    if read:
        return value, next_idx, True
    end = _spanning_flow_end(lines, idx + 1, indent, value_text, anchors)
    if end != None:
        state.problems.append(_span_flow_problem(line))
        return None, end, True
    return None, idx + 1, False

def _map_line(lines, idx, indent, text, frame, anchors, state):
    """Reads one line of a block mapping. Returns (next index, pending)."""
    if _is_explicit_key_text(text):
        # Explicit keys are not supported (see the module docstring). They fail
        # naming the line even where an entry is not expected, so a `:`
        # continuation of a plain scalar fails closed instead of vanishing.
        _record_unreadable(state, idx, text)
        return idx + 1, None
    if not _entry_indent_ok(frame, indent):
        _record_unreadable(state, idx, text)
        return idx + 1, None
    if _is_dash(text):
        # A sequence entry never belongs to a mapping; it is unreadable here
        # rather than a key named "- ...".
        _record_unreadable(state, idx, text)
        return idx + 1, None
    key_text, value_text, ok = _split_key_value(text)
    if not ok or key_text == "":
        _record_unreadable(state, idx, text)
        return idx + 1, None

    line = idx + 1
    mapping = frame["value"]
    key = _key(_parse_scalar(key_text, anchors, state, line))
    anchor = _anchor_only(value_text)
    if value_text == "" or anchor != None:
        if _is_duplicate(mapping, key, line, state):
            return idx + 1, None
        mapping[key] = None
        return idx + 1, {"parent": mapping, "slot": key, "indent": indent, "anchor": anchor}

    if value_text.startswith("|") or value_text.startswith(">"):
        parsed, next_idx = _parse_block_scalar(lines, idx + 1, indent, value_text)
        return _map_store(mapping, key, parsed, next_idx, line, state)

    flow_value, flow_next, flow_done = _map_flow_value(lines, idx, indent, text, value_text, anchors, state, line)
    if flow_done:
        return _map_store(mapping, key, flow_value, flow_next, line, state)

    raw_head = lines[idx][indent + _find_colon(text) + 1:]
    value, next_idx, _read = _block_fold_scalar(lines, idx + 1, indent, value_text, raw_head, idx, text, indent > 0, anchors, state)
    return _map_store(mapping, key, value, next_idx, line, state)

def _seq_dash_map(lines, idx, indent, text, items, anchors, stack, state):
    """Reads a `- key: value` line, starting a mapping for the sequence item. Returns (next index, pending)."""
    line = idx + 1
    rest = text[1:].strip()
    key_text, value_text, _ok = _split_key_value(rest)
    item = {}
    key = _key(_parse_scalar(key_text, anchors, state, line))
    after_dash = lines[idx][indent + 1:]
    gap = len(after_dash) - len(after_dash.lstrip(" \t"))
    head = after_dash[gap + _find_colon(rest) + 1:]
    flow_value, flow_next, flow_read = _folded_head_flow(head, line, lines, idx, indent, anchors, state)
    if flow_read:
        item[key] = flow_value
        items.append(item)
        stack.append({"kind": "map", "indent": indent, "value": item, "entry": None})
        return flow_next, None
    end = _spanning_flow_end(lines, idx + 1, indent, value_text, anchors)
    if end != None:
        state.problems.append(_span_flow_problem(line))
        item[key] = None
        items.append(item)
        stack.append({"kind": "map", "indent": indent, "value": item, "entry": None})
        return end, None
    if value_text == "":
        items.append(item)
        stack.append({"kind": "map", "indent": indent, "value": item, "entry": None})
        return idx + 1, {"parent": item, "slot": key, "indent": indent, "anchor": None}
    value, next_idx, _read = _block_fold_scalar(lines, idx + 1, indent, value_text, head, idx, text, True, anchors, state)
    item[key] = value
    items.append(item)
    stack.append({"kind": "map", "indent": indent, "value": item, "entry": None})
    return next_idx, None

def _seq_line(lines, idx, indent, text, frame, anchors, stack, state):
    """Reads one line of a block sequence. Returns (next index, pending)."""
    if not _entry_indent_ok(frame, indent):
        _record_unreadable(state, idx, text)
        return idx + 1, None
    if not _is_dash(text):
        _record_unreadable(state, idx, text)
        return idx + 1, None

    line = idx + 1
    items = frame["value"]
    rest = text[1:].strip()
    if rest == "":
        items.append(None)
        return idx + 1, {"parent": items, "slot": len(items) - 1, "indent": indent, "anchor": None}

    if _find_colon(rest) >= 0:
        # `- key: value` starts a mapping whose first entry is on this line.
        return _seq_dash_map(lines, idx, indent, text, items, anchors, stack, state)

    if rest.startswith("|") or rest.startswith(">"):
        parsed, next_idx = _parse_block_scalar(lines, idx + 1, indent, rest)
        items.append(parsed)
        return next_idx, None

    after_dash = lines[idx][indent + 1:]
    gap = len(after_dash) - len(after_dash.lstrip(" \t"))
    head = after_dash[gap + _find_colon(rest) + 1:]
    flow_value, flow_next, flow_read = _folded_head_flow(head, line, lines, idx, indent, anchors, state)
    if flow_read:
        items.append(flow_value)
        return flow_next, None
    end = _spanning_flow_end(lines, idx + 1, indent, rest, anchors)
    if end != None:
        state.problems.append(_span_flow_problem(line))
        items.append(None)
        return end, None
    value, next_idx, _read = _block_fold_scalar(lines, idx + 1, indent, rest, after_dash, idx, text, False, anchors, state)
    items.append(value)
    return next_idx, None

def _new_block(text):
    """The container for a child block, chosen by the first line of the block."""
    return [] if _is_dash(text) else {}

def _entry_indent_ok(frame, indent):
    """Records the column of a container's first entry, then checks `indent`."""
    if frame["entry"] == None:
        frame["entry"] = indent
        return True
    return frame["entry"] == indent

def _anchor_only(value_text):
    """Returns the anchor name when `value_text` is only `&name`, else None."""
    if value_text.startswith("&") and " " not in value_text:
        return value_text[1:]
    return None

def _is_duplicate(mapping, key, line, state):
    """Records a duplicate-key problem when `key` is taken. Returns whether it is."""
    if key not in mapping:
        return False
    state.problems.append("duplicate key %r at line %d" % (key, line))
    return True

def _is_explicit_key_text(text):
    """Returns whether `text` is an explicit-key line: `? key` or `: value`.

    A bare `?` or `:` counts too. Without a following space, tab or
    end-of-line the mark is a plain scalar, not an explicit key.
    """
    if text == "?" or text == ":":
        return True
    if len(text) < 2:
        return False
    return text[0] in ["?", ":"] and text[1] in [" ", "\t"]

def _record_unreadable(state, idx, text):
    """Records a skipped line when strict. Lenient parsing ignores it.

    An explicit key is never skipped silently: it is not supported, so it is
    always a problem naming the line, in strict and lenient modes alike.
    """
    if _is_explicit_key_text(text):
        state.problems.append("explicit key at line %d is not supported: %r" % (idx + 1, text))
        return
    if state.strict_lines:
        state.problems.append("unreadable line %d: %r" % (idx + 1, text))

def _key(value):
    """Converts a parsed value to a dict key, as yaml.bzl does."""
    t = type(value)
    if t in ["string", "int", "float", "bool", "NoneType"]:
        return value
    if t in ["list", "dict"]:
        return json.encode(value)
    return str(value)

# ---------------------------------------------------------------------------
# Block scalars
# ---------------------------------------------------------------------------

def _block_scalar_header(header):
    """Reads a `|` or `>` header into (style, chomping, explicit_indent)."""
    style = header[0]
    chomping = ""
    explicit_indent = 0
    for i in range(1, len(header)):
        ch = header[i]
        if ch in ["+", "-"] and chomping == "":
            chomping = ch
        elif ch.isdigit() and explicit_indent == 0:
            explicit_indent = int(ch)
    return style, chomping, explicit_indent

def _block_scalar_raw_lines(lines, start, parent_indent):
    """Collects the scalar content lines. Returns (raw_lines, min_indent, next index)."""
    idx = start
    raw_lines = []
    min_indent = -1
    for _ in range(len(lines) + 1):
        if idx >= len(lines):
            break
        raw = lines[idx]
        if not raw.strip():
            raw_lines.append("")
            idx += 1
            continue
        indent = _indent_width(raw)
        if indent <= parent_indent:
            break
        if min_indent < 0 or indent < min_indent:
            min_indent = indent
        raw_lines.append(raw)
        idx += 1
    return raw_lines, min_indent, idx

def _block_scalar_chomp(style, values, chomping):
    """Folds a `>` scalar and applies the chomping indicator."""
    if style == "|":
        text = "\n".join(values)
    else:
        text = _fold_lines(values)

    trailing_blank_lines = 0
    for value in reversed(values):
        if value != "":
            break
        trailing_blank_lines += 1

    text = text.rstrip("\n")
    if chomping == "+":
        text += "\n" * (1 + trailing_blank_lines)
    elif chomping == "":
        text += "\n"
    return text

def _parse_block_scalar(lines, start, parent_indent, header):
    """Reads a `|` or `>` block scalar. Returns (text, next index).

    `header` is the indicator text after the key or dash, such as `|-` or
    `>2`. The content is every following line indented deeper than
    `parent_indent`, plus the blank lines between them.
    """
    style, chomping, explicit_indent = _block_scalar_header(header)

    raw_lines, min_indent, idx = _block_scalar_raw_lines(lines, start, parent_indent)

    if explicit_indent > 0:
        content_indent = parent_indent + explicit_indent
    elif min_indent >= 0:
        content_indent = min_indent
    else:
        content_indent = parent_indent + 1

    values = [raw[content_indent:] if raw != "" else "" for raw in raw_lines]

    return _block_scalar_chomp(style, values, chomping), idx

def _fold_lines(values):
    """Folds `>` scalar lines: a single newline becomes a space, blanks stay."""
    pieces = []
    prev_blank = False
    has_text = False
    prev_line = ""
    for line in values:
        if line == "":
            if has_text:
                pieces.append("\n")
            prev_blank = True
            continue
        if has_text:
            if prev_blank or line.startswith(" ") or prev_line.startswith(" "):
                pieces.append("\n")
            else:
                pieces.append(" ")
        pieces.append(line)
        prev_blank = False
        has_text = True
        prev_line = line
    return "".join(pieces)

# ---------------------------------------------------------------------------
# Lines
# ---------------------------------------------------------------------------

def _indent_width(raw):
    """Counts the leading spaces and tabs, each as one column, as yaml.bzl does."""
    return len(raw) - len(raw.lstrip(" \t"))

def _quote_track(ch, st):
    """Tracks quote state for `ch`, updating `st` in place. Returns whether `ch` was consumed.

    `st` carries single, double, escaped, at_start and affix. A quote opens
    only where a scalar starts, so an apostrophe in a plain scalar stays
    content; a backslash escapes the next character in double quotes.
    """
    if st["escaped"]:
        st["escaped"] = False
        return True
    if st["double"] and ch == "\\":
        st["escaped"] = True
        return True
    if ch == "'" and not st["double"]:
        if st["single"]:
            st["single"] = False
            st["at_start"] = False
        elif st["at_start"]:
            st["single"] = True
        st["affix"] = False
        return True
    if ch == '"' and not st["single"]:
        if st["double"]:
            st["double"] = False
            st["at_start"] = False
        elif st["at_start"]:
            st["double"] = True
        st["affix"] = False
        return True
    return False

def _depth_track(ch, counts):
    """Counts one bracket character into `counts`, doing nothing when None.

    `counts` carries the brace and bracket depth.
    """
    if counts == None:
        return
    if ch == "{":
        counts["braces"] += 1
    elif ch == "}":
        counts["braces"] -= 1
    elif ch == "[":
        counts["brackets"] += 1
    elif ch == "]":
        counts["brackets"] -= 1

def _depth_top(counts):
    """Returns whether `counts` is None or both depths are zero."""
    return counts == None or (counts["braces"] == 0 and counts["brackets"] == 0)

def _sep_track(ch, nxt, st, counts):
    """Tracks scalar-start state for a character outside quotes.

    `st` carries at_start and affix; `counts`, when not None, carries the
    brace and bracket depth. A `-` or `:` starts a fresh scalar with
    separation after it, as do `[`, `{` and `,`; an `&` or `!` word does once
    a space ends it. A nested colon changes nothing.
    """
    if ch in ["&", "!"]:
        st["affix"] = True
        st["at_start"] = False
    elif ch in ["[", "{", ","]:
        _depth_track(ch, counts)
        st["at_start"] = True
        st["affix"] = False
    elif ch in ["}", "]"]:
        _depth_track(ch, counts)
    elif ch == ":" and nxt in [" ", "\t", ""] and _depth_top(counts):
        st["at_start"] = True
        st["affix"] = False
    elif ch == "-" and nxt in [" ", "\t", ""]:
        st["at_start"] = True
        st["affix"] = False
    elif ch in [" ", "\t"]:
        if st["affix"]:
            st["affix"] = False
            st["at_start"] = True
    elif ch == ":":
        st["at_start"] = False
        st["affix"] = False
    else:
        st["at_start"] = False
        st["affix"] = False

def _strip_comment(text):
    """Removes a trailing `#` comment, ignoring `#` inside quotes.

    A quote opens only where a scalar starts (the line start, or after `[`,
    `{`, `,`, a separating colon, a `- ` dash or an anchor or tag word), so
    an apostrophe in a plain scalar never hides a comment.
    """
    if "#" not in text:
        return text.rstrip()
    st = {"single": False, "double": False, "escaped": False, "at_start": True, "affix": False}
    for i in range(len(text)):
        ch = text[i]
        if _quote_track(ch, st):
            continue
        if ch == "#":
            if not st["single"] and not st["double"]:
                if i == 0 or text[i - 1] in [" ", "\t"]:
                    return text[:i].rstrip()
            continue
        _sep_track(ch, text[i + 1:i + 2], st, None)
    return text.rstrip()

def _find_colon(text):
    """Returns the index of the first top-level `: ` in `text`, or -1.

    A colon inside quotes or brackets does not count, and a trailing colon
    does. A quote opens only where a scalar starts, so an apostrophe in a
    plain scalar never hides a colon.
    """
    if ":" not in text:
        return -1
    st = {"single": False, "double": False, "escaped": False, "at_start": True, "affix": False}
    counts = {"braces": 0, "brackets": 0}
    for i in range(len(text)):
        ch = text[i]
        if _quote_track(ch, st):
            continue
        if st["single"] or st["double"]:
            continue
        if ch == ":" and counts["braces"] == 0 and counts["brackets"] == 0 and (i + 1 == len(text) or text[i + 1] in [" ", "\t"]):
            return i
        _sep_track(ch, text[i + 1:i + 2], st, counts)
    return -1

def find_colon(text):
    """Returns the index of the first top-level `: ` in `text`, or -1.

    A colon inside quotes or brackets does not count, and a trailing colon
    does. A quote opens only where a scalar starts.
    Shared with the `//dart/pub:yaml_parser.bzl` lock checks so both read a
    `key: value` line the same way.
    """
    return _find_colon(text)

def strip_comment(text):
    """Removes a trailing `#` comment, ignoring `#` inside quotes.

    A quote opens only where a scalar starts.
    Shared with the `//dart/pub:yaml_parser.bzl` lock checks so both skip
    the same comment text.
    """
    return _strip_comment(text)

def _split_key_value(text):
    """Splits `key: value` at the top-level colon. Returns (key, value, found)."""
    c = _find_colon(text)
    if c < 0:
        return "", "", False
    return text[:c].strip(), text[c + 1:].strip(), True

def _is_quoted(text):
    return len(text) >= 2 and ((text[0] == '"' and text[-1] == '"') or (text[0] == "'" and text[-1] == "'"))

# ---------------------------------------------------------------------------
# Scalars
# ---------------------------------------------------------------------------

def _parse_scalar(text, anchors, state, line):
    """Parses the text after a key, dash or flow separator into a value.

    Leading `&anchor` and `!tag` words are consumed first. An anchor records
    a shallow copy of the value under its name. A flow collection that cannot
    be read is a strict-lines problem; lenient parsing reads it as None.
    """
    s = text.strip()
    if s == "":
        return None
    anchor = None
    tag = None
    for _ in range(4):
        if not s:
            break
        if s.startswith("&"):
            parts = s.split(" ", 1)
            anchor = parts[0][1:]
            s = parts[1].strip() if len(parts) > 1 else ""
        elif s.startswith("!"):
            parts = s.split(" ", 1)
            tag = parts[0]
            s = parts[1].strip() if len(parts) > 1 else ""
        else:
            break

    if s[:1] in ["[", "{"]:
        value = _parse_flow(s, anchors, state, line)
        if value == None and state.strict_lines:
            state.problems.append("unreadable flow value at line %d: %r" % (line, s))
    else:
        value = _parse_nonflow(s, anchors)
    if tag != None:
        value = _apply_tag(tag, s, value, anchors, state, line)
    if anchor:
        anchors[anchor] = _clone(value)
    return value

def _clone(value):
    """A shallow copy of a container, as yaml.bzl makes for aliases."""
    t = type(value)
    if t == "list":
        return list(value)
    if t == "dict":
        return dict(value)
    return value

def _apply_seq_map_tag(name, raw, value, anchors, state, line):
    """Applies a `!!seq` or `!!map` tag, converting or emptying as yaml.bzl does."""
    want = "list" if name == "seq" else "dict"
    if type(value) == want:
        return value
    parsed = _parse_flow(raw, anchors, state, line) if raw[:1] in ["[", "{"] else None
    if type(parsed) == want:
        return parsed
    return [] if name == "seq" else {}

def _apply_int_tag(value, raw):
    """Applies a `!!int` tag; a failed conversion gives 0, as yaml.bzl does."""
    if type(value) == "int":
        return value
    parsed = _parse_int_text(value if type(value) == "string" else raw)
    return parsed if parsed != None else 0

def _apply_float_tag(value, raw):
    """Applies a `!!float` tag; a failed conversion gives 0.0, as yaml.bzl does."""
    if type(value) == "float":
        return value
    parsed = _parse_float_text(value if type(value) == "string" else raw)
    return parsed if parsed != None else 0.0

def _apply_bool_tag(value, raw):
    """Applies a `!!bool` tag; only true/yes/on spell true, as yaml.bzl does."""
    if type(value) == "bool":
        return value
    return (value if type(value) == "string" else raw).strip().lower() in ["true", "yes", "on"]

def _apply_tag(tag, raw, value, anchors, state, line):
    """Applies a supported tag to a parsed value. `raw` is the untagged text.

    A tag that names a type the value does not have converts it where yaml.bzl
    does; a conversion that fails gives the type's empty value.
    """
    name = _tag_name(tag)
    if name == "seq" or name == "map":
        return _apply_seq_map_tag(name, raw, value, anchors, state, line)
    if name == "str":
        return value if type(value) == "string" else raw
    if name == "int":
        return _apply_int_tag(value, raw)
    if name == "float":
        return _apply_float_tag(value, raw)
    if name == "bool":
        return _apply_bool_tag(value, raw)
    if name == "null":
        return None
    return value

def _tag_name(tag):
    """The short name of a tag written as `!!x`, `!x` or `!<tag:yaml.org,2002:x>`."""
    if tag.startswith("!<") and tag.endswith(">"):
        uri = tag[2:-1]
        return uri[len(_YAML_TAG_PREFIX):] if uri.startswith(_YAML_TAG_PREFIX) else None
    if tag.startswith("!!"):
        return tag[2:]
    if tag.startswith("!") and len(tag) > 1 and tag.count("!") == 1:
        return tag[1:]
    return None

def _parse_numeric_text(s, lower, num):
    """Parses an int, based int, infinity, NaN or float, or returns `s` unchanged."""
    if _is_int_digits(num):
        return int(num)
    if len(num) > 2 and num[0:2].lower() == "0x":
        parsed = _parse_based_int(num, 16)
        return parsed if parsed != None else s
    if len(num) > 2 and num[0:2].lower() == "0o":
        parsed = _parse_based_int(num, 8)
        return parsed if parsed != None else s
    if lower in [".inf", "+.inf"]:
        return float("inf")
    if lower == "-.inf":
        return float("-inf")
    if lower == ".nan":
        return float("nan")
    scientific = _parse_scientific_float(num)
    if scientific != None:
        return scientific
    if num.count(".") == 1:
        left, right = num.split(".")
        if _is_decimal_part(left) and right.isdigit():
            return float(num)
    return s

def _parse_nonflow(s, anchors):
    """Parses an alias, a quoted scalar or a plain scalar."""
    if s.startswith("*"):
        name = s[1:].strip()
        if name not in anchors:
            return None
        return _clone(anchors[name])
    if _is_quoted(s):
        if s[0] == '"':
            return _unescape_double(s[1:-1])
        return s[1:-1].replace("''", "'")
    if s[:1] in ["@", "`"]:
        return s

    lower = s.lower()
    normalized = _normalize_decimal_number(s)
    num = normalized if normalized != None else s
    if lower in ["null", "~"]:
        return None
    if lower == "true":
        return True
    if lower == "false":
        return False
    return _parse_numeric_text(s, lower, num)

def _is_int_digits(text):
    """True for `123`, `+123` and `-123`."""
    return text.isdigit() or (len(text) > 1 and text[0] in ["-", "+"] and text[1:].isdigit())

def _is_decimal_part(text):
    """True for the part before a decimal point, which may be a bare sign."""
    return _is_int_digits(text) or text in ["-", "+"]

def _normalize_decimal_number(s):
    """Removes `_` digit separators. Returns None when a separator is misplaced."""
    if "_" not in s:
        return s
    if s.startswith("_") or s.endswith("_"):
        return None
    out = []
    for i in range(len(s)):
        ch = s[i]
        if ch != "_":
            out.append(ch)
            continue
        prev = s[i - 1] if i > 0 else ""
        nxt = s[i + 1] if i + 1 < len(s) else ""
        if not (prev.isdigit() and nxt.isdigit()):
            return None
    return "".join(out)

def _parse_scientific_float(text):
    """Parses `1e3`, `1.5E-3` and similar, or returns None."""
    normalized = _normalize_decimal_number(text)
    if normalized == None:
        return None
    s = normalized.lower()
    e = s.find("e")
    if e < 0:
        return None
    left = s[:e]
    right = s[e + 1:]
    if right == "":
        return None
    if right[0] in ["+", "-"]:
        if len(right) == 1 or not right[1:].isdigit():
            return None
    elif not right.isdigit():
        return None
    if _is_int_digits(left):
        return float(normalized)
    if left.count(".") == 1:
        whole, frac = left.split(".")
        if _is_decimal_part(whole) and frac.isdigit():
            return float(normalized)
    return None

def _parse_based_int(text, base):
    """Parses `0x` (base 16) or `0o` (base 8) digits, with `_` separators."""
    s = text.lower()[2:]
    if s == "":
        return None
    normalized = []
    prev_digit = False
    for i in range(len(s)):
        ch = s[i]
        if ch == "_":
            if i == 0 or i == len(s) - 1 or not prev_digit:
                return None
            nxt_pos = _HEX_DIGITS.find(s[i + 1])
            if nxt_pos < 0 or nxt_pos >= base:
                return None
            prev_digit = False
            continue
        pos = _HEX_DIGITS.find(ch)
        if pos < 0 or pos >= base:
            return None
        normalized.append(ch)
        prev_digit = True
    total = 0
    for ch in normalized:
        total = total * base + _HEX_DIGITS.find(ch)
    return total

def _parse_int_text(text):
    """The integer named by a `!!int` value, or None."""
    s = _normalize_decimal_number(text.strip())
    if s == None:
        return None
    if _is_int_digits(s):
        return int(s)
    if len(s) > 2 and s[0:2].lower() == "0x":
        return _parse_based_int(s, 16)
    if len(s) > 2 and s[0:2].lower() == "0o":
        return _parse_based_int(s, 8)
    return None

def _parse_float_text(text):
    """The float named by a `!!float` value, or None."""
    s = _normalize_decimal_number(text.strip())
    if s == None:
        return None
    lower = s.lower()
    if lower in [".inf", "+.inf"]:
        return float("inf")
    if lower == "-.inf":
        return float("-inf")
    if lower == ".nan":
        return float("nan")
    scientific = _parse_scientific_float(s)
    if scientific != None:
        return scientific
    if s.count(".") == 1:
        left, right = s.split(".")
        if _is_decimal_part(left) and right.isdigit():
            return float(s)
    return None

# ---------------------------------------------------------------------------
# Double-quoted escapes
# ---------------------------------------------------------------------------

def _unescape_code_point(text, i, nxt):
    """Decodes a `\\x`, `\\u` or `\\U` escape at `i`. Returns (decoded, next index)."""
    width = 2 if nxt == "x" else (4 if nxt == "u" else 8)
    if i + 1 + width >= len(text):
        # Too few characters left for the digits: keep the escape letter.
        return "\\" + nxt, i + 2
    digits = text[i + 2:i + 2 + width]
    code_point = _parse_hex(digits)
    converted = _code_point_text(code_point) if code_point != None else None
    if converted == None:
        return "\\" + nxt + digits, i + 2 + width
    return converted, i + 2 + width

def _unescape_double(text):
    """Decodes the escapes in the body of a double-quoted scalar.

    An unknown or malformed escape is kept as written, as yaml.bzl keeps it.
    """
    out = []
    i = 0
    for _ in range(len(text) + 1):
        if i >= len(text):
            break
        ch = text[i]
        if ch != "\\" or i + 1 >= len(text):
            out.append(ch)
            i += 1
            continue
        nxt = text[i + 1]
        if nxt in _ESCAPES:
            out.append(_ESCAPES[nxt])
            i += 2
        elif nxt == "e":
            out.append(_code_point_text(0x1b))
            i += 2
        elif nxt in ["x", "u", "U"]:
            decoded, i = _unescape_code_point(text, i, nxt)
            out.append(decoded)
        else:
            out.append("\\" + nxt)
            i += 2
    return "".join(out)

def _parse_hex(text):
    if text == "":
        return None
    total = 0
    for i in range(len(text)):
        pos = _HEX_DIGITS.find(text[i].lower())
        if pos < 0:
            return None
        total = total * 16 + pos
    return total

def _code_point_text(code_point):
    """The string for a Unicode code point, or None when it is out of range."""
    if code_point < 0 or code_point > 0x10ffff:
        return None
    if code_point <= 0xffff:
        return json.decode('"\\u%s"' % _hex4(code_point))
    offset = code_point - 0x10000
    high = 0xd800 + offset // 0x400
    low = 0xdc00 + offset % 0x400
    return json.decode('"\\u%s\\u%s"' % (_hex4(high), _hex4(low)))

def _hex4(value):
    out = []
    n = value
    for _ in range(4):
        out.append(_HEX_DIGITS[n % 16])
        n = n // 16
    return "".join(out[::-1])

# ---------------------------------------------------------------------------
# Flow collections
# ---------------------------------------------------------------------------

def _flow_close_step(stack, s, i, frame, state, line):
    """Pops a closed flow frame. Returns (done, value, next_i)."""
    stack.pop()
    i += 1
    if not stack:
        rest = s[i:].lstrip(_FLOW_SPACE)
        if rest == "" or rest.startswith("#"):
            return True, frame["value"], i
        return True, None, i
    _flow_add(stack[-1], frame["value"], state, line)
    return False, None, i

def _flow_key_step(s, i, frame, anchors):
    """Reads one flow map key up to its colon. Returns (next_i, ok)."""
    token, i = _flow_token(s, i, [":", frame["close"], ","])
    if token == "" or not _flow_scalar_ok(token):
        return i, False
    frame["key"] = _key(_parse_nonflow(token, anchors))
    i = _skip_flow_space(s, i)
    if i >= len(s) or s[i] != ":":
        return i, False
    frame["state"] = "value"
    return i + 1, True

def _flow_item_step(s, i, frame, anchors, stack, state, line):
    """Reads one nested collection or scalar flow token. Returns (next_i, ok)."""
    if s[i] in ["[", "{"]:
        stack.append(_flow_frame(s[i]))
        return i + 1, True
    token, next_i = _flow_token(s, i, [",", frame["close"]])
    if token == "" or not _flow_scalar_ok(token):
        return next_i, False
    _flow_add(frame, _flow_token_value(token, anchors), state, line)
    return next_i, True

def _parse_flow(text, anchors, parse_state, line):
    """Parses the flow collection that starts `text`, or returns None.

    A flow frame is a dict {kind, close, value, state, key}. The frame's
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
        frame = stack[-1]
        ch = s[i]
        state = frame["state"]

        if ch == frame["close"] and state != "value":
            done, value, i = _flow_close_step(stack, s, i, frame, parse_state, line)
            if done:
                return value
            continue

        if state == "after":
            if ch != ",":
                return None
            frame["state"] = "key" if frame["kind"] == "map" else "item"
            i += 1
            continue

        if state == "key":
            i, ok = _flow_key_step(s, i, frame, anchors)
            if not ok:
                return None
            continue

        i, ok = _flow_item_step(s, i, frame, anchors, stack, parse_state, line)
        if not ok:
            return None
    return None

def _flow_frame(opener):
    if opener == "[":
        return {"kind": "seq", "close": "]", "value": [], "state": "item", "key": None}
    return {"kind": "map", "close": "}", "value": {}, "state": "key", "key": None}

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

def _flow_token_value(token, anchors):
    """A flow token is a scalar, or a one-pair mapping when it holds a key and a colon."""
    key_text, value_text, is_pair = _flow_pair_split(token)
    if not is_pair:
        return _parse_nonflow(token, anchors)
    pair = {}
    pair[_key(_parse_nonflow(key_text, anchors))] = _parse_nonflow(value_text, anchors)
    return pair

def _flow_quoted_end(s):
    """Returns the index of the quote closing the scalar at `s[0]`, or -1.

    `s` starts with `'` or `"`. `''` inside single quotes is one escaped
    quote and a backslash escapes the next character in double quotes, as
    pub reads them. Returns -1 when the quote never closes.
    """
    quote = s[0]
    i = 1
    for _ in range(len(s) + 1):
        if i >= len(s):
            return -1
        ch = s[i]
        if quote == '"' and ch == "\\":
            i += 2
            continue
        if ch == quote:
            if quote == "'" and s[i + 1:i + 2] == "'":
                i += 2
                continue
            return i
        i += 1
    return -1

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
    end = _flow_quoted_end(token)
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
    key_text, value_text, ok = _split_key_value(token)
    if ok:
        return key_text, value_text, True
    if len(token) < 3 or token[:1] not in ["'", '"']:
        return "", "", False
    end = _flow_quoted_end(token)
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
    quotes is one escaped quote, as pub reads it. Returns (stripped token,
    index of the stop character).
    """
    i = start
    st = {"single": False, "double": False, "escaped": False, "at_start": True, "affix": False}
    for _ in range(len(s) + 1):
        if i >= len(s):
            break
        ch = s[i]
        if st["single"] and ch == "'" and s[i + 1:i + 2] == "'":
            i += 2
            continue
        if _quote_track(ch, st):
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
