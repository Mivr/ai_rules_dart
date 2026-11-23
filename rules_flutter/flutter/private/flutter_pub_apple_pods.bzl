"""CocoaPods native dependency resolution for rules_flutter.

Implements the 7-step CocoaPods resolution order for Apple plugin native
dependencies, hub-level precomputation into `ios_native_deps.json`, and spoke
resolution in CocoaPods mode with mixed-mode `Package.swift` fallback and
fail-closed refusals.
"""

load(
    "//flutter/private:flutter_pub_apple_pods_hub.bzl",
    "make_pod_resolution",
    "pod_resolution_to_dict",
    "read_ios_pod_native_deps",
)
load("//flutter/private:podfile_lock.bzl", "read_podfile_lock")

visibility(["//flutter/..."])

def format_message_9(plugin = None, lock_label = None, package = None):
    """Format Message 9 when a plugin has iOS sources but no lock entry and no Package.swift.

    Args:
        plugin: The Flutter plugin package name.
        lock_label: The string label of Podfile.lock.
        package: Optional alias for plugin.

    Returns:
        The formatted refusal error message string.
    """
    pkg = plugin if plugin != None else package
    return (
        'Flutter plugin "{plugin}" has iOS sources but {lock_label} lists no pod for it ' +
        '(expected an EXTERNAL SOURCES entry ".symlinks/plugins/{plugin}/ios"), and the ' +
        "plugin ships no Package.swift to fall back to. Run pod install for the app so the " +
        "lock lists every plugin, or list the plugin's dependencies with " +
        'flutter.pub(ios_plugin_deps = {{"{plugin}": "<label>"}}).'
    ).format(plugin = pkg, lock_label = lock_label)

def format_message_11(plugin = None, pod = "", version = "", lock_label = "", reason = "", package = None):
    """Format Message 11 when a CocoaPods pod dependency cannot be resolved.

    Args:
        plugin: The Flutter plugin package name.
        pod: The name of the CocoaPods pod that has no Bazel target.
        version: The locked version string, or "".
        lock_label: The string label of Podfile.lock.
        reason: Optional refusal reason, or "".
        package: Optional alias for plugin.

    Returns:
        The formatted refusal error message string.
    """
    pkg = plugin if plugin != None else package
    version_in_lock = ("(" + version + " in " + lock_label + ")") if version else ("(in " + lock_label + ")")
    reason_suffix = (": " + reason) if reason else ""
    return (
        'Flutter plugin "{plugin}" depends on pod "{pod}" {version_in_lock}, ' +
        "which no Bazel target provides{reason_suffix}. " +
        'Map it with flutter.pub(ios_pod_deps = {{"{pod}": "<label>"}}) ' +
        'or declare it unneeded with flutter.pub(ios_pod_ignore = ["{pod}"]).'
    ).format(
        plugin = pkg,
        pod = pod,
        version_in_lock = version_in_lock,
        reason_suffix = reason_suffix,
    )

def resolve_binary_pod_stub(_pod = "", _root = "", _version = ""):
    """Pure stub for binary pod resolution (filled in by POD-21).

    Args:
        _pod: The name of the pod being resolved; unused by the stub.
        _root: The name of the root pod of the resolved pod; unused by the stub.
        _version: The version string locked in `Podfile.lock`; unused by the stub.

    Returns:
        Always `None`, because no resolver is wired in behind this stub yet.
    """
    return None

def resolve_swiftpm_pod_stub(_pod = "", _root = "", _version = ""):
    """Pure stub for pod-to-SwiftPM table resolution (filled in by POD-18).

    Args:
        _pod: The name of the pod being resolved; unused by the stub.
        _root: The name of the root pod of the resolved pod; unused by the stub.
        _version: The version string locked in `Podfile.lock`; unused by the stub.

    Returns:
        Always `None`, because no resolver is wired in behind this stub yet.
    """
    return None

def _podfile_maps(podfile):
    """Extract `(plugin_pods, pods_map)` from a parsed podfile struct or dict."""
    if podfile == None:
        return {}, {}
    if type(podfile) == "dict":
        return podfile.get("plugin_pods", {}), podfile.get("pods", {})
    plugin_pods = podfile.plugin_pods if hasattr(podfile, "plugin_pods") else {}
    pods_map = podfile.pods if hasattr(podfile, "pods") else {}
    return plugin_pods, pods_map

def _locked_pod_version(pods_map, pod, root):
    """Read the locked version for `pod` (falling back to `root`, else `""`)."""
    entry = pods_map.get(pod)
    if entry == None:
        entry = pods_map.get(root)
    if entry == None:
        return ""
    if type(entry) == "dict":
        return entry.get("version", "")
    return entry.version if hasattr(entry, "version") else ""

def _entry_dep_names(entry):
    """Return dependency pod names from one `podfile.pods` entry."""
    if type(entry) == "dict":
        deps = entry.get("deps", [])
    else:
        deps = entry.deps if hasattr(entry, "deps") else []
    names = []
    for dep in deps:
        if type(dep) == "dict":
            dep_name = dep.get("name", "")
        elif hasattr(dep, "name"):
            dep_name = dep.name
        else:
            dep_name = str(dep)
        if dep_name:
            names.append(dep_name)
    return names

def resolve_pod(
        pod,
        hub_name = "",
        all_package_names = (),
        podfile = None,
        lock_label = "",
        ios_pod_deps = {},
        ios_pod_ignore = (),
        platform = "ios"):
    """Resolve one CocoaPods pod according to the 7-step resolution order.

    1. Engine pods (Flutter, FlutterMacOS) -> skip.
    2. ios_pod_deps: exact pod key wins over root key.
    3. Flutter plugin pod: root in plugin_pods and pkg in all_package_names.
    4. ios_pod_ignore: pod or root in ios_pod_ignore -> drop.
    5. Binary pod stub (POD-21) -> None.
    6. Pod-to-SwiftPM table stub (POD-18) -> None.
    7. Refusal: unresolved pod at locked version.

    Args:
        pod: Pod name (e.g. "Firebase/Auth" or "path_provider_foundation").
        hub_name: The flutter.pub hub name.
        all_package_names: List, tuple or dict of packages in pubspec.lock.
        podfile: Parsed Podfile.lock struct or None.
        lock_label: String label of the Podfile.lock.
        ios_pod_deps: Dict mapping pod name to canonical Bazel label string.
        ios_pod_ignore: List, tuple or dict of pod names to drop.
        platform: Platform string ("ios", "macos", or "" when precomputing).

    Returns:
        A pod resolution struct created with make_pod_resolution.
    """
    root = pod.partition("/")[0]
    if pod in ("Flutter", "FlutterMacOS") or root in ("Flutter", "FlutterMacOS"):
        return make_pod_resolution(kind = "skip", pod = pod)

    if pod in ios_pod_deps:
        return make_pod_resolution(kind = "label", label = str(ios_pod_deps[pod]), pod = pod)
    if root in ios_pod_deps:
        return make_pod_resolution(kind = "label", label = str(ios_pod_deps[root]), pod = pod)

    plugin_pods, pods_map = _podfile_maps(podfile)
    pkg = plugin_pods.get(root, "")
    if pkg and pkg in all_package_names:
        plugin_label = ""
        if hub_name and platform:
            plugin_label = "@{hub}__{pkg}//:{pkg}_apple_{plat}".format(
                hub = hub_name,
                pkg = pkg,
                plat = platform,
            )
        return make_pod_resolution(
            kind = "plugin",
            label = plugin_label,
            package = pkg,
            hub = hub_name,
            pod = pod,
        )

    if pod in ios_pod_ignore or root in ios_pod_ignore:
        return make_pod_resolution(kind = "drop", pod = pod)

    version = _locked_pod_version(pods_map, pod, root)
    binary_res = resolve_binary_pod_stub(pod, root, version)
    if binary_res != None:
        return binary_res
    swiftpm_res = resolve_swiftpm_pod_stub(pod, root, version)
    if swiftpm_res != None:
        return swiftpm_res

    return make_pod_resolution(
        kind = "unresolved",
        pod = pod,
        version = version,
        lock_label = lock_label,
        reason = "",
    )

def precompute_hub_apple_pods(
        hub_name,
        all_package_names,
        podfile,
        lock_label,
        ios_pod_deps,
        ios_pod_ignore):
    """Precompute CocoaPods resolutions for all pods named in Podfile.lock.

    Resolves every pod in podfile.pods (keys and dep.name entries).
    Unresolvable pods are recorded as unresolved entries without failing.

    Args:
        hub_name: The flutter.pub hub name.
        all_package_names: List or dict of packages in pubspec.lock.
        podfile: Parsed Podfile.lock struct or None.
        lock_label: String label of the Podfile.lock.
        ios_pod_deps: Dict mapping pod name to canonical Bazel label string.
        ios_pod_ignore: List of pod names to drop.

    Returns:
        Dict mapping pod name to deterministic resolution dict for JSON.
    """
    if not podfile:
        return {}
    _, pods_map = _podfile_maps(podfile)
    all_pods = {}
    for name, entry in pods_map.items():
        all_pods[name] = True
        for dep_name in _entry_dep_names(entry):
            all_pods[dep_name] = True

    package_set = {pkg: True for pkg in all_package_names}
    ignore_set = {item: True for item in ios_pod_ignore}
    resolved = {}
    for pod in sorted(all_pods.keys()):
        res = resolve_pod(
            pod = pod,
            hub_name = hub_name,
            all_package_names = package_set,
            podfile = podfile,
            lock_label = lock_label,
            ios_pod_deps = ios_pod_deps,
            ios_pod_ignore = ignore_set,
            platform = "",
        )
        resolved[pod] = pod_resolution_to_dict(res)
    return resolved

def hub_cocoapods_attrs(hub_name, all_package_names, podfile, lock_label, pub_tag):
    """Serialise CocoaPods tag inputs and precompute hub pod resolutions.

    Args:
        hub_name: The `flutter.pub` hub name.
        all_package_names: Packages present in `pubspec.lock`.
        podfile: Parsed `Podfile.lock` struct, or None in SwiftPM mode.
        lock_label: Canonical label string of `ios_podfile_lock`, or "".
        pub_tag: The `flutter.pub` tag struct.

    Returns:
        `struct(ios_pod_deps, ios_pod_ignore, ios_pods_json)` for the hub rule.
    """
    raw_deps = pub_tag.ios_pod_deps if hasattr(pub_tag, "ios_pod_deps") else {}
    ios_pod_deps = {key: str(raw_deps[key]) for key in sorted(raw_deps)}
    raw_ignore = pub_tag.ios_pod_ignore if hasattr(pub_tag, "ios_pod_ignore") else []
    ios_pod_ignore = sorted(raw_ignore)
    ios_pods = precompute_hub_apple_pods(
        hub_name = hub_name,
        all_package_names = all_package_names,
        podfile = podfile,
        lock_label = lock_label,
        ios_pod_deps = ios_pod_deps,
        ios_pod_ignore = ios_pod_ignore,
    )
    return struct(
        ios_pod_deps = ios_pod_deps,
        ios_pod_ignore = ios_pod_ignore,
        ios_pods_json = json.encode(ios_pods),
    )

def _collect_matching_lock_entries(podfile, package_name):
    """Find all PODS entries belonging to `package_name`, sorted by `entry.line`."""
    matched = []
    for pod_name, entry in podfile.pods.items():
        root = pod_name.partition("/")[0]
        if podfile.plugin_pods.get(root) == package_name:
            matched.append((entry.line, pod_name))
    return [podfile.pods[pod_name] for _, pod_name in sorted(matched)]

def _filter_kept_deps(matching_entries, podfile, package_name):
    """Collect kept dependencies in lock order, skipping engine and self edges."""
    kept = []
    for entry in matching_entries:
        for dep_name in _entry_dep_names(entry):
            dep_root = dep_name.partition("/")[0]
            if dep_name in ("Flutter", "FlutterMacOS") or dep_root in ("Flutter", "FlutterMacOS"):
                continue
            if podfile.plugin_pods.get(dep_root) == package_name:
                continue
            kept.append(dep_name)
    return kept

def _infer_spoke_hub_name(ctx, native_deps_label):
    """Read `ctx.attr.hub_name`, falling back to the repo of `native_deps_label`."""
    hub_name = ctx.attr.hub_name if hasattr(ctx.attr, "hub_name") else ""
    if hub_name or native_deps_label == None:
        return hub_name
    label_str = str(native_deps_label)
    if label_str.startswith("@@"):
        return label_str[2:].partition("//")[0]
    if label_str.startswith("@"):
        return label_str[1:].partition("//")[0]
    return ""

def _plugin_pod_target(pod_res, spoke, platform):
    """Return the Apple plugin target string for a plugin pod resolution.

    Args:
        pod_res: Resolution struct with `package` and optional `hub`.
        spoke: Spoke struct with `hub_name` and optional `scc_targets`.
        platform: Platform string ("ios" or "macos").

    Returns:
        The target label string.
    """
    scc_targets = spoke.scc_targets if hasattr(spoke, "scc_targets") and spoke.scc_targets else {}
    if pod_res.package in scc_targets:
        scc_repo = scc_targets[pod_res.package].partition("//:")[0]
        return "{repo}//:{pkg}_apple_{plat}".format(
            repo = scc_repo,
            pkg = pod_res.package,
            plat = platform,
        )
    hub = pod_res.hub if pod_res.hub else spoke.hub_name
    return "@{hub}__{pkg}//:{pkg}_apple_{plat}".format(
        hub = hub,
        pkg = pod_res.package,
        plat = platform,
    )

def _resolve_spoke_deps_for_platform(kept_deps, platform, hub_data, spoke, fail_fn):
    """Resolve kept dependencies for one platform through precomputed hub data.

    Args:
        kept_deps: List of pod names in lock order.
        platform: Platform string ("ios" or "macos").
        hub_data: Hub data struct from `read_ios_pod_native_deps`.
        spoke: `struct(package_name, lock_label, hub_name, podfile)`.
        fail_fn: Failure function to call on an unresolved pod.

    Returns:
        `(labels, error_string)` tuple.
    """
    seen = {}
    labels = []
    for dep in kept_deps:
        pod_res = hub_data.ios_pods.get(dep)
        if pod_res == None:
            pod_res = resolve_pod(
                pod = dep,
                hub_name = spoke.hub_name,
                all_package_names = (),
                podfile = spoke.podfile,
                lock_label = spoke.lock_label,
                ios_pod_deps = hub_data.ios_pod_deps,
                ios_pod_ignore = hub_data.ios_pod_ignore,
                platform = platform,
            )
        if pod_res.kind in ("skip", "drop"):
            continue
        if pod_res.kind == "label":
            target = pod_res.label
        elif pod_res.kind == "plugin":
            target = _plugin_pod_target(pod_res, spoke, platform)
        else:
            ref_lock = spoke.lock_label if spoke.lock_label else pod_res.lock_label
            err_msg = format_message_11(
                spoke.package_name,
                dep,
                pod_res.version,
                ref_lock,
                pod_res.reason,
            )
            fail_fn(err_msg)
            return labels, err_msg
        if target not in seen:
            seen[target] = True
            labels.append(target)
    return labels, ""

def _read_spoke_hub_data(ctx, fail_fn):
    """Read and validate `ctx.attr.ios_native_deps` for a spoke with pod deps."""
    native_deps_label = ctx.attr.ios_native_deps if hasattr(ctx.attr, "ios_native_deps") else None
    hub_name = _infer_spoke_hub_name(ctx, native_deps_label)
    if native_deps_label == None:
        err = (
            "flutter.pub hub {hub}: missing `ios_native_deps` attribute in " +
            "CocoaPods mode: regenerate the hub."
        ).format(hub = repr(hub_name))
        fail_fn(err)
        return None, hub_name
    label_str = str(native_deps_label)
    if hasattr(ctx, "path") and not ctx.path(native_deps_label).exists:
        err = (
            "flutter.pub hub {hub}: its iOS native-deps file {label} is " +
            "missing: regenerate the hub."
        ).format(hub = repr(hub_name), label = label_str)
        fail_fn(err)
        return None, hub_name
    hub_data = read_ios_pod_native_deps(ctx.read(native_deps_label), label_str, hub_name)
    if not hub_data.ok:
        fail_fn(hub_data.error)
        return None, hub_name
    return hub_data, hub_name

def _resolve_spoke_from_lock(ctx, matching_entries, spoke, apple, fail_fn):
    """Resolve Apple dependencies from matching Podfile.lock entries."""
    kept_deps = _filter_kept_deps(matching_entries, spoke.podfile, spoke.package_name)
    if not kept_deps:
        return struct(macos = [], ios = [])

    hub_data, hub_name = _read_spoke_hub_data(ctx, fail_fn)
    if hub_data == None:
        return struct(macos = [], ios = [])

    spoke_with_hub = struct(
        package_name = spoke.package_name,
        lock_label = spoke.lock_label,
        hub_name = hub_name,
        podfile = spoke.podfile,
        scc_targets = ctx.attr.scc_targets if hasattr(ctx.attr, "scc_targets") else {},
    )
    macos_labels = []
    if apple.macos_srcs:
        macos_labels, err = _resolve_spoke_deps_for_platform(
            kept_deps,
            "macos",
            hub_data,
            spoke_with_hub,
            fail_fn,
        )
        if err:
            return struct(macos = [], ios = [])

    ios_labels = []
    if apple.ios_srcs:
        ios_labels, err = _resolve_spoke_deps_for_platform(
            kept_deps,
            "ios",
            hub_data,
            spoke_with_hub,
            fail_fn,
        )
        if err:
            return struct(macos = [], ios = [])

    return struct(macos = macos_labels, ios = ios_labels)

def _spoke_swiftpm_pin_attrs(ctx):
    """Extract optional SwiftPM pin and hub attributes from a spoke context."""
    return struct(
        resolved = ctx.attr.package_resolved if hasattr(ctx.attr, "package_resolved") else None,
        checksums = ctx.attr.package_sha256 if hasattr(ctx.attr, "package_sha256") else None,
        native_deps = ctx.attr.ios_native_deps if hasattr(ctx.attr, "ios_native_deps") else None,
        hub_name = ctx.attr.hub_name if hasattr(ctx.attr, "hub_name") else "",
    )

def _mixed_mode_swiftpm_fallback(ctx, package_name, apple, detect_swiftpm_platform, manifest_presence):
    """Run SwiftPM fallback for platforms that ship a Package.swift."""
    pins = _spoke_swiftpm_pin_attrs(ctx)

    macos_labels = []
    if apple.macos_srcs and (manifest_presence.macos or manifest_presence.darwin):
        macos_labels = detect_swiftpm_platform(
            ctx,
            package_name,
            "macos",
            apple.macos_srcs,
            pins.resolved,
            pins.checksums,
            pins.native_deps,
            pins.hub_name,
        )

    ios_labels = []
    if apple.ios_srcs and (manifest_presence.ios or manifest_presence.darwin):
        ios_labels = detect_swiftpm_platform(
            ctx,
            package_name,
            "ios",
            apple.ios_srcs,
            pins.resolved,
            pins.checksums,
            pins.native_deps,
            pins.hub_name,
        )

    return struct(macos = macos_labels, ios = ios_labels)

def detect_apple_cocoapods_deps(ctx, package_name, apple, detect_swiftpm_platform, fail_fn = fail):
    """Resolve Apple dependencies in CocoaPods mode.

    Args:
        ctx: Spoke repository context.
        package_name: Pub plugin package name.
        apple: Struct with macos_srcs and ios_srcs.
        detect_swiftpm_platform: Fallback function for mixed-mode SwiftPM.
        fail_fn: Function to invoke on error, defaults to `fail`.

    Returns:
        `struct(macos, ios)` with resolved target label lists.
    """
    if not apple.macos_srcs and not apple.ios_srcs:
        return struct(macos = [], ios = [])

    podfile_lock_attr = ctx.attr.podfile_lock if hasattr(ctx.attr, "podfile_lock") else None
    if podfile_lock_attr == None:
        return struct(macos = [], ios = [])

    lock_label = str(podfile_lock_attr)
    podfile = read_podfile_lock(ctx.read(podfile_lock_attr), lock_label)
    if not podfile.ok:
        fail_fn(podfile.error)
        return struct(macos = [], ios = [])

    matching_entries = _collect_matching_lock_entries(podfile, package_name)
    if matching_entries:
        spoke = struct(
            package_name = package_name,
            lock_label = lock_label,
            hub_name = "",
            podfile = podfile,
        )
        return _resolve_spoke_from_lock(ctx, matching_entries, spoke, apple, fail_fn)

    manifest_presence = struct(
        ios = ctx.path("ios/" + package_name + "/Package.swift").exists,
        darwin = ctx.path("darwin/" + package_name + "/Package.swift").exists,
        macos = ctx.path("macos/" + package_name + "/Package.swift").exists,
    )
    if apple.ios_srcs and not manifest_presence.ios and not manifest_presence.darwin:
        fail_fn(format_message_9(package_name, lock_label))
        return struct(macos = [], ios = [])

    return _mixed_mode_swiftpm_fallback(
        ctx,
        package_name,
        apple,
        detect_swiftpm_platform,
        manifest_presence,
    )
