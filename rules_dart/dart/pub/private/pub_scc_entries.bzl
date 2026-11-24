"""Member entries for a merged pub dependency cycle.

The `pub` module extension resolves a lock, plans its cycles, and hands each
merged repository the member coordinates it needs in `members_json`. Building
those entries is pure given the resolved packages and their plans, so it lives
here rather than beside the extension's state machine.
"""

visibility(["//dart/..."])

def scc_member_entries(members, hosted, git_pkgs, plans, labels):
    """Builds the merged repository's member entries for `members_json`.

    Pure given the resolved packages: hosted members carry their archive
    URL and hash, git members their remote, resolved ref and in-repo path,
    so the merged repository fetches each member the way its spoke would.
    Each entry also carries the sorted dependency names planning used for
    that member, so the merged repository verifies the plan against the
    real pubspecs, and the labels of the member's dependencies outside the
    cycle. Nothing else of the graph: the entries change only when a member
    does.

    Args:
      members: Sorted member package names.
      hosted: Dict of hosted package name to
        `struct(version, sha256, url, package_files)`.
      git_pkgs: Dict of git package name to
        `struct(version, url, resolved_ref, path, package_files)`.
      plans: Dict of package name to its plan (`deps`, and `archive_url`
        for a hosted package).
      labels: The scope's package-name-to-label map.

    Returns:
      List of structs, each with `source` (`"hosted"` or `"git"`), the
      coordinates the merged repository rule reads, `planned_deps`, `deps`
      (labels outside the cycle), and the member's runtime
      `package_files` globs.
    """
    in_cycle = {m: True for m in members}
    entries = []
    for member in members:
        planned = sorted(plans[member]["deps"])
        outside = [labels[d] for d in planned if d in labels and d not in in_cycle]
        if member in hosted:
            pkg = hosted[member]
            entries.append(struct(
                source = "hosted",
                name = member,
                version = pkg.version,
                sha256 = pkg.sha256,
                url = plans[member]["archive_url"],
                planned_deps = planned,
                deps = outside,
                package_files = getattr(pkg, "package_files", ["pubspec.yaml", "LICENSE*"]),
            ))
        else:
            pkg = git_pkgs[member]
            entries.append(struct(
                source = "git",
                name = member,
                version = pkg.version,
                url = pkg.url,
                resolved_ref = pkg.resolved_ref,
                path = pkg.path,
                planned_deps = planned,
                deps = outside,
                package_files = getattr(pkg, "package_files", ["pubspec.yaml", "LICENSE*"]),
            ))
    return entries
