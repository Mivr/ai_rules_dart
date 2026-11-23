"""Hub repository rule for pubspec.lock packages.

Generates a BUILD file with aliases from each package name to its
repository: a one-package spoke (`@hub__pkg//:pkg`), an explicit
`pub.package()` repository (`@pkg//:pkg`), or — for a package merged over a
dependency cycle — the merged repository holding the whole cycle. A package
also declared with `pub.package()` aliases to that explicit repository
instead, `@pkg//:pkg`, which is the one repository the name means in this
build.
"""

visibility(["//dart/..."])

def pub_lock_hub_content(packages, explicit_packages, spoke_prefix, scc_targets = {}):
    """Generates the hub BUILD file content, as a string.

    Pure so the alias layout for acyclic graphs can be pinned byte-for-byte:
    when no package is merged (`scc_targets` empty), the output is exactly
    what the hub has always generated.

    Args:
      packages: All hosted package names to create aliases for.
      explicit_packages: Names in `packages` that are also declared with
        `pub.package()`. Each aliases to that explicit repository rather
        than a spoke.
      spoke_prefix: Prefix for spoke repo names.
      scc_targets: Dict of package name to the merged repository target a
        cycle member aliases to. Empty when nothing is merged.

    Returns:
      BUILD.bazel content as a string.
    """
    explicit = {pkg: True for pkg in explicit_packages}
    aliases = []
    for pkg in packages:
        if pkg in scc_targets:
            actual = scc_targets[pkg]
        elif pkg in explicit:
            actual = "@{pkg}//:{pkg}".format(pkg = pkg)
        else:
            actual = "@{spoke}__{pkg}//:{pkg}".format(spoke = spoke_prefix, pkg = pkg)
        aliases.append("""\
alias(
    name = "{pkg}",
    actual = "{actual}",
    visibility = ["//visibility:public"],
)""".format(
            pkg = pkg,
            actual = actual,
        ))
    return "\n\n".join(aliases) + "\n"

def hub_files_error(files):
    """Validates a hub's extra files before any is written.

    Args:
      files: Dict of repository-relative path to file content.

    Returns:
      An error naming the first path that is not a plain relative path inside
      the hub, or that would replace the hub's own `BUILD.bazel`, else None.
    """
    for path in sorted(files.keys()):
        parts = path.split("/")
        if path in ("BUILD.bazel", "BUILD", "REPO.bazel", "WORKSPACE") or path.startswith("/") or "" in parts or "." in parts or ".." in parts or "\\" in path:
            return "pub_lock_hub: extra file %r is not a relative path inside the hub, or replaces the hub's own BUILD file" % path
    return None

def _pub_lock_hub_impl(ctx):
    spoke_prefix = ctx.attr.spoke_prefix if ctx.attr.spoke_prefix else ctx.attr.hub_name
    err = hub_files_error(ctx.attr.files)
    if err:
        fail(err)
    for path in sorted(ctx.attr.files.keys()):
        ctx.file(path, ctx.attr.files[path], executable = False)
    ctx.file("BUILD.bazel", pub_lock_hub_content(
        ctx.attr.packages,
        ctx.attr.explicit_packages,
        spoke_prefix,
        ctx.attr.scc_targets,
    ))
    return ctx.repo_metadata(reproducible = True)

pub_lock_hub = repository_rule(
    implementation = _pub_lock_hub_impl,
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
            doc = "All hosted package names to create aliases for.",
            mandatory = True,
        ),
        "explicit_packages": attr.string_list(
            doc = "Names in `packages` that are also declared with `pub.package()`. " +
                  "Each aliases to that explicit repository rather than a spoke.",
            default = [],
        ),
        "scc_targets": attr.string_dict(
            doc = "Package name to merged repository target, for packages merged over a dependency cycle. " +
                  "Each aliases to the merged target instead of a spoke. Empty when nothing is merged.",
            default = {},
        ),
        "files": attr.string_dict(
            doc = "Extra files written into the hub, as relative path to content: what a " +
                  "rule set built on this hub adds next to the package aliases (a BUILD " +
                  "file in a subdirectory, a `.bzl` or JSON file its package repositories " +
                  "read). It cannot replace the hub's own `BUILD.bazel`. Empty by default.",
            default = {},
        ),
    },
    doc = "Creates a hub repo with aliases pointing to individual spoke package repos.",
)
