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

# The generic runner's sources, copied into the hub's `build_runner` package
# so they compile there against the hub's own lock.
_RUNNER_SOURCES = {
    "build_runner/bin/gen_entry.dart": Label("//dart/build_runner:runner/bin/gen_entry.dart"),
    "build_runner/lib/declared_paths.dart": Label("//dart/build_runner:runner/declared_paths.dart"),
    "build_runner/lib/runner.dart": Label("//dart/build_runner:runner/lib/runner.dart"),
}

def pub_lock_hub_build_runner_content(hub_name, build_runner_version, builder_packages):
    """The hub's `build_runner/BUILD.bazel`, as a string.

    Args:
      hub_name: The hub's name, for messages.
      build_runner_version: The locked `build_runner` version, or "".
      builder_packages: Dict of package name to the label of its `build.yaml`
        file group, for the packages that may define builders.

    Returns:
      BUILD.bazel content as a string.
    """
    lines = ['        "{}": "{}",'.format(name, builder_packages[name]) for name in sorted(builder_packages.keys())]
    return """\
load("@rules_dart//dart/build_runner/private:build_runner.bzl", "build_runner_targets")

# The generic build_runner runner, compiled from this hub's lock with every
# package of it that may define builders. `dart_build_runner(runner = ...)`
# names `:build_runner`.
build_runner_targets(
    name = "build_runner",
    hub = "{hub}",
    version = "{version}",
    builder_packages = {{
{lines}
    }},
)
""".format(hub = hub_name, version = build_runner_version, lines = "\n".join(lines))

_UNAVAILABLE_BZL = str(Label("//dart/pub/private:pub_unavailable.bzl"))

def pub_lock_hub_content(packages, explicit_packages, spoke_prefix, scc_targets = {}, local_targets = {}, unavailable = {}):
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
      local_targets: Dict of package name to the label of a target in a
        module that serves it (a `path` package's `dart_library`).
      unavailable: Dict of package name to the message of a target that
        fails when used (a package this hub cannot build).

    Returns:
      BUILD.bazel content as a string.
    """
    explicit = {pkg: True for pkg in explicit_packages}
    aliases = []
    for pkg in packages:
        if pkg in unavailable:
            aliases.append("""\
pub_unavailable_package(
    name = "{pkg}",
    message = {message},
    visibility = ["//visibility:public"],
)""".format(pkg = pkg, message = json.encode(unavailable[pkg])))
            continue
        if pkg in local_targets:
            actual = local_targets[pkg]
        elif pkg in scc_targets:
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
    header = 'load("%s", "pub_unavailable_package")\n\n' % _UNAVAILABLE_BZL if unavailable else ""
    return header + "\n\n".join(aliases) + "\n"

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
    content = pub_lock_hub_content(
        ctx.attr.packages,
        ctx.attr.explicit_packages,
        spoke_prefix,
        ctx.attr.scc_targets,
        ctx.attr.local_targets,
        ctx.attr.unavailable,
    )
    if ctx.attr.package_graph:
        ctx.file("package_graph.json", ctx.attr.package_graph)
        content += """
exports_files(
    ["package_graph.json"],
    visibility = ["//visibility:public"],
)
"""
        ctx.file("build_runner/BUILD.bazel", pub_lock_hub_build_runner_content(
            ctx.attr.hub_name,
            ctx.attr.build_runner_version,
            ctx.attr.builder_packages,
        ))
        for path, label in _RUNNER_SOURCES.items():
            # A copy, not a symlink: a repository that links to files outside
            # itself is not shared through the repository contents cache.
            ctx.file(path, ctx.read(label), executable = False)
    ctx.file("BUILD.bazel", content)
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
        "package_graph": attr.string(
            doc = "The lock's package graph as JSON, in the shape of pub's `.dart_tool/package_graph.json`: " +
                  "every package of the lock with its version and dependencies. Written to `package_graph.json` " +
                  "with the hub's `build_runner` package. Empty writes neither.",
            default = "",
        ),
        "build_runner_version": attr.string(
            doc = "The locked `build_runner` version, or empty when the lock has none.",
            default = "",
        ),
        "builder_packages": attr.string_dict(
            doc = "Package name to the label of its `build.yaml` file group, for every package of the lock " +
                  "that may define builders. The hub's runner is compiled with them.",
            default = {},
        ),
        "scc_targets": attr.string_dict(
            doc = "Package name to merged repository target, for packages merged over a dependency cycle. " +
                  "Each aliases to the merged target instead of a spoke. Empty when nothing is merged.",
            default = {},
        ),
        "local_targets": attr.string_dict(
            doc = "Package name to the label of a target in a module that serves it: the " +
                  "`dart_library` of a `path` package. Each aliases to that target.",
            default = {},
        ),
        "unavailable": attr.string_dict(
            doc = "Package name to a message: the package gets a target that fails with the " +
                  "message when used, for a lock entry this hub cannot build (an SDK package).",
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
