"""CocoaPods `Podfile.lock` reader and validator for rules_flutter.

Reads the evaluated CocoaPods lockfile committed by Flutter iOS/macOS apps
to discover plugin native pod dependencies and versions without running Ruby.
The file is YAML: the caller converts it with `yaml_to_json` from
`@rules_dart//dart/pub:yaml.bzl`, and this module checks and projects the
decoded mapping. Only the pod entries themselves (`<name> (<version>)`) are
CocoaPods text inside YAML scalars, split here.
"""

visibility(["//flutter/..."])

_ALLOWED_TOP_LEVEL = {
    "CHECKOUT OPTIONS": True,
    "COCOAPODS": True,
    "DEPENDENCIES": True,
    "EXTERNAL SOURCES": True,
    "PODFILE CHECKSUM": True,
    "PODS": True,
    "SPEC CHECKSUMS": True,
    "SPEC REPOS": True,
}

_CHECKOUT_KINDS = {
    "git": True,
    "hg": True,
    "http": True,
    "svn": True,
}

def _refusal(label, where, detail):
    """Format a refusal naming the label, the place in the lock and the detail."""
    return "{label} (Podfile.lock {where}): {detail}.".format(
        label = label,
        where = where,
        detail = detail,
    )

def _failure(error):
    """Build a failure struct with empty maps."""
    return struct(
        ok = False,
        error = error,
        pods = {},
        plugin_pods = {},
        spec_repos = {},
        checksums = {},
        checkout = {},
    )

def _is_valid_pod_token(token, allow_spaces = False):
    """Whether `token` is non-empty and free of delimiter characters."""
    if not token or token.startswith("-"):
        return False
    bad_chars = ("(", ")", ":", '"', "'", "\t") if allow_spaces else (" ", "\t", "(", ")", ":", '"', "'")
    for ch in bad_chars:
        if token.find(ch) != -1:
            return False
    return True

def _split_pod_entry(text):
    """Split a `<name> (<version>)` PODS entry, or None when it is not one."""
    if type(text) != "string" or not text.endswith(")"):
        return None
    open_paren = text.rfind(" (")
    if open_paren <= 0:
        return None
    name = text[:open_paren]
    version = text[open_paren + 2:-1]
    if not _is_valid_pod_token(name) or not _is_valid_pod_token(version):
        return None
    return struct(name = name, version = version)

def _split_pod_dep(text):
    """Split a `<name>` or `<name> (<requirement>)` dependency, or None."""
    if type(text) != "string":
        return None
    if text.endswith(")"):
        open_paren = text.rfind(" (")
        if open_paren <= 0:
            return None
        name = text[:open_paren]
        req = text[open_paren + 2:-1].strip()
        if not _is_valid_pod_token(name) or not _is_valid_pod_token(req, allow_spaces = True):
            return None
        return struct(name = name, requirement = req)
    if not _is_valid_pod_token(text):
        return None
    return struct(name = text, requirement = "")

def _entry_text(value):
    """Render a PODS item for a refusal message."""
    return value if type(value) == "string" else json.encode(value)

def _read_pods(raw, label):
    """Read the `PODS` list into `(pods, error)`; `pods` keeps lock order."""
    pods = {}
    if raw == None:
        return pods, ""
    if type(raw) != "list":
        return None, _refusal(label, "PODS", "PODS is not a list of \"<name> (<version>)\" entries")
    for index, item in enumerate(raw):
        where = "PODS entry %d" % (index + 1)
        if type(item) == "dict" and len(item) == 1:
            entry_text, deps_raw = item.items()[0]
        else:
            entry_text, deps_raw = item, None
        entry = _split_pod_entry(entry_text)
        if entry == None:
            return None, _refusal(label, where, '"{text}" is not a "<name> (<version>):" PODS entry'.format(text = _entry_text(entry_text)))
        if entry.name in pods:
            return None, _refusal(label, where, 'PODS lists "{pod}" twice'.format(pod = entry.name))
        if deps_raw == None:
            deps_raw = []
        if type(deps_raw) != "list":
            return None, _refusal(label, where, '"{pod}" lists its dependencies as something other than a list'.format(pod = entry.name))
        deps = []
        for dep_raw in deps_raw:
            dep = _split_pod_dep(dep_raw)
            if dep == None:
                return None, _refusal(label, where, '"{text}" is not a "<name> (<requirement>)" PODS dependency'.format(text = _entry_text(dep_raw)))
            deps.append(dep)
        pods[entry.name] = struct(version = entry.version, deps = deps, index = index)
    return pods, ""

def _plugin_pkg_from_path(path):
    """Extract pub package name from `.symlinks/plugins/<pkg>/<ios|darwin|macos>`, or `""`."""
    prefix = ".symlinks/plugins/"
    if type(path) != "string" or not path.startswith(prefix):
        return ""
    parts = path[len(prefix):].split("/")
    if len(parts) == 2 and parts[1] in ("ios", "darwin", "macos") and parts[0] not in ("", ".", ".."):
        return parts[0]
    return ""

def _mapping(data, key):
    """The mapping under a top-level key, or `{}` when it is absent or not one."""
    value = data.get(key)
    return value if type(value) == "dict" else {}

def _source_kinds(source):
    """The `(kind, value)` pairs of a source mapping's `:<kind>` keys, in order."""
    if type(source) != "dict":
        return []
    return [(key[1:], value) for key, value in source.items() if key.startswith(":")]

def read_podfile_lock(data, label):
    """Check a decoded CocoaPods `Podfile.lock` and project its pod data.

    Args:
        data: The lock's top-level mapping, from `yaml_to_json`.
        label: The file label string, for error reporting.

    Returns:
        `struct(ok, error, pods, plugin_pods, spec_repos, checksums, checkout)`:
        on success, `ok` is True and `error` is `""`; `pods` maps each pod
        to `struct(version, deps, index)`, `deps` holding
        `struct(name, requirement)` and `index` the entry's position in
        `PODS`. On failure, `ok` is False, `error` holds the refusal message,
        and all maps are empty.
    """
    for key in data.keys():
        if key not in _ALLOWED_TOP_LEVEL:
            return _failure(_refusal(label, "top level", '"{key}" is not a Podfile.lock top-level key rules_flutter reads'.format(key = key)))

    pods, err = _read_pods(data.get("PODS"), label)
    if err:
        return _failure(err)

    spec_repos = {}
    for repo, repo_pods in _mapping(data, "SPEC REPOS").items():
        if type(repo_pods) != "list":
            continue
        for pod in repo_pods:
            if type(pod) == "string" and pod:
                spec_repos[pod] = repo

    # The first checkout kind named for a pod wins, in file order, whichever
    # of the two sections names it first.
    plugin_pods = {}
    checkout = {}
    for section in data.keys():
        if section not in ("EXTERNAL SOURCES", "CHECKOUT OPTIONS"):
            continue
        for pod, source in _mapping(data, section).items():
            for kind, value in _source_kinds(source):
                if kind == "path" and section == "EXTERNAL SOURCES":
                    pkg = _plugin_pkg_from_path(value)
                    if pkg:
                        plugin_pods[pod] = pkg
                elif kind in _CHECKOUT_KINDS and pod not in checkout:
                    checkout[pod] = kind

    checksums = {}
    for pod, checksum in _mapping(data, "SPEC CHECKSUMS").items():
        if pod and type(checksum) == "string" and checksum:
            checksums[pod] = checksum

    return struct(
        ok = True,
        error = "",
        pods = pods,
        plugin_pods = plugin_pods,
        spec_repos = spec_repos,
        checksums = checksums,
        checkout = checkout,
    )
