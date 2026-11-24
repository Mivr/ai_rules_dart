"""Which repositories are `flutter.pub` hubs, so an app finds its lock's packages.

An app whose `deps` name packages of a `flutter.pub` hub bundles with every
package of that hub's lock in the package config, as `pub get` writes it, so
its `NOTICES` holds every package's licence, dev dependencies' too. The app's
rule reads `@flutter_pub_hubs//:hubs.bzl` (`PUB_HUBS`: each hub's canonical
repository name to a `packages` target) in a computed default of its `deps`
(`hub_packages_of` in `flutter_bundle.bzl`); `pub_packages` overrides it.

Hubs that read the same lock (an iOS plugin mode's twin, say) hold the same
Dart packages and differ only in their plugins' native parts, which neither
the package config nor `NOTICES` reads; each maps to the `packages` target of
the first hub declared with that lock, so a twin never fetches its own
plugins' repositories for a bundle.
"""

visibility(["//flutter/..."])

def _flutter_pub_hubs_impl(rctx):
    entries = [
        '    Label("@{hub}//packages").repo_name: Label("@{lock_hub}//packages"),'.format(hub = hub, lock_hub = lock_hub)
        for hub, lock_hub in sorted(rctx.attr.hubs.items())
    ]
    rctx.file("hubs.bzl", "\n".join([
        '"""Each `flutter.pub` hub\'s canonical repository name, to its `packages` target."""',
        "",
        "PUB_HUBS = {",
    ] + entries + ["}", ""]))
    rctx.file("BUILD.bazel", """\
load("@bazel_skylib//:bzl_library.bzl", "bzl_library")

bzl_library(
    name = "hubs",
    srcs = ["hubs.bzl"],
    visibility = ["//visibility:public"],
)
""")

flutter_pub_hubs = repository_rule(
    implementation = _flutter_pub_hubs_impl,
    doc = "`hubs.bzl`: the `flutter.pub` hubs of the module graph, by canonical repository name.",
    attrs = {
        "hubs": attr.string_dict(doc = "Each hub's name, to the name of the first hub declared with the same lock."),
    },
)

def register_pub_hubs_index(module_ctx):
    """Declares `flutter_pub_hubs`, naming every `flutter.pub` hub of the module graph and its lock's first hub.

    Args:
      module_ctx: The `flutter` extension's context.
    """
    hubs = {}
    for mod in module_ctx.modules:
        first = {}
        for tag in mod.tags.pub:
            lock = str(tag.lock)
            first.setdefault(lock, tag.name)
            hubs.setdefault(tag.name, first[lock])
    flutter_pub_hubs(name = "flutter_pub_hubs", hubs = hubs)
