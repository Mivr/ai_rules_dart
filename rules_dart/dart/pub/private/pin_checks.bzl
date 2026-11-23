"""Pin checks for pub sources: archive digests, git commits and lock entries.

None of this reads YAML. The checks run on values that are already decoded.
"""

visibility(["//dart/..."])

_HEX_LOWER = "0123456789abcdef"

def _is_lower_hex(text, length):
    """Returns whether `text` trims to `length` lowercase hex digits."""
    if type(text) != "string":
        return False
    trimmed = text.strip()
    if len(trimmed) != length:
        return False
    for ch in trimmed.elems():
        if ch not in _HEX_LOWER:
            return False
    return True

def is_valid_sha256(sha256):
    """Returns True when `sha256` is 64 lowercase hex digits after trimming.

    Args:
        sha256: Candidate SHA-256 string.

    Returns:
        True when `sha256` trims to 64 lowercase hex characters, else False.
    """
    return _is_lower_hex(sha256, 64)

def is_valid_git_ref(ref):
    """Returns True when `ref` is a full 40-hex lowercase commit SHA.

    Args:
        ref: Candidate resolved-ref string.

    Returns:
        True when `ref` trims to 40 lowercase hex characters, else False.
    """
    return _is_lower_hex(ref, 40)

def lock_package_error(name, info, lock_file):
    """Validates that a decoded `pubspec.lock` package entry is pinned.

    Hosted packages must carry a 64-lowercase-hex-digit `sha256` after
    trimming, and git packages must carry a non-empty `resolved-ref`.

    Args:
        name: Package name from `pubspec.lock`.
        info: The entry dict, with string fields and a dict `description`.
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
