"""Pubspec-shape extractors for pubspec.lock and pubspec.yaml files.

Generic YAML parsing is done by `//dart/pub/private:yaml_subset.bzl`; this
module just projects the parsed value down to the exact shapes the rules_dart
pub extension and repository rules consume.
"""

load("//dart/pub/private:yaml_subset.bzl", "document_problems", "document_value_and_problems", "parse_document")

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

def pubspec_lock_error(content, lock_label = "pubspec.lock"):
    """Returns why a pubspec.lock is unreadable, or None when it is clean.

    Duplicate keys, lines the parser cannot read (other than blank and
    comment lines), a missing or non-mapping `packages`, and package entries
    that are not mappings are all errors. `packages: {}` with valid `sdks`
    stays a valid, empty lock.

    Args:
        content: String contents of a pubspec.lock file.
        lock_label: Label naming the lock file for diagnostics.

    Returns:
        An error string naming the lock and the problem, or None.
    """
    err = _lock_syntax_error(content, lock_label)
    if err:
        return err
    data = parse_document(content)
    err = _lock_shape_error(data, lock_label)
    if err:
        return err
    for name, info in data["packages"].items():
        err = _lock_entry_shape_error(name, info, lock_label)
        if err:
            return err
    return None

def parse_pubspec_lock(content, lock_label = "pubspec.lock"):
    """Parse a pubspec.lock file into a dict of package info.

    Fails when the lock has duplicate keys, lines the parser cannot read, a
    missing or non-mapping `packages`, or a package entry that is not a
    mapping, so a lock the parser cannot read never becomes a silently
    empty hub.

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
