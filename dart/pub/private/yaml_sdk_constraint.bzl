"""`environment.sdk` constraint grammar: what `VersionConstraint.parse` reads.

Mirrors package:pub_semver 2.2.0 (`version_constraint.dart`, `patterns.dart`,
`version.dart`): `any` alone reads; otherwise a lone `^` version, or `>`,
`>=`, `<`, `<=` comparisons and bare versions, each a full
`major.minor.patch` of ASCII digits fitting a signed 64-bit int with optional
`-prerelease` and `+build` identifiers. Anything else fails there, so it
fails here.

Blanks are Dart `String.trim` blanks: pub trims the whole constraint, and
again past each operator and between bounds, so every blank reads in each of
those places. A `^` version is refused where `nextBreaking` would overflow
the int64 range, as its increment throws there.
"""

# Single-unit blanks pub skips: ASCII space, tab, newline, vertical tab, form
# feed and carriage return, plus the lone units of U+0085 and U+00A0 (content
# the YAML layer reads carries their two-byte UTF-8 forms below; a lone unit
# reads the same Dart character).
_SDK_ASCII_BLANK_UNITS = " \t\n\v\f\r\205\240"

# Multi-unit blanks pub skips, as the UTF-8 byte sequences the YAML layer
# carries them in: U+0085, U+00A0, U+1680, U+2000-U+200A, U+2028, U+2029,
# U+202F, U+205F, U+3000 and U+FEFF. Written as octal escapes so the source
# stays ASCII. U+200B, U+180E and U+2060 are absent on purpose: Dart does not
# trim them, so pub refuses them everywhere.
_SDK_MULTIBYTE_BLANKS = [
    "\302\205",
    "\302\240",
    "\341\232\200",
    "\342\200\200",
    "\342\200\201",
    "\342\200\202",
    "\342\200\203",
    "\342\200\204",
    "\342\200\205",
    "\342\200\206",
    "\342\200\207",
    "\342\200\210",
    "\342\200\211",
    "\342\200\212",
    "\342\200\250",
    "\342\200\251",
    "\342\200\257",
    "\342\201\237",
    "\343\200\200",
    "\357\273\277",
]

_SDK_DIGITS = "0123456789"

# Characters of a prerelease or build identifier: ASCII letters, digits and
# `-`. Anything else ends the version there, as pub reads it there.
_SDK_IDENT = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-"

# Largest major, minor or patch pub reads: Dart ints are signed 64-bit, so
# a longer run fails its `int.parse`.
_SDK_INT64_MAX = "9223372036854775807"

def _sdk_blank_len_at(s, pos, n):
    """Returns the blank length opening at `pos`, or 0 when none opens there.

    Args:
        s: The constraint text.
        pos: Index the blank opens at.
        n: Length of the constraint text.

    Returns:
        1, 2 or 3 for the blank opening at `pos`, else 0.
    """
    if s[pos] in _SDK_ASCII_BLANK_UNITS:
        return 1
    for blank in _SDK_MULTIBYTE_BLANKS:
        size = len(blank)
        if pos + size <= n and s[pos:pos + size] == blank:
            return size
    return 0

def _sdk_trailing_blank_len(s, start, end, n):
    """Returns the blank length closing at `end`, or 0 when none closes there.

    Args:
        s: The constraint text.
        start: Index the trimmed text opens at.
        end: Index the trimmed text closes at.
        n: Length of the constraint text.

    Returns:
        1, 2 or 3 for the blank closing at `end`, else 0.
    """
    for size in [3, 2, 1]:
        if end - size >= start and _sdk_blank_len_at(s, end - size, n) == size:
            return size
    return 0

def _sdk_trim(s):
    """Trims the blanks pub trims from both ends of `s`."""
    n = len(s)
    start = 0
    for _ in range(n):
        if start >= n:
            break
        size = _sdk_blank_len_at(s, start, n)
        if size == 0:
            break
        start += size
    end = n
    for _ in range(n):
        if end <= start:
            break
        size = _sdk_trailing_blank_len(s, start, end, n)
        if size == 0:
            break
        end -= size
    return s[start:end]

def _sdk_digits_end(s, pos):
    """Returns the index past the digit run opening at `pos` (maybe `pos`)."""
    end = pos
    for _ in range(len(s)):
        if end < len(s) and s[end] in _SDK_DIGITS:
            end += 1
        else:
            break
    return end

def _sdk_uint_ok(s, start, end):
    """Returns whether `s[start:end]` is a version number pub reads.

    One or more ASCII digits fitting a signed 64-bit int. Leading zeroes
    read, as pub keeps `02.12.0`; a longer run fails there.

    Args:
        s: The constraint text.
        start: Index the number opens at.
        end: Index past the digit run.

    Returns:
        Whether the run is a version number pub reads.
    """
    if end <= start:
        return False
    num = s[start:end]
    for _ in range(len(num)):
        if num[0] == "0":
            num = num[1:]
        else:
            break
    if num == "":
        return True
    if len(num) != len(_SDK_INT64_MAX):
        return len(num) < len(_SDK_INT64_MAX)
    return num <= _SDK_INT64_MAX

def _sdk_suffix_end(s, pos):
    """Returns the index past the identifiers opening at `pos`, or -1.

    Identifiers are dot-separated runs of identifier characters, one or
    more per identifier. An empty identifier fails, as pub rejects it
    there, and so does a trailing or doubled dot.

    Args:
        s: The constraint text.
        pos: Index the first identifier opens at.

    Returns:
        The index past the identifiers, or -1 when none reads there.
    """
    end = pos
    for _ in range(len(s) + 1):
        ident = end
        for _ in range(len(s)):
            if end < len(s) and s[end] in _SDK_IDENT:
                end += 1
            else:
                break
        if end == ident:
            return -1
        if end < len(s) and s[end] == ".":
            if end + 1 >= len(s) or s[end + 1] not in _SDK_IDENT:
                return -1
            end += 1
        else:
            return end
    return -1

def _sdk_version_end(s, pos):
    """Returns the index past the version opening at `pos`, or -1.

    A version is `major.minor.patch` of version numbers with an optional
    `-prerelease` and an optional `+build`, each dot-separated
    identifiers. Anything else fails, as pub rejects it there.

    Args:
        s: The constraint text.
        pos: Index the version opens at.

    Returns:
        The index past the version, or -1 when none reads there.
    """
    end = _sdk_digits_end(s, pos)
    if not _sdk_uint_ok(s, pos, end):
        return -1
    if end >= len(s) or s[end] != ".":
        return -1
    minor = end + 1
    end = _sdk_digits_end(s, minor)
    if not _sdk_uint_ok(s, minor, end):
        return -1
    if end >= len(s) or s[end] != ".":
        return -1
    patch = end + 1
    end = _sdk_digits_end(s, patch)
    if not _sdk_uint_ok(s, patch, end):
        return -1
    if end < len(s) and s[end] == "-":
        end = _sdk_suffix_end(s, end + 1)
        if end == -1:
            return -1
    if end < len(s) and s[end] == "+":
        end = _sdk_suffix_end(s, end + 1)
        if end == -1:
            return -1
    return end

def _sdk_skip_blanks(s, pos, n):
    """Returns the index past the blanks opening at `pos`, as pub skips them.

    Args:
        s: The constraint text.
        pos: Index the blanks open at.
        n: Length of the constraint text.

    Returns:
        The index past the blanks.
    """
    for _ in range(n):
        if pos >= n:
            break
        size = _sdk_blank_len_at(s, pos, n)
        if size == 0:
            break
        pos += size
    return pos

def _sdk_operator_end(s, pos, n):
    """Returns the index past the `<` or `>` comparison opening at `pos`.

    Consumes an optional `=` and the blanks pub skips past the operator.

    Args:
        s: The constraint text.
        pos: Index the `<` or `>` opens at.
        n: Length of the constraint text.

    Returns:
        The index past the operator and its blanks.
    """
    pos += 1
    if pos < n and s[pos] == "=":
        pos += 1
    return _sdk_skip_blanks(s, pos, n)

def _sdk_terms_ok(s):
    """Returns whether `s` holds comparisons or versions, as pub reads them.

    Each term is a `>`, `>=`, `<` or `<=` comparison (with optional blanks
    past the operator) or a bare version, glued or blank-separated. A term
    pub cannot read fails the whole constraint there.

    Args:
        s: The trimmed constraint text, not starting with `^`.

    Returns:
        Whether pub reads the terms.
    """
    pos = 0
    n = len(s)
    terms = 0
    for _ in range(n + 1):
        pos = _sdk_skip_blanks(s, pos, n)
        if pos >= n:
            break
        if s[pos] == "<" or s[pos] == ">":
            pos = _sdk_operator_end(s, pos, n)
        end = _sdk_version_end(s, pos)
        if end == -1:
            return False
        pos = end
        terms += 1
    return terms > 0 and pos >= n

def _sdk_num_is_zero(num):
    """Returns whether the digit run `num` reads as zero, as pub reads `00`."""
    for ch in num.elems():
        if ch != "0":
            return False
    return True

def _sdk_num_is_int64_max(num):
    """Returns whether the digit run `num` reads as the int64 maximum."""
    stripped = num.lstrip("0")
    if len(stripped) != len(_SDK_INT64_MAX):
        return False
    return stripped == _SDK_INT64_MAX

def _sdk_caret_overflows(s, pos):
    """Returns whether `^` on the version at `pos` overflows, as pub throws.

    `^V` makes pub compute `V.nextBreaking`, which increments the major (or
    the minor when the major is 0). Past the int64 maximum the increment
    throws, so the constraint fails there. Components pub does not increment
    never overflow: any patch, and any minor once the major is past 0.

    Args:
        s: The constraint text, holding a version at `pos`.
        pos: Index the version opens at.

    Returns:
        Whether the incremented component reads as the int64 maximum.
    """
    major_end = _sdk_digits_end(s, pos)
    major = s[pos:major_end]
    minor_start = major_end + 1
    minor_end = _sdk_digits_end(s, minor_start)
    minor = s[minor_start:minor_end]
    if _sdk_num_is_zero(major):
        return _sdk_num_is_int64_max(minor)
    return _sdk_num_is_int64_max(major)

def is_valid_sdk_constraint(sdk_constraint):
    """Returns whether `sdk_constraint` is a version constraint pub reads.

    Mirrors `VersionConstraint.parse` from package:pub_semver 2.2.0: `any`
    alone reads; otherwise a lone `^` version, or `>`, `>=`, `<`, `<=`
    comparisons and bare versions, each a full `major.minor.patch` of
    ASCII digits fitting a signed 64-bit int with optional `-prerelease`
    and `+build` identifiers. Anything else — a partial version, `*`,
    `=`, `||`, text past a `^` version, a `^` version whose `nextBreaking`
    overflows the int64 range, or an empty string — fails there, so it
    fails here.

    Args:
        sdk_constraint: Candidate constraint string.

    Returns:
        True when pub reads the constraint, else False.
    """
    if type(sdk_constraint) != "string":
        return False
    s = _sdk_trim(sdk_constraint)
    if s == "":
        return False
    if s == "any":
        return True
    if s.startswith("^"):
        rest = s[1:]
        pos = _sdk_skip_blanks(rest, 0, len(rest))
        end = _sdk_version_end(rest, pos)
        if end == -1 or end != len(rest):
            return False
        return not _sdk_caret_overflows(rest, pos)
    return _sdk_terms_ok(s)

def normalize_sdk_blanks(s):
    """Returns `s` with every blank pub skips replaced by an ASCII space.

    Lets the language-version derivation reuse its ASCII-space grammar over
    constraints pub reads: a constraint pub accepts then derives what its
    ASCII-space twin derives.

    Args:
        s: The constraint text.

    Returns:
        The text with each blank replaced by `" "`.
    """
    out = s
    for blank in _SDK_MULTIBYTE_BLANKS:
        out = out.replace(blank, " ")
    # Lone units last: replacing them first would split the two-byte forms.
    for unit in ["\205", "\240"]:
        out = out.replace(unit, " ")
    return out
