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

The default follows the project first. `PUB_HUBS_BY_PACKAGE` maps each
package of the main repository that holds the lock of a root-module hub to
that hub's `packages`. The app, test and web macros look up their own package
and then each enclosing one (a pub workspace member under its root's lock),
and set `pub_packages` from the nearest (`project_pub_packages` in
`flutter_bundle.bzl`). Only when no package on the way holds a lock does the
first dependency's hub apply. Hubs of one lock in one package (twins) give
the first declared. A package holding the locks of two different files maps
to None: its targets fall back to the first dependency's hub, as the package
alone cannot say which lock they build with.
"""

visibility(["//flutter/..."])

def _flutter_pub_hubs_impl(rctx):
    entries = [
        '    Label("@{hub}//packages").repo_name: Label("@{lock_hub}//packages"),'.format(hub = hub, lock_hub = lock_hub)
        for hub, lock_hub in sorted(rctx.attr.hubs.items())
    ]
    by_package = [
        "    %r: %s," % (package, 'Label("@%s//packages")' % hub if hub else "None")
        for package, hub in sorted(rctx.attr.by_package.items())
    ]
    rctx.file("hubs.bzl", "\n".join([
        '"""Each `flutter.pub` hub\'s canonical repository name, to its `packages` target;',
        "each package of the main repository holding a hub's lock, to that hub's `packages`",
        '(None: the locks of two different files)."""',
        "",
        "PUB_HUBS = {",
    ] + entries + ["}", "", "PUB_HUBS_BY_PACKAGE = {"] + by_package + ["}", ""]))
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
        "by_package": attr.string_dict(doc = "Each main-repository package holding a root-module hub's lock, to the first hub declared with it; \"\" for a package holding two different locks."),
    },
)

def register_pub_hubs_index(module_ctx):
    """Declares `flutter_pub_hubs`, naming every `flutter.pub` hub of the module graph and its lock's first hub.

    Args:
      module_ctx: The `flutter` extension's context.
    """
    hubs = {}
    by_package = {}
    lock_of_package = {}
    for mod in module_ctx.modules:
        first = {}
        for tag in mod.tags.pub:
            lock = str(tag.lock)
            first.setdefault(lock, tag.name)
            hubs.setdefault(tag.name, first[lock])
            if not mod.is_root or tag.lock.repo_name != "":
                continue
            package = tag.lock.package
            if package not in lock_of_package:
                lock_of_package[package] = lock
                by_package[package] = first[lock]
            elif lock_of_package[package] != lock:
                by_package[package] = ""
    flutter_pub_hubs(name = "flutter_pub_hubs", hubs = hubs, by_package = by_package)
