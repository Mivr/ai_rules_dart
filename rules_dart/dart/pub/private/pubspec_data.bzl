"""What the pub rules read from decoded `pubspec.lock` and `pubspec.yaml` data.

`yaml2json.bzl` turns the files into data; this file checks that data the way `pub`
does and projects it to the shapes the pub extension and repository rules
consume. Scalars arrive as strings holding their source text, booleans as
booleans and empty values as None (see `yaml2json.bzl`).

The pub extension's facts key digests this file with `yaml2json.bzl`, so a change
here re-derives every recorded fact.
"""

load("//dart/pub/private:yaml_sdk_constraint.bzl", "is_valid_sdk_constraint")

visibility(["//dart/..."])

_NAME_FIRST = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"
_NAME_CHARS = _NAME_FIRST + "0123456789"
_DIGITS = "0123456789"
_IDENT_CHARS = _DIGITS + "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-"

def is_package_name(name):
    """Returns whether `name` is a valid Dart package name.

    Letters, digits and underscores, not starting with a digit.

    Args:
      name: The candidate package name.

    Returns:
      True when `name` is a valid Dart package name.
    """
    if type(name) != "string" or name == "":
        return False
    if name[0] not in _NAME_FIRST:
        return False
    for ch in name.elems():
        if ch not in _NAME_CHARS:
            return False
    return True

def _is_digits(part):
    if part == "":
        return False
    for ch in part.elems():
        if ch not in _DIGITS:
            return False
    return True

def _is_version_number(part):
    return _is_digits(part) and (len(part) == 1 or part[0] != "0")

def _is_version_ident(seg, prerelease):
    if seg == "":
        return False
    for ch in seg.elems():
        if ch not in _IDENT_CHARS:
            return False
    if prerelease and _is_digits(seg) and len(seg) > 1 and seg[0] == "0":
        return False
    return True

def is_lock_version(version):
    """Returns whether `version` is a semantic version as pub writes it.

    MAJOR.MINOR.PATCH with numeric parts without leading zeros, plus
    optional `-prerelease` and `+build` dot-separated identifiers.

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
            if not _is_version_ident(seg, False):
                return False
    release, dash, pre = core.partition("-")
    parts = release.split(".")
    if len(parts) != 3:
        return False
    for part in parts:
        if not _is_version_number(part):
            return False
    if dash:
        if pre == "":
            return False
        for seg in pre.split("."):
            if not _is_version_ident(seg, True):
                return False
    return True

def _scalar_text(value):
    """Renders a decoded scalar as the string the pub rules compare."""
    return "" if value == None else str(value)

def _lock_entry(info):
    """Projects one lock package entry to string fields and a dict description."""
    entry = {}
    for k, v in info.items():
        if k == "description":
            # An inline scalar `description: flutter` reads as
            # {"name": "flutter"}, so callers always see a dict.
            if type(v) == "dict":
                entry[k] = {dk: _scalar_text(dv) for dk, dv in v.items()}
            else:
                entry[k] = {"name": _scalar_text(v)}
        else:
            entry[k] = _scalar_text(v)
    return entry

def _lock_entry_error(name, info, lock_label):
    """Returns why one lock package entry is unusable, or None."""
    if type(info) != "dict":
        return "%s: package %r entry is not a mapping" % (lock_label, name)
    if not is_package_name(name):
        return "%s: package %r is not a valid package name" % (lock_label, name)
    source = info.get("source", None)
    if source == None:
        return "%s: package %r has no 'source'" % (lock_label, name)
    if type(source) != "string":
        return "%s: package %r has non-string 'source'" % (lock_label, name)
    version = info.get("version", None)
    if version == None:
        return "%s: package %r has no 'version'" % (lock_label, name)
    if type(version) != "string":
        return "%s: package %r has non-string 'version'" % (lock_label, name)
    if not is_lock_version(version):
        return "%s: package %r has invalid version %r" % (lock_label, name, version)
    return None

def lock_packages_or_error(data, lock_label = "pubspec.lock"):
    """Checks a decoded `pubspec.lock` and projects its packages.

    A missing or non-mapping `packages`, an entry that is not a mapping, an
    invalid package name, two names equal ignoring case, and a missing or
    non-string `source` or `version`, or a `version` that is not a semantic
    version, are errors. `packages: {}` is a valid, empty lock.

    Args:
      data: The lock's top-level mapping, from `yaml_to_json`.
      lock_label: Label naming the lock file for diagnostics.

    Returns:
      struct(packages, error): `packages` maps each package name to a dict
      of string fields (`dependency`, `source`, `version`, ...) plus a dict
      `description`; or `error` names the lock and the problem.
    """
    if "packages" not in data:
        return struct(packages = None, error = "%s: missing 'packages' mapping" % lock_label)
    packages = data["packages"]
    if type(packages) != "dict":
        return struct(packages = None, error = "%s: 'packages' is not a mapping" % lock_label)
    folded = {}
    for name, info in packages.items():
        err = _lock_entry_error(name, info, lock_label)
        if err != None:
            return struct(packages = None, error = err)
        lower = name.lower()
        if lower in folded:
            return struct(packages = None, error = "%s: packages %r and %r differ only in case" % (lock_label, folded[lower], name))
        folded[lower] = name
    return struct(
        packages = {name: _lock_entry(info) for name, info in packages.items()},
        error = None,
    )

def lock_packages(data, lock_label = "pubspec.lock"):
    """Like `lock_packages_or_error`, failing on an error.

    Args:
      data: The lock's top-level mapping, from `yaml_to_json`.
      lock_label: Label naming the lock file for diagnostics.

    Returns:
      Dict of package name to its entry (see `lock_packages_or_error`).
    """
    result = lock_packages_or_error(data, lock_label)
    if result.error != None:
        fail(result.error)
    return result.packages

def pubspec_deps(data):
    """Returns the names under a decoded pubspec's `dependencies:`.

    Args:
      data: The pubspec's top-level mapping, from `yaml_to_json`.

    Returns:
      List of dependency package names, in file order.
    """
    deps = data.get("dependencies")
    if type(deps) != "dict":
        return []
    return list(deps.keys())

def pubspec_sdk_constraint(data):
    """Returns a decoded pubspec's `environment.sdk`, or "" when it has none.

    Args:
      data: The pubspec's top-level mapping, from `yaml_to_json`.

    Returns:
      The SDK version constraint string, e.g. `^3.5.0` or `>=2.12.0 <4.0.0`.
    """
    env = data.get("environment")
    if type(env) != "dict":
        return ""
    sdk = env.get("sdk")
    if sdk == None:
        return ""
    return str(sdk)

def _constraint_error(package, pubspec_label, key, constraint):
    if type(constraint) == "string" and is_valid_sdk_constraint(constraint):
        return None
    return "%s in %s: invalid environment.%s constraint \"%s\": expected a version constraint pub reads, such as ^3.0.0 or >=2.12.0 <4.0.0" % (package, pubspec_label, key, str(constraint))

def pubspec_environment_error(data, pubspec_label = "pubspec.yaml"):
    """Returns why a decoded pubspec's `environment` is unusable, or None.

    Mirrors pub's `_parseEnvironment`: a present, non-null `environment`
    must be a map, no SDK may be named `dart` (Dart SDK constraints read as
    `sdk`), and every present, non-null constraint must be a string pub
    reads (`VersionConstraint.parse`).

    Args:
      data: The pubspec's top-level mapping, from `yaml_to_json`.
      pubspec_label: Label naming the pubspec file for diagnostics.

    Returns:
      An error string naming the package, the label and the reason, or None.
    """
    package = pubspec_label
    if data.get("name") != None:
        package = str(data["name"])
    env = data.get("environment")
    if env == None:
        return None
    if type(env) != "dict":
        return "%s in %s: \"environment\" field must be a map." % (package, pubspec_label)
    if env.get("sdk") != None:
        err = _constraint_error(package, pubspec_label, "sdk", env["sdk"])
        if err != None:
            return err
    for name, constraint in env.items():
        if name == "dart":
            return "%s in %s: Use \"sdk\" to for Dart SDK constraints." % (package, pubspec_label)
        if name == "sdk" or constraint == None:
            continue
        err = _constraint_error(package, pubspec_label, name, constraint)
        if err != None:
            return err
    return None
