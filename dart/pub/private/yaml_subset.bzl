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
duplicate keys and the unsupported forms. Leading byte-order marks are
stripped, as pub accepts them at the stream start; a mark anywhere else is
a problem naming the line, as pub rejects it, except a bare mark line at
column 0, which is blank-like and skipped, and marks inside quoted and
block scalars, which stay content as pub reads them.

Supported:
- block mappings and sequences nested by indentation, including `- key: v`
  items, children that start on the lines after `key:` or `-`, and compact
  sequences where `- ` entries sit at their key's own column
- `#` comments, `%` directive lines before any content (skipped), and `---`
  and `...` document markers at column 0 only: an indented marker is never
  a marker, so one inside a `|` or `>` block scalar stays scalar content.
  A `%` line after content is a problem naming the line, as pub rejects it.
  One stream carries one document, as pub reads it: a second `---` fails
  naming its line, even before any content and even with only comments
  after it, and so does any content after a `...` line, naming the
  content's line, while a trailing `...` alone stays allowed. Inline text
  after a pre-content marker reads as the document, as pub reads `--- foo`
  as "foo" and `... text` as "text".
- plain, single-quoted and double-quoted scalars, with yaml.bzl's escapes,
  including scalars that start on the line after `key:` or continue on
  deeper lines, which fold through the same quote-aware pass as flow lines.
  Double-quoted escapes decode as pub decodes them, including `\\N`, `\\_`,
  `\\L`, `\\P` and a backslash with a space or tab; an unknown escape, a
  short or non-hex escape, a surrogate, and a code point past U+10FFFF
  fail naming the line, as pub rejects them.
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
- block scalars `|` and `>` with chomping and indentation indicators: `|`
  joins lines with breaks and `>` folds them, as pub folds them. A break
  between base-indented lines is one space, the break after a base line
  drops only where the next non-blank line is a base line it folds into;
  where a more-indented line follows, the break stays and each blank line
  is one break. Leading blanks are kept, breaks around more-indented lines
  are kept, and spaces beyond the indentation on a blank line are content. Clip keeps one final
  break only when anything was read, keep adds the final break and every
  trailing blank, and strip drops them, including empty scalars. A header
  with other text fails naming the line, as pub rejects it, and without
  an explicit indicator so does a leading blank line deeper than the
  content; with one such a line strips to content instead.
- plain, quoted, typed and anchored scalars continued on more-indented
  lines, folded through the same quote-aware pass: a break between content
  lines is one space, quotes close at any indent, and indented markers read
  as content. A tab never indents: a line starting with a tab, and a content
  line with a tab in its leading whitespace, fail naming the line, while a
  whitespace-only line starting with spaces stays blank and a deeper line
  with spaces before its tab folds, as pub reads them. A block scalar ends
  before a line starting with a tab, which then fails as a tab-indented
  line, as pub rejects it. A `-` entry opens with a space or a tab after
  it, as pub reads `-\tx` as `x`. A `?` line without a colon folds into an open scalar except
  in a nested mapping, where it opens an explicit key; a `- ` line without
  a colon folds into an open scalar at any depth, while one with a colon
  ends it. A comment-only or trailing-comment line ends a plain scalar
  silently; text after a same-line closing quote, a tab-indented line and
  a `%` line where pub rejects it are problems naming the line. These
  shapes read as package:yaml 3.1.4 reads them.
- anchors and aliases: an alias reads the anchor's value cloned shallowly
  as yaml.bzl copies it, after its collection closes as pub closes it. An
  alias name runs to whitespace or `,[]{}` as pub scans it, so a glued
  colon or hash is part of the name. An empty alias or anchor, an
  undefined or self-referential alias, an anchor or tag with an alias as
  its value, a second anchor or tag word, an alias key swallowing its
  colon, and text after an alias are problems naming the line, as pub
  rejects them, in strict and lenient modes alike. A pending anchor marks
  its collection open until the frame closes, when the anchor binds, so a
  use after the collection reads while a use inside it fails closed. A
  flow `*` word pairs only a colon-free name with a spaced colon, as pub
  reads it; any other flow `&` or `!` word takes a glued colon into its
  name, so the key after it reads plainly and an anchor binds that key, as
  pub reads them. A bare flow anchor reads a null key and a bare flow tag
  its dropped value, and a colon where the value starts pairs that key
  with the value, as pub reads them. A `!!` flow key tag with no scalar to
  convert is an undefined tag problem naming the line, as pub reports it;
  any other `!!` flow key tag converts the key as the same-line tags do,
  and a local flow key tag reads a string key as is and any other key as
  its raw text, as pub reads them.
- the tags !!str, !!int, !!float, !!bool, !!null, !!seq and !!map, which
  convert as pub converts them: a value that does not resolve fails naming
  the line, as pub rejects it. Only true, True, TRUE, false, False and
  FALSE convert under `!!bool`, and an empty scalar reads null under
  `!!null`, as pub reads them. A `!!seq` or `!!map` tag reads a matching
  collection, fails another collection as an invalid tag for its kind, and
  fails any other node as an undefined tag; any other `!!` tag is an
  undefined tag, and a named handle and a verbatim tag are undefined-handle
  problems, as pub reports them. A `!` alone and any other `!` word is a
  local tag, which reads a scalar as its string and a collection as is, as
  pub reads them. A problem still reads the value untagged, so parsing
  continues past it.

Divergences from yaml.bzl. None occurs in the pubspec corpus used for parity
testing, so the projections are unaffected on real pubspec files:
- explicit keys (`? key` with `: value`) are not supported; yaml.bzl reads
  both. They fail naming the line, even a `:` line that continues a plain
  scalar: pub rejects that line, while yaml.bzl folds it, so failing closed
  matches pub. A tab-indented line fails naming the line: pub rejects it,
  while yaml.bzl counts the tab as indentation. A tab-indented continuation
  folded before; pub folds one with spaces before its tab but rejects one
  starting with a tab, as read now. A `-\t` entry read as an unreadable line
  before; pub reads it as the value, as read now. Reading and failing closed changed for the forms an older
  revision misread: a `:` continuation (folded before), a `%`-leading flow
  scalar (read as plain before), a flow-looking document that reads as no
  collection (read as empty before), text after a same-line closing quote
  (kept before), a `%` line at a scalar's start or after content (folded or
  skipped before), a stray
  line after a comment-ended scalar (folded before), and an indented marker
  after a same-line scalar (reported before, pub folds it into the scalar).
  A folded `>` scalar with blank lines read an extra break before, an
  all-blank clip or keep scalar added a break before, a `|`/`>` header with
  trailing text read as a scalar before, a `- key: >` or `|` value read as
  plain before, a block scalar ended by a less-indented line folded
  that line in before, and a keep scalar at the end of the file read one
  break too many before; pub rejects the header and ending forms and folds
  the rest as read now. A second `---` after content read the first
  document and dropped the second before, content after a `...` line was
  dropped before, and a doubled pre-content `---` read the content before;
  pub rejects all three, so they fail naming the line. An undefined alias
  read None before, an alias inside its own collection read a partial value
  or None before, an anchor or tag with an alias value read None before,
  and a second anchor or tag word kept the last one before; pub rejects
  all of these, so they fail naming the line. A `- key:` value read nested
  one column too early before, so a same-column line folded in as a child
  before; pub reads it as a sibling, as read now. A same-line value's
  anchor and tag prefixes folded twice before, so a tagged scalar read its
  tag as a repeated tag; pub reads one prefix, as read now. A tag whose
  value does not resolve read the type's empty value before, a `!!seq` or
  `!!map` tag off its kind read an empty collection before, and any other
  `!!` tag, named handle or verbatim tag read untagged before; pub rejects
  them, so they fail naming the line. An unknown or
  malformed double-quoted escape read kept before, and `\\N`, `\\_`, `\\L`,
  `\\P` and a backslash with a space or tab read literally before; pub
  rejects the first and decodes the rest, as read now. A flow alias
  with a glued colon resolved the short name before, a flow anchor or tag
  word ended its key at a glued colon before, a key with no pair colon
  failed its flow before, and a colon after a bare flow anchor or tag
  misread before; pub scans the word through the colon and reads a lone
  key with a null value, as read now.
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
- floats past the double range read as infinity, as pub reads them
  (package:yaml 3.1.4 with the pinned SDK 3.13.5): only a finite value
  reaches the conversion, so finite values convert exactly as before.
- `%TAG` handles are ignored, so a tag written through one reads as untagged;
  yaml.bzl resolves it. Other unknown tags read as untagged in both.
- duplicate mapping keys fail; yaml.bzl's default non-strict mode silently
  keeps the first scalar and replaces a nested block with a later one.
"""

# Escapes allowed in double-quoted scalars, as yaml.bzl maps them: the
# single-character escapes, backslash with a space or tab (which pub reads
# as the space or tab), and the YAML line/paragraph escapes N, _, L and P.
# Any other escape, a short or non-hex hex escape, a surrogate, or a code
# point past U+10FFFF is a problem naming the line, as pub rejects it.
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
    "\t": "\t",
    '"': '"',
    "/": "/",
    "\\": "\\",
    "N": json.decode('"\\u0085"'),
    "_": json.decode('"\\u00a0"'),
    "L": json.decode('"\\u2028"'),
    "P": json.decode('"\\u2029"'),
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
        content: The text of a YAML stream. Leading byte-order marks are
            stripped, as pub accepts them at the stream start.

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
    lines = _first_document_lines(_strip_bom(content), state)
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
    """Strips every leading UTF-8 byte-order mark, which pub accepts at the start."""
    for _ in range(len(content) + 1):
        if content.startswith(_BOM):
            content = content[len(_BOM):]
        else:
            break
    return content

def _strip_bom_text(text):
    """Strips leading whitespace and byte-order marks, returning the rest."""
    s = text
    for _ in range(len(s) + 1):
        t = s.lstrip(" \t")
        if t.startswith(_BOM):
            s = t[len(_BOM):]
        else:
            return t
    return ""

def _is_bom_only_line(raw):
    """Returns whether `raw` carries no content past byte-order marks: only BOMs, whitespace and a `#` comment."""
    rest = _strip_bom_text(raw)
    return rest == "" or rest.startswith("#")

def _is_marker_line(raw, marker):
    """Returns whether `raw` is a document marker: the marker at column 0 with only whitespace after it.

    An indented marker is never a document marker: inside a `|` or `>`
    block scalar it is content, and elsewhere it is an ordinary line.
    """
    if not raw.startswith(marker):
        return False
    return raw[len(marker):].strip() == ""

def _is_clean_marker_line(raw, marker):
    """Returns whether `raw` is a document marker: the marker at column 0 with only whitespace or a `#` comment after it.

    A `#` after separation is a comment, as pub reads `... # c` as a clean
    document end; text glued to the marker or after a space is content the
    document handlers place.
    """
    if not raw.startswith(marker):
        return False
    rest = raw[len(marker):]
    if rest.strip() == "":
        return True
    return rest[:1] in [" ", "\t"] and rest.strip().startswith("#")

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
    pub reads it as a key.
    """
    if _is_clean_marker_line(line, "---"):
        if doc["ended"] or doc["content"] or doc["marker"]:
            state.problems.append("second document marker (---) at line %d" % idx)
            return True
        if _has_directive(current):
            current.append(line)
            doc["content"] = True
        else:
            doc["marker"] = True
        return False
    text = line[3:].strip() if line[3:4] in [" ", "\t"] else line
    if doc["ended"] or doc["content"]:
        state.problems.append("second document marker (---) at line %d" % idx)
        return True
    current.append(text)
    doc["content"] = True
    return False

def _doc_dots_line(line, idx, current, doc, state):
    """Handles a column-0 `...` line. Returns whether collection stops.

    Text glued to the end marker (`...x`) reads as an ordinary line where
    the document has no content yet, as pub reads it, and fails where
    content or the end came before, as pub rejects it.
    """
    if line[3:4] not in ["", " ", "\t"]:
        if doc["ended"] or doc["content"]:
            state.problems.append("content after document end (...) at line %d" % idx)
            return True
        current.append(line)
        doc["content"] = True
        return False
    if _is_clean_marker_line(line, "..."):
        doc["ended"] = True
        return False
    text = line[3:].strip() if line[3:4] in [" ", "\t"] else line
    if doc["ended"] or doc["content"]:
        state.problems.append("content after document end (...) at line %d" % idx)
        return True
    current.append(text)
    doc["content"] = True
    return False

def _first_document_lines(content, state):
    """Returns the lines of the first document, split as yaml.bzl splits them.

    One stream carries one document, as pub reads it: a second column-0
    `---` line is a problem naming its line, even before any content and
    even with only comments after it, and so is any content after a
    column-0 `...` line, naming the content's line. A marker is the three
    characters followed by a space, a tab or the end of the line: text
    glued to it is an ordinary line, as pub reads `---x: 1` as a key. A `---` before any
    content starts the document, unless a directive precedes it, in which
    case it is kept as an ordinary line; inline text after a pre-content
    marker reads as the document, as pub reads `--- foo` as "foo" and
    `... text` as "text". A trailing `...` alone stays allowed.
    """
    normalized = content.replace("\r\n", "\n").replace("\r", "\n")
    current = []
    doc = {"content": False, "marker": False, "ended": False}
    idx = 0
    for line in normalized.split("\n"):
        idx += 1
        if line.startswith("---") and line[3:4] in ["", " ", "\t"]:
            if _doc_dash_line(line, idx, current, doc, state):
                return current
            continue
        if line.startswith("..."):
            if _doc_dots_line(line, idx, current, doc, state):
                return current
            continue
        if doc["ended"]:
            if _doc_tail_content(line):
                state.problems.append("content after document end (...) at line %d" % idx)
                return current
            continue
        current.append(line)
        if _doc_content_line(line):
            doc["content"] = True
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
    """Returns whether `text` opens a block sequence entry.

    A dash opens an entry with a space or a tab after it, as pub reads
    `-\tx` as `x`.
    """
    return text == "-" or text.startswith("- ") or text.startswith("-\t")

def _is_mapping_start(text):
    """Returns whether `text` opens a block mapping entry."""
    return text.startswith("? ") or text.startswith(": ") or _find_colon(text) >= 0

def _is_compact_seq(pending, indent, text):
    """Returns whether `text` is a compact entry of a pending mapping key."""
    return type(pending["parent"]) == "dict" and indent == pending["indent"] and _is_dash(text)

def _close_block_containers(stack, indent, text, anchors, state):
    """Pops the containers that the line at `indent` is not nested into.

    A compact sequence keeps its entries at its key's own column, so a dash
    at the entry column stays inside it while any other line closes it. A
    container that closes with an open anchor binds its value then, as pub
    reads an alias after the collection closes; rebinding replaces any
    older binding.
    """
    for _ in range(len(stack)):
        if not stack or indent > stack[-1]["indent"]:
            break
        top = stack[-1]
        if top.get("compact", False) and top.get("entry", None) == indent and _is_dash(text):
            break
        if top.get("anchor", None) != None:
            anchors[top["anchor"]] = _clone(top["value"])
        stack.pop()

def _undefined_tag_problem(word, line):
    """The problem for a `!!` tag with no node to convert, as pub reports it.

    The display is the full tag URI, as pub names it; a verbatim tag shows
    its inner text.
    """
    if word.startswith("!<") and word.endswith(">"):
        display = word[2:-1]
    elif word.startswith("!!"):
        display = _YAML_TAG_PREFIX + word[2:]
    else:
        display = word
    return "Undefined tag: %s at line %d" % (display, line)

def _apply_child_collection_tag(word, value, anchors, state, line):
    """Applies a pending or flow-close tag to a collection child. Returns the value.

    A `!!seq` or `!!map` tag reads a matching collection as the same-line
    tags do; any other `!!` tag on a collection is a problem
    naming the tag's line, as pub rejects it, and a named handle or
    verbatim tag is an undefined-handle problem, while a local tag rides
    through as the same-line tags do. A problem still reads the child
    untagged, so parsing continues past it.
    """
    if word == None:
        return value
    if _is_unknown_tag_handle(word):
        state.problems.append("Undefined tag handle at line %d" % line)
        return value
    if word.startswith("!!") or word.startswith("!<"):
        name = _tag_name(word)
        if (name == "seq" and type(value) == "list") or (name == "map" and type(value) == "dict"):
            return value
        kind = "sequence" if type(value) == "list" else "mapping"
        state.problems.append("Invalid tag for %s at line %d" % (kind, line))
        return value
    return value

def _apply_pending_scalar_tag(word, value, raw, anchors, state, line):
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
    if _is_unknown_tag_handle(word):
        state.problems.append("Undefined tag handle at line %d" % line)
        return value
    if word.startswith("!!"):
        name = _tag_name(word)
        if name == "bool":
            return _apply_bool_tag(value, raw, state, line)
        if name == "null":
            if value == None or value == "":
                return None
            state.problems.append("Invalid null scalar at line %d" % line)
            return None
        if name in ["str", "int", "float"]:
            return _apply_tag(word, raw, value, anchors, state, line)
        state.problems.append(_undefined_tag_problem(word, line))
        return value
    if type(value) == "list" or type(value) == "dict":
        return value
    return value if type(value) == "string" else raw

def _drop_tag_value(word, line, state):
    """Reads a tag closed with no node. Returns the value.

    A dropped `!!str` or local tag reads an empty scalar, as pub reads it,
    and a dropped `!!null` reads null; a dropped `!!bool` is an invalid bool
    problem, a dropped `!!int` or `!!float` is a problem naming the line, as
    pub crashes on it, a dropped named handle or verbatim tag is an
    undefined-handle problem, and any other dropped `!!` tag is an undefined
    tag problem, as pub reports them.
    """
    if word == None:
        return None
    if _is_unknown_tag_handle(word):
        state.problems.append("Undefined tag handle at line %d" % line)
        return None
    name = _tag_name(word)
    if name == "str" or (word.startswith("!") and not word.startswith("!!") and not word.startswith("!<")):
        return ""
    if name == "null":
        return None
    if name == "bool":
        state.problems.append("Invalid bool scalar at line %d" % line)
        return None
    if name in ["int", "float"]:
        state.problems.append("tag %s with no value at line %d is not supported" % (word, line))
        return None
    state.problems.append(_undefined_tag_problem(word, line))
    return None

def _apply_key_tag(word, key, raw, anchors, state, line):
    """Applies a flow key tag. Returns the key.

    A named handle or verbatim tag is an undefined-handle problem, and a
    `!!` tag with no scalar to convert is an undefined tag problem, naming
    the tag's line, as pub reports them; any other `!!` tag converts the key
    as the same-line tags do, and a local tag reads a string key as is and
    any other key as its raw text, as pub reads them. A problem still reads
    the key untagged, so parsing continues past it.
    """
    if _is_unknown_tag_handle(word):
        state.problems.append("Undefined tag handle at line %d" % line)
        return key
    if word.startswith("!!"):
        name = _tag_name(word)
        if name not in ["str", "int", "float", "bool", "null", "seq", "map"]:
            state.problems.append(_undefined_tag_problem(word, line))
            return key
        if name in ["seq", "map"]:
            return key
        return _apply_tag(word, raw, key, anchors, state, line)
    if type(key) == "string":
        return _apply_tag(word, raw, key, anchors, state, line)
    return raw

def _drop_pending_value(pending, anchors, state):
    """Reads a pending key or dash closed with no child. Returns the value.

    The slot and a pending anchor read the dropped value, so parsing
    continues past it.
    """
    value = _drop_tag_value(pending["tag"], pending["line"], state)
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
        value = _apply_child_collection_tag(pending["tag"], child, anchors, state, pending["line"])
        pending["parent"][pending["slot"]] = value
        if pending["anchor"] != None:
            anchors[pending["anchor"]] = _OPEN_ANCHOR
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
    seq = _apply_child_collection_tag(pending["tag"], [], anchors, state, pending["line"])
    pending["parent"][pending["slot"]] = seq
    if pending["anchor"] != None:
        anchors[pending["anchor"]] = _OPEN_ANCHOR
    stack.append({
        "kind": "seq",
        "indent": pending["indent"],
        "value": seq,
        "entry": None,
        "compact": True,
        "anchor": pending["anchor"],
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

def _flow_fresh_res():
    """A fresh per-line scan result for `_flow_scan_text`."""
    return {"kept": [], "plain_comment": False, "pct_flag": False, "stopped": False, "skip": False}

def _block_fold_begin(head, core, scan):
    """Initializes one block fold. Returns the mutable fold dict.

    `head` carries the head line as {text, raw, idx, entry}: `text` is the
    same-line value after `key:` or `- `, comment-free as `_block_line_text`
    strips it, or "" when the value starts on a later line; `raw` is the
    same slice with its comment intact, "" when pending; `idx` is the head's
    0-based line and `entry` the whole entry for head problems.

    The head scans through the quote-aware pass, and a head comment poisons
    the scalar, ending it silently as pub ends it. Anchor and tag prefixes
    are stripped before scanning, so a quote after `&a ` still opens, and
    re-attached before parsing, so `&a one` folding with `two` reads the
    anchor `one two`.
    """
    if core:
        prefix = head["text"][:len(head["text"]) - len(core)]
    elif head["text"]:
        prefix = head["text"] + " "
    else:
        prefix = ""
    if core:
        _flow_scan_text(core, scan, _flow_fresh_res())
    poison = False
    if head["raw"]:
        probe = _flow_scan_start()
        raw_res = _flow_fresh_res()
        _flow_scan_text(head["raw"], probe, raw_res)
        poison = raw_res["plain_comment"] or (raw_res["stopped"] and not raw_res["pct_flag"])
    opened, closed = _block_head_quotes(core)
    head_complete = core != "" and core[:1] in ["'", '"'] and not scan["single"] and not scan["double"]
    items = [(head["idx"] + 1, core)] if core != "" else []
    return {"prefix": prefix, "poison": poison, "opened": opened, "closed": closed, "head_complete": head_complete, "seen": core != "", "items": items, "consumed": 0, "bom": False, "tab": False}

def _block_fold_quoted(raw, idx, scan, fold):
    """Takes a line inside open quotes at any indent.

    Inside quotes every line is content, as pub reads it, including
    markers, entries and `%` lines.
    """
    fold["items"].append((idx + 1, raw))
    _flow_scan_text(raw.lstrip(" \t"), scan, _flow_fresh_res())
    fold["consumed"] += 1
    fold["seen"] = True

def _block_fold_plain(raw, scan, fold, question_stops):
    """Decides one deeper plain line. Returns take, break, fail or comment.

    Checked against package:yaml 3.1.4, a `?` line without a colon folds
    into an open scalar except in a nested mapping, where it opens an
    explicit key; a `- ` line without a colon folds into an open scalar at
    any depth, while one with a colon ends it. A `:` line never continues a
    scalar: pub rejects it where an entry belongs, so ending the scalar
    fails closed downstream. An indented `%` line is content once the scalar
    is open, as pub folds it, and a problem where pub rejects it otherwise.
    A comment-only or trailing-comment line ends a plain scalar, as pub ends
    it; the comment line itself is silent, as pub places it.
    """
    text = raw.lstrip(" \t")
    res = _flow_fresh_res()
    _flow_scan_text(text, scan, res)
    if res["pct_flag"]:
        return "take" if fold["seen"] else "fail"
    if res["plain_comment"] or res["stopped"]:
        return "comment"
    if fold["poison"]:
        return "break"
    if text == ":" or text[:2] == ": " or text[:2] == ":\t":
        return "break"
    if text[:1] == "?":
        if _find_colon(text) >= 0 or not fold["seen"] or question_stops:
            return "break"
        return "take"
    if _is_dash(text):
        if not fold["seen"] or text == "-":
            return "break"
        if _block_dash_colon(text[1:]):
            return "break"
        return "take"
    if _is_mapping_start(text) or _is_explicit_key_text(text):
        return "break"
    return "take"

def _block_fold_gather(lines, start, parent_indent, scan, fold, question_stops, state):
    """Gathers a scalar's continuation lines. Returns (next index, fail).

    `fail` is the 0-based failing line, or -1: a line starting with a tab is
    a problem naming the line, as pub rejects it, while a line with spaces
    before its tab folds, as pub folds it. A byte-order mark outside
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
            if raw.startswith("\t") and not (scan["single"] or scan["double"]):
                fold["tab"] = True
                fail = idx
                break
            if not fold["poison"]:
                fold["items"].append((idx + 1, ""))
            idx += 1
            continue
        if scan["single"] or scan["double"]:
            _block_fold_quoted(raw, idx, scan, fold)
            idx += 1
            continue
        if _indent_width(raw) <= parent_indent:
            break
        if raw.startswith("\t"):
            fold["tab"] = True
            fail = idx
            break
        if _BOM in raw:
            state.problems.append("byte-order mark at line %d is not supported" % (idx + 1))
            fold["bom"] = True
            fail = idx
            break
        action = _block_fold_plain(raw, scan, fold, question_stops)
        if action == "take":
            fold["items"].append((idx + 1, raw))
            fold["consumed"] += 1
            fold["seen"] = True
        elif action == "comment":
            fold["poison"] = True
        elif action == "fail":
            fail = idx
            break
        else:
            break
        idx += 1
    return (idx, fail)

def _block_fold_finish(fold, core, lines, idx, head, anchors, state, scan):
    """Folds and validates the gathered lines. Returns (value, next, read).

    When read is False, value is None and a problem names the failing line.
    Text after a same-line closing quote, a second quoted scalar on the head
    line, and a continuation of an alias are problems naming the head line,
    as pub rejects them.
    """
    items = fold["items"]
    for _ in range(len(items) + 1):
        if not items or items[-1][1] != "":
            break
        items.pop()
    folded, problem = _flow_fold_lines(items, _flow_scan_start())
    if problem != None:
        line = problem[1] - 1
        _record_unreadable(state, line, _block_fail_text(lines, line, head["idx"], head["entry"]))
        return None, idx, False
    if scan["single"] or scan["double"]:
        _record_unreadable(state, head["idx"], head["entry"] or head["text"])
        return None, idx, False
    if fold["head_complete"] and (fold["opened"] != 1 or fold["closed"] != 1 or not _is_quoted(core) or fold["consumed"] > 0):
        _record_unreadable(state, head["idx"], head["entry"] or head["text"])
        return None, idx, False
    if core[:1] == "*" and fold["consumed"] > 0:
        _record_unreadable(state, head["idx"], head["entry"] or head["text"])
        return None, idx, False
    return _parse_scalar(fold["prefix"] + folded, anchors, state, head["idx"] + 1, fold["prefix"] == ""), idx, True

def _block_fold_scalar(lines, start, parent_indent, head, question_stops, anchors, state):
    """Folds a block scalar head with its continuation lines. Returns (value, next index, read).

    `head` carries the head line as {text, raw, idx, entry}; see
    `_block_fold_begin`. The head folds with its deeper lines through the
    same quote-aware pass the flow fold uses (`_flow_scan_text` with
    `_flow_fold_lines`), so a break folds to one space, blanks fold
    quote-aware, and comments and `%` behave as pub reads them. A line
    starting with a tab is a problem naming the line, while a deeper line
    with spaces before its tab folds, as pub reads them.
    """
    core = _flow_head_text(head["text"])
    if core[:1] in ["[", "{"]:
        # A flow collection closed on its own line reads within that line,
        # as before: deeper lines are placed downstream, and a broken flow
        # stays an unreadable flow value naming the line.
        return _parse_scalar(head["text"], anchors, state, head["idx"] + 1), start, True
    scan = _flow_scan_start()
    fold = _block_fold_begin(head, core, scan)
    idx, fail = _block_fold_gather(lines, start, parent_indent, scan, fold, question_stops, state)
    if fail >= 0:
        if not fold["bom"]:
            if fold["tab"]:
                state.problems.append("tab indentation at line %d is not supported" % (fail + 1))
            else:
                _record_unreadable(state, fail, _block_fail_text(lines, fail, head["idx"], head["entry"]))
        return None, idx + 1, False
    return _block_fold_finish(fold, core, lines, idx, head, anchors, state, scan)

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
    as today. Every caller already split the head's prefixes, so the parse
    reads them without recording again.
    """
    if _unclosed_flow_head(head_raw, anchors) == None:
        return None, idx + 1, False
    raws, next_idx = _pending_flow_raws(lines, idx + 1, parent_indent)
    items = [(head_line, head_raw)] + raws
    folded, problem = _flow_fold_lines(items, _flow_scan_start())
    if problem != None or not _folded_flow_ok(folded, anchors):
        return None, next_idx, False
    return _parse_scalar(folded, anchors, state, head_line, False), next_idx, True

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
            _store_pending_value(pending, value, "", anchors, state)
            return next_idx
        if problem != None:
            state.problems.append(_flow_fold_problem(problem[0], problem[1]))
        else:
            state.problems.append(_span_flow_problem(idx + 1))
        end = _spanning_flow_end(lines, idx + 1, parent_indent, text0, anchors)
        return end if end != None else next_idx
    value, next_idx, _read = _block_fold_scalar(lines, idx, parent_indent, {"text": "", "raw": "", "idx": idx, "entry": ""}, type(parent) == "dict" and parent_indent > 0, anchors, state)
    _store_pending_value(pending, value, text0, anchors, state)
    return next_idx

def _store_pending_value(pending, value, raw, anchors, state):
    """Stores a folded pending child, reading it through a pending tag.

    A collection child follows the collection rule; any other child follows
    the scalar rule with `raw` as the raw text, as pub reads them. A pending
    anchor binds the stored value, replacing any older binding.
    """
    if pending["tag"] != None:
        if type(value) in ["list", "dict"]:
            value = _apply_child_collection_tag(pending["tag"], value, anchors, state, pending["line"])
        else:
            value = _apply_pending_scalar_tag(pending["tag"], value, raw, anchors, state, pending["line"])
    pending["parent"][pending["slot"]] = value
    if pending["anchor"] != None:
        anchors[pending["anchor"]] = _clone(value)

def _resolve_pending(pending, cursor, env):
    """Resolves a pending key or dash against the current line.

    Returns (next index, consumed): consumed is True when deeper scalar lines
    were folded into the pending value and the caller must continue.
    """
    indent = cursor.indent
    text = cursor.text
    if _is_compact_seq(pending, indent, text):
        _attach_compact_seq(pending, env.anchors, env.stack, env.state)
        return cursor.idx, False
    if indent > pending["indent"]:
        if _is_dash(text) or _is_mapping_start(text):
            _attach_pending_child(pending, indent, text, env.anchors, env.stack, env.state)
            return cursor.idx, False
        next_idx = _consume_pending_scalar(struct(lines = cursor.lines, idx = cursor.idx), pending, struct(anchors = env.anchors, state = env.state))
        return next_idx, True
    _drop_pending_value(pending, env.anchors, env.state)
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
        if _BOM in raw and _is_bom_only_line(raw):
            # A bare mark line is blank-like at column 0, as pub skips it,
            # and a problem naming the line anywhere else, as pub rejects it.
            if _indent_width(raw) > 0:
                state.problems.append("byte-order mark at line %d is not supported" % (idx + 1))
            idx += 1
            continue
        if raw.startswith("\t") or (raw.strip(" \t") != "" and "\t" in raw[:_indent_width(raw)]):
            # A tab never indents: a line starting with a tab, and a content
            # line with a tab in its leading whitespace, are problems naming
            # the line, as pub rejects them. A whitespace-only line starting
            # with spaces stays blank, as pub skips it, and deeper lines of a
            # folded scalar never reach here, as the fold consumes them.
            state.problems.append("tab indentation at line %d is not supported" % (idx + 1))
            idx += 1
            continue
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
        _close_block_containers(stack, indent, text, anchors, state)

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
    if pending != None:
        _drop_pending_value(pending, anchors, state)
    for _ in range(len(stack) + 1):
        if not stack:
            break
        top = stack.pop()
        if top.get("anchor", None) != None:
            anchors[top["anchor"]] = _clone(top["value"])
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
    key = _map_key_value(text, key_text, anchors, state, line)
    anchor, tag, rest, failed = _split_value_text(value_text, anchors, state, line)
    if failed:
        return _map_store(mapping, key, None, idx + 1, line, state)
    if rest == "":
        if _is_duplicate(mapping, key, line, state):
            return idx + 1, None
        mapping[key] = None
        pending = {"parent": mapping, "slot": key, "indent": indent, "anchor": anchor, "tag": tag, "line": line}
        if anchor != None:
            anchors[anchor] = _OPEN_ANCHOR
        return idx + 1, pending

    if rest.startswith("|") or rest.startswith(">"):
        parsed, next_idx, _ok = _parse_block_scalar(lines, idx + 1, indent, indent, rest, idx, text, state)
        value = _apply_pending_scalar_tag(tag, parsed, parsed, anchors, state, line)
        if anchor != None:
            anchors[anchor] = _clone(value)
        return _map_store(mapping, key, value, next_idx, line, state)

    flow_value, flow_next, flow_done = _map_flow_value(lines, idx, indent, text, value_text, anchors, state, line)
    if flow_done:
        return _map_store(mapping, key, flow_value, flow_next, line, state)

    raw_head = lines[idx][indent + _find_colon(text) + 1:]
    value, next_idx, _read = _block_fold_scalar(lines, idx + 1, indent, {"text": value_text, "raw": raw_head, "idx": idx, "entry": text}, indent > 0, anchors, state)
    return _map_store(mapping, key, value, next_idx, line, state)

def _seq_dash_map(lines, idx, indent, text, items, anchors, stack, state):
    """Reads a `- key: value` line, starting a mapping for the sequence item. Returns (next index, pending).

    A pending value nests past the key's own column, as pub reads it, so a
    dash at the key's column or shallower is a sibling, not a child.
    """
    line = idx + 1
    rest = text[1:].strip()
    key_text, value_text, _ok = _split_key_value(rest)
    item = {}
    key = _map_key_value(rest, key_text, anchors, state, line)
    after_dash = lines[idx][indent + 1:]
    gap = len(after_dash) - len(after_dash.lstrip(" \t"))
    key_indent = indent + 1 + gap
    head = after_dash[gap + _find_colon(rest) + 1:]
    anchor, tag, rest_value, failed = _split_value_text(value_text, anchors, state, line)
    if failed:
        item[key] = None
        items.append(item)
        stack.append({"kind": "map", "indent": indent, "value": item, "entry": None})
        return idx + 1, None
    if rest_value.startswith("|") or rest_value.startswith(">"):
        # A block scalar after `- key:` reads as pub reads it; an
        # indentation indicator counts from the key's own column.
        parsed, next_idx, _ok = _parse_block_scalar(lines, idx + 1, indent, key_indent, rest_value, idx, text, state)
        value = _apply_pending_scalar_tag(tag, parsed, parsed, anchors, state, line)
        if anchor != None:
            anchors[anchor] = _clone(value)
        item[key] = value
        items.append(item)
        stack.append({"kind": "map", "indent": indent, "value": item, "entry": None})
        return next_idx, None
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
    if rest_value == "":
        items.append(item)
        stack.append({"kind": "map", "indent": indent, "value": item, "entry": None})
        pending = {"parent": item, "slot": key, "indent": key_indent, "anchor": anchor, "tag": tag, "line": line}
        if anchor != None:
            anchors[anchor] = _OPEN_ANCHOR
        return idx + 1, pending
    value, next_idx, _read = _block_fold_scalar(lines, idx + 1, indent, {"text": value_text, "raw": head, "idx": idx, "entry": text}, True, anchors, state)
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
    anchor, tag, rest_value, failed = _split_value_text(rest, anchors, state, line)
    if failed:
        items.append(None)
        return idx + 1, None
    if rest_value == "":
        items.append(None)
        pending = {"parent": items, "slot": len(items) - 1, "indent": indent, "anchor": anchor, "tag": tag, "line": line}
        if anchor != None:
            anchors[anchor] = _OPEN_ANCHOR
        return idx + 1, pending

    if _find_colon(rest) >= 0:
        # `- key: value` starts a mapping whose first entry is on this line.
        return _seq_dash_map(lines, idx, indent, text, items, anchors, stack, state)

    if rest_value.startswith("|") or rest_value.startswith(">"):
        parsed, next_idx, _ok = _parse_block_scalar(lines, idx + 1, indent, indent, rest_value, idx, text, state)
        value = _apply_pending_scalar_tag(tag, parsed, parsed, anchors, state, line)
        if anchor != None:
            anchors[anchor] = _clone(value)
        items.append(value)
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
    value, next_idx, _read = _block_fold_scalar(lines, idx + 1, indent, {"text": rest, "raw": after_dash, "idx": idx, "entry": text}, False, anchors, state)
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

def _block_scalar_header_ok(header):
    """Returns whether `header` is a valid `|` or `>` indicator.

    After the style comes at most one chomping indicator and at most one
    digit, in either order. Anything else is rejected, as pub rejects text
    after the indicator where it expects a comment or line break.
    """
    if len(header) < 1 or len(header) > 3:
        return False
    if header[0] != "|" and header[0] != ">":
        return False
    chomping = False
    digit = False
    for i in range(1, len(header)):
        ch = header[i]
        if (ch == "+" or ch == "-") and not chomping:
            chomping = True
        elif ch.isdigit() and not digit:
            digit = True
        else:
            return False
    return True

def _block_scalar_raw_lines(lines, start, parent_indent):
    """Collects the scalar lines. Returns (items, next index).

    Each item is [raw, indent], with indent -1 for a blank line, which is
    kept verbatim: spaces beyond the content indentation are content, as
    pub reads them. Collection stops before the first line at or above
    `parent_indent`, and before a line starting with a tab, which pub never
    reads as scalar content: the driver re-reads it downstream, where the
    tab indentation fails naming the line, as pub rejects it.
    """
    idx = start
    items = []
    for _ in range(len(lines) + 1):
        if idx >= len(lines):
            break
        raw = lines[idx]
        if raw.startswith("\t"):
            break
        if not raw.strip():
            items.append([raw, -1])
            idx += 1
            continue
        indent = _indent_width(raw)
        if indent <= parent_indent:
            break
        items.append([raw, indent])
        idx += 1
    return items, idx

def _block_scalar_indent(items, explicit_base, explicit_indent):
    """Reads the content indent. Returns (indent, putback, bad_lead).

    With an explicit indicator the content sits `explicit_indent` past
    `explicit_base`, the key's own column. Otherwise it sits at the first
    content line. `putback` is the first item the scalar does not cover: a
    line less indented than the content ends the scalar, as pub ends it,
    and the driver re-reads it downstream. `bad_lead` is the first content
    item when, without an explicit indicator, a leading blank line runs
    deeper than it, which pub rejects; with an explicit indicator such a
    line strips to content instead. Only spaces count toward the depth: a
    tab never indents, so a blank with spaces up to the content and a tab
    past it strips to content, as pub reads it.
    """
    first = -1
    for i in range(len(items)):
        if items[i][1] >= 0:
            first = i
            break
    if explicit_indent > 0:
        indent = explicit_base + explicit_indent
    elif first < 0:
        indent = -1
    else:
        indent = items[first][1]
    putback = len(items)
    bad_lead = -1
    if first >= 0:
        if explicit_indent == 0:
            for i in range(first):
                if _spaces_width(items[i][0]) > indent:
                    bad_lead = first
                    break
        for i in range(first, len(items)):
            if items[i][1] >= 0 and items[i][1] < indent:
                putback = i
                break
    return (indent, putback, bad_lead)

def _block_scalar_values(items, kept, indent):
    """Strips the content indent. What strips to nothing stays blank.

    A line without content of its own still contributes when it runs past
    the content indent, as pub reads those spaces as content.
    """
    values = []
    for i in range(kept):
        values.append(items[i][0][indent:])
    return values

def _fold_next_is_more(values, i):
    """Returns whether the next non-blank line after `i` is more-indented.

    With no non-blank line after `i`, the break stays, so this returns True.
    A line that is whitespace past the content indent counts as
    more-indented, as pub keeps the break before it.
    """
    for j in range(i + 1, len(values)):
        if values[j] != "":
            return values[j].startswith(" ") or values[j].strip(" \t") == ""
    return True

def _fold_flowed_line(values, i, state, pieces):
    """Appends folded `>` line `i`. Returns the next state.

    `state` is start, blank, base or more, describing the previous line. A
    blank line becomes one break, with a second one after a more-indented
    line whose breaks around it are kept. The break after a base-indented
    line drops only when the next non-blank line is a base line it folds
    into; when a more-indented line follows, the break stays and each blank
    line adds one break. A break between two base lines is one space. A line
    that is whitespace past the content indent counts as more-indented, as
    pub keeps its breaks around it.
    """
    line = values[i]
    if line == "":
        pieces.append("\n")
        if state == "more" or (state == "base" and _fold_next_is_more(values, i)):
            pieces.append("\n")
        return "blank"
    more = line.startswith(" ") or line.strip(" \t") == ""
    if state == "start" or state == "blank":
        pieces.append(line)
    elif state == "base" and not more:
        pieces.append(" ")
        pieces.append(line)
    else:
        pieces.append("\n")
        pieces.append(line)
    return "more" if more else "base"

def _fold_flowed(values):
    """Folds `>` lines as pub folds them. Checked against package:yaml 3.1.4."""
    pieces = []
    state = "start"
    for i in range(len(values)):
        state = _fold_flowed_line(values, i, state, pieces)
    return "".join(pieces)

def _block_scalar_chomp(style, values, chomping):
    """Joins a block scalar and applies the chomping indicator, as pub does.

    `|` joins lines with breaks and `>` folds them with `_fold_flowed`.
    Clip keeps one final break only when anything was read, keep adds the
    final break and every trailing blank, and strip drops them.
    """
    if style == "|":
        folded = "\n".join(values)
    else:
        folded = _fold_flowed(values)
    trailing = 0
    for value in reversed(values):
        if value != "":
            break
        trailing += 1
    text = folded.rstrip("\n")
    if chomping == "-":
        return text
    if chomping == "+":
        return text + "\n" * (1 + trailing) if text else "\n" * trailing
    return text + "\n" if text else ""

def _parse_block_scalar(lines, start, parent_indent, explicit_base, header, head_idx, head_text, state):
    """Reads a `|` or `>` block scalar. Returns (text, next index, ok).

    `header` is the indicator text after the key or dash, such as `|-` or
    `>2`; `explicit_base` is the key's own column, which an indentation
    indicator counts from. The content is every following line indented
    deeper than `parent_indent`, minus any lines put back past a
    less-indented line. A header with other text, and without an explicit
    indicator a leading blank line deeper than the content, are problems
    naming the line, as pub rejects them; then text is None and the driver
    re-reads from next index.
    """
    if not _block_scalar_header_ok(header):
        _record_unreadable(state, head_idx, head_text)
        return None, start, False
    style, chomping, explicit_indent = _block_scalar_header(header)
    items, _idx = _block_scalar_raw_lines(lines, start, parent_indent)
    indent, putback, bad_lead = _block_scalar_indent(items, explicit_base, explicit_indent)
    if bad_lead >= 0:
        _record_unreadable(state, start + bad_lead, lines[start + bad_lead].strip())
        return None, start + bad_lead, False
    values = _block_scalar_values(items, putback, indent)
    if _idx >= len(lines) and values and values[-1] == "":
        # The file ends with a newline, so the split left one artifact blank
        # line after the scalar: keep chomping must not count it as a
        # trailing blank line, as pub does not count it.
        values = values[:-1]
    return _block_scalar_chomp(style, values, chomping), start + putback, True

# ---------------------------------------------------------------------------
# Lines
# ---------------------------------------------------------------------------

def _indent_width(raw):
    """Counts the leading spaces and tabs, each as one column, as yaml.bzl does."""
    return len(raw) - len(raw.lstrip(" \t"))

def _spaces_width(raw):
    """Counts the leading spaces, stopping at a tab, which never indents."""
    return len(raw) - len(raw.lstrip(" "))

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

def _parse_scalar(text, anchors, state, line, record_prefix = True):
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
    anchor, tag, s, bad = _strip_value_prefix(s)
    if record_prefix:
        _record_prefix_problems(bad, state, line)
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

    if s[:1] in ["[", "{"]:
        if anchor != None:
            anchors[anchor] = _OPEN_ANCHOR
        value = _parse_flow(s, anchors, state, line)
        if value == None and state.strict_lines:
            state.problems.append("unreadable flow value at line %d: %r" % (line, s))
    else:
        value = _parse_nonflow(s, anchors, state, line)
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

def _apply_int_tag(value, raw, state, line):
    """Applies a `!!int` tag. Returns the value, or None with a problem naming the line.

    An int reads as is and a string naming one converts, as pub reads them;
    anything else is an invalid int scalar problem naming the line, as pub
    rejects it.
    """
    if type(value) == "int":
        return value
    if type(value) == "string":
        parsed = _parse_int_text(value)
        if parsed != None:
            return parsed
    state.problems.append("Invalid int scalar at line %d" % line)
    return None

def _apply_float_tag(value, raw, state, line):
    """Applies a `!!float` tag. Returns the value, or None with a problem naming the line.

    A float reads as is and a float-shaped string converts, as pub reads
    them; an int node or an int-shaped string is an invalid float scalar
    problem naming the line, as pub rejects it (package:yaml crashes on it).
    """
    if type(value) == "float":
        return value
    if type(value) == "string":
        parsed = _parse_float_text(value)
        if parsed != None:
            return parsed
    state.problems.append("Invalid float scalar at line %d" % line)
    return None

def _apply_bool_tag(value, raw, state, line):
    """Applies a `!!bool` tag. Returns the value, or None with a problem naming the line.

    Only `true`, `True`, `TRUE`, `false`, `False` and `FALSE` convert, as
    pub reads them; anything else is an invalid bool scalar problem naming
    the line, as pub rejects it. A resolved bool reads through its raw
    spelling, so a wider untagged spelling still fails here as pub fails it.
    """
    if type(value) == "string":
        text = value
    elif type(value) == "bool" and type(raw) == "string":
        text = raw.strip()
    else:
        text = ""
    if text in ["true", "True", "TRUE", "false", "False", "FALSE"]:
        return text.lower() == "true"
    state.problems.append("Invalid bool scalar at line %d" % line)
    return None

def _is_unknown_tag_handle(tag):
    """Whether `tag` is a named handle or a verbatim tag.

    A `!` alone is the non-specific tag and `!!x` the default handle, which
    resolve below. A verbatim tag never resolves, as pub rejects it with an
    undefined tag handle, and any other `!` word with a second `!` is a
    named handle pub rejects the same way; any other `!` word is a local
    tag, which reads below.
    """
    if tag == "!" or tag.startswith("!!"):
        return False
    if tag.startswith("!<"):
        return True
    return tag.startswith("!") and "!" in tag[1:]

def _apply_tag(tag, raw, value, anchors, state, line):
    """Applies a tag to a parsed value. Returns the value.

    A named handle or verbatim tag is an undefined handle problem naming
    the line, as pub rejects it. A local or non-specific (`!`) tag reads a
    scalar as its string and a collection as is, as pub reads them. A
    `!!seq` or `!!map` tag reads a matching collection, fails another
    collection as an invalid tag for its kind, and fails any other node as
    an undefined tag; a scalar type tag fails a collection as an invalid tag
    for its kind, as pub reports them. A problem still reads the value
    untagged, so parsing continues past it. Scalar conversions fail naming
    the line where the value does not resolve, as pub rejects them.
    """
    if _is_unknown_tag_handle(tag):
        state.problems.append("Undefined tag handle at line %d" % line)
        return value
    if not tag.startswith("!!"):
        if type(value) == "list" or type(value) == "dict":
            return value
        return value if type(value) == "string" else raw
    name = _tag_name(tag)
    if name == None:
        return value
    if name == "seq" or name == "map":
        want = "list" if name == "seq" else "dict"
        if type(value) == want:
            return value
        if type(value) != "list" and type(value) != "dict":
            state.problems.append(_undefined_tag_problem(tag, line))
            return value
    if type(value) == "list" or type(value) == "dict":
        kind = "sequence" if type(value) == "list" else "mapping"
        state.problems.append("Invalid tag for %s at line %d" % (kind, line))
        return value
    if name == "str":
        return value if type(value) == "string" else raw
    if name == "int":
        return _apply_int_tag(value, raw, state, line)
    if name == "float":
        return _apply_float_tag(value, raw, state, line)
    if name == "bool":
        return _apply_bool_tag(value, raw, state, line)
    if name == "null":
        if value == None or value == "":
            return None
        state.problems.append("Invalid null scalar at line %d" % line)
        return None
    state.problems.append(_undefined_tag_problem(tag, line))
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
            return _safe_float(num)
    return s

# An anchor name whose collection is still open: an alias to it fails
# closed instead of reading a partial value, as pub rejects self-reference.
_OPEN_ANCHOR = struct(open = True)

def _split_prefix_word(s):
    """Splits a leading `&`/`!` word at the first space or tab. Returns (word, rest)."""
    for i in range(len(s)):
        if s[i] in [" ", "\t"]:
            return s[:i], s[i + 1:].lstrip(" \t")
    return s, ""

def _strip_value_prefix(s):
    """Splits leading `&anchor` and `!tag` words. Returns (anchor, tag, rest, bad).

    At most one anchor and one tag read, in either order, as pub reads
    them; `bad` is "" or the first rejected shape: an empty anchor name, a
    repeated anchor or a repeated tag. A `!` word alone is a non-specific
    tag, as pub reads it.
    """
    anchor = None
    tag = None
    bad = ""
    rest = s
    for _ in range(4):
        if rest == "":
            break
        if rest.startswith("&"):
            word, rest = _split_prefix_word(rest)
            name = word[1:]
            if name == "":
                if bad == "":
                    bad = "empty-anchor"
            elif anchor != None:
                if bad == "":
                    bad = "repeat-anchor"
            else:
                anchor = name
        elif rest.startswith("!"):
            word, rest = _split_prefix_word(rest)
            if tag != None:
                if bad == "":
                    bad = "repeat-tag"
            else:
                tag = word
        else:
            break
    return (anchor, tag, rest, bad)

def _record_prefix_problems(bad, state, line):
    """Records a rejected anchor or tag prefix naming the line, as pub rejects it."""
    if bad == "empty-anchor":
        state.problems.append("empty anchor at line %d is not supported" % line)
    elif bad == "repeat-anchor":
        state.problems.append("repeated anchor at line %d is not supported" % line)
    elif bad == "repeat-tag":
        state.problems.append("repeated tag at line %d is not supported" % line)

def _split_value_text(value_text, anchors, state, line):
    """Splits a same-line value into (anchor, tag, rest, failed).

    Shape problems are recorded naming the line, as pub rejects them: an
    alias after an anchor or tag reads `None`, and the anchor binds `None`
    too, so parsing continues past it. Otherwise `rest` is the value after
    the prefix, "" when the value is on the following lines.
    """
    anchor, tag, rest, bad = _strip_value_prefix(value_text)
    _record_prefix_problems(bad, state, line)
    if anchor != None and rest.startswith("*"):
        state.problems.append("alias after anchor at line %d is not supported" % line)
        anchors[anchor] = None
        return None, None, "", True
    if tag != None and rest.startswith("*"):
        state.problems.append("alias after tag at line %d is not supported" % line)
        return None, None, "", True
    if rest == ":" or (rest.startswith(":") and len(rest) > 1 and rest[1] in [" ", "\t", "\r"]):
        # A mapping value indicator where a value starts is rejected, as pub
        # rejects it; a colon glued to content stays a plain scalar.
        state.problems.append("mapping value at line %d is not supported" % line)
        return None, None, "", True
    return anchor, tag, rest, False

def _map_key_value(text, key_text, anchors, state, line):
    """Reads a block mapping or dash key, failing a glued alias key closed.

    A colon glued to an alias (`*x: 2`) joins the alias name, as pub scans
    it, and never reads as a pair, as pub rejects it; an unresolvable name
    reports its alias problem, and a resolvable one is still a problem
    naming the line. Any other key reads as before.
    """
    if key_text.startswith("*") and text[len(key_text):len(key_text) + 1] == ":":
        ok, _value = _resolve_alias(key_text[1:] + ":", anchors, state, line)
        if not ok:
            return None
        state.problems.append("glued alias key at line %d is not supported" % line)
        return None
    return _key(_parse_scalar(key_text, anchors, state, line))

def _alias_name_end(s):
    """Returns the end index of the alias name in `s`, which starts with `*`.

    The name runs to whitespace or `,[]{}`, as pub scans it, so a glued
    colon or hash is part of the name.
    """
    i = 1
    for _ in range(len(s) + 1):
        if i >= len(s) or s[i] in [" ", "\t", "\r", "\n", ",", "[", "]", "{", "}"]:
            break
        i += 1
    return i

def _resolve_alias(name, anchors, state, line):
    """Resolves an alias `name`. Returns (ok, value).

    An empty, undefined or self-referential alias is an always-on problem
    naming the line, as pub rejects it; a use after its collection closes
    reads the value cloned shallowly, as yaml.bzl copies it.
    """
    if name == "":
        state.problems.append("empty alias at line %d is not supported" % line)
        return (False, None)
    if name not in anchors:
        state.problems.append("undefined alias %r at line %d" % (name, line))
        return (False, None)
    value = anchors[name]
    if value == _OPEN_ANCHOR:
        state.problems.append("self-referential alias %r at line %d is not supported" % (name, line))
        return (False, None)
    return (True, _clone(value))

def _parse_alias(s, anchors, state, line):
    """Parses an alias at the start of `s`, or returns None with a problem.

    Text after the alias name is a problem naming the line, as pub rejects
    it; a comment never reaches here, as block lines strip it first.
    """
    end = _alias_name_end(s)
    ok, value = _resolve_alias(s[1:end], anchors, state, line)
    if not ok:
        return None
    if s[end:].strip() != "":
        state.problems.append("trailing text after alias at line %d is not supported" % line)
        return None
    return value

def _parse_nonflow(s, anchors, state, line):
    """Parses an alias, a quoted scalar or a plain scalar.

    A byte-order mark in a plain scalar is a problem naming the line, as pub
    rejects it; quoted scalars keep it as content, as pub reads them.
    """
    if s.startswith("*"):
        return _parse_alias(s, anchors, state, line)
    if _is_quoted(s):
        if s[0] == '"':
            return _unescape_double(s[1:-1], state, line)
        return s[1:-1].replace("''", "'")
    if _BOM in s:
        state.problems.append("byte-order mark at line %d is not supported" % line)
        return None
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
        return _safe_float(normalized)
    if left.count(".") == 1:
        whole, frac = left.split(".")
        if _is_decimal_part(whole) and frac.isdigit():
            return _safe_float(normalized)
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
            return _safe_float(s)
    return None

def _float_parts(text):
    """Splits a validated float text into (negative, adjusted, digits).

    `text` has a validated shape: an optional sign, digits with at most one
    point, and an optional `e` exponent with an optional sign and digits.
    `adjusted` is the base-10 exponent of the first significant digit and
    `digits` are the significant digits without the point, "" for a zero
    mantissa.
    """
    s = text
    neg = False
    if s[:1] in ["-", "+"]:
        neg = s[:1] == "-"
        s = s[1:]
    exp = 0
    e = s.lower().find("e")
    if e >= 0:
        exp = int(s[e + 1:])
        s = s[:e]
    dot = s.find(".")
    if dot < 0:
        intpart, frac = s, ""
    else:
        intpart, frac = s[:dot], s[dot + 1:]
    intpart = intpart.lstrip("0")
    if intpart != "":
        return (neg, exp + len(intpart) - 1, intpart + frac)
    rest = frac.lstrip("0")
    if rest == "":
        return (neg, 0, "")
    return (neg, exp - (len(frac) - len(rest)) - 1, rest)

def _float_over_max(digits):
    """Returns whether significant `digits` past 1e308 exceed the double range.

    Called only for an adjusted exponent of 308, so the value sits in
    [1e308, 1e309): it overflows past the leading digits of DBL_MAX
    (1.7976931348623157e308), or past equal leading digits with any nonzero
    digit after them.
    """
    head = (digits + "00000000000000000")[:17]
    if head != "17976931348623157":
        return head > "17976931348623157"
    for ch in digits[17:].elems():
        if ch != "0":
            return True
    return False

def _safe_float(text):
    """Converts a validated float text, overflowing to infinity as pub reads it.

    Starlark `float()` fails on magnitudes past the double range, while pub
    reads them as infinity, so the magnitude is compared first and only a
    finite value reaches `float()`: the returned double is exactly the one a
    direct conversion gives. Underflow reaches `float()`, which rounds to zero.
    """
    neg, adjusted, digits = _float_parts(text)
    if digits == "":
        return -0.0 if neg else 0.0
    if adjusted > 308 or (adjusted == 308 and _float_over_max(digits)):
        return float("-inf") if neg else float("inf")
    return float(text)

# ---------------------------------------------------------------------------
# Double-quoted escapes
# ---------------------------------------------------------------------------

def _unescape_code_point(text, i, nxt, state, line):
    """Decodes a `\\x`, `\\u` or `\\U` escape at `i`. Returns (decoded, next index, ok).

    Fewer digits than the width needs, a non-hex digit, a surrogate, and a
    code point past U+10FFFF are problems naming the line, as pub rejects
    them; pub rejects even a well-formed surrogate pair.
    """
    width = 2 if nxt == "x" else (4 if nxt == "u" else 8)
    if i + 2 + width > len(text):
        state.problems.append("short %s escape at line %d is not supported" % (nxt, line))
        return "", len(text), False
    digits = text[i + 2:i + 2 + width]
    code_point = _parse_hex(digits)
    if code_point == None:
        state.problems.append("bad %s escape at line %d is not supported" % (nxt, line))
        return "", i + 2 + width, False
    if code_point > 0x10ffff or (code_point >= 0xd800 and code_point <= 0xdfff):
        state.problems.append("bad %s escape at line %d is not supported" % (nxt, line))
        return "", i + 2 + width, False
    return _code_point_text(code_point), i + 2 + width, True

def _unescape_double(text, state, line):
    """Decodes the escapes in the body of a double-quoted scalar.

    Returns the decoded text, or None with a problem naming the line: an
    unknown escape and a malformed hex, Unicode or surrogate escape are
    rejected, as pub rejects them.
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
            decoded, i, ok = _unescape_code_point(text, i, nxt, state, line)
            if not ok:
                return None
            out.append(decoded)
        else:
            state.problems.append("unknown escape at line %d is not supported" % line)
            return None
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

def _flow_close_step(stack, s, i, frame, anchors, state, line):
    """Pops a closed flow frame. Returns (done, value, next_i).

    A frame anchor binds the closed collection, replacing any older
    binding, and a frame tag reads it as a pending tag reads an attached
    child, as pub reads them.
    """
    stack.pop()
    value = frame["value"]
    if frame["tag"] != None:
        value = _apply_child_collection_tag(frame["tag"], value, anchors, state, line)
    if frame["anchor"] != None:
        anchors[frame["anchor"]] = _clone(value)
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
    a glued colon does, reads with a null value, as pub reads it.
    """
    token, i = _flow_token(s, i, [":", frame["close"], ","])
    if token == "" or not _flow_scalar_ok(token):
        return i, False
    frame["key"] = _flow_key_value(token, anchors, state, line)
    i = _skip_flow_space(s, i)
    if i >= len(s) or s[i] != ":":
        _flow_add(frame, None, state, line)
        return i, True
    frame["state"] = "value"
    return i + 1, True

def _flow_item_step(s, i, frame, anchors, stack, state, line):
    """Reads one nested collection or scalar flow token. Returns (next_i, ok)."""
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
    _flow_add(frame, _flow_scalar_value(token, anchors, state, line), state, line)
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
            done, value, i = _flow_close_step(stack, s, i, frame, anchors, parse_state, line)
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

def _flow_scalar_value(token, anchors, state, line):
    """Value of a flow item token with alias, anchor or tag prefixes.

    A token starting with `*` is always an alias: a glued colon or hash
    joins the alias name, as pub scans it, so only a name without a colon
    followed by a spaced colon pairs with a value, as pub reads it. Any
    other token strips one anchor and tag first: an alias after them is a
    problem naming the line, as pub rejects it; a colon where the value
    starts pairs the anchor or tag on its own with the value, as pub reads
    it; any other `:` pair reads with the tag on a string key and the anchor
    on the key, as pub reads them. A problem still reads `None`, so parsing
    continues past it.
    """
    if token.startswith("*"):
        end = _alias_name_end(token)
        if ":" not in token[1:end] and token[end:].strip().startswith(":"):
            key_text, value_text, _ok = _flow_pair_split(token)
            return _flow_pair(key_text, value_text, None, None, anchors, state, line)
        return _parse_alias(token, anchors, state, line)
    anchor, tag, rest, bad = _strip_value_prefix(token)
    _record_prefix_problems(bad, state, line)
    if anchor != None and rest.startswith("*"):
        state.problems.append("alias after anchor at line %d is not supported" % line)
        anchors[anchor] = None
        return None
    if tag != None and rest.startswith("*"):
        state.problems.append("alias after tag at line %d is not supported" % line)
        return None
    if rest.startswith(":"):
        key = _drop_tag_value(tag, line, state) if tag != None else None
        if anchor != None:
            anchors[anchor] = _clone(key)
        value_text = rest[1:].strip()
        value = _flow_atom(value_text, anchors, state, line) if value_text != "" else None
        pair = {}
        pair[_key(key)] = value
        return pair
    if rest == "":
        return _flow_bare_affix(anchor, tag, state, line, anchors)
    key_text, value_text, is_pair = _flow_pair_split(rest)
    if is_pair:
        return _flow_pair(key_text, value_text, anchor, tag, anchors, state, line)
    value = _parse_nonflow(rest, anchors, state, line)
    if tag != None:
        value = _apply_tag(tag, rest, value, anchors, state, line)
    if anchor != None:
        anchors[anchor] = _clone(value)
    return value

def _flow_bare_affix(anchor, tag, state, line, anchors):
    """Value of a flow item that is only an anchor and/or tag.

    With no node the anchor binds `None` and the tag reads as a dropped
    pending tag does, as pub reads them.
    """
    value = _drop_tag_value(tag, line, state)
    if anchor != None:
        anchors[anchor] = _clone(value)
    return value

def _flow_atom(text, anchors, state, line):
    """Value of a flow pair key or value, which nests no further pair.

    An alias after an anchor or tag is a problem naming the line, as pub
    rejects it, and a pair inside is one too, as pub rejects that as well; a
    bare anchor or tag reads as it does on its own. A problem still reads
    `None`, so parsing continues past it.
    """
    if text.startswith("*"):
        return _parse_alias(text, anchors, state, line)
    anchor, tag, rest, bad = _strip_value_prefix(text)
    _record_prefix_problems(bad, state, line)
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
    value = _parse_nonflow(rest, anchors, state, line)
    if tag != None:
        value = _apply_tag(tag, rest, value, anchors, state, line)
    if anchor != None:
        anchors[anchor] = _clone(value)
    return value

def _flow_pair(key_text, value_text, anchor, tag, anchors, state, line):
    """Value of a flow pair after alias, anchor or tag prefixes.

    The key and value nest no further pair, as pub rejects that; the tag
    reads a string key as the same-line tags do and a key of any other type
    drops it, and the anchor binds the key, as pub reads them.
    """
    key = _flow_atom(key_text, anchors, state, line)
    value = _flow_atom(value_text, anchors, state, line)
    if tag != None:
        key = _apply_key_tag(tag, key, key_text, anchors, state, line)
    if anchor != None:
        anchors[anchor] = _clone(key)
    pair = {}
    pair[_key(key)] = value
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
        return _parse_alias(token, anchors, state, line)
    anchor, tag, rest, bad = _strip_value_prefix(token)
    _record_prefix_problems(bad, state, line)
    if anchor != None and rest.startswith("*"):
        state.problems.append("alias after anchor at line %d is not supported" % line)
        anchors[anchor] = None
        return None
    if tag != None and rest.startswith("*"):
        state.problems.append("alias after tag at line %d is not supported" % line)
        return None
    if rest == "":
        key = _drop_tag_value(tag, line, state) if tag != None else None
        if anchor != None:
            anchors[anchor] = _clone(key)
        return _key(key)
    key = _parse_nonflow(rest, anchors, state, line)
    if tag != None:
        key = _apply_key_tag(tag, key, rest, anchors, state, line)
    if anchor != None:
        anchors[anchor] = _clone(key)
    return _key(key)

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
        end = j + _alias_name_end(s[j:])
        word = s[j:end]
        if not word.startswith("&") and not word.startswith("!"):
            break
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
        j = end + len(s[end:]) - len(s[end:].lstrip(" \t"))
    if j >= len(s) or s[j] not in ["[", "{"]:
        return False, i
    _record_prefix_problems(bad, state, line)
    if anchor != None:
        anchors[anchor] = _OPEN_ANCHOR
    stack.append(_flow_frame(s[j], anchor, tag))
    return True, j + 1

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
    quotes is one escaped quote, as pub reads it. An alias, anchor or tag
    word runs to whitespace or `,[]{}`, as pub scans it, so a glued colon or
    hash stays in the word instead of ending the token. Returns (stripped token,
    index of the stop character).
    """
    i = start
    if s[i:i + 1] in ["*", "&", "!"]:
        i = start + _alias_name_end(s[start:])
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
