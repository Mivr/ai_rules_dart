"""Semantic-version parsing for path-package lock agreement.

A `path:` spoke must check that the package's own `pubspec.yaml` agrees
with the lock entry (overlays and code assets are selected by lock name
and version). The two sides are compared as parsed semantic versions —
`major.minor.patch` with optional `-pre-release` and `+build` — never as
raw strings, so quoting, surrounding whitespace and the YAML scalar type
cannot skew the outcome.

A missing (or empty) `version:` reads as `0.0.0`, exactly how `pub get`
locks it (pub's `Version.none`): unversioned `publish_to: none` monorepo
packages agree with the lock instead of failing every fetch.
"""

visibility(["//flutter/..."])

def pub_version_text(value):
    """The comparison text for a raw `version:` scalar.

    Coerces with `str()` (so quoting and the YAML scalar type do not
    matter), strips surrounding whitespace and one layer of matching
    quotes, and reads `None` as empty. Empty means "no version stated",
    which the caller maps to `0.0.0`.

    Args:
        value: The raw `version:` scalar from the parsed pubspec or lock.

    Returns:
        The stripped version text, or `""` when nothing was stated.
    """
    if value == None:
        return ""
    text = str(value).strip()
    if len(text) >= 2:
        first = text[0]
        last = text[len(text) - 1]
        if first == last and (first == '"' or first == "'"):
            text = text[1:len(text) - 1].strip()
    return text

def _pub_version_is_digits(part):
    """True when `part` is one or more ASCII digits."""
    if part == "":
        return False
    for ch in part.elems():
        if ch not in "0123456789":
            return False
    return True

def _pub_version_is_identifier(part):
    """True when `part` is a valid pre-release/build identifier."""
    if part == "":
        return False
    for ch in part.elems():
        if ch not in "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-":
            return False
    return True

def _pub_version_normalize_identifier(part):
    """The identifier without insignificant leading zeros.

    All-digit identifiers compare numerically (`01` is `1`); other
    identifiers compare literally and keep their spelling.
    """
    if _pub_version_is_digits(part):
        return str(int(part))
    return part

def _pub_version_normalize_dotted(text):
    """The dotted identifiers normalized, or `None` when malformed.

    Splits `text` on `.`, refusing empty segments and bad characters, and
    normalizes each identifier numerically where it applies.
    """
    normalized = []
    for part in text.split("."):
        if not _pub_version_is_identifier(part):
            return None
        normalized.append(_pub_version_normalize_identifier(part))
    return ".".join(normalized)

def parse_pub_version(value):
    """Parse a raw `version:` scalar into a comparable semantic version.

    Accepts `major.minor.patch` of all-digit parts (compared numerically,
    so leading zeros do not matter) with optional `-pre-release` and
    `+build` dotted identifiers. Empty text reads as `0.0.0`: a pubspec
    with no `version:` field locks as `0.0.0` under `pub get`.

    Args:
        value: The raw `version:` scalar from the pubspec or the lock.

    Returns:
        A `struct(ok, canonical, text)`: `ok` is False for anything that
        is not a semantic version; `canonical` is the normalized
        `M.m.p[-pre][+build]` form (equal versions share it); `text` is
        the stripped input, for refusal messages.
    """
    text = pub_version_text(value)
    if text == "":
        return struct(ok = True, canonical = "0.0.0", text = text)
    rest = text
    had_build = "+" in rest
    build = ""
    if had_build:
        pieces = rest.split("+")
        if len(pieces) != 2:
            return struct(ok = False, canonical = "", text = text)
        rest = pieces[0]
        build = pieces[1]
    had_pre = "-" in rest
    pre = ""
    if had_pre:
        pieces = rest.split("-")
        rest = pieces[0]
        pre = "-".join(pieces[1:])
    core = rest.split(".")
    if len(core) != 3:
        return struct(ok = False, canonical = "", text = text)
    numbers = []
    for part in core:
        if not _pub_version_is_digits(part):
            return struct(ok = False, canonical = "", text = text)
        numbers.append(str(int(part)))
    canonical = ".".join(numbers)
    if had_pre:
        pre = _pub_version_normalize_dotted(pre)
        if pre == None:
            return struct(ok = False, canonical = "", text = text)
        canonical += "-" + pre
    if had_build:
        build = _pub_version_normalize_dotted(build)
        if build == None:
            return struct(ok = False, canonical = "", text = text)
        canonical += "+" + build
    return struct(ok = True, canonical = canonical, text = text)
