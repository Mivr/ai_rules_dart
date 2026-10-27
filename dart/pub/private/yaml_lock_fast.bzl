"""Dedicated reader for the pubspec.lock layout `dart pub get` writes.

`lock_fast_packages` recognises exactly the canonical layout pub writes: a
`packages:` mapping whose entries sit at 2-space indentation with
`dependency`, `description`, `source` and `version` fields at 4 spaces and an
optional `description` mapping at 6 spaces, then an `sdks:` mapping, with
same-line plain or double-quoted scalars throughout. It returns those
packages without running the general YAML reader.

Anything else bails out with `ok = False` so the caller falls back to the
general reader, which reports the exact same value or error as before: blank
or comment lines past the header, single quotes, escape sequences, flow
values, tabs, carriage returns, byte-order marks, document markers,
directives, anchors, aliases, tags, other indentation, quoted or unusual
keys, missing or extra fields, non-string fields, duplicate or
case-clashing names, and invalid versions. The fast path therefore only ever
succeeds on locks the general reader reads identically; it never invents a
value or an error, and no input fails the evaluation.
"""

load("//dart/pub/private:yaml_chars.bzl", "BOM", "first_bad_utf8_line")

# Characters a Dart package name may start with, and contain.
_LOCK_NAME_FIRST = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"
_LOCK_NAME_CHARS = _LOCK_NAME_FIRST + "0123456789"
_LOCK_DIGITS = "0123456789"
_LOCK_IDENT_CHARS = _LOCK_DIGITS + "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-"

# Characters a bare fast-path scalar may start with, and contain. A bare
# scalar starting with anything else (a digit, a sign, a dot, a quote, a
# flow bracket or a special marker) may resolve to a non-string under the
# general reader, so it bails out instead.
_LOCK_BARE_FIRST = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"
_LOCK_BARE_CHARS = _LOCK_BARE_FIRST + "0123456789.+-"

# Plain scalars the general reader resolves to a null or a bool. Anything
# else starting with a letter reads as a string, as do all double-quoted
# scalars without escapes.
_LOCK_NULLS = ["null", "Null", "NULL"]
_LOCK_TRUES = ["true", "True", "TRUE"]
_LOCK_FALSES = ["false", "False", "FALSE"]

# Plain scalars the general reader would resolve to a non-string key. A
# mapping key spelled any of these reads as a bool or a null, never as the
# string the fast path would record, so lines using them bail out.
_LOCK_NON_STRING_WORDS = _LOCK_NULLS + _LOCK_TRUES + _LOCK_FALSES

def is_lock_package_name(name):
    """Returns whether `name` is a valid Dart package name.

    Letters, digits and underscores, not starting with a digit. Non-strings
    are never names: the general reader keeps them typed, so the fast path
    bails out on them instead.

    Args:
      name: The candidate package name.

    Returns:
      True when `name` is a valid Dart package name.
    """
    if type(name) != "string" or name == "":
        return False
    if name[0] not in _LOCK_NAME_FIRST:
        return False
    for ch in name.elems():
        if ch not in _LOCK_NAME_CHARS:
            return False
    return True

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

    Args:
      seg: The candidate identifier.
      prerelease: Whether it sits in the prerelease part.

    Returns:
      True when `seg` is a valid identifier.
    """
    if seg == "":
        return False
    for ch in seg.elems():
        if ch not in _LOCK_IDENT_CHARS:
            return False
    if prerelease and _is_lock_digits(seg) and len(seg) > 1 and seg[0] == "0":
        return False
    return True

def is_lock_version(version):
    """Returns whether `version` is a semantic version as pub writes it.

    MAJOR.MINOR.PATCH with numeric parts without leading zeros, plus
    optional `-prerelease` and `+build` dot-separated identifiers. Anything
    else (a float such as `1.10`, an int such as `3`, folded continuation
    text) is not a version pub writes. Non-strings are never versions: the
    caller reports those without showing the re-spelled value.

    Args:
      version: The candidate version string.

    Returns:
      True when `version` is a semantic version as pub writes it.
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

def _lock_fast_word(key):
    """Returns whether `key` is a plain word the general reader keeps a string.

    A leading letter or underscore followed by letters, digits, underscores,
    dots, pluses and hyphens always reads as a string key; anything else
    (literals resolving to bools or nulls, digits, quotes, flow or marker
    characters) may not, so it bails out instead.

    Args:
      key: The candidate key text.

    Returns:
      True when `key` is a plain word reading as a string.
    """
    if key == "" or key[0] not in _LOCK_BARE_FIRST:
        return False
    for ch in key.elems():
        if ch not in _LOCK_BARE_CHARS:
            return False
    return key not in _LOCK_NON_STRING_WORDS

def _lock_fast_scalar(text):
    """Reads one same-line lock scalar. Returns struct(kind, value), or None.

    `kind` is `"text"` for a YAML string (with its string value), `"null"`
    for a YAML null, or `"bool"` (with `"True"` or `"False"`, as the general
    reader spells them). Anything that may read otherwise — single quotes,
    escape sequences, flow or special markers, numbers, an unclosed quote,
    or text after the closing quote — bails out with None so the general
    reader reports it.

    Args:
      text: The scalar text after `key:`, with surrounding spaces stripped.

    Returns:
      A struct with the scalar kind and its string value, or None to bail.
    """
    if text == "":
        return None
    if text[0] == '"':
        if "\\" in text:
            return None
        end = text.find('"', 1)
        if end < 0:
            return None
        if text[end + 1:].strip() != "":
            return None
        return struct(kind = "text", value = text[1:end])
    if text[0] not in _LOCK_BARE_FIRST:
        return None
    for ch in text.elems():
        if ch not in _LOCK_BARE_CHARS:
            return None
    if text in _LOCK_NULLS:
        return struct(kind = "null", value = "")
    if text in _LOCK_TRUES:
        return struct(kind = "bool", value = "True")
    if text in _LOCK_FALSES:
        return struct(kind = "bool", value = "False")
    return struct(kind = "text", value = text)

def _lock_fast_split(line, indent):
    """Splits an indented `key: scalar` line. Returns struct(key, text), or None.

    The key must be a plain word; the character after the first colon must
    be a space or the end of the line. Anything else bails out with None.

    Args:
      line: The source line, carrying exactly `indent` leading spaces.
      indent: The expected leading-space count.

    Returns:
      A struct with the key and the stripped value text, or None to bail.
    """
    rest = line[indent:]
    c = rest.find(":")
    if c <= 0:
        return None
    key = rest[:c]
    if not _lock_fast_word(key):
        return None
    after = rest[c + 1:]
    if after != "" and after[0] != " ":
        return None
    return struct(key = key, text = after.strip())

def _lock_fast_state(st, phase, entry, desc, sdks, saw_sdks):
    """Builds the fast-path state for `phase`, keeping the collected maps.

    Args:
      st: The fast-path state whose packages and folded names carry over.
      phase: The next reader phase.
      entry: The open package entry, or None.
      desc: The open description block, or None.
      sdks: The recorded `sdks:` names.
      saw_sdks: Whether the `sdks:` mapping has been seen.

    Returns:
      The next fast-path state.
    """
    return struct(
        phase = phase,
        packages = st.packages,
        folded = st.folded,
        entry = entry,
        desc = desc,
        sdks = sdks,
        saw_sdks = saw_sdks,
    )

def _lock_fast_close_desc(st):
    """Closes an open description block. Returns the updated state.

    An empty block reads as `{"name": ""}`, exactly as a null description
    normalises.

    Args:
      st: The fast-path state.

    Returns:
      The state with the description block folded into its entry.
    """
    if st.desc == None:
        return st
    desc = st.desc if len(st.desc) > 0 else {"name": ""}
    st.entry.fields["description"] = desc
    return _lock_fast_state(st, "pkgs", st.entry, None, st.sdks, st.saw_sdks)

def _lock_fast_close_entry(st):
    """Closes an open package entry. Returns the updated state, or None.

    Every entry needs all four fields, a valid package name and a semantic
    version; anything else bails out with None so the general reader reports
    the exact error.

    Args:
      st: The fast-path state.

    Returns:
      The state with the entry recorded, or None to bail.
    """
    st = _lock_fast_close_desc(st)
    entry = st.entry
    if entry == None:
        return _lock_fast_state(st, "pkgs", None, None, st.sdks, st.saw_sdks)
    fields = entry.fields
    if len(fields) != 4:
        return None
    if "dependency" not in fields or "description" not in fields:
        return None
    if "source" not in fields or "version" not in fields:
        return None
    if not is_lock_version(fields["version"]):
        return None
    st.packages[entry.name] = fields
    return _lock_fast_state(st, "pkgs", None, None, st.sdks, st.saw_sdks)

def _lock_fast_head(st, line):
    """Opens the `packages:` mapping. Returns the updated state, or None.

    Args:
      st: The fast-path state.
      line: The first content line of the file.

    Returns:
      The state in the packages phase, or None to bail.
    """
    if line.startswith("packages:") and line[len("packages:"):].strip() == "":
        return _lock_fast_state(st, "pkgs", None, None, st.sdks, st.saw_sdks)
    return None

def _lock_fast_package(st, line):
    """Opens one package entry. Returns the updated state, or None.

    Duplicate and case-clashing names bail out so the general reader reports
    them exactly.

    Args:
      st: The fast-path state.
      line: A 2-space-indented `name:` line.

    Returns:
      The state with the entry open, or None to bail.
    """
    st = _lock_fast_close_entry(st)
    if st == None or st.phase != "pkgs":
        return None
    split = _lock_fast_split(line, 2)
    if split == None or split.text != "":
        return None
    if not is_lock_package_name(split.key):
        return None
    folded = split.key.lower()
    if split.key in st.packages:
        return None
    if folded in st.folded and st.folded[folded] != split.key:
        return None
    st.folded[folded] = split.key
    entry = struct(name = split.key, fields = {})
    return _lock_fast_state(st, "pkgs", entry, None, st.sdks, st.saw_sdks)

def _lock_fast_field(st, line):
    """Records one entry field. Returns the updated state, or None.

    `description:` with no value opens the description block; with a value
    it normalises to `{"name": value}`. Only strings read for the other
    fields; anything else bails out.

    Args:
      st: The fast-path state.
      line: A 4-space-indented `key: scalar` line.

    Returns:
      The state with the field recorded, or None to bail.
    """
    if st.entry == None:
        return None
    st = _lock_fast_close_desc(st)
    split = _lock_fast_split(line, 4)
    if split == None:
        return None
    if split.key in st.entry.fields:
        return None
    if split.key == "description":
        if split.text == "":
            return _lock_fast_state(st, "desc", st.entry, {}, st.sdks, st.saw_sdks)
        scalar = _lock_fast_scalar(split.text)
        if scalar == None:
            return None
        st.entry.fields["description"] = {"name": scalar.value}
        return st
    if split.key != "dependency" and split.key != "source" and split.key != "version":
        return None
    scalar = _lock_fast_scalar(split.text)
    if scalar == None or scalar.kind != "text":
        return None
    st.entry.fields[split.key] = scalar.value
    return st

def _lock_fast_desc_child(st, line):
    """Records one description entry. Returns the updated state, or None.

    Args:
      st: The fast-path state.
      line: A 6-space-indented `key: scalar` line.

    Returns:
      The state with the description entry recorded, or None to bail.
    """
    if st.desc == None:
        return None
    split = _lock_fast_split(line, 6)
    if split == None:
        return None
    if split.key in st.desc:
        return None
    if split.text == "":
        st.desc[split.key] = ""
        return st
    scalar = _lock_fast_scalar(split.text)
    if scalar == None:
        return None
    st.desc[split.key] = scalar.value
    return st

def _lock_fast_top(st, line):
    """Opens the `sdks:` mapping. Returns the updated state, or None.

    Args:
      st: The fast-path state.
      line: A column-0 line.

    Returns:
      The state in the sdks phase, or None to bail.
    """
    st = _lock_fast_close_entry(st)
    if st == None or st.phase != "pkgs" or st.saw_sdks:
        return None
    if line.startswith("sdks:") and line[len("sdks:"):].strip() == "":
        return _lock_fast_state(st, "sdks", None, None, st.sdks, True)
    return None

def _lock_fast_sdks_child(st, line):
    """Records one `sdks:` entry. Returns the updated state, or None.

    Sdks values never reach the lock result, so only their shape is
    recognised; anything else bails out.

    Args:
      st: The fast-path state.
      line: A 2-space-indented `key: scalar` line.

    Returns:
      The state with the entry noted, or None to bail.
    """
    split = _lock_fast_split(line, 2)
    if split == None or split.text == "":
        return None
    if split.key in st.sdks:
        return None
    if _lock_fast_scalar(split.text) == None:
        return None
    st.sdks[split.key] = True
    return st

def _lock_fast_step(st, line):
    """Advances the fast-path reader by one line. Returns state, or None.

    Blank and comment lines only stand before `packages:` and after the
    `sdks:` block; anywhere else they bail out. Every line carries exactly
    the indentation its position needs.

    Args:
      st: The fast-path state.
      line: The source line.

    Returns:
      The updated state, or None to bail to the general reader.
    """
    stripped = line.strip()
    if stripped == "" or stripped.startswith("#"):
        if st.phase == "head":
            return st
        if st.phase == "sdks" or st.phase == "tail":
            return _lock_fast_state(st, "tail", st.entry, st.desc, st.sdks, st.saw_sdks)
        return None
    if st.phase == "head":
        return _lock_fast_head(st, line)
    if st.phase == "tail":
        return None
    indent = len(line) - len(line.lstrip(" "))
    if indent == 0:
        return _lock_fast_top(st, line)
    if st.phase == "sdks":
        if indent != 2:
            return None
        return _lock_fast_sdks_child(st, line)
    if indent == 2:
        return _lock_fast_package(st, line)
    if indent == 4:
        if st.phase != "pkgs" and st.phase != "desc":
            return None
        return _lock_fast_field(st, line)
    if indent == 6 and st.phase == "desc":
        return _lock_fast_desc_child(st, line)
    return None

def _lock_fast_finish(st):
    """Finishes the fast-path reader. Returns struct(ok, packages).

    Args:
      st: The fast-path state after the last line.

    Returns:
      `ok` with the packages when the whole file was canonical, else a
      bail-out asking for the general reader.
    """
    if st.entry != None or st.desc != None:
        return struct(ok = False, packages = {})
    if st.phase != "sdks" and st.phase != "tail":
        return struct(ok = False, packages = {})
    if len(st.packages) == 0:
        return struct(ok = False, packages = {})
    return struct(ok = True, packages = st.packages)

def lock_fast_packages(content):
    """Reads canonical pubspec.lock packages without the general YAML reader.

    Recognises exactly the layout `dart pub get` writes and returns its
    packages; anything else bails out with `ok = False` so the caller falls
    back to the general reader. A bail-out never means the lock is invalid,
    only that it is not canonical. Carriage returns, tabs, byte-order marks
    and undecodable bytes always bail out, as does any text the scalar
    reader cannot prove the general reader reads identically.

    Args:
      content: String contents of a pubspec.lock file.

    Returns:
      A struct(ok, packages): the packages when the file is canonical, else
      `ok = False` with an empty mapping.
    """
    if "\r" in content or "\t" in content or BOM in content:
        return struct(ok = False, packages = {})
    if first_bad_utf8_line(content) > 0:
        return struct(ok = False, packages = {})
    st = struct(phase = "head", packages = {}, folded = {}, entry = None, desc = None, sdks = {}, saw_sdks = False)
    for line in content.split("\n"):
        st = _lock_fast_step(st, line)
        if st == None:
            return struct(ok = False, packages = {})
    return _lock_fast_finish(st)
