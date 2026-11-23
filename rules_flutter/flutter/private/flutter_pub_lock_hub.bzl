"""Augmented hub repo rule for Flutter pub lock files.

Mirrors `rules_dart//dart/pub:pub_lock_hub.bzl`'s top-level alias
structure (`@<hub>//:pkg` → `@<hub>__<pkg>//:<pkg>`) and additionally
emits an `android/BUILD.bazel` containing the
`all_android_plugin_libs` aggregator, plus
`swift_package_sha256.json` with the hub's SwiftPM checksum table and
`ios_native_deps.json` with the hub's SwiftPM product mapping. The
aggregator is a `kt_android_library` whose deps are every spoke's
`android:lib` target (see `flutter_pub_package`'s
`make_android_subpackage_build_content`). A plugin pub spoke reads the
checksum table lazily, only after finding its own `Package.swift`.

`flutter_android_app` does not use the aggregator: an app compiles the Android
library of each plugin in its own transitive Dart dependencies, which each
plugin's Dart target names. The aggregator stays for a caller that names it.
Spokes without Android sources contribute an empty `:lib` (a no-op at link
time) so the aggregator's deps list is mechanical.

Loaded lazily — Bazel only parses `android/BUILD.bazel` when something
queries the aggregator. Non-Android workspaces (mac-only, web-only)
don't pay the `@rules_android` / `@rules_kotlin` cost.

This rule is the rules_flutter sibling of rules_dart's `pub_lock_hub`;
the two never run for the same hub. `flutter.pub()` always invokes
this one. `pub.pub()` (in non-Flutter modules) keeps using
`pub_lock_hub`.
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

def hub_scc_dep_targets(hub_name, scc_targets):
    """Maps each SCC member package to its `@<hub>//:<pkg>` hub target.

    Singleton pub spokes route dependencies on cycle members through the hub so
    an Android build traverses the hub's `@platforms//os:android` plugin edge.

    Args:
        hub_name: Apparent name of the hub repository.
        scc_targets: Mapping `package -> "@<scc_repo>//:<package>"` for cycle members.

    Returns:
        Mapping `package -> "@<hub>//:<package>"`, or `{}` when `scc_targets` is empty.
    """
    return {
        pkg: "@{hub}//:{pkg}".format(hub = hub_name, pkg = pkg)
        for pkg in scc_targets
    }

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

def _scc_members_by_repo(scc_targets):
    """Groups non-`test` SCC member package names by their merged `@<scc_repo>` prefix."""
    by_repo = {}
    for member in sorted(scc_targets):
        if member == "test":
            continue
        repo = scc_targets[member].partition("//:")[0]
        by_repo.setdefault(repo, []).append(member)
    return by_repo

def _render_scc_hub_entry(pkg, actual, repo_members):
    """Renders the Android edge target and `select()` alias for one SCC member `pkg`."""
    scc_repo = actual.partition("//:")[0]
    lib_lines = [
        '            "{repo}//{m}/android:lib",'.format(repo = scc_repo, m = m)
        for m in repo_members
    ]
    libs_block = "\n".join(lib_lines)
    return """\
flutter_pub_scc_android_edge(
    name = "_scc_android_{pkg}",
    android_libs = select({{
        "@platforms//os:android": [
{libs}
        ],
        "//conditions:default": [],
    }}),
    tags = ["manual"],
    deps = ["{actual}"],
)

alias(
    name = "{pkg}",
    actual = select({{
        "@platforms//os:android": ":_scc_android_{pkg}",
        "//conditions:default": "{actual}",
    }}),
    visibility = ["//visibility:public"],
)""".format(
        pkg = pkg,
        actual = actual,
        libs = libs_block,
    )

def make_flutter_pub_hub_build_content(packages, spoke_prefix, scc_targets = {}):
    """Renders the root `BUILD.bazel` aliases for a `flutter_pub_lock_hub` repo.

    Args:
        packages: Sorted package names in the lock.
        spoke_prefix: Prefix for single-package spoke repository names.
        scc_targets: Mapping `package -> "@<scc_repo>//:<package>"` for cycle
            members. Empty produces byte-identical output to acyclic hubs.

    Returns:
        The generated `BUILD.bazel` text.
    """
    by_repo = _scc_members_by_repo(scc_targets)
    has_scc_edges = False
    entries = []
    for pkg in packages:
        if pkg in scc_targets and pkg != "test":
            actual = scc_targets[pkg]
            scc_repo = actual.partition("//:")[0]
            repo_members = by_repo.get(scc_repo, [])
            if repo_members:
                has_scc_edges = True
                entries.append(_render_scc_hub_entry(pkg, actual, repo_members))
                continue
        actual = scc_targets[pkg] if pkg in scc_targets else "@{spoke}__{pkg}//:{pkg}".format(
            spoke = spoke_prefix,
            pkg = pkg,
        )
        entries.append("""\
alias(
    name = "{pkg}",
    actual = "{actual}",
    visibility = ["//visibility:public"],
)""".format(
            pkg = pkg,
            actual = actual,
        ))
    header = 'load(":scc_android_edge.bzl", "flutter_pub_scc_android_edge")\n\n' if has_scc_edges else ""
    return header + "\n\n".join(entries) + "\n"

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

def _flutter_pub_lock_hub_impl(ctx):
    """Emits the Flutter pub hub BUILD aliases, Android aggregator, and native-dep JSON files."""
    spoke_prefix = ctx.attr.spoke_prefix if ctx.attr.spoke_prefix else ctx.attr.hub_name
    scc_targets = ctx.attr.scc_targets

    # SwiftPM checksum state for the pub spokes: a plugin spoke reads this
    # file (and only this file) after it finds its own `Package.swift`, so
    # the checksum table never reaches a pure-Dart spoke's attributes.
    ctx.file("swift_package_sha256.json", json.encode(ctx.attr.swift_package_sha256))

    # SwiftPM product mappings and CocoaPods pod resolutions for the pub
    # spokes. Each label is already canonical (the extension serialised it
    # from the module that wrote the tag), so a spoke's generated BUILD file
    # can name it directly. Keys are sorted so the output is deterministic.
    product_deps = {}
    for key in sorted(ctx.attr.swift_package_product_deps):
        product_deps[key] = ctx.attr.swift_package_product_deps[key]

    ios_pod_deps = {}
    for key in sorted(ctx.attr.ios_pod_deps):
        ios_pod_deps[key] = ctx.attr.ios_pod_deps[key]

    ios_pod_ignore = sorted(ctx.attr.ios_pod_ignore)

    ios_pods_raw = json.decode(ctx.attr.ios_pods) if ctx.attr.ios_pods else {}
    ios_pods = {}
    for key in sorted(ios_pods_raw):
        ios_pods[key] = ios_pods_raw[key]

    ctx.file(
        "ios_native_deps.json",
        json.encode({
            "ios_pod_deps": ios_pod_deps,
            "ios_pod_ignore": ios_pod_ignore,
            "ios_pods": ios_pods,
            "swift_package_product_deps": product_deps,
            "version": 1,
        }),
    )

    if scc_targets:
        ctx.file("scc_android_edge.bzl", make_hub_scc_android_edge_bzl_content())
    ctx.file(
        "BUILD.bazel",
        make_flutter_pub_hub_build_content(ctx.attr.packages, spoke_prefix, scc_targets),
    )
    ctx.file(
        "android/BUILD.bazel",
        make_flutter_pub_hub_android_build_content(ctx.attr.packages, spoke_prefix, scc_targets),
    )
    return ctx.repo_metadata(reproducible = True)

flutter_pub_lock_hub = repository_rule(
    implementation = _flutter_pub_lock_hub_impl,
    attrs = {
        "hub_name": attr.string(
            doc = "The apparent name of this hub repo (for constructing spoke labels).",
            mandatory = True,
        ),
        "spoke_prefix": attr.string(
            doc = "Prefix for spoke repo names. If empty, defaults to hub_name.",
            default = "",
        ),
        "packages": attr.string_list(
            doc = "All hosted package names to create aliases and Android-aggregator deps for.",
            mandatory = True,
        ),
        "scc_targets": attr.string_dict(
            doc = "Package name to merged repository target, for dependencies on cycle members.",
            default = {},
        ),
        "swift_package_sha256": attr.string_dict(
            doc = "The hub's `swift_package_sha256` map, written to " +
                  "`swift_package_sha256.json` for a plugin spoke that links " +
                  "a SwiftPM pin. Reading is lazy: a pure-Dart spoke never " +
                  "reads the file, so its marker stays independent of it.",
            default = {},
        ),
        "swift_package_product_deps": attr.string_dict(
            doc = "Canonical labels for the hub's `swift_package_product_deps` " +
                  "map, written to `ios_native_deps.json` for a plugin spoke " +
                  "that links a SwiftPM product. Reading is lazy: a spoke " +
                  "without a product dependency never reads the file, so its " +
                  "marker stays independent of it.",
            default = {},
        ),
        "ios_pod_deps": attr.string_dict(
            doc = "Canonical labels for CocoaPods pod mapping.",
            default = {},
        ),
        "ios_pod_ignore": attr.string_list(
            doc = "Pod names to drop.",
            default = [],
        ),
        "ios_pods": attr.string(
            doc = "JSON-encoded precomputed pod resolution mapping.",
            default = "{}",
        ),
    },
    doc = "Creates a Flutter pub hub repo with both the standard top-level package aliases " +
          "and an `android/all_android_plugin_libs` aggregator that a caller may name. The " +
          "aggregator pulls in every spoke's `android:lib`; `flutter_android_app` selects " +
          "its plugins from the app's Dart dependencies instead.",
)
