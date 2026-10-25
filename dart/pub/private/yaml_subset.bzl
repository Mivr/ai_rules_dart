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
block scalars, which stay content as pub reads them. A byte sequence that
is not UTF-8 is a problem naming its line, as pub fails reading the file:
`ctx.read` keeps the file's bytes verbatim.

Supported:
- block mappings and sequences nested by indentation, including `- key: v`
  items, children that start on the lines after `key:` or `-`, and compact
  sequences where `- ` entries sit at their key's own column
- `#` comments, `%` directives before any content or marker, and `---`
  and `...` document markers at column 0 only: an indented marker is never
  a marker, so one inside a `|` or `>` block scalar stays scalar content.
  A `%` line after content is a problem naming the line, as pub rejects it.
  A column-0 `%YAML` with a missing, malformed or incompatible version, a
  duplicate `%YAML`, a `%TAG` without a valid handle and prefix, a second
  `%TAG` with the same handle, and an indented `%` line before any content
  all fail naming the line, as pub rejects them; an unknown directive reads
  on, as pub only warns about it. A `%YAML` or `%TAG` without a later `---`
  fails at the first content line, or past the end when the document has no
  content, as pub expects the document start; a `---` with inline text
  starts the document, as pub reads `--- foo` as "foo". A `%` line after a
  `---` marker or `...` end keeps the old behavior.
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
  fail naming the line, as pub rejects them. A plain scalar starting with
  `@` or a backtick, and one holding a control character or DEL, fail
  naming the line, as pub refuses them; quoted scalars keep them as
  content, as pub reads them, and a tab inside a plain scalar stays
  content too. A bare `&` or `*` fails naming the line, as pub rejects an
  empty anchor or alias.
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
  supported, and fail naming the line. A block entry inside a flow fails
  naming the line, as pub rejects it: a `- ` entry, a `-: ` pair and a `?`
  marker where a flow value starts, and a `- ` entry as a flow map key
  unless a bare dash pairs at once with its colon, as pub reads `{-: 1}`.
  A `-: ` pair as a sequence item reads as a one-pair mapping, and a `?`
  key and `-:x` without a space read, as pub reads them.
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
  the line, as pub rejects it. `!!int` and `!!float` convert through the
  scalar text rather than the resolved value, so an int node reads 12 under
  `!!int` and 12.0 under `!!float` while `1_000`, `0X1F`, `0x10` under
  `!!float` and a lone character under `!!float` fail, as pub reads them.
  Only true, True, TRUE, false, False and FALSE convert under `!!bool`, and
  an empty scalar reads null under `!!null`, as pub reads them. A `!!seq` or `!!map` tag reads a matching
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
  rejects the first and decodes the rest, as read now. A plain scalar
  starting with `@` or a backtick, and one holding a control character or
  DEL, read as plain before; pub refuses them, so they fail naming the
  line. A block entry inside a flow read as plain before: `[- a]`,
  `[a, - b]`, `{a: - b}`, `[a: - b]` and `{ - : 1}` read `"- a"`, `"- b"`
  and `"-"` before; pub rejects them, so they fail naming the line. A flow alias
  with a glued colon resolved the short name before, a flow anchor or tag
  word ended its key at a glued colon before, a key with no pair colon
  failed its flow before, and a colon after a bare flow anchor or tag
  misread before; pub scans the word through the colon and reads a lone
  key with a null value, as read now. A same-line `- ` entry read as a plain
  scalar before (`key: - a` read `"- a"`), a same-line `? ` marker read as a
  plain scalar before (`key: ? bar` read `"? bar"`), and a `: `, `:\t` or
  trailing colon inside a plain same-line value read as content before
  (`key: a: b` read `"a: b"`); pub rejects all three, so they fail naming
  the line. Later keys of a `- key:` item merged at any deeper column
  before; pub only merges them at the key's own column, as read now. A
  block value starting with `]`, `}` or `,` read as a plain scalar before
  (`key: ]x` read `"]x"`), and a `|` or `>` where a flow item, pair value
  or key starts read as a plain scalar before (`[a, |b]` read `"|b"`);
  pub rejects both, so they fail naming the line. A `0` indentation
  indicator read as an indicator before (`key: |0` read the content); pub
  rejects it, so it fails naming the line, while other digits read as pub
  reads them. A byte sequence that is not UTF-8 read as content before; pub
  fails reading the file, so it fails naming the line. A `%YAML` or `%TAG`
  without a later `---`, a duplicate or malformed directive and an indented
  `%` line read the document before; pub rejects them, so they fail naming
  the line, while `%YAML 1.3` and unknown directives read as pub reads them.
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
  reaches the conversion, so finite values convert exactly as before. A
  decimal past the int64 range reads as a double, overflowing to infinity,
  as pub reads it; a decimal with a `_` separator past the range stays a
  string, as pub reads it. A hex value wraps modulo 2^64 into the signed
  range and past 2^64-1 fails, and an octal past 2^63-1 fails, as pub reads
  them; a hex or octal with a `_` separator stays a string, as pub reads
  it. Only the exact `.inf` and `.nan` casings read, so other casings stay
  strings now, as pub reads them. `1.e5` and `.5e5` read as doubles now, as
  pub reads them. `1.` and `.5` stay strings and `1_000`, `0X1F` and `0O17`
  read as before; pub reads some differently (out of scope: scalar typing).
- `%TAG` handles are ignored, so a tag written through one reads as untagged;
  yaml.bzl resolves it. Other unknown tags read as untagged in both.
- duplicate mapping keys fail; yaml.bzl's default non-strict mode silently
  keeps the first scalar and replaces a nested block with a later one.
"""

load(":yaml_block_scalar.bzl", "parse_block_scalar")
load(":yaml_chars.bzl", "BOM", "first_bad_utf8_line", "is_bom_only_line", "is_clean_marker_line", "is_marker_line", "strip_bom")
load(":yaml_flow.bzl", "flow_fold_lines", "flow_fold_problem", "flow_scan_start", "parse_flow", "parse_scalar")
load(":yaml_fold.bzl", "block_fold_scalar")
load(":yaml_scalar.bzl", "OPEN_ANCHOR", "apply_bool_tag", "apply_child_collection_tag", "apply_tag", "drop_tag_value", "is_unknown_tag_handle", "resolve_alias", "resolve_handle", "split_value_text", "strip_value_prefix", "tag_name", "undefined_tag_problem")
load(":yaml_text.bzl", "bad_blank_index", "block_line_text", "clone", "dict_key", "find_top_colon", "flow_head_text", "indent_width", "is_compact_seq", "is_dash", "is_explicit_key_text", "is_mapping_start", "is_question_entry", "record_unreadable", "split_key_value", "strip_trailing_comment")

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
    stripped = strip_bom(content)
    bad_line = first_bad_utf8_line(stripped)
    if bad_line > 0:
        state.problems.append("invalid UTF-8 at line %d is not supported" % bad_line)
    lines, tag_prefixes, dropped_marker = first_document_lines(stripped, state)
    state = struct(problems = state.problems, strict_lines = strict_lines, tag_prefixes = tag_prefixes)
    first = first_content(lines)
    if first.text[:1] in ["{", "["] and allows_flow_doc(lines, first.index):
        items = []
        for i in range(len(lines)):
            items.append((i + 1, lines[i]))
        folded, problem = flow_fold_lines(items, flow_scan_start(), False)
        if problem != None:
            state.problems.append(flow_fold_problem(problem[0], problem[1]))
            return None, state.problems
        value = parse_flow(folded, {}, state, 1)
        if value == None:
            state.problems.append(flow_doc_problem(lines))
            return None, state.problems
        return value, state.problems
    return parse_block(lines, state, not dropped_marker), state.problems

def first_content(lines):
    """Returns the first line with block content as struct(index, text).

    Blank lines, `#` comments, `%` directives and document markers carry no
    block content. Returns index -1 and text "" when no line has content.
    """
    for i in range(len(lines)):
        _indent, text = block_line_text(lines[i])
        if text != None:
            return struct(index = i, text = text)
    return struct(index = -1, text = "")

def allows_flow_doc(lines, index):
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

def flow_doc_problem(lines):
    """The problem for a flow-looking document that reads as no collection.

    The fold succeeded but the folded text is not one complete collection:
    pub rejects these shapes (an unclosed collection, text or a comment past
    the closing bracket), so the reader fails closed naming the last content
    line instead of reading an empty document.
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
        if _has_directive(current):
            current.append(line)
            doc["content"] = True
            doc["pending"] = False
        else:
            doc["marker"] = True
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
    `--- &x a: 1`; an alias or a block scalar header reads as before.
    """
    _anchor, _tag, s, _bad = strip_value_prefix(strip_trailing_comment(rest).strip())
    if is_dash(s):
        return "Block sequence entries are not allowed here at line %d" % idx
    if is_question_entry(s):
        return "Mapping keys are not allowed here at line %d" % idx
    dict_key, _value, found = split_key_value(s)
    if found:
        return "Mapping values are not allowed here at line %d" % idx
    return None

def _collect_doc_line(line, idx, current, doc, state):
    """Collects one raw line into the first document. Returns True when collection stops here."""
    if line.startswith("---") and line[3:4] in ["", " ", "\t"]:
        return _doc_dash_line(line, idx, current, doc, state)
    if line.startswith("...") and line[3:4] in ["", " ", "\t"]:
        return _doc_dots_line(line, idx, current, doc, state)
    if doc["ended"]:
        if _doc_tail_content(line):
            state.problems.append("content after document end (...) at line %d" % idx)
            return True
        return False
    if not doc["content"] and not doc["marker"] and not doc["ended"] and line.strip().startswith("%"):
        if line.startswith("%"):
            _directive_line(line, idx, doc, state)
        else:
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
    consumed, so lines[0] is not the file's first line.
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

def _has_directive(lines):
    for line in lines:
        if line.strip().startswith("%"):
            return True
    return False

# ---------------------------------------------------------------------------
# Block structure
# ---------------------------------------------------------------------------

def close_block_containers(stack, indent, text, anchors):
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
        if top.get("compact", False) and top.get("entry", None) == indent and is_dash(text):
            break
        if top.get("anchor", None) != None:
            anchors[top["anchor"]] = clone(top["value"])
        stack.pop()

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

def drop_pending_value(pending, anchors, state):
    """Reads a pending key or dash closed with no child. Returns the value.

    The slot and a pending anchor read the dropped value, so parsing
    continues past it.
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
    folded, problem = flow_fold_lines(items, flow_scan_start(), True)
    if problem != None or not _folded_flow_ok(folded, anchors):
        return None, next_idx, False
    return parse_scalar(folded, anchors, state, head_line, False), next_idx, True

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
        raws, next_idx = _pending_flow_raws(lines, idx, parent_indent)
        folded, problem = flow_fold_lines(raws, flow_scan_start(), True)
        if problem == None and _folded_flow_ok(folded, anchors):
            # The folded lines read as one flow collection, as pub reads
            # them: keep the value, as revisions before the span check did.
            value = parse_scalar(folded, anchors, state, idx + 1)
            _store_pending_value(pending, value, "", anchors, state)
            return next_idx
        if problem != None:
            state.problems.append(flow_fold_problem(problem[0], problem[1]))
        else:
            state.problems.append(_span_flow_problem(idx + 1))
        end = _spanning_flow_end(lines, idx + 1, parent_indent, text0, anchors)
        return end if end != None else next_idx
    value, next_idx, _read = block_fold_scalar(lines, idx, parent_indent, {"text": "", "raw": "", "idx": idx, "entry": ""}, type(parent) == "dict" and parent_indent > 0, anchors, state)
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
    """
    indent = cursor.indent
    text = cursor.text
    if is_compact_seq(pending, indent, text):
        _attach_compact_seq(pending, env.anchors, env.stack, env.state)
        return cursor.idx, False
    if indent > pending["indent"]:
        if is_dash(text) or is_mapping_start(text):
            _attach_pending_child(pending, indent, text, env.anchors, env.stack, env.state)
            return cursor.idx, False
        next_idx = _consume_pending_scalar(struct(lines = cursor.lines, idx = cursor.idx), pending, struct(anchors = env.anchors, state = env.state))
        return next_idx, True
    drop_pending_value(pending, env.anchors, env.state)
    return cursor.idx, False

def init_block_root(text, indent, anchors, stack, state, line):
    """Creates the root container or scalar. Returns (root, is_scalar)."""
    if is_dash(text):
        root = []
        stack.append({"kind": "seq", "indent": indent - 1, "value": root, "entry": None, "compact": False})
        return root, False
    if find_top_colon(text) >= 0 or text.startswith("? "):
        root = {}
        stack.append({"kind": "map", "indent": indent - 1, "value": root, "entry": None, "compact": False})
        return root, False
    return parse_scalar(text, anchors, state, line), True

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

def parse_block(lines, state, first_line):
    """Parses the block-structured lines of one document into a value.

    `first_line` tells whether lines[0] is the file's first line: there
    tabs and spaces before the first token are separation, not indentation,
    as pub reads them. A consumed pre-content `---` shifts every line down,
    so only an unshifted first line is exempt.

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
            if saw_content and raw.strip().startswith("%"):
                # A `%` line after content is no directive: pub rejects it,
                # so it is a problem naming the line, as the oracle reads it.
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
    head = lines[idx][indent + find_top_colon(text) + 1:]
    value, next_idx, read = _folded_head_flow(head, line, lines, idx, indent, anchors, state)
    if read:
        return value, next_idx, True
    end = _spanning_flow_end(lines, idx + 1, indent, value_text, anchors)
    if end != None:
        state.problems.append(_span_flow_problem(line))
        return None, end, True
    return None, idx + 1, False

def map_line(lines, idx, indent, text, frame, anchors, state):
    """Reads one line of a block mapping. Returns (next index, pending)."""
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
    key_text, value_text, ok = split_key_value(text)
    if not ok or key_text == "":
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

    raw_head = lines[idx][indent + find_top_colon(text) + 1:]
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
    key_text, value_text, _ok = split_key_value(rest)
    item = {}
    key = _map_key_value(rest, key_text, anchors, state, line)
    after_dash = lines[idx][indent + 1:]
    gap = len(after_dash) - len(after_dash.lstrip(" \t"))
    key_indent = indent + 1 + gap
    head = after_dash[gap + find_top_colon(rest) + 1:]
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
    end = _spanning_flow_end(lines, idx + 1, indent, value_text, anchors)
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

def seq_line(lines, idx, indent, text, frame, anchors, stack, state):
    """Reads one line of a block sequence. Returns (next index, pending)."""
    if not _entry_indent_ok(frame, indent):
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

    if find_top_colon(rest) >= 0:
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
    head = after_dash[gap + find_top_colon(rest) + 1:]
    flow_value, flow_next, flow_read = _folded_head_flow(head, line, lines, idx, indent, anchors, state)
    if flow_read:
        items.append(flow_value)
        return flow_next, None
    end = _spanning_flow_end(lines, idx + 1, indent, rest, anchors)
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

def find_colon(text):
    """Returns the index of the first top-level `: ` in `text`, or -1.

    A colon inside quotes or brackets does not count, and a trailing colon
    does. A quote opens only where a scalar starts.
    Shared with the `//dart/pub:yaml_parser.bzl` lock checks so both read a
    `key: value` line the same way.
    """
    return find_top_colon(text)

def strip_comment(text):
    """Removes a trailing `#` comment, ignoring `#` inside quotes.

    A quote opens only where a scalar starts.
    Shared with the `//dart/pub:yaml_parser.bzl` lock checks so both skip
    the same comment text.
    """
    return strip_trailing_comment(text)

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

def _map_key_value(text, key_text, anchors, state, line):
    """Reads a block mapping or dash key, failing a glued alias key closed.

    A colon glued to an alias (`*x: 2`) joins the alias name, as pub scans
    it, and never reads as a pair, as pub rejects it; an unresolvable name
    reports its alias problem, and a resolvable one is still a problem
    naming the line. A block scalar header (`|`, `>` with any indicators)
    never reads as a key, as pub rejects a block scalar there; anything
    starting with `|` or `>` is one, since a plain scalar never starts with
    a reserved indicator, as pub scans it. Any other key reads as before.
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
    return dict_key(parse_scalar(key_text, anchors, state, line))
