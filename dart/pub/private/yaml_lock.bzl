"""Pubspec.lock validation and parsing over one shared document read.

`parse_pubspec_lock` and `pubspec_lock_error` first try the dedicated
`lock_fast_packages` reader, which recognises exactly the layout `dart pub
get` writes without running the general YAML reader. Anything else goes
through `lock_general_packages`, which reads the document exactly once with
`document_value_and_problems` and validates the parsed value plus one shared
scan of the text: a single pass over the shared line split feeds the
document-tail, tab-indentation, quote-trailer and entry-line checks together,
in the same priority the separate checks ran before. Shape, entry and
case-clash validation then runs on the parsed value. No lock is ever parsed
twice.
"""

load("//dart/pub/private:yaml_lock_fast.bzl", "is_lock_package_name", "is_lock_version", "lock_fast_packages")
load("//dart/pub/private:yaml_subset.bzl", "document_value_and_problems", "find_colon", "strip_comment")

def _lock_description(value):
    """Normalises a lock `description` value to a dict of strings."""
    if type(value) == "dict":
        return {sk: "" if sv == None else str(sv) for sk, sv in value.items()}
    return {"name": "" if value == None else str(value)}

def _lock_entry(info):
    """Projects one lock package entry to string fields and a dict description."""
    entry = {}
    for k, v in info.items():
        if k == "description":
            # An inline scalar `description: flutter` is normalised to
            # {"name": "flutter"} so callers can always treat description
            # as a dict.
            entry["description"] = _lock_description(v)
        else:
            entry[k] = "" if v == None else str(v)
    return entry

def _lock_shape_error(data, lock_label):
    """Returns the missing or non-mapping `packages` error, or None."""
    if type(data) != "dict":
        return "%s: expected a mapping with a 'packages' key" % lock_label
    if "packages" not in data:
        return "%s: missing 'packages' mapping" % lock_label
    if type(data["packages"]) != "dict":
        return "%s: 'packages' is not a mapping" % lock_label
    return None

def _lock_entry_shape_error(name, info, lock_label):
    """Returns the non-mapping package entry error, or None."""
    if type(info) != "dict":
        return "%s: package %r entry is not a mapping" % (lock_label, name)
    return None

def _lock_text_lines(content):
    """Splits lock text into lines with newlines normalized and the BOMs stripped."""
    text = content.replace("\r\n", "\n").replace("\r", "\n")
    for _ in range(len(text) + 1):
        if text.startswith("\357\273\277"):
            text = text[len("\357\273\277"):]
        else:
            break
    return text.split("\n")

def _is_lock_marker_line(line, marker):
    """Returns whether `line` is a document marker: the marker at column 0 with only whitespace after it.

    An indented marker is never a document marker, so one inside a block
    scalar stays content and one elsewhere is an ordinary line.
    """
    if not line.startswith(marker):
        return False
    return line[len(marker):].strip() == ""

def _lock_tail_content_error(lines, start, lock_label, marker):
    """Returns the error for the first content line at or after `start`, or None.

    Blank lines, `#` comment lines and further `...` lines are not content;
    anything else (including a `---` line, which opens a second document)
    ends the single-document lock.
    """
    for j in range(start, len(lines)):
        stripped = lines[j].strip()
        if stripped == "" or stripped.startswith("#") or _is_lock_marker_line(lines[j], "..."):
            continue
        return "%s: content after document end (%s) at line %d" % (lock_label, marker, j + 1)
    return None

def _lock_second_doc_error(lines, marker_idx, lock_label):
    """Returns the error for a second `---` document marker, or None when absent."""
    err = _lock_tail_content_error(lines, marker_idx + 1, lock_label, "---")
    if err:
        return err
    return "%s: second document marker (---) at line %d" % (lock_label, marker_idx + 1)

def _lock_tail_step(tail, line, stripped, i, lines, lock_label):
    """Advances the document-tail check by one line.

    A lock is one YAML document: a `---` before any content stays allowed,
    and so does a final `...`. Any content after a `...` line is an error
    naming its 1-based line, and so is any content after a second `---`.
    Blank lines and `#` comment lines do not count as content. Marker lines
    skip every other text check, so this step reports them through `skip`.

    Args:
      tail: A struct(content, directive, closed) with the check state.
      line: The source line.
      stripped: The line stripped of surrounding whitespace.
      i: The 0-based line index.
      lines: All lock lines, for the forward content scan past a marker.
      lock_label: Label naming the lock file for diagnostics.

    Returns:
      A struct(tail, error, skip) with the new state, the tail error when
      this line ends the check with one, and whether other checks skip it.
    """
    if _is_lock_marker_line(line, "..."):
        if tail.closed:
            return struct(tail = tail, error = None, skip = True)
        return struct(
            tail = struct(content = tail.content, directive = tail.directive, closed = True),
            error = _lock_tail_content_error(lines, i + 1, lock_label, "..."),
            skip = True,
        )
    if _is_lock_marker_line(line, "---"):
        if tail.closed:
            return struct(tail = tail, error = None, skip = True)
        if tail.content:
            return struct(tail = tail, error = _lock_second_doc_error(lines, i, lock_label), skip = True)
        if tail.directive:
            return struct(
                tail = struct(content = True, directive = tail.directive, closed = False),
                error = None,
                skip = True,
            )
        return struct(tail = tail, error = None, skip = True)
    if tail.closed or stripped == "" or stripped.startswith("#"):
        return struct(tail = tail, error = None, skip = False)
    if stripped.startswith("%"):
        return struct(
            tail = struct(content = tail.content, directive = True, closed = False),
            error = None,
            skip = False,
        )
    return struct(
        tail = struct(content = True, directive = tail.directive, closed = False),
        error = None,
        skip = False,
    )

def _lock_tab_line(line, stripped, i, lock_label):
    """Returns the tab-indentation error for one line, or None.

    A tab anywhere in a content line's indentation is an error naming the
    line, as YAML forbids tabs in indentation. A tab after the indentation
    (between `key:` and its value, say) stays allowed, as YAML allows it.

    Args:
      line: The source line.
      stripped: The line stripped of surrounding whitespace.
      i: The 0-based line index.
      lock_label: Label naming the lock file for diagnostics.

    Returns:
      The tab error, or None.
    """
    if stripped == "" or stripped.startswith("#"):
        return None
    leading = line[:len(line) - len(line.lstrip(" \t"))]
    if "\t" in leading:
        return "%s: tab in indentation at line %d" % (lock_label, i + 1)
    return None

def _lock_quoted_tail(value):
    """Returns the text after a quoted scalar's same-line closing quote.

    Returns None when `value` is unquoted or its closing quote is on a later
    line (a multiline scalar the parser folds); the parser reports an
    unclosed scalar itself.
    """
    if len(value) == 0 or (value[0] != '"' and value[0] != "'"):
        return None
    quote = value[0]
    i = 1
    for _ in range(len(value)):
        if i >= len(value):
            return None
        ch = value[i]
        if quote == '"' and ch == "\\":
            i += 2
            continue
        if ch == quote:
            if quote == "'" and i + 1 < len(value) and value[i + 1] == "'":
                i += 2
                continue
            return value[i + 1:]
        i += 1
    return None

def _lock_flow_quoted_end(flow, i, quote):
    """Returns the index just after the quoted scalar opened before `i`, or -1.

    `i` is the index just after the opening quote. A missing closing quote
    returns -1, leaving the value to the parser.
    """
    for _ in range(len(flow) + 1):
        if i >= len(flow):
            return -1
        ch = flow[i]
        if quote == '"' and ch == "\\":
            i += 2
            continue
        if ch == quote:
            if quote == "'" and i + 1 < len(flow) and flow[i + 1] == "'":
                i += 2
                continue
            return i + 1
        i += 1
    return -1

def _lock_flow_follower_ok(flow, i):
    """Returns whether only `,`, `:`, `]` or `}` follows index `i` after spaces."""
    for _ in range(len(flow) + 1):
        if i >= len(flow):
            return True
        if flow[i] not in [" ", "\t"]:
            return flow[i] in [",", ":", "]", "}"]
        i += 1
    return True

def _lock_flow_quote_error(flow):
    """Returns the quote-trailer problem inside a flow value, or None.

    After a quoted scalar's closing quote only `,`, `:`, `]` or `}` may
    follow. Anything else (another scalar directly after the quote) ends up
    folded into the value, so it is an error.
    """
    i = 0
    for _ in range(len(flow) + 1):
        if i >= len(flow):
            return None
        ch = flow[i]
        if ch == '"' or ch == "'":
            end = _lock_flow_quoted_end(flow, i + 1, ch)
            if end < 0:
                return None
            if not _lock_flow_follower_ok(flow, end):
                return "unexpected text after closing quote"
            i = end
            continue
        i += 1
    return None

def _lock_line_quote_error(body):
    """Returns the quote-trailer problem for one comment-free line, or None."""
    text = body
    if text.startswith("- "):
        text = text[2:].strip()
        if text == "":
            return None
    elif text == "-":
        return None
    if text.startswith("? ") or text.startswith(": "):
        return None
    value = text
    c = find_colon(text)
    if c >= 0:
        value = text[c + 1:].strip()
    if value == "":
        return None
    if value[0] in ["[", "{"]:
        return _lock_flow_quote_error(value)
    if value[0] not in ['"', "'"]:
        return None
    tail = _lock_quoted_tail(value)
    if tail == None:
        return None
    if tail.strip() != "":
        return "unexpected text after closing quote"
    return None

def _lock_quote_applies(stripped, body, line):
    """Returns whether the quote-trailer check applies to one line.

    Blank, comment and directive lines never carry a same-line scalar, and
    neither do document marker lines or lines with no comment-free body.

    Args:
      stripped: The line stripped of surrounding whitespace.
      body: The line with its trailing comment stripped and trimmed.
      line: The source line, for the document marker check.

    Returns:
      True when the quote-trailer check reads this line.
    """
    if stripped == "" or stripped.startswith("#") or stripped.startswith("%"):
        return False
    if _is_lock_marker_line(line, "---") or _is_lock_marker_line(line, "..."):
        return False
    return body != ""

def _lock_quote_line(body, i, lock_label):
    """Returns the quoted-scalar trailer error for one line body, or None.

    After the closing quote of a quoted scalar only whitespace and an
    optional `#` comment may follow on that line. Anything else is an error
    naming the line. Quoted scalars closed on a later line are left to the
    parser; non-strict parsing keeps today's behaviour.

    Args:
      body: The comment-free trimmed line body.
      i: The 0-based line index.
      lock_label: Label naming the lock file for diagnostics.

    Returns:
      The quote-trailer error, or None.
    """
    err = _lock_line_quote_error(body)
    if err == None:
        return None
    return "%s: %s at line %d" % (lock_label, err, i + 1)

def _lock_unquote(key):
    """Removes one pair of matching quotes from a mapping key, or returns it."""
    if len(key) >= 2 and key[0] == '"' and key[-1] == '"':
        return key[1:-1]
    if len(key) >= 2 and key[0] == "'" and key[-1] == "'":
        return key[1:-1].replace("''", "'")
    return key

def _lock_entry_step(est, body, line, i):
    """Advances package entry-line tracking by one line. Returns the state.

    Maps each block `packages` entry key to its 1-based line. Keys are
    unquoted to match the parsed mapping. A `packages` that is a flow value
    or is missing leaves the mapping empty; the shape check reports those.

    Args:
      est: A struct(pkg, item, closed, entries) with the tracking state.
      body: The line with its trailing comment stripped and trimmed.
      line: The source line, for indentation and the marker check.
      i: The 0-based line index.

    Returns:
      The updated tracking state.
    """
    if body == "" or body.startswith("#") or body.startswith("%"):
        return est
    if _is_lock_marker_line(line, "---") or _is_lock_marker_line(line, "..."):
        return est
    indent = len(line) - len(line.lstrip(" \t"))
    if est.pkg < 0:
        if body == "packages:":
            return struct(pkg = indent, item = est.item, closed = est.closed, entries = est.entries)
        return est
    if indent <= est.pkg:
        return struct(pkg = est.pkg, item = est.item, closed = True, entries = est.entries)
    if est.closed:
        return est
    item = est.item
    if item < 0:
        item = indent
        est = struct(pkg = est.pkg, item = item, closed = est.closed, entries = est.entries)
    if indent != item:
        return est
    c = find_colon(body)
    if c <= 0:
        return est
    key = _lock_unquote(body[:c].strip())
    if key not in est.entries:
        est.entries[key] = i + 1
    return est

def _lock_text_scan(lines, lock_label):
    """Runs the lock text checks in one shared pass over `lines`.

    A single walk feeds the document-tail, tab-indentation, quote-trailer
    and entry-line checks together. A document-tail error ends the scan at
    once: it outranks every other text error, so no later check is needed.
    Otherwise the first tab error outranks the first quote-trailer error,
    exactly as the separate checks ordered them.

    Args:
      lines: The lock lines from one shared `_lock_text_lines` split.
      lock_label: Label naming the lock file for diagnostics.

    Returns:
      A struct(error, entries) with the first text error, or None with the
      entry-line mapping.
    """
    tail = struct(content = False, directive = False, closed = False)
    est = struct(pkg = -1, item = -1, closed = False, entries = {})
    tab = None
    quote = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        tstep = _lock_tail_step(tail, line, stripped, i, lines, lock_label)
        tail = tstep.tail
        if tstep.error != None:
            return struct(error = tstep.error, entries = {})
        if tstep.skip:
            continue
        if tab == None:
            tab = _lock_tab_line(line, stripped, i, lock_label)
        body = strip_comment(line).strip()
        if quote == None and _lock_quote_applies(stripped, body, line):
            quote = _lock_quote_line(body, i, lock_label)
        est = _lock_entry_step(est, body, line, i)
    if tab != None:
        return struct(error = tab, entries = {})
    if quote != None:
        return struct(error = quote, entries = {})
    return struct(error = None, entries = est.entries)

def _lock_entry_error(name, info, entry_lines, lock_label):
    """Returns the package entry shape error, or None.

    Every entry needs a valid Dart package name and a `source` and a
    `version` that are YAML strings; a missing `source` is an error, never
    only a warning. The `version` must be a semantic version as pub writes
    it. Non-string versions name the entry's line, never the re-spelled
    value.
    """
    if not is_lock_package_name(name):
        return "%s: package %r is not a valid package name" % (lock_label, name)
    key = name if type(name) == "string" else str(name)
    at = ""
    if key in entry_lines:
        at = " at line %d" % entry_lines[key]
    source = info.get("source", None)
    if source == None:
        return "%s: package %r has no 'source'%s" % (lock_label, name, at)
    if type(source) != "string":
        return "%s: package %r has non-string 'source'%s" % (lock_label, name, at)
    version = info.get("version", None)
    if version == None:
        return "%s: package %r has no 'version'%s" % (lock_label, name, at)
    if type(version) != "string":
        return "%s: package %r has non-string 'version'%s" % (lock_label, name, at)
    if not is_lock_version(version):
        return "%s: package %r has invalid version %r%s" % (lock_label, name, version, at)
    return None

def _lock_case_error(packages, lock_label):
    """Returns the case-collision error naming both packages, or None.

    Two names equal ignoring case collide on case-insensitive filesystems,
    where their repositories and paths are the same entry.
    """
    seen = {}
    for name in packages.keys():
        if type(name) != "string":
            continue
        folded = name.lower()
        if folded in seen and seen[folded] != name:
            return "%s: packages %r and %r differ only in case" % (lock_label, seen[folded], name)
        if folded not in seen:
            seen[folded] = name
    return None

def lock_general_packages(content, lock_label = "pubspec.lock"):
    """Parses a lock through the general YAML reader. Returns struct(error, packages).

    Reads the document exactly once and validates the parsed value plus one
    shared scan of the text, reporting the same value or the same error
    message, word for word, as the separate passes did before.

    Args:
      content: String contents of a pubspec.lock file.
      lock_label: Label naming the lock file for diagnostics.

    Returns:
      A struct(error, packages): `error` names the lock and the problem, or
      None with the package mapping.
    """
    data, problems = document_value_and_problems(content, True)
    if problems:
        return struct(error = "%s: %s" % (lock_label, problems[0]), packages = {})
    scan = _lock_text_scan(_lock_text_lines(content), lock_label)
    if scan.error != None:
        return struct(error = scan.error, packages = {})
    err = _lock_shape_error(data, lock_label)
    if err != None:
        return struct(error = err, packages = {})
    for name, info in data["packages"].items():
        err = _lock_entry_shape_error(name, info, lock_label)
        if err != None:
            return struct(error = err, packages = {})
        err = _lock_entry_error(name, info, scan.entries, lock_label)
        if err != None:
            return struct(error = err, packages = {})
    err = _lock_case_error(data["packages"], lock_label)
    if err != None:
        return struct(error = err, packages = {})
    result = {}
    for name, info in data["packages"].items():
        result[name] = _lock_entry(info)
    return struct(error = None, packages = result)

def pubspec_lock_error(content, lock_label = "pubspec.lock"):
    """Returns why a pubspec.lock is unreadable, or None when it is clean.

    Duplicate keys, lines the parser cannot read (other than blank and
    comment lines), content after a `...` line or a second `---` (naming its
    line), tab indentation, and text after a quoted scalar's closing quote
    are all errors. A missing or non-mapping `packages`, package entries
    that are not mappings, invalid package names, names equal ignoring
    case, a missing or non-string `source` (never only a warning), and a
    missing, non-string or non-semantic `version` are errors too.
    `packages: {}` with valid `sdks` stays a valid, empty lock.

    Args:
        content: String contents of a pubspec.lock file.
        lock_label: Label naming the lock file for diagnostics.

    Returns:
        An error string naming the lock and the problem, or None.
    """
    if lock_fast_packages(content).ok:
        return None
    return lock_general_packages(content, lock_label).error

def parse_pubspec_lock(content, lock_label = "pubspec.lock"):
    """Parse a pubspec.lock file into a dict of package info.

    Fails when the lock has duplicate keys, lines the parser cannot read,
    content after a `...` line or a second `---`, tab indentation, text
    after a quoted scalar's closing quote, a missing or non-mapping
    `packages`, a package entry that is not a mapping, an invalid package
    name, case-colliding names, or a missing, non-string or non-semantic
    `source` or `version`, so a lock the parser cannot read never becomes a
    silently empty hub.

    Args:
        content: String contents of a pubspec.lock file.
        lock_label: Label naming the lock file for diagnostics.

    Returns:
        Dict of package_name -> {
            "dependency": str,
            "source": str,
            "version": str,
            "description": dict (keys vary by source type),
        }
    """
    fast = lock_fast_packages(content)
    if fast.ok:
        return fast.packages
    general = lock_general_packages(content, lock_label)
    if general.error != None:
        fail(general.error)
    return general.packages
