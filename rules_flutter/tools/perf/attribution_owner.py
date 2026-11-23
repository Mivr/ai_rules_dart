"""Exec tool target per host-tool repository, and spawn counts.

Both are derived offline from the saved execution log: a host-tool
repository is tied to the exec tool target whose spawns read its
outputs (directly or through other host-tool spawns); executed and
cache-hit spawns are counted per mnemonic.
"""

from attribution_trace import MissingData
from replay import builds_host_tool
from replay import spawn_input_strings
from replay import spawn_output_strings
from summarize import summarize_values

REQUIRED_MNEMONICS = ("ImportedDynamicFrameworkProcessor", "ProcessAndSign",
                      "BundleApp")


def repo_of(label):
    """Repository name of a target label ("_main" for the main repo)."""
    text = label if isinstance(label, str) else ""
    if not text.startswith("@"):
        return "_main"
    return text.lstrip("@").split("//", 1)[0] or "_main"


def check_input_data(spawns):
    """Raises MissingData when no spawn lists its inputs."""
    if any(spawn_input_strings(s) for s in spawns):
        return
    if any(builds_host_tool(s) for s in spawns):
        raise MissingData("execution log lists no spawn inputs "
                          "(inputs), needed for by_repo_owner")


def _consumers(host):
    """{producer index: set of consumer indexes} among host spawns."""
    producers = {}
    for index, spawn in enumerate(host):
        for path in spawn_output_strings(spawn):
            producers[path] = index
    edges = {}
    for index, spawn in enumerate(host):
        for path in spawn_input_strings(spawn):
            source = producers.get(path)
            if source is not None and source != index:
                edges.setdefault(source, set()).add(index)
    return edges


def _reached(starts, edges):
    """Indexes reachable from starts through consumer edges."""
    seen = set()
    todo = list(starts)
    while todo:
        for nxt in edges.get(todo.pop(), ()):
            if nxt not in seen:
                seen.add(nxt)
                todo.append(nxt)
    return seen


def _terminal_labels(reached, edges, labels, repo):
    """Labels outside `repo` that no other reached label consumes."""
    names = {labels[i] for i in reached if repo_of(labels[i]) != repo}
    inner = set()
    for index in reached:
        for nxt in edges.get(index, ()):
            if nxt in reached and labels[nxt] in names \
                    and labels[nxt] != labels[index]:
                inner.add(labels[index])
    return sorted(names - inner)


def repo_owners(spawns):
    """{repo: sorted exec tool target labels} for every host-tool repo."""
    host = [s for s in spawns if builds_host_tool(s)]
    labels = [s.get("targetLabel") or "" for s in host]
    edges = _consumers(host)
    by_repo = {}
    for index, label in enumerate(labels):
        by_repo.setdefault(repo_of(label), []).append(index)
    return {repo: _terminal_labels(_reached(starts, edges), edges, labels,
                                   repo)
            for repo, starts in by_repo.items()}


def spawn_counts(spawns):
    """{mnemonic: {"executed", "cache_hit"}} with the required names."""
    counts = {name: {"executed": 0, "cache_hit": 0}
              for name in REQUIRED_MNEMONICS}
    for spawn in spawns:
        entry = counts.setdefault(spawn.get("mnemonic") or "",
                                  {"executed": 0, "cache_hit": 0})
        entry["cache_hit" if spawn.get("cacheHit") else "executed"] += 1
    return counts


def median_counts(maps):
    """Per-mnemonic median of executed and cache_hit over repeats."""
    names = set(REQUIRED_MNEMONICS)
    for entry in maps:
        names.update(entry)
    return {name: {key: summarize_values(
        [m.get(name, {}).get(key, 0) for m in maps])["median"]
        for key in ("executed", "cache_hit")} for name in sorted(names)}


def merge_owners(maps):
    """Union over repeats of each repo's owner labels, sorted."""
    merged = {}
    for entry in maps:
        for repo, labels in entry.items():
            merged.setdefault(repo, set()).update(labels)
    return {repo: sorted(labels) for repo, labels in merged.items()}


def owner_warnings(by_repo, owners):
    """Warnings naming each reported repository without an owner."""
    return ["no exec tool target found for repository %s" % repo
            for repo in sorted(by_repo)
            if repo != "other" and not owners.get(repo)]
