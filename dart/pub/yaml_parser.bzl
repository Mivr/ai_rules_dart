"""Pubspec-shape extractors for pubspec.lock and pubspec.yaml files.

Generic YAML parsing is done by `//dart/pub/private:yaml_subset.bzl`; this
module just projects the parsed value down to the exact shapes the rules_dart
pub extension and repository rules consume.
"""

load("//dart/pub/private:yaml_lock.bzl", _lock_error = "pubspec_lock_error", _parse_lock = "parse_pubspec_lock")
load("//dart/pub/private:yaml_sdk_constraint.bzl", _sdk_constraint_ok = "is_valid_sdk_constraint")
load("//dart/pub/private:yaml_subset.bzl", "document_value_and_problems")

def _pubspec_parse(content, pubspec_label):
    """Parses a pubspec into (mapping, error) without failing."""
    data, problems = document_value_and_problems(content, True, refuse_tail_directives = True)
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
    return _lock_error(content, lock_label)

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
    return _parse_lock(content, lock_label)

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
    return _sdk_constraint_ok(sdk_constraint)

def pubspec_sdk_constraint_error(content, pubspec_label = "pubspec.yaml"):
    """Returns why a pubspec's `environment.sdk` is unreadable, or None when it is clean.

    A present, non-null `environment.sdk` must be a string pub reads (see
    `is_valid_sdk_constraint`): anything else fails the fetch with a
    message naming the package, the label and the quoted value. A missing
    `environment`, a non-mapping one, a missing `sdk` key or a null value
    reads as before, with no error.

    Args:
        content: String contents of a pubspec.yaml file.
        pubspec_label: Label naming the pubspec file for diagnostics.

    Returns:
        An error string naming the package, the label and the value, or None.
    """
    data, err = _pubspec_parse(content, pubspec_label)
    if err:
        return err
    package = pubspec_label
    if "name" in data and data["name"] != None:
        package = str(data["name"])
    env = data.get("environment")
    if type(env) != "dict":
        return None
    if "sdk" not in env:
        return None
    sdk = env["sdk"]
    if sdk == None:
        return None
    if type(sdk) != "string" or not is_valid_sdk_constraint(sdk):
        return "%s in %s: invalid environment.sdk constraint \"%s\": expected a version constraint pub reads, such as ^3.0.0 or >=2.12.0 <4.0.0" % (package, pubspec_label, str(sdk))
    return None
