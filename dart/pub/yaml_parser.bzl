"""Pubspec-shape extractors for pubspec.lock and pubspec.yaml files.

Generic YAML parsing is done by `//dart/pub/private:yaml_subset.bzl`; this
module just projects the parsed value down to the exact shapes the rules_dart
pub extension and repository rules consume.
"""

load("//dart/pub/private:yaml_subset.bzl", "parse_document")

def _load(content):
    """Parse YAML content into a top-level dict, or None if not a mapping."""
    data = parse_document(content)
    return data if type(data) == "dict" else None

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

def parse_pubspec_lock(content):
    """Parse a pubspec.lock file into a dict of package info.

    Args:
        content: String contents of a pubspec.lock file.

    Returns:
        Dict of package_name -> {
            "dependency": str,
            "source": str,
            "version": str,
            "description": dict (keys vary by source type),
        }
    """
    data = _load(content)
    if data == None:
        return {}
    packages = data.get("packages")
    if type(packages) != "dict":
        return {}

    result = {}
    for name, info in packages.items():
        if type(info) != "dict":
            continue
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
    data = _load(content)
    if data == None:
        return []
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
    data = _load(content)
    if data == None:
        return ""
    env = data.get("environment")
    if type(env) != "dict":
        return ""
    sdk = env.get("sdk")
    if sdk == None:
        return ""
    return str(sdk)
