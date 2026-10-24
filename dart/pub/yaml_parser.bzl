"""Pubspec-shape extractors for pubspec.lock and pubspec.yaml files.

Generic YAML parsing is done by `//dart/pub/private:yaml_subset.bzl`; this
module just projects the parsed value down to the exact shapes the rules_dart
pub extension and repository rules consume.
"""

load("//dart/pub/private:yaml_subset.bzl", "document_problems", "document_value_and_problems", "find_colon", "parse_document", "strip_comment")

def _pubspec_parse(content, pubspec_label):
    """Parses a pubspec into (mapping, error) without failing."""
    data, problems = document_value_and_problems(content, True)
    if problems:
        package = pubspec_label
        if type(data) == "dict" and "name" in data and data["name"] != None:
            package = str(data["name"])
        return None, "%s in %s: %s" % (package, pubspec_label, problems[0])
    if data == None:
        return {}, None
    if type(data) != "dict":
        return None, "%s: expected a mapping at line 1" % pubspec_label
    return data, None

def parse_pubspec_document_error(content, pubspec_label = "pubspec.yaml"):
    """Returns why a pubspec.yaml is unreadable, or None when it is clean.

    Args:
        content: String contents of a pubspec.yaml file.
        pubspec_label: Label naming the pubspec file for diagnostics.

    Returns:
        An error string naming the package, the label and the line, or None.
    """
    _data, err = _pubspec_parse(content, pubspec_label)
    return err

def parse_pubspec_document(content, pubspec_label = "pubspec.yaml"):
    """Parses a pubspec.yaml file into its top-level mapping.

    Fails on any problem or a non-mapping root with a message naming the
    package (its top-level `name:` value, or the label when there is none),
    the label and the line. An empty document returns `{}`.

    Args:
        content: String contents of a pubspec.yaml file.
        pubspec_label: Label naming the pubspec file for diagnostics.

    Returns:
        The document's top-level mapping.
    """
    data, err = _pubspec_parse(content, pubspec_label)
    if err:
        fail(err)
    return data

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

def _lock_syntax_error(content, lock_label):
    """Returns the first strict-parse problem for lock content, or None."""
    problems = document_problems(content, True)
    if not problems:
        return None
    return "%s: %s" % (lock_label, problems[0])

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

# Characters a Dart package name may start with, and contain.
_LOCK_NAME_FIRST = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"
_LOCK_NAME_CHARS = _LOCK_NAME_FIRST + "0123456789"
_LOCK_DIGITS = "0123456789"
_LOCK_IDENT_CHARS = _LOCK_DIGITS + "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-"

def _lock_text_lines(content):
    """Splits lock text into lines with newlines normalized and the BOM stripped."""
    text = content.replace("\r\n", "\n").replace("\r", "\n")
    if text.startswith("\357\273\277"):
        text = text[len("\357\273\277"):]
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

def _lock_doc_tail_error(content, lock_label):
    """Returns the trailing-document error for lock text, or None.

    A lock is one YAML document: a `---` before any content stays allowed,
    and so does a final `...`. Any content after a `...` line is an error
    naming its 1-based line, and so is any content after a second `---`.
    Blank lines and `#` comment lines do not count as content.
    """
    lines = _lock_text_lines(content)
    saw_content = False
    saw_directive = False
    for i, line in enumerate(lines):
        stripped = line.strip()
        if _is_lock_marker_line(line, "..."):
            return _lock_tail_content_error(lines, i + 1, lock_label, "...")
        if _is_lock_marker_line(line, "---"):
            if saw_content:
                return _lock_second_doc_error(lines, i, lock_label)
            if saw_directive:
                saw_content = True
            continue
        if stripped == "" or stripped.startswith("#"):
            continue
        if stripped.startswith("%"):
            saw_directive = True
            continue
        saw_content = True
    return None

def _lock_tab_error(content, lock_label):
    """Returns the tab-indentation error for lock text, or None.

    A tab anywhere in a content line's indentation is an error naming the
    line, as YAML forbids tabs in indentation. A tab after the indentation
    (between `key:` and its value, say) stays allowed, as YAML allows it.
    """
    for i, line in enumerate(_lock_text_lines(content)):
        stripped = line.strip()
        if stripped == "" or stripped.startswith("#"):
            continue
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

def _lock_quote_error(content, lock_label):
    """Returns the quoted-scalar trailer error for lock text, or None.

    After the closing quote of a quoted scalar only whitespace and an
    optional `#` comment may follow on that line. Anything else is an error
    naming the line. Quoted scalars closed on a later line are left to the
    parser; non-strict parsing keeps today's behaviour.
    """
    for i, line in enumerate(_lock_text_lines(content)):
        stripped = line.strip()
        if stripped == "" or stripped.startswith("#") or stripped.startswith("%"):
            continue
        if _is_lock_marker_line(line, "---") or _is_lock_marker_line(line, "..."):
            continue
        body = strip_comment(line).strip()
        if body == "" or _is_lock_marker_line(line, "---") or _is_lock_marker_line(line, "..."):
            continue
        err = _lock_line_quote_error(body)
        if err:
            return "%s: %s at line %d" % (lock_label, err, i + 1)
    return None

def _is_lock_package_name(name):
    """Returns whether `name` is a valid Dart package name.

    Letters, digits and underscores, not starting with a digit.
    """
    if type(name) != "string" or name == "":
        return False
    if name[0] not in _LOCK_NAME_FIRST:
        return False
    for ch in name.elems():
        if ch not in _LOCK_NAME_CHARS:
            return False
    return True

def _lock_unquote(key):
    """Removes one pair of matching quotes from a mapping key, or returns it."""
    if len(key) >= 2 and key[0] == '"' and key[-1] == '"':
        return key[1:-1]
    if len(key) >= 2 and key[0] == "'" and key[-1] == "'":
        return key[1:-1].replace("''", "'")
    return key

def _lock_entry_lines(content):
    """Maps each block `packages` entry key to its 1-based line.

    Keys are unquoted to match the parsed mapping. Returns {} when
    `packages` is a flow value or is missing; the shape check reports those.
    """
    found = {}
    lines = _lock_text_lines(content)
    pkg_indent = -1
    entry_indent = -1
    for i, line in enumerate(lines):
        body = strip_comment(line).strip()
        if body == "" or body.startswith("#") or body.startswith("%"):
            continue
        if _is_lock_marker_line(line, "---") or _is_lock_marker_line(line, "..."):
            continue
        indent = len(line) - len(line.lstrip(" \t"))
        if pkg_indent < 0:
            if body == "packages:":
                pkg_indent = indent
            continue
        if indent <= pkg_indent:
            break
        if entry_indent < 0:
            entry_indent = indent
        if indent != entry_indent:
            continue
        c = find_colon(body)
        if c <= 0:
            continue
        key = _lock_unquote(body[:c].strip())
        if key not in found:
            found[key] = i + 1
    return found

def _is_lock_digits(part):
    """Returns whether `part` is a non-empty run of ASCII digits."""
    if part == "":
        return False
    for ch in part.elems():
        if ch not in _LOCK_DIGITS:
            return False
    return True

def _is_lock_version_number(part):
    """Returns whether `part` is a numeric core part: digits, no leading zeros."""
    return _is_lock_digits(part) and (len(part) == 1 or part[0] != "0")

def _is_lock_version_ident(seg, prerelease):
    """Returns whether `seg` is a prerelease or build identifier.

    Non-empty runs of letters, digits and hyphens; a numeric prerelease
    identifier keeps no leading zeros.
    """
    if seg == "":
        return False
    for ch in seg.elems():
        if ch not in _LOCK_IDENT_CHARS:
            return False
    if prerelease and _is_lock_digits(seg) and len(seg) > 1 and seg[0] == "0":
        return False
    return True

def _is_lock_version(version):
    """Returns whether `version` is a semantic version as pub writes it.

    MAJOR.MINOR.PATCH with numeric parts without leading zeros, plus
    optional `-prerelease` and `+build` dot-separated identifiers. Anything
    else (a float such as `1.10`, an int such as `3`, folded continuation
    text) is not a version pub writes. Non-strings are never versions: the
    caller reports those without showing the re-spelled value.
    """
    if type(version) != "string":
        return False
    core, plus, build = version.partition("+")
    if plus:
        if build == "":
            return False
        for seg in build.split("."):
            if not _is_lock_version_ident(seg, False):
                return False
    release, dash, pre = core.partition("-")
    parts = release.split(".")
    if len(parts) != 3:
        return False
    for part in parts:
        if not _is_lock_version_number(part):
            return False
    if dash:
        if pre == "":
            return False
        for seg in pre.split("."):
            if not _is_lock_version_ident(seg, True):
                return False
    return True

def _lock_entry_error(name, info, entry_lines, lock_label):
    """Returns the package entry shape error, or None.

    Every entry needs a valid Dart package name and a `source` and a
    `version` that are YAML strings; a missing `source` is an error, never
    only a warning. The `version` must be a semantic version as pub writes
    it. Non-string versions name the entry's line, never the re-spelled
    value.
    """
    if not _is_lock_package_name(name):
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
    if not _is_lock_version(version):
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
    err = _lock_syntax_error(content, lock_label)
    if err:
        return err
    err = _lock_doc_tail_error(content, lock_label)
    if err:
        return err
    err = _lock_tab_error(content, lock_label)
    if err:
        return err
    err = _lock_quote_error(content, lock_label)
    if err:
        return err
    data = parse_document(content)
    err = _lock_shape_error(data, lock_label)
    if err:
        return err
    entry_lines = _lock_entry_lines(content)
    for name, info in data["packages"].items():
        err = _lock_entry_shape_error(name, info, lock_label)
        if err:
            return err
        err = _lock_entry_error(name, info, entry_lines, lock_label)
        if err:
            return err
    return _lock_case_error(data["packages"], lock_label)

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
    err = pubspec_lock_error(content, lock_label)
    if err:
        fail(err)
    packages = parse_document(content)["packages"]

    result = {}
    for name, info in packages.items():
        result[name] = _lock_entry(info)
    return result

_HEX_LOWER = {
    "0": True,
    "1": True,
    "2": True,
    "3": True,
    "4": True,
    "5": True,
    "6": True,
    "7": True,
    "8": True,
    "9": True,
    "a": True,
    "b": True,
    "c": True,
    "d": True,
    "e": True,
    "f": True,
}

def is_valid_sha256(sha256):
    """Returns True when `sha256` is 64 lowercase hex digits after trimming.

    Args:
        sha256: Candidate SHA-256 string.

    Returns:
        True when `sha256` trims to 64 lowercase hex characters, else False.
    """
    if type(sha256) != "string":
        return False
    trimmed = sha256.strip()
    if len(trimmed) != 64:
        return False
    for ch in trimmed.elems():
        if ch not in _HEX_LOWER:
            return False
    return True

def is_valid_git_ref(ref):
    """Returns True when `ref` is a full 40-hex lowercase commit SHA.

    Args:
        ref: Candidate resolved-ref string.

    Returns:
        True when `ref` trims to 40 lowercase hex characters, else False.
    """
    if type(ref) != "string":
        return False
    trimmed = ref.strip()
    if len(trimmed) != 40:
        return False
    for ch in trimmed.elems():
        if ch not in _HEX_LOWER:
            return False
    return True

# Backwards/alternative names for callers and tests.
is_valid_resolved_ref = is_valid_git_ref
is_valid_commit_sha = is_valid_git_ref

def lock_package_error(name, info, lock_file):
    """Validates that a parsed `pubspec.lock` package entry is pinned.

    Hosted packages must carry a 64-lowercase-hex-digit `sha256` after
    trimming, and git packages must carry a non-empty `resolved-ref`.

    Args:
        name: Package name from `pubspec.lock`.
        info: Entry dict from `parse_pubspec_lock`.
        lock_file: Label or string identifying the lock file for diagnostics.

    Returns:
        An error string when the entry is unpinned or malformed, or None when valid.
    """
    source = info.get("source", "unknown")
    version = info.get("version", "")
    desc = info.get("description", {})
    if source == "hosted":
        raw_sha256 = desc.get("sha256", "")
        sha256 = str(raw_sha256).strip() if raw_sha256 != None else ""
        if not sha256:
            return (
                'pub package "%s" %s in %s has no sha256. ' +
                "Run `dart pub get` (Dart 2.19 or newer records one) and commit the lock."
            ) % (name, version, lock_file)
        if not is_valid_sha256(sha256):
            return (
                'pub package "%s" %s in %s has invalid sha256 %r: ' +
                "expected 64 lowercase hex digits."
            ) % (name, version, lock_file, raw_sha256)
    elif source == "git":
        raw_ref = desc.get("resolved-ref", "")
        resolved_ref = str(raw_ref).strip() if raw_ref != None else ""
        if not resolved_ref:
            return (
                'pub package "%s" %s in %s has no resolved-ref. ' +
                "Run `dart pub get` and commit the lock."
            ) % (name, version, lock_file)
        if not is_valid_git_ref(resolved_ref):
            return (
                'pub package "%s" %s in %s has invalid resolved-ref %r: ' +
                "expected 40 lowercase hex digits."
            ) % (name, version, lock_file, raw_ref)
    return None

def parse_pubspec_deps(content):
    """Extract dependency names from a pubspec.yaml file.

    Only extracts package names from the `dependencies:` section.

    Args:
        content: String contents of a pubspec.yaml file.

    Returns:
        List of dependency package names.
    """
    data = parse_pubspec_document(content)
    deps = data.get("dependencies")
    if type(deps) != "dict":
        return []
    return list(deps.keys())

def parse_pubspec_sdk_constraint(content):
    """Extract the `environment.sdk` constraint from a pubspec.yaml file.

    Returns the value of `environment.sdk` as a string. Returns the empty
    string when the constraint is missing.

    Args:
        content: String contents of a pubspec.yaml file.

    Returns:
        The SDK version constraint string, e.g. `^3.5.0` or `>=2.12.0 <4.0.0`.
    """
    data = parse_pubspec_document(content)
    env = data.get("environment")
    if type(env) != "dict":
        return ""
    sdk = env.get("sdk")
    if sdk == None:
        return ""
    return str(sdk)
