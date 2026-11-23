#!/usr/bin/env python3
"""Execution wall time attribution for host tools.

Derives host-tool wall times, mnemonics, repositories and repository
owners from an execution log when spawn CPU metrics are unavailable.
"""

import gzip
import os
import tempfile

from attribution_owner import check_input_data
from attribution_owner import merge_owners
from attribution_owner import owner_warnings
from attribution_owner import repo_of
from attribution_owner import repo_owners
from attribution_trace import MissingData
from execlog import load_spawns
from execlog import parse_duration
from replay import builds_host_tool
from replay import spawn_output_strings
from summarize import summarize_values

TOP_N = 10
_EXECLOG = "execlog.json.gz"


def top_with_other(values, limit=TOP_N):
    """The `limit` largest entries plus an "other" sum of the rest."""
    ranked = sorted(values.items(), key=lambda item: (-item[1], item[0]))
    named = dict(ranked[:limit])
    named["other"] = sum(value for _, value in ranked[limit:])
    return named


def median_map(maps):
    """Per-key median over maps."""
    keys = set()
    for entry in maps:
        keys.update(entry)
    return {key: summarize_values(
        [entry.get(key, 0.0) for entry in maps])["median"] for key in keys}


def spawn_wall(spawn):
    """executionWallTime seconds of one executed spawn."""
    if spawn.get("cacheHit"):
        return 0.0
    metrics = spawn.get("metrics") or {}
    return parse_duration(metrics.get("executionWallTime"))


def has_wall_metrics(spawns):
    """True when any executed spawn carries executionWallTime."""
    executed = [s for s in spawns if not s.get("cacheHit")]
    return bool(executed) and any(
        (s.get("metrics") or {}).get("executionWallTime") is not None
        for s in executed)


def check_wall_outputs(spawns):
    """Raises MissingData when executed spawns list no outputs."""
    executed = [s for s in spawns if not s.get("cacheHit")]
    if executed and not any(spawn_output_strings(s) for s in executed):
        raise MissingData("execution log lists no spawn outputs "
                          "(listedOutputs/actualOutputs)")


def accumulate_host_costs(spawns, cost_fn):
    """Host build costs and repo owners extracted with cost_fn(spawn)."""
    host = {"total": 0.0, "by_mnemonic": {}, "by_repo": {}}
    for spawn in spawns:
        if not builds_host_tool(spawn):
            continue
        cost = cost_fn(spawn)
        host["total"] += cost
        mnemonic = spawn.get("mnemonic") or ""
        repo = repo_of(spawn.get("targetLabel"))
        for key, name in (("by_mnemonic", mnemonic), ("by_repo", repo)):
            host[key][name] = host[key].get(name, 0.0) + cost
    host["owners"] = repo_owners(spawns)
    return host


def summarize_host_tools(hosts, unit=None):
    """Medians over repeats of host tool costs, top N, and owner targets."""
    record = {}
    if unit is not None:
        record["unit"] = unit
    record["total"] = summarize_values([h["total"] for h in hosts])["median"]
    record["by_mnemonic"] = top_with_other(
        median_map([h["by_mnemonic"] for h in hosts]))
    record["by_repo"] = top_with_other(
        median_map([h["by_repo"] for h in hosts]))
    owners = merge_owners([h["owners"] for h in hosts])
    record["by_repo_owner"] = {
        repo: owners.get(repo, [])
        for repo in record["by_repo"] if repo != "other"}
    return record


def _gunzip_to(src, dst):
    with open(src, "rb") as fin:
        data = fin.read()
    with open(dst, "wb") as fout:
        fout.write(gzip.decompress(data))


def load_rep_spawns(rep_dir):
    """Loads spawns from rep_dir/execlog.json.gz."""
    with tempfile.TemporaryDirectory() as tmp:
        log = os.path.join(tmp, "execlog.json")
        _gunzip_to(os.path.join(rep_dir, _EXECLOG), log)
        return load_spawns(log)


def _rep_host_wall(rep_dir):
    """Extracts host wall costs for one repeat; raises MissingData."""
    try:
        spawns = load_rep_spawns(rep_dir)
        if not has_wall_metrics(spawns):
            return None
        check_wall_outputs(spawns)
        check_input_data(spawns)
        return accumulate_host_costs(spawns, spawn_wall)
    except MissingData as exc:
        raise MissingData("%s (in %s)" % (exc, rep_dir))


def try_wall_attribution(rep_dirs, cpu_error):
    """Builds host_tools_wall record when executionWallTime is available."""
    rep_hosts = []
    for rep_dir in rep_dirs:
        host = _rep_host_wall(rep_dir)
        if host is None:
            return None
        rep_hosts.append(host)
    host_wall = summarize_host_tools(rep_hosts, unit="wall_s")
    return {
        "ok": False,
        "error": cpu_error,
        "host_tools_wall": host_wall,
        "warnings": owner_warnings(host_wall["by_repo"],
                                   host_wall["by_repo_owner"]),
    }
