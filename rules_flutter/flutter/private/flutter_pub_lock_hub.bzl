"""What a `flutter.pub` hub adds to rules_dart's pub hub.

`flutter.pub` generates its hub with rules_dart's `pub_lock_hub`: one alias
per package (`@<hub>//:pkg` to `@<hub>__<pkg>//:<pkg>`, or to the merged
repository of a dependency cycle). This file renders what a Flutter hub adds
through that rule's `files`:

- `swift_package_sha256.json` and `ios_native_deps.json`, the SwiftPM checksum
  table and the native-dependency mappings a plugin spoke reads lazily, only
  once it finds a `Package.swift` or a pod it needs.
- `pub_packages.json`, the hub's package names and cycle members, which an
  Apple plugin spoke reads lazily to name a sibling plugin's library.
- `packages.bzl`, which a Flutter SDK package's BUILD file loads to keep the
  dependencies the lock pins (an SDK package's own pubspec is read only when
  its spoke is fetched, so its names cannot be planned).
"""

load("@rules_dart//dart/pub:pub_plan.bzl", "package_graph_json")

visibility(["//flutter/..."])

def hub_scc_targets(merged_members):
    """Where the hub's alias of each cycle member points: the merged repository of its cycle.

    Args:
        merged_members: Mapping of cycle member to its merged repository name.

    Returns:
        Mapping of member to the label its hub alias names.
    """
    return {
        member: "@{repo}//:{pkg}".format(repo = merged_members[member], pkg = member)
        for member in sorted(merged_members)
    }

def ios_native_deps_json(swift_package_product_deps, ios_pod_deps, ios_pod_ignore, ios_pods_json):
    """Renders the hub's `ios_native_deps.json`.

    Each label is already canonical (the extension serialised it from the
    module that wrote the tag), so a spoke's generated BUILD file can name it
    directly. Keys are sorted so the output is deterministic.

    Args:
        swift_package_product_deps: `<identity>:<product>` to canonical label.
        ios_pod_deps: Pod name to canonical label.
        ios_pod_ignore: Pod names to drop.
        ios_pods_json: JSON-encoded precomputed pod resolution mapping.

    Returns:
        The file content.
    """
    ios_pods_raw = json.decode(ios_pods_json) if ios_pods_json else {}
    return json.encode({
        "ios_pod_deps": {key: ios_pod_deps[key] for key in sorted(ios_pod_deps)},
        "ios_pod_ignore": sorted(ios_pod_ignore),
        "ios_pods": {key: ios_pods_raw[key] for key in sorted(ios_pods_raw)},
        "swift_package_product_deps": {key: swift_package_product_deps[key] for key in sorted(swift_package_product_deps)},
        "version": 1,
    })

def hub_packages_bzl_content(hub_name, packages):
    """Renders the hub's `packages.bzl`, which an SDK package's BUILD file loads.

    Args:
        hub_name: The hub's repository name, for the docstring.
        packages: The hub's package names.

    Returns:
        The `.bzl` text: `hub_deps(names)` keeps the names the hub holds,
        as labels of its aliases.
    """
    return """\
\"\"\"The packages of the `{hub}` hub, for the Flutter SDK packages' BUILD files.\"\"\"

_PACKAGES = {{name: True for name in {packages}}}

def hub_deps(names):
    \"\"\"Labels of the hub's aliases for the names it holds; other names are dropped.

    Args:
        names: Dependency names from an SDK package's pubspec.

    Returns:
        The labels, in the order given.
    \"\"\"
    return [Label("//:" + name) for name in names if name in _PACKAGES]
""".format(hub = hub_name, packages = repr(sorted(packages)))

def hub_pub_packages_json(packages, merged_members):
    """Renders the hub's `pub_packages.json`, read lazily by Apple plugin spokes.

    Args:
        packages: The hub's package names.
        merged_members: Mapping of cycle member to its merged repository name.

    Returns:
        The file content: `packages` and `scc_targets` (member to
        `@<merged repository>//:<member>`).
    """
    return json.encode({
        "packages": sorted(packages),
        "scc_targets": {m: "@{repo}//:{m}".format(repo = merged_members[m], m = m) for m in sorted(merged_members)},
    })

def read_hub_pub_packages(ctx):
    """Reads the hub's `pub_packages.json` through the spoke's `hub_packages` label.

    Call it only on the path that needs the hub's package names: reading the
    file makes the spoke depend on every package the hub holds.

    Args:
        ctx: The spoke's repository context (or a member facade carrying
            `attr.hub_packages` and `read`).

    Returns:
        `struct(packages, scc_targets)`; empty when the spoke has no hub.
    """
    label = getattr(ctx.attr, "hub_packages", None)
    if label == None:
        return struct(packages = [], scc_targets = {})
    data = json.decode(ctx.read(label))
    return struct(packages = data["packages"], scc_targets = data["scc_targets"])

def hub_package_finder(ctx):
    """How a spoke finds another package of its hub by name, from its own slice of the plan first.

    A spoke's own planned dependencies (`planned_deps`) and those of them in a
    dependency cycle (`cycle_deps`, each to its merged repository) answer
    without reading anything. Only a name outside them reads the hub's
    `pub_packages.json` (`read_hub_pub_packages`), once: so a plugin that
    names only its own dependencies does not depend on every package of the
    lock, and is not fetched again when another package is added. A member
    of a merged cycle has no `cycle_deps` and always reads the hub's list.

    Args:
        ctx: The spoke's repository context (or a member facade).

    Returns:
        A function of a package name (matched without regard to case) that
        returns `struct(name, scc_target)` (the name as the lock spells it,
        and `@<merged repository>//:<name>` for a cycle member, else None),
        or None when the hub's lock has no such package.
    """
    own = getattr(ctx.attr, "planned_deps", None) if hasattr(ctx.attr, "cycle_deps") else None
    cycles = getattr(ctx.attr, "cycle_deps", {})
    read = {}

    def find(name):
        lowered = name.lower()
        for dep in own or []:
            if dep.lower() == lowered:
                repo = cycles.get(dep)
                return struct(name = dep, scc_target = "@%s//:%s" % (repo, dep) if repo else None)
        if "hub" not in read:
            read["hub"] = read_hub_pub_packages(ctx)
        hub = read["hub"]
        for locked in hub.packages:
            if locked.lower() == lowered:
                return struct(name = locked, scc_target = hub.scc_targets.get(locked))
        return None

    return find

def hub_lock_packages_build_content(packages):
    """Renders the hub's `packages/BUILD.bazel`: every package of the lock as one target.

    An app's `pub_packages` (by default the hub its `deps` come from) names
    it, so the package config its asset bundle reads lists every package
    `pub get` would list, dev dependencies too, as the licences in `NOTICES`
    need, and the bundle reads the lock's package graph beside it.

    Args:
        packages: The hub's package names.

    Returns:
        The BUILD file text.
    """
    deps = "".join(['        "//:%s",\n' % name for name in sorted(packages)])
    return """\
load("@rules_flutter//flutter:defs.bzl", "flutter_pub_packages")

flutter_pub_packages(
    name = "packages",
    package_graph = "package_graph.json",
    deps = [
{deps}    ],
    visibility = ["//visibility:public"],
)
""".format(deps = deps)

def hub_package_graph(versions, planned):
    """The lock's package graph, for the hub's `packages/package_graph.json`.

    Holds the packages whose dependencies the lock's plan knows (hosted, git
    and path ones); the asset tool adds the project's own package and reads
    the Flutter SDK's packages from their pubspecs.

    Args:
        versions: Package name to its locked version, for the planned packages.
        planned: Package name to its planned dependency names.

    Returns:
        The JSON text.
    """
    return package_graph_json(versions, {name: planned.get(name, []) for name in versions})

def flutter_pub_hub_files(hub_name, packages, merged_members, swift_package_sha256, ios_native_deps, package_graph = None):
    """Every file a Flutter hub adds to rules_dart's hub (`pub_lock_hub(files = ...)`).

    Args:
        hub_name: The hub's repository name.
        packages: The hub's package names.
        merged_members: Mapping of cycle member to its merged repository name.
        swift_package_sha256: The tag's SwiftPM checksum table.
        ios_native_deps: The rendered `ios_native_deps.json`.
        package_graph: The rendered `packages/package_graph.json` (`hub_package_graph`).

    Returns:
        Dict of hub-relative path to content.
    """
    return {
        "packages/BUILD.bazel": hub_lock_packages_build_content(packages),
        "packages/package_graph.json": package_graph or hub_package_graph({}, {}),
        "ios_native_deps.json": ios_native_deps,
        "packages.bzl": hub_packages_bzl_content(hub_name, packages),
        "pub_packages.json": hub_pub_packages_json(packages, merged_members),
        "swift_package_sha256.json": json.encode(swift_package_sha256),
    }
