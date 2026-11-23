"""What a `flutter.pub` hub adds to rules_dart's pub hub.

`flutter.pub` generates its hub with rules_dart's `pub_lock_hub`: one alias
per package (`@<hub>//:pkg` to `@<hub>__<pkg>//:<pkg>`, or to the merged
repository of a dependency cycle). This file renders what a Flutter hub adds
through that rule's `files`:

- `android/BUILD.bazel`, the `all_android_plugin_libs` aggregator of every
  spoke's `android:lib` (`flutter_android_app` does not use it: an app takes
  the Android libraries of the plugins its own Dart graph reaches; the
  aggregator stays for a caller that names it). Bazel parses it only when
  something names it, so a workspace without Android never loads
  `@rules_android` or `@rules_kotlin`.
- `scc/BUILD.bazel` and `scc/scc_android_edge.bzl`, for cycle members: under
  Android a member's alias carries the Android libraries of its cycle.
- `swift_package_sha256.json` and `ios_native_deps.json`, the SwiftPM checksum
  table and the native-dependency mappings a plugin spoke reads lazily, only
  once it finds a `Package.swift` or a pod it needs.
- `pub_packages.json`, the hub's package names and cycle members, which an
  Apple plugin spoke reads lazily to name a sibling plugin's library.
- `packages.bzl`, which a Flutter SDK package's BUILD file loads to keep the
  dependencies the lock pins (an SDK package's own pubspec is read only when
  its spoke is fetched, so its names cannot be planned).
"""

visibility(["//flutter/..."])

_ANDROID_EDGE_ATTR = (
    '    android_libs = select({"@platforms//os:android": ["//android:lib"], ' +
    '"//conditions:default": []}),\n'
)

def android_plugin_libs_arg(plugin_platforms_json):
    """The `android_libs` attribute line for an Android native or FFI plugin, or `""`.

    Federated umbrellas (`default_package` only) and pure-Dart Android
    implementations (`dartPluginClass` only, or `pluginClass: "none"`) ship no
    Android library and are not named in `GeneratedPluginRegistrant.java`, so
    they carry no edge; native (`pluginClass`) and FFI (`ffiPlugin`) plugins do.

    Args:
        plugin_platforms_json: JSON-encoded `flutter.plugin.platforms` dict.

    Returns:
        The indented `android_libs = select(...)` line, or `""`.
    """
    android = json.decode(plugin_platforms_json or "{}").get("android") or {}
    plugin_class = android.get("pluginClass", "")
    if (plugin_class and plugin_class != "none") or android.get("ffiPlugin") == True:
        return _ANDROID_EDGE_ATTR
    return ""

def overlay_with_android_edge(content, package_name):
    """Gives an overlay's `flutter_plugin` the same Android edge a generated one has.

    An overlay that already sets `android_libs`, or whose plugin call is not
    shaped `flutter_plugin(name = "<package>", ...)`, is returned untouched.

    Args:
        content: Rendered `BUILD.bazel` text of the overlay spoke.
        package_name: The pub package name whose `flutter_plugin` gains the edge.

    Returns:
        `content` with the `android_libs` `select()` inserted, or `content` unchanged.
    """
    head = 'flutter_plugin(\n    name = "%s",\n' % package_name
    if head not in content or "android_libs" in content:
        return content
    return content.replace(head, head + _ANDROID_EDGE_ATTR, 1)

def make_hub_scc_android_edge_bzl_content():
    """Renders `scc_android_edge.bzl` for a hub with merged SCC targets.

    Emitted only when `scc_targets` is non-empty. Loads only `@rules_dart` and
    `@rules_flutter` providers so non-Android workspaces never load
    `@rules_android` or `@rules_kotlin`.

    Returns:
        The Starlark source string for `scc_android_edge.bzl`.
    """
    return """\
\"\"\"Hub forwarding rule attaching Android plugin libraries to merged SCC targets.\"\"\"

load("@rules_dart//dart:providers.bzl", "DartAnalyzableInfo", "DartCodeAssetInfo", "DartInfo", "DartKernelInfo")
load("@rules_flutter//flutter:providers.bzl", "FlutterInfo")

def _flutter_pub_scc_android_edge_impl(ctx):
    \"\"\"Forwards Dart and Flutter providers from the merged SCC member target.\"\"\"
    dep = ctx.attr.deps[0]
    providers = [
        DefaultInfo(
            files = dep[DefaultInfo].files,
            runfiles = dep[DefaultInfo].default_runfiles,
        ),
        dep[DartInfo],
    ]
    for p in (DartAnalyzableInfo, DartCodeAssetInfo, DartKernelInfo, FlutterInfo):
        if p in dep:
            providers.append(dep[p])
    return providers

flutter_pub_scc_android_edge = rule(
    implementation = _flutter_pub_scc_android_edge_impl,
    attrs = {
        "deps": attr.label_list(
            mandatory = True,
            providers = [DartInfo],
            doc = "Single-element list naming the merged SCC member target.",
        ),
        "android_libs": attr.label_list(
            default = [],
            doc = "Android plugin libraries across the SCC's members.",
        ),
        "srcs_dir": attr.string(
            default = ".",
            doc = "Marks multi-package SCC targets opaque to modular kernel compilation.",
        ),
    },
    doc = "Attaches an SCC's Android plugin libraries under Android while forwarding Dart/Flutter providers.",
)
"""

def _scc_members_by_repo(merged_members):
    """Groups non-`test` cycle members by their merged repository name."""
    by_repo = {}
    for member in sorted(merged_members):
        if member == "test":
            continue
        by_repo.setdefault(merged_members[member], []).append(member)
    return by_repo

def hub_scc_targets(merged_members):
    """Where the hub's alias of each cycle member points.

    A member of a cycle that holds another member besides `test` aliases to
    `//scc:<pkg>` in the hub, whose Android-only `select()` adds the cycle's
    Android libraries; `test` and the members of a cycle with no other
    member alias to the merged repository directly.

    Args:
        merged_members: Mapping of cycle member to its merged repository name.

    Returns:
        Mapping of member to the label its hub alias names (`//scc:<pkg>`
        names the hub's own package).
    """
    by_repo = _scc_members_by_repo(merged_members)
    targets = {}
    for member in sorted(merged_members):
        repo = merged_members[member]
        if member != "test" and by_repo.get(repo):
            targets[member] = "//scc:" + member
        else:
            targets[member] = "@{repo}//:{pkg}".format(repo = repo, pkg = member)
    return targets

def make_hub_scc_build_content(merged_members):
    """Renders the hub's `scc/BUILD.bazel` for its cycle members, or `""`.

    Args:
        merged_members: Mapping of cycle member to its merged repository name.

    Returns:
        The BUILD text, or `""` when no member gets an Android edge.
    """
    by_repo = _scc_members_by_repo(merged_members)
    entries = []
    for member in sorted(merged_members):
        repo = merged_members[member]
        repo_members = by_repo.get(repo, [])
        if member == "test" or not repo_members:
            continue
        libs = "\n".join([
            '            "@{repo}//{m}/android:lib",'.format(repo = repo, m = m)
            for m in repo_members
        ])
        entries.append("""\
flutter_pub_scc_android_edge(
    name = "_scc_android_{pkg}",
    android_libs = select({{
        "@platforms//os:android": [
{libs}
        ],
        "//conditions:default": [],
    }}),
    tags = ["manual"],
    deps = ["@{repo}//:{pkg}"],
)

alias(
    name = "{pkg}",
    actual = select({{
        "@platforms//os:android": ":_scc_android_{pkg}",
        "//conditions:default": "@{repo}//:{pkg}",
    }}),
    visibility = ["//visibility:public"],
)""".format(pkg = member, repo = repo, libs = libs))
    if not entries:
        return ""
    return 'load(":scc_android_edge.bzl", "flutter_pub_scc_android_edge")\n\n' + "\n\n".join(entries) + "\n"

def make_flutter_pub_hub_android_build_content(packages, spoke_prefix, scc_targets = {}):
    """Renders `android/BUILD.bazel` for a `flutter_pub_lock_hub` repo.

    Args:
        packages: Sorted package names in the lock.
        spoke_prefix: Prefix for single-package spoke repository names.
        scc_targets: Mapping `package -> "@<scc_repo>//:<package>"` for cycle
            members. Cycle members export `@<scc_repo>//<pkg>/android:lib`.

    Returns:
        The generated `android/BUILD.bazel` text.
    """
    android_deps = []
    for pkg in packages:
        if pkg in scc_targets:
            scc_repo = scc_targets[pkg].partition("//:")[0]
            android_deps.append('"{repo}//{pkg}/android:lib"'.format(
                repo = scc_repo,
                pkg = pkg,
            ))
        else:
            android_deps.append('"@{spoke}__{pkg}//android:lib"'.format(
                spoke = spoke_prefix,
                pkg = pkg,
            ))
    deps_block = ",\n        ".join(android_deps)
    if deps_block:
        deps_block = "\n        " + deps_block + ",\n    "

    return """\
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

# Aggregator — re-exports every spoke's `android:lib`. Spokes without
# Android sources contribute empty libraries (a no-op at link time).
# `flutter_android_app` does not add it: an app takes only the Android
# libraries of the plugins its Dart graph reaches. A caller may name it
# in `deps` to package every plugin in the lock.
#
# `exports = [...]` (rather than `deps = [...]`) is required by
# rules_android: a `kt_android_library` without `srcs` or
# `resource_files` may not declare `deps` directly — the supported way
# to forward dependencies is `exports`.
kt_android_library(
    name = "all_android_plugin_libs",
    srcs = [],
    visibility = ["//visibility:public"],
    exports = [{deps}],
)
""".format(deps = deps_block)

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

def flutter_pub_hub_files(hub_name, packages, merged_members, swift_package_sha256, ios_native_deps):
    """Every file a Flutter hub adds to rules_dart's hub (`pub_lock_hub(files = ...)`).

    Args:
        hub_name: The hub's repository name.
        packages: The hub's package names.
        merged_members: Mapping of cycle member to its merged repository name.
        swift_package_sha256: The tag's SwiftPM checksum table.
        ios_native_deps: The rendered `ios_native_deps.json`.

    Returns:
        Dict of hub-relative path to content.
    """
    scc_targets = {m: "@{repo}//:{m}".format(repo = merged_members[m], m = m) for m in merged_members}
    files = {
        "android/BUILD.bazel": make_flutter_pub_hub_android_build_content(sorted(packages), hub_name, scc_targets),
        "ios_native_deps.json": ios_native_deps,
        "packages.bzl": hub_packages_bzl_content(hub_name, packages),
        "pub_packages.json": hub_pub_packages_json(packages, merged_members),
        "swift_package_sha256.json": json.encode(swift_package_sha256),
    }
    scc_build = make_hub_scc_build_content(merged_members)
    if scc_build:
        files["scc/BUILD.bazel"] = scc_build
        files["scc/scc_android_edge.bzl"] = make_hub_scc_android_edge_bzl_content()
    return files
