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

The reader is split across cohesive modules, each loaded in one direction
only: `yaml_chars.bzl` holds the byte-level checks, `yaml_text.bzl` the line
shapes, `yaml_escape.bzl` the double-quoted escapes, `yaml_scalar.bzl` the
scalars, typing and tags, `yaml_flow.bzl` the flow collections,
`yaml_flow_scan.bzl` the quote-aware scan and fold they share,
`yaml_fold.bzl` the folded continuations, `yaml_block_scalar.bzl` the block
scalars, `yaml_block.bzl` the block containers and `yaml_document.bzl` the
document structure and container walk. Helpers a module shares with another
are public; file-local helpers keep their leading underscore.
"""

load(":yaml_chars.bzl", "first_bad_utf8_line", "strip_bom")
load(":yaml_document.bzl", "allows_flow_doc", "first_content", "first_document_lines", "flow_doc_problem", "parse_block")
load(":yaml_flow.bzl", "parse_flow")
load(":yaml_flow_scan.bzl", "flow_fold_lines", "flow_fold_problem", "flow_scan_start")
load(":yaml_text.bzl", "find_top_colon", "strip_trailing_comment")

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
