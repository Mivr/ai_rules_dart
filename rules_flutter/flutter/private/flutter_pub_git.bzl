"""Fetches a git-sourced pub package at its locked commit.

`flutter.pub` serves a lock's `source: git` entries as `pub get` does: the
package is the locked commit's tree at the entry's `path`, fetched with the
host `git` through rules_dart's two-phase helpers (the network fetch, then a
`git archive` of the one tree), and refused like a hosted archive when an
entry escapes the package.
"""

load(
    "@rules_dart//dart/pub:pinned_sources.bzl",
    "git_materialize",
    "git_transport_fetch",
    "pinned_source_error",
)
load("@rules_dart//dart/pub:pub_scan.bzl", "check_package_symlinks", "run_pub_archive_scan")

visibility(["//flutter/..."])

def git_package_subdir(path):
    """The lock entry's `path` inside the repository; `.` for its root."""
    path = path.strip() if path else "."
    return path or "."

def fetch_git_package(ctx, package_name, version, url, resolved_ref, path, rule, output = ""):
    """Fetches one git package's tree into `output` (the repository root by default).

    Args:
        ctx: The repository context.
        package_name: The pub package name, for messages and the scan.
        version: The locked version, for messages.
        url: The git remote.
        resolved_ref: The locked 40-hex commit.
        path: The package's directory inside the git repository.
        rule: The repository rule's name, for messages.
        output: The directory to extract into, relative to the repository.
    """
    err = pinned_source_error("git", package_name, version, resolved_ref = resolved_ref, rule = rule)
    if err:
        fail(err)
    subdir = git_package_subdir(path)
    what = '%s "%s"' % (rule, package_name)
    bare = "_git_bare_" + package_name
    git_transport_fetch(ctx, url, bare, resolved_ref, what)
    archive = ctx.path("_git_%s.tar" % package_name)
    git_materialize(ctx, bare, resolved_ref, archive, resolved_ref if subdir == "." else resolved_ref + ":" + subdir, what)

    # `git archive` output is a plain tar: refuse hostile entries from its
    # headers before the extractor trusts them, as for a hosted archive.
    run_pub_archive_scan(ctx, archive, package_name)
    ctx.extract(archive, output = output)
    ctx.delete(archive)
    ctx.delete(ctx.path(bare))
    check_package_symlinks(ctx, package_name, root = output)
