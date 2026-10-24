"""Verification of merged pub dependency-cycle repositories.

Cycle planning trusts the lockfile's pub cycle-planning facts without
checking them: a fact that gains or loses an edge corrupts the merge plan. Facts
are therefore hints. Each merged member entry records the sorted dependency
names planning used, and the merged repository rule checks them against the
real pubspecs it fetches: a member whose real names differ, or a member set
that is not strongly connected through its real dependencies, fails the fetch
with the lockfile recovery step.

This module holds the two pure decisions (names match, members connected) so
Starlark unit tests cover them without a context. The rule in
`//dart/pub:pub_lock_scc.bzl` calls them; it does not decide itself.
"""

load("//dart/pub/private:scc.bzl", "compute_sccs")

# How a lockfile with wrong cycle-planning facts recovers: dropping the
# extension's facts and its recorded repositories re-evaluates the extension
# from the packages' real pubspecs. The workspace lockfile alone is not
# enough: Bazel also keeps the last evaluation's facts in the `MODULE.bazel.lock`
# inside its output base (`bazel info output_base` shows the directory), and
# those fill in for deleted workspace entries. Proven on a scratch workspace:
# removing the workspace entries without deleting that file rebuilds the same
# wrong plan and fails again.
_RECOVERY_STEP = "remove the pub extension's `facts` entry and its `moduleExtensions` entry from MODULE.bazel.lock, delete the `MODULE.bazel.lock` inside Bazel's output base (`bazel info output_base` shows the directory), then run the build again"

def scc_member_deps_error(repo_name, member_name, planned_deps, real_deps):
    """Decides whether one merged member's real pubspec matches the plan.

    Args:
      repo_name: The merged repository's name, for diagnostics.
      member_name: The member package being checked.
      planned_deps: The sorted dependency names planning used for the member
        (the same unfiltered names the facts record).
      real_deps: The sorted dependency names its fetched pubspec lists.

    Returns:
      An error string naming the repository and the member, listing the
      planned and the real names and giving the lockfile recovery step, when
      they differ; None when they match.
    """
    if sorted(planned_deps) == sorted(real_deps):
        return None
    return (
        'pub_lock_scc_package "%s": member "%s" lists different dependencies than cycle planning used ' +
        "(planned [%s], pubspec [%s]). The lockfile's pub cycle-planning facts disagree with the package. " +
        "To recover, %s."
    ) % (repo_name, member_name, ", ".join(sorted(planned_deps)), ", ".join(sorted(real_deps)), _RECOVERY_STEP)

def scc_members_connectivity_error(repo_name, real_deps):
    """Decides whether the merged members form one cycle through their real deps.

    Args:
      repo_name: The merged repository's name, for diagnostics.
      real_deps: Dict of member name to its sorted real dependency names.

    Returns:
      An error string naming the repository and its members and giving the
      lockfile recovery step when the members are not strongly connected
      through edges between members; None when they form one cycle.
    """
    members = sorted(real_deps.keys())
    if len(members) < 2:
        return None
    in_cycle = {name: True for name in members}
    graph = {
        name: sorted([dep for dep in real_deps[name] if dep in in_cycle and dep != name])
        for name in members
    }
    if len(compute_sccs(graph)) == 1:
        return None
    return (
        'pub_lock_scc_package "%s": members [%s] are not strongly connected through their real pubspec dependencies. ' +
        "The lockfile's pub cycle-planning facts disagree with the packages. To recover, %s."
    ) % (repo_name, ", ".join(members), _RECOVERY_STEP)
