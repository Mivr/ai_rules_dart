"""Verification of pub cycle-planning facts against fetched pubspecs.

Cycle planning trusts the lockfile's pub cycle-planning facts without
checking them: a fact that gains or loses an edge corrupts the merge plan. Facts
are therefore hints. Every repository planning covered — each hosted or git
spoke as well as each merged cycle — checks the sorted dependency names
planning used against the real pubspec it fetches. Each merged member entry
records the names planning used, and the merged repository rule checks them
against the real pubspecs it fetches: a member whose real names differ, or a
member set that is not strongly connected through its real dependencies, fails
the fetch with the lockfile recovery step. Each spoke carries the names
planning used in its `planned_deps` attribute and fails its fetch the same
way — naming the package, listing the planned and the real names — so a wrong
fact on a package planning left as its own repository fails at fetch time,
never as a target cycle in analysis.

This module holds the three pure decisions (spoke names match, merged names
match, members connected) so Starlark unit tests cover them without a
context. The rules in `//dart/pub:pub_lock_package.bzl` and
`//dart/pub:pub_lock_scc.bzl` call them; they do not decide themselves.
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

def scc_planned_deps_error(repo_name, member_name, planned):
    """Decides whether one merged member's entry carries usable planned names.

    Args:
      repo_name: The merged repository's name, for diagnostics.
      member_name: The member package being checked.
      planned: The member entry's `planned_deps` value (None when the entry
        carries none).

    Returns:
      An error string naming the repository and the member when the entry
      carries no planned names, or names that are not a list of strings; None
      when planning named a list of strings (possibly empty).
    """
    if type(planned) != "list":
        return (
            'pub_lock_scc_package "%s": member "%s" has no usable cycle-planning names ' +
            "(its entry carries no `planned_deps` list of strings). The lockfile's pub cycle-planning facts disagree with the packages. " +
            "To recover, %s."
        ) % (repo_name, member_name, _RECOVERY_STEP)
    for dep in planned:
        if type(dep) != "string":
            return (
                'pub_lock_scc_package "%s": member "%s" has no usable cycle-planning names ' +
                "(its entry's `planned_deps` holds a non-string). The lockfile's pub cycle-planning facts disagree with the packages. " +
                "To recover, %s."
            ) % (repo_name, member_name, _RECOVERY_STEP)
    return None

def _planned_deps_mismatch_error(rule_name, repo_name, subject_kind, subject_name, planned_deps, real_deps):
    """Formats the fetch failure for names planning used that the pubspec contradicts.

    The spoke and the merged checks share this formatter — with the rule kind
    and the subject as parameters — so their messages can never drift apart.

    Args:
      rule_name: The repository rule (`"pub_lock_scc_package"`,
        `"pub_lock_package"`, or `"pub_lock_git_package"`), for diagnostics.
      repo_name: The repository's name, for diagnostics.
      subject_kind: `"member"` for a merged member, `"package"` for a spoke.
      subject_name: The member or package being checked.
      planned_deps: The dependency names planning used for the subject.
      real_deps: The dependency names its fetched pubspec lists.

    Returns:
      An error string naming the repository and the subject, listing the
      planned and the real names and giving the lockfile recovery step.
    """
    return (
        '%s "%s": %s "%s" lists different dependencies than cycle planning used ' +
        "(planned [%s], pubspec [%s]). The lockfile's pub cycle-planning facts disagree with the package. " +
        "To recover, %s."
    ) % (rule_name, repo_name, subject_kind, subject_name, ", ".join(sorted(planned_deps)), ", ".join(sorted(real_deps)), _RECOVERY_STEP)

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
    return _planned_deps_mismatch_error("pub_lock_scc_package", repo_name, "member", member_name, planned_deps, real_deps)

def spoke_planned_deps_error(rule_name, repo_name, package_name, planned, real_deps):
    """Decides whether one spoke's fetched pubspec matches the cycle-planning names.

    Every repository cycle planning covered — a hosted or git spoke as well
    as a merged cycle — checks the names planning used against the real
    pubspec it fetched. A spoke left as its own repository still carries the
    names planning used in its `planned_deps` attribute, so a fact that drops
    a real edge (hiding a cycle that then fails analysis bare) or gains a
    fake edge (passing silently) fails the spoke's fetch instead, naming the
    package and giving the lockfile recovery step.

    Args:
      rule_name: The spoke rule (`"pub_lock_package"` or
        `"pub_lock_git_package"`), for diagnostics.
      repo_name: The spoke repository's name, for diagnostics.
      package_name: The pub package the spoke fetches.
      planned: The sorted dependency names planning used for the package (the
        spoke's `planned_deps` attribute), or None when planning did not
        cover the package and there is nothing to check. The attribute is an
        `attr.string_list`, so a covered package always carries a list of
        strings; there is no unusable-names case to report.
      real_deps: The sorted dependency names its fetched pubspec lists.

    Returns:
      An error string naming the repository and the package, listing the
      planned and the real names and giving the lockfile recovery step, when
      they differ; None when they match or planning did not cover the
      package. The mismatch shares its formatter with the merged check, and
      both reuse `_RECOVERY_STEP`, so a spoke and a merged repository always
      give the same message and the same recovery.
    """
    if planned == None:
        return None
    if sorted(planned) == sorted(real_deps):
        return None
    return _planned_deps_mismatch_error(rule_name, repo_name, "package", package_name, planned, real_deps)

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
