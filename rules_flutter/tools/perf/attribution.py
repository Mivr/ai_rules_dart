#!/usr/bin/env python3
"""Per-flow CPU attribution of the clean and cold flows.

Splits a flow's ``bazel`` CPU into fetch/extract, module resolution,
loading/analysis, host-tool builds (by mnemonic and by repository),
target actions, sandbox and a shown remainder, from the saved
``trace.json.gz`` (activity by category, see attribution_trace) and
``execlog.json.gz`` (userTime + systemTime of each spawn). A log without
spawn CPU metrics or listed outputs, or an empty trace, gives
``{"ok": false, "error": ...}`` instead of zeros. No Bazel run
and no command lines. The remainder is total minus parts 1 to 6, never
clamped; ``ok`` holds while it is within 5% of the total.
"""

import os

from attribution_owner import check_input_data
from attribution_owner import median_counts
from attribution_owner import owner_warnings
from attribution_owner import spawn_counts
from attribution_trace import MissingData
from attribution_trace import TRACE_PARTS
from attribution_trace import trace_part_seconds
from attribution_wall import accumulate_host_costs
from attribution_wall import load_rep_spawns
from attribution_wall import summarize_host_tools
from attribution_wall import top_with_other
from attribution_wall import try_wall_attribution
from execlog import parse_duration
from replay import builds_host_tool
from replay import spawn_output_strings
from summarize import summarize_values

ATTRIBUTED_FLOWS = frozenset([
    "ios-debug-clean", "ios-debug-body", "ios-debug-app",
    "android-debug-body", "android-release-noop"])
TOLERANCE = 0.05
TOP_N = 10
SIMPLE_PARTS = ("fetch_extract", "module_resolution", "loading_analysis",
                "target_actions", "sandbox")
_TRACE = "trace.json.gz"
_EXECLOG = "execlog.json.gz"


def spawn_cpu(spawn):
    """user + system CPU seconds of one executed spawn."""
    if spawn.get("cacheHit"):
        return 0.0
    metrics = spawn.get("metrics") or {}
    return (parse_duration(metrics.get("userTime"))
            + parse_duration(metrics.get("systemTime")))


def check_spawn_data(spawns):
    """Raises MissingData unless the log can be split into host/target.

    Looks at executed (non cache-hit) spawns only: they must carry
    userTime/systemTime and list their outputs, or every cost reads 0.
    """
    executed = [s for s in spawns if not s.get("cacheHit")]
    if not executed:
        return
    if not any((s.get("metrics") or {}).get(key) is not None
               for s in executed for key in ("userTime", "systemTime")):
        raise MissingData("execution log has no spawn CPU metrics "
                          "(metrics.userTime/systemTime)")
    if not any(spawn_output_strings(s) for s in executed):
        raise MissingData("execution log lists no spawn outputs "
                          "(listedOutputs/actualOutputs)")


def spawn_costs(spawns):
    """{"target_actions", "host": {"total","by_mnemonic","by_repo"}}."""
    check_spawn_data(spawns)
    check_input_data(spawns)
    host = accumulate_host_costs(spawns, spawn_cpu)
    target = sum(spawn_cpu(s) for s in spawns if not builds_host_tool(s))
    return {"target_actions": target, "host": host,
            "counts": spawn_counts(spawns)}


def rep_parts(rep_dir):
    """One repeat's raw parts; raises OSError/ValueError if unreadable."""
    try:
        costs = spawn_costs(load_rep_spawns(rep_dir))
    except MissingData as exc:
        raise MissingData("%s (in %s)" % (exc, rep_dir))
    seconds = trace_part_seconds(os.path.join(rep_dir, _TRACE))
    parts = {name: seconds[name] for name in TRACE_PARTS}
    parts["target_actions"] = costs["target_actions"]
    parts["host"] = costs["host"]
    parts["counts"] = costs["counts"]
    return parts


def missing_input(rep_dirs):
    """Message naming the first absent file, or None."""
    for rep_dir in rep_dirs:
        for name in (_TRACE, _EXECLOG):
            if not os.path.isfile(os.path.join(rep_dir, name)):
                return "missing %s in %s" % (name, rep_dir)
    return None


def median_parts(reps):
    """Per-key median over the repeats' raw parts."""
    out = {name: summarize_values([r[name] for r in reps])["median"]
           for name in SIMPLE_PARTS}
    hosts = [r["host"] for r in reps]
    out["host_tools"] = summarize_host_tools(hosts)
    return out


def build_attribution(parts, total, counts=None):
    """The attribution record; unattributed = total - parts 1..6."""
    summed = sum(parts[name] for name in SIMPLE_PARTS)
    summed += parts["host_tools"]["total"]
    gap = total - summed
    record = dict(parts)
    record["unattributed"] = gap
    host = parts["host_tools"]
    return {"ok": abs(gap) <= TOLERANCE * total, "gap_s": gap,
            "total_s": total, "parts": record,
            "spawns_by_mnemonic": counts or {},
            "warnings": owner_warnings(host["by_repo"],
                                       host["by_repo_owner"])}


def attribute_flow(rep_dirs, total):
    """Attribution of one flow from its rep directories and bazel total."""
    if not rep_dirs:
        return {"ok": False, "error": "no repeat directories"}
    if total is None:
        return {"ok": False, "error": "flow has no bazel total"}
    absent = missing_input(rep_dirs)
    if absent:
        return {"ok": False, "error": absent}
    try:
        reps = [rep_parts(rep_dir) for rep_dir in rep_dirs]
    except MissingData as exc:
        if "metrics.userTime/systemTime" in str(exc):
            try:
                wall = try_wall_attribution(rep_dirs, str(exc))
                if wall is not None:
                    return wall
            except MissingData as wall_exc:
                return {"ok": False, "error": str(wall_exc)}
        return {"ok": False, "error": str(exc)}
    except (OSError, ValueError) as exc:
        return {"ok": False, "error": "unreadable input: %s" % (exc,)}
    return build_attribution(median_parts(reps), total,
                             median_counts([r["counts"] for r in reps]))


def strict_attribution_exit(summaries, strict):
    """Exit code: 1 only in strict mode when some attribution.ok is false."""
    if not strict:
        return 0
    failed = []
    for summary in summaries.values():
        for flow, entry in sorted(summary["flows"].items()):
            attribution = entry.get("attribution")
            if attribution is not None and not attribution["ok"]:
                failed.append(flow)
    for flow in failed:
        print("flow=%s attribution not ok" % flow)
    return 1 if failed else 0
