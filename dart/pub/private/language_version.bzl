"""Derive a Dart language version from an `environment.sdk` constraint string.

Replicates `pub`'s `LanguageVersion.fromSdkConstraint` from
`dart-lang/pub/lib/src/language_version.dart`. The output is the value pub
writes into the `languageVersion` field of each `package_config.json` entry —
`<major>.<minor>` form, defaulting to `"2.7"` when the constraint is missing
or has no lower bound.

The algorithm mirrors pub's source (`VersionConstraint.parse` intersected
with `LanguageVersion.fromSdkConstraint`):

  - Empty / `null` constraint → DEFAULT (`"2.7"`).
  - Caret (`^X.Y.Z`) → the version's canonical `"X.Y"`.
  - Terms (`>=X.Y.Z <A.B.C`, `>=X.Y.Z`, `>X.Y.Z`, bare versions, ...)
    intersect the way pub combines them: the tightest (highest) min and
    the tightest (lowest) max win, conjoining inclusivity on ties. A
    single remaining version gives its `<major>.<minor>`; an empty
    intersection gives DEFAULT.
  - A lone min gives its `<major>.<minor>`; a lone max gives DEFAULT.
  - Union (`alt1 || alt2`) → derive on each alternative; take the result
    corresponding to the smallest min (or DEFAULT if any alternative has no
    lower bound and that one sorts first). Pub sorts internally; users
    typically write unions in ascending order.

Versions compare the way pub_semver orders them (numeric components,
then pre-release with numbers before strings, then build), so an empty
range of any bound kind derives DEFAULT. Components read as ints, so
leading zeroes derive canonically (`02.12.0` → `"2.12"`).

The DEFAULT (`"2.7"`) is intentionally fixed at the version pub adopted
language versioning at. It is **not** the running SDK's language version. See
the `defaultLanguageVersion` const in pub's source.
"""

load(":yaml_sdk_constraint.bzl", "normalize_sdk_blanks", "sdk_parse_version")

DEFAULT_LANGUAGE_VERSION = "2.7"

def derive_language_version(sdk_constraint):
    """Compute the language version string implied by an `environment.sdk` constraint.

    Args:
        sdk_constraint: Verbatim string from `pubspec.yaml`'s `environment.sdk`
            field, or empty / `None` if the constraint is missing.

    Returns:
        A `<major>.<minor>` language version string.
    """
    if not sdk_constraint:
        return DEFAULT_LANGUAGE_VERSION
    s = normalize_sdk_blanks(sdk_constraint).strip()
    if not s or s == "any" or s == "*":
        return DEFAULT_LANGUAGE_VERSION

    # VersionUnion: pick the alternative with the smallest min. If that
    # alternative lacks a lower bound, fall back to DEFAULT (matches pub:
    # ranges.first.min is null → return defaultLanguageVersion).
    if "||" in s:
        scored = [(_min_sort_key(alt.strip()), alt.strip()) for alt in s.split("||")]
        scored = sorted(scored, key = lambda t: t[0])
        first_key, first_alt = scored[0]

        # Sentinel for "no lower bound" → pub returns DEFAULT.
        if first_key == _MIN_KEY_NONE:
            return DEFAULT_LANGUAGE_VERSION
        return _derive_single(first_alt)

    return _derive_single(s)

def _derive_single(s):
    """Derive language version from a single (non-union) constraint string.

    Intersects the terms the way `VersionConstraint.parse` does and reads
    the result the way `LanguageVersion.fromSdkConstraint` does: a single
    remaining version gives its canonical `<major>.<minor>`, a range with
    a min gives its min's, and an empty intersection gives DEFAULT.

    Args:
        s: A blank-normalized, stripped single constraint string.

    Returns:
        A canonical `<major>.<minor>` language version string.
    """
    if not s or s == "any" or s == "*":
        return DEFAULT_LANGUAGE_VERSION

    # Caret: ^X.Y.Z[+meta][-prerelease].
    if s.startswith("^"):
        return _derive_caret(s[1:])

    terms = _parse_intersection(s)
    if terms == None:
        return DEFAULT_LANGUAGE_VERSION
    if terms.min_version != None and terms.max_version != None:
        order = _compare_versions(terms.min_version, terms.max_version)
        if order > 0:
            return DEFAULT_LANGUAGE_VERSION
        if order == 0 and not (terms.min_inc and terms.max_inc):
            return DEFAULT_LANGUAGE_VERSION
    if terms.min_version != None:
        return _format_version(terms.min_version)
    return DEFAULT_LANGUAGE_VERSION

def _derive_caret(rest):
    """Derive the language version of the version past a `^`.

    Args:
        rest: The constraint text past the `^`.

    Returns:
        The version's canonical `<major>.<minor>`, or DEFAULT when no
        version pub reads opens there.
    """
    n = len(rest)
    pos = _skip_blanks(rest, 0, n)
    v = sdk_parse_version(rest, pos)
    if v == None or v.end != n:
        return DEFAULT_LANGUAGE_VERSION
    return _format_version(v)

def _parse_intersection(s):
    """Intersect the terms of `s` the way `VersionConstraint.parse` does.

    Each term is a `>`, `>=`, `<` or `<=` comparison or a bare version; a
    bare version bounds both ends inclusively. Keeps the tightest
    (highest) min and the tightest (lowest) max, conjoining inclusivity
    on ties.

    Args:
        s: A blank-normalized, stripped single constraint without `^`.

    Returns:
        A struct with `min_version`, `min_inc`, `max_version`, `max_inc`
        (versions are `sdk_parse_version` structs, None when unbounded),
        or None when a term is not a comparison or version pub reads.
    """
    n = len(s)
    pos = 0
    low = struct(v = None, inc = False)
    high = struct(v = None, inc = False)
    terms = 0
    for _ in range(n + 1):
        pos = _skip_blanks(s, pos, n)
        if pos >= n:
            break
        if s[pos] == "<" or s[pos] == ">":
            want_low = s[pos] == ">"
            pos += 1
            inc = False
            if pos < n and s[pos] == "=":
                inc = True
                pos += 1
            pos = _skip_blanks(s, pos, n)
            v = sdk_parse_version(s, pos)
            if v == None:
                return None
            pos = v.end
            if want_low:
                low = _tighter_bound(low, struct(v = v, inc = inc), True)
            else:
                high = _tighter_bound(high, struct(v = v, inc = inc), False)
        else:
            v = sdk_parse_version(s, pos)
            if v == None:
                return None
            pos = v.end
            low = _tighter_bound(low, struct(v = v, inc = True), True)
            high = _tighter_bound(high, struct(v = v, inc = True), False)
        terms += 1
    if terms == 0:
        return None
    return struct(
        min_version = low.v,
        min_inc = low.inc,
        max_version = high.v,
        max_inc = high.inc,
    )

def _tighter_bound(bound, cand, want_higher):
    """Intersect one end: keep the tighter of two bounds on the same side.

    Args:
        bound: The running `struct(v, inc)` bound (`v` None when open).
        cand: The next term's `struct(v, inc)` bound on the same side.
        want_higher: Keep the higher version for a min, the lower for a max.

    Returns:
        The tighter `struct(v, inc)`, conjoining inclusivity on ties.
    """
    if bound.v == None:
        return cand
    order = _compare_versions(cand.v, bound.v)
    if (want_higher and order > 0) or (not want_higher and order < 0):
        return cand
    if order == 0 and not cand.inc:
        return struct(v = bound.v, inc = False)
    return bound

# Blanks that survive blank-normalization: the YAML layer carries the ASCII
# six through, while every multibyte blank reads as an ASCII space already.
_SKIP_BLANKS = " \t\n\v\f\r"

def _skip_blanks(s, pos, n):
    """Returns the index past the blanks opening at `pos`, as pub skips them.

    The caller blank-normalizes first, so every blank pub skips reads as
    one of the ASCII six here.

    Args:
        s: The constraint text.
        pos: Index the blanks open at.
        n: Length of the constraint text.

    Returns:
        The index past the blanks.
    """
    for _ in range(n):
        if pos < n and s[pos] in _SKIP_BLANKS:
            pos += 1
        else:
            break
    return pos

def _format_version(v):
    """Returns the canonical `<major>.<minor>` of a parsed version.

    Args:
        v: An `sdk_parse_version` struct.

    Returns:
        The `<major>.<minor>` language version string.
    """
    return "%d.%d" % (v.major, v.minor)

def _compare_versions(a, b):
    """Orders two parsed versions the way `Version.compareTo` does.

    Major, minor then patch numerically; a missing pre-release sorts past
    any present one while a missing build sorts before any present one;
    identifier lists compare numerically when both sides read as int64,
    with numbers before strings.

    Args:
        a: First `sdk_parse_version` struct.
        b: Second `sdk_parse_version` struct.

    Returns:
        -1, 0 or 1.
    """
    for field in ["major", "minor", "patch"]:
        diff = getattr(a, field) - getattr(b, field)
        if diff < 0:
            return -1
        if diff > 0:
            return 1
    order = _compare_identifiers(a.pre, b.pre, True)
    if order != 0:
        return order
    return _compare_identifiers(a.build, b.build, False)

def _compare_identifiers(text_a, text_b, missing_sorts_high):
    """Compares dot-separated pre-release or build identifier lists.

    A missing identifier comes before a present one; numeric identifiers
    compare numerically and come before alphanumeric ones, which compare
    lexically.

    Args:
        text_a: First raw identifier text (`""` when absent).
        text_b: Second raw identifier text (`""` when absent).
        missing_sorts_high: Whether a missing list sorts past a present
            one (pre-releases) rather than before it (builds).

    Returns:
        -1, 0 or 1.
    """
    if text_a == "" and text_b == "":
        return 0
    if text_a == "":
        return 1 if missing_sorts_high else -1
    if text_b == "":
        return -1 if missing_sorts_high else 1
    parts_a = text_a.split(".")
    parts_b = text_b.split(".")
    count = len(parts_a)
    if len(parts_b) > count:
        count = len(parts_b)
    for i in range(count):
        if i >= len(parts_a):
            return -1
        if i >= len(parts_b):
            return 1
        order = _compare_identifier_part(parts_a[i], parts_b[i])
        if order != 0:
            return order
    return 0

def _compare_identifier_part(part_a, part_b):
    """Compares two single pre-release or build identifiers.

    Numeric identifiers compare numerically and come before alphanumeric
    ones, which compare lexically.

    Args:
        part_a: First identifier.
        part_b: Second identifier.

    Returns:
        -1, 0 or 1.
    """
    if part_a == part_b:
        return 0
    num_a = _identifier_number(part_a)
    num_b = _identifier_number(part_b)
    if num_a != None and num_b != None:
        if num_a == num_b:
            return 0
        return -1 if num_a < num_b else 1
    if num_a != None:
        return -1
    if num_b != None:
        return 1
    return -1 if part_a < part_b else 1

# Largest identifier pub reads numerically: Dart ints are signed 64-bit,
# so a longer run stays alphanumeric there, as `int.tryParse` misses it.
_INT64_MAX_TEXT = "9223372036854775807"

_IDENT_DIGITS = "0123456789"

def _identifier_number(part):
    """Returns the int64 value of an all-digit identifier, or None.

    Mirrors `int.tryParse` there: digit runs past the int64 range stay
    alphanumeric, as does anything with another character.

    Args:
        part: One dot-separated identifier.

    Returns:
        Its int value, or None when it is not an int64-fitting digit run.
    """
    if part == "":
        return None
    for ch in part.elems():
        if ch not in _IDENT_DIGITS:
            return None
    start = 0
    for _ in range(len(part)):
        if start < len(part) and part[start] == "0":
            start += 1
        else:
            break
    if start >= len(part):
        return 0
    digits = part[start:]
    if len(digits) < len(_INT64_MAX_TEXT):
        return int(digits)
    if len(digits) > len(_INT64_MAX_TEXT):
        return None
    if digits <= _INT64_MAX_TEXT:
        return int(digits)
    return None

# Sentinel: when an alternative has no lower bound, sort it before any
# numeric (major, minor) tuple. Tuples are compared element-wise so this
# tuple of three ints sorts strictly less than any (major, minor, _) tuple
# the version-parsing path can produce.
_MIN_KEY_NONE = (-1, -1, -1)

def _min_sort_key(alt):
    """Compute a sort key for a union alternative.

    Returns `_MIN_KEY_NONE` for alternatives with no lower bound (pub treats
    these as sorting first). Otherwise returns a `(major, minor, 0)` tuple
    derived from the alternative's lower-bound version.
    """
    a = alt.strip()
    if not a or a == "any" or a == "*":
        return _MIN_KEY_NONE
    if a.startswith("^"):
        return _version_sort_key(a[1:])
    a_compact = _compact_operators(a)
    tokens = [t for t in a_compact.split(" ") if t]
    lower = None
    for tok in tokens:
        if tok.startswith(">="):
            lower = tok[2:]
        elif tok.startswith(">"):
            lower = tok[1:]
    if lower:
        return _version_sort_key(lower)
    has_upper = False
    for tok in tokens:
        if tok.startswith("<"):
            has_upper = True
            break
    if has_upper:
        return _MIN_KEY_NONE
    return _version_sort_key(a)

def _version_sort_key(version_str):
    """Compute a `(major, minor, 0)` sort key from a version string.

    Returns `_MIN_KEY_NONE` when the version cannot be parsed.
    """
    mm = _major_minor(version_str)
    if mm == DEFAULT_LANGUAGE_VERSION and not _looks_like_default_version(version_str):
        return _MIN_KEY_NONE
    parts = mm.split(".")
    return (int(parts[0]), int(parts[1]), 0)

def _looks_like_default_version(version_str):
    """Distinguish a parse-failure DEFAULT from a literal "2.7"-shaped input."""
    v = version_str.strip()
    if "+" in v:
        v = v[:v.index("+")]
    if "-" in v:
        v = v[:v.index("-")]
    parts = v.split(".")
    return len(parts) >= 2 and parts[0] == "2" and parts[1] == "7"

def _compact_operators(s):
    """Collapse whitespace between comparison operators and their versions.

    Handles `>= 2.12.0` → `>=2.12.0`. pub_semver permits the optional
    whitespace; pubspec authors sometimes use it.
    """
    out = ""
    i = 0
    n = len(s)
    operators = [">=", "<=", ">", "<"]
    for _ in range(n + 1):
        if i >= n:
            break
        matched = False
        for op in operators:
            ol = len(op)
            if s[i:i + ol] == op:
                out += op
                i += ol
                for _ in range(n):
                    if i < n and s[i] == " ":
                        i += 1
                    else:
                        break
                matched = True
                break
        if not matched:
            out += s[i]
            i += 1
    return out

def _major_minor(version_str):
    """Extract `<major>.<minor>` from a version string. Returns DEFAULT on parse failure."""
    v = version_str.strip()
    if "+" in v:
        v = v[:v.index("+")]
    if "-" in v:
        v = v[:v.index("-")]
    parts = v.split(".")
    if len(parts) < 2:
        return DEFAULT_LANGUAGE_VERSION
    major = parts[0]
    minor = parts[1]
    if not major.isdigit() or not minor.isdigit():
        return DEFAULT_LANGUAGE_VERSION
    return major + "." + minor
