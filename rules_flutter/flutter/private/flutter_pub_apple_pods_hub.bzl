"""Hub JSON serialisation and validation helpers for CocoaPods native dependencies."""

load("//flutter/private:podfile_lock.bzl", "read_podfile_lock")
load("//flutter/private:swiftpm_resolved.bzl", "swiftpm_check_json")

visibility(["//flutter/..."])

_VALID_POD_RESOLUTION_KINDS = ("skip", "label", "plugin", "drop", "unresolved")
_POD_RESOLUTION_STRING_FIELDS = (
    "hub",
    "kind",
    "label",
    "lock_label",
    "package",
    "pod",
    "reason",
    "version",
)

def make_pod_resolution(
        kind,
        label = "",
        package = "",
        hub = "",
        pod = "",
        version = "",
        lock_label = "",
        reason = ""):
    """Create a pod resolution result struct.

    Args:
        kind: One of "skip", "label", "plugin", "drop", "unresolved".
        label: Resolved Bazel target label string, or "".
        package: Flutter plugin pub package name, or "".
        hub: Hub name, or "".
        pod: CocoaPods pod name, or "".
        version: Locked version string, or "".
        lock_label: Label string of the Podfile.lock, or "".
        reason: Refusal reason string, or "".

    Returns:
        A struct with the resolution fields.
    """
    return struct(
        kind = kind,
        label = label,
        package = package,
        hub = hub,
        pod = pod,
        version = version,
        lock_label = lock_label,
        reason = reason,
        ok = (kind != "unresolved"),
        error = reason,
    )

def pod_resolution_to_dict(res):
    """Convert a pod resolution struct to a deterministic JSON dict.

    Args:
        res: The resolution struct from `make_pod_resolution`.

    Returns:
        A dict with sorted keys suitable for JSON encoding.
    """
    return {
        "hub": res.hub,
        "kind": res.kind,
        "label": res.label,
        "lock_label": res.lock_label,
        "package": res.package,
        "pod": res.pod,
        "reason": res.reason,
        "version": res.version,
    }

def _pod_resolution_from_dict(d):
    """Convert a validated JSON dict into a pod resolution struct."""
    kind = d.get("kind", "")
    reason = d.get("reason", "")
    return struct(
        hub = d.get("hub", ""),
        kind = kind,
        label = d.get("label", ""),
        lock_label = d.get("lock_label", ""),
        package = d.get("package", ""),
        pod = d.get("pod", ""),
        reason = reason,
        version = d.get("version", ""),
        ok = (kind != "unresolved"),
        error = reason,
    )

def read_hub_podfile_lock(module_ctx, pub_tag):
    """Read and validate `pub_tag.ios_podfile_lock` when configured on the hub.

    Args:
        module_ctx: Module extension context with `read(...)`.
        pub_tag: The `flutter.pub` tag struct.

    Returns:
        `(podfile, lock_label)` tuple, or `(None, "")` when unset.
    """
    if not hasattr(pub_tag, "ios_podfile_lock") or pub_tag.ios_podfile_lock == None:
        return None, ""
    lock_label = str(pub_tag.ios_podfile_lock)
    podfile = read_podfile_lock(module_ctx.read(pub_tag.ios_podfile_lock), lock_label)
    if not podfile.ok:
        fail(podfile.error)
    return podfile, lock_label

def _hub_data_failure(error):
    """Build a failed `read_ios_pod_native_deps` result struct."""
    return struct(
        ok = False,
        error = error,
        ios_pods = {},
        ios_pod_deps = {},
        ios_pod_ignore = [],
        product_deps = {},
    )

def _validate_pod_deps(data, label, hub_name):
    """Validate and return the `ios_pod_deps` string-to-string map."""
    ios_pod_deps = data.get("ios_pod_deps", None)
    if type(ios_pod_deps) != "dict":
        return struct(
            ok = False,
            error = "flutter.pub hub {hub}: {label} has no `ios_pod_deps` object.".format(
                hub = repr(hub_name),
                label = label,
            ),
            pod_deps = {},
        )
    for key in ios_pod_deps:
        if type(key) != "string" or type(ios_pod_deps[key]) != "string":
            return struct(
                ok = False,
                error = (
                    "flutter.pub hub {hub}: {label} maps a non-string key " +
                    "to a non-string label in `ios_pod_deps`."
                ).format(hub = repr(hub_name), label = label),
                pod_deps = {},
            )
    return struct(ok = True, error = "", pod_deps = ios_pod_deps)

def _validate_pod_ignore(data, label, hub_name):
    """Validate and return the `ios_pod_ignore` string list."""
    ios_pod_ignore = data.get("ios_pod_ignore", None)
    if type(ios_pod_ignore) != "list":
        return struct(
            ok = False,
            error = "flutter.pub hub {hub}: {label} has no `ios_pod_ignore` list.".format(
                hub = repr(hub_name),
                label = label,
            ),
            pod_ignore = [],
        )
    for item in ios_pod_ignore:
        if type(item) != "string":
            return struct(
                ok = False,
                error = "flutter.pub hub {hub}: {label} contains a non-string element in `ios_pod_ignore`.".format(
                    hub = repr(hub_name),
                    label = label,
                ),
                pod_ignore = [],
            )
    return struct(ok = True, error = "", pod_ignore = ios_pod_ignore)

def _is_valid_pod_entry_dict(entry):
    """Return True when a decoded `ios_pods` entry has valid field types."""
    if type(entry) != "dict":
        return False
    kind = entry.get("kind", "")
    if kind not in _VALID_POD_RESOLUTION_KINDS:
        return False
    for field in _POD_RESOLUTION_STRING_FIELDS:
        if type(entry.get(field, "")) != "string":
            return False
    if kind == "label" and not entry.get("label", ""):
        return False
    if kind == "plugin" and not entry.get("package", ""):
        return False
    return True

def _parse_ios_pods(data, label, hub_name):
    """Validate and parse the `ios_pods` dictionary."""
    ios_pods_raw = data.get("ios_pods", None)
    if type(ios_pods_raw) != "dict":
        return struct(
            ok = False,
            error = "flutter.pub hub {hub}: {label} has no `ios_pods` object.".format(
                hub = repr(hub_name),
                label = label,
            ),
            ios_pods = {},
        )
    ios_pods = {}
    for pod_name in ios_pods_raw:
        raw_entry = ios_pods_raw[pod_name]
        if type(pod_name) != "string" or not _is_valid_pod_entry_dict(raw_entry):
            return struct(
                ok = False,
                error = "flutter.pub hub {hub}: {label} contains an invalid entry in `ios_pods`.".format(
                    hub = repr(hub_name),
                    label = label,
                ),
                ios_pods = {},
            )
        ios_pods[pod_name] = _pod_resolution_from_dict(raw_entry)
    return struct(ok = True, error = "", ios_pods = ios_pods)

def read_ios_pod_native_deps(content, label, hub_name):
    """Read a hub's `ios_native_deps.json` CocoaPods entries.

    Validates that the file contains version 1 and valid `ios_pod_deps`,
    `ios_pod_ignore`, and `ios_pods` structures.

    Args:
        content: The full text of the file that is being parsed.
        label: The file label string, for error reporting.
        hub_name: The flutter.pub hub name, for error reporting.

    Returns:
        `struct(ok, error, ios_pods, ios_pod_deps, ios_pod_ignore, product_deps)`.
    """
    if type(content) != "string":
        return _hub_data_failure(
            "flutter.pub hub {hub}: {label} is missing or unreadable.".format(
                hub = repr(hub_name),
                label = label,
            ),
        )
    bad = swiftpm_check_json(content, label)
    if bad:
        return _hub_data_failure("flutter.pub hub {hub}: {bad}".format(hub = repr(hub_name), bad = bad))
    data = json.decode(content)
    if type(data) != "dict":
        return _hub_data_failure(
            "flutter.pub hub {hub}: {label} must hold a JSON object.".format(
                hub = repr(hub_name),
                label = label,
            ),
        )
    if data.get("version", 0) != 1:
        return _hub_data_failure((
            "flutter.pub hub {hub}: {label} has an unsupported version " +
            "({version}): only version 1 parses."
        ).format(hub = repr(hub_name), label = label, version = repr(data.get("version", 0))))
    pod_deps_res = _validate_pod_deps(data, label, hub_name)
    if not pod_deps_res.ok:
        return _hub_data_failure(pod_deps_res.error)
    pod_ignore_res = _validate_pod_ignore(data, label, hub_name)
    if not pod_ignore_res.ok:
        return _hub_data_failure(pod_ignore_res.error)
    pods_res = _parse_ios_pods(data, label, hub_name)
    if not pods_res.ok:
        return _hub_data_failure(pods_res.error)
    return struct(
        ok = True,
        error = "",
        ios_pods = pods_res.ios_pods,
        ios_pod_deps = pod_deps_res.pod_deps,
        ios_pod_ignore = pod_ignore_res.pod_ignore,
        product_deps = data.get("swift_package_product_deps", {}),
    )
