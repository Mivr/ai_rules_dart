#!/usr/bin/env python3
"""Growth report for the scale bench: `scale.json` and its exit status.

Takes the existing per-flow results (`ios-sol.json`, `android-sol.json`)
measured at two or more workspace sizes and writes `scale.json` with, per
flow, the cost at every size, the analysis-only time, the action count and
the action count per plugin, plus the fitted growth exponent: the
least-squares slope of log cost against log size, over packages and over
plugins separately. `scale_ceilings.json` holds one exponent ceiling per
flow and size axis.

The report exits 1, after writing `scale.json`, when an exponent exceeds
its ceiling, a flow failed, or a flow has no ceiling. Exit 2 is a usage or
input error.

Usage:
  scale_report.py --point PACKAGES,PLUGINS,SOL_JSON [--point ...]
                  [--ceilings scale_ceilings.json] [--out scale.json]
"""

import argparse
import json
import math
import os
import sys

AXES = ("packages", "plugins")
ANALYSIS_PHASE = "Load and analyze dependencies"
DEFAULT_CEILINGS = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "scale_ceilings.json")
EXPONENT_DIGITS = 12


def fit_exponent(sizes, costs):
    """Least-squares slope of log(cost) against log(size).

    Pure. Raises ValueError for fewer than two points, a length mismatch,
    a non-positive size or cost, or sizes that are all equal.
    """
    if len(sizes) != len(costs):
        raise ValueError("sizes and costs differ in length")
    if len(sizes) < 2:
        raise ValueError("a growth exponent needs at least two points")
    if any(not value > 0 for value in list(sizes) + list(costs)):
        raise ValueError("sizes and costs must be positive")
    xs = [math.log(size) for size in sizes]
    ys = [math.log(cost) for cost in costs]
    mean_x = math.fsum(xs) / len(xs)
    mean_y = math.fsum(ys) / len(ys)
    denominator = math.fsum((x - mean_x) ** 2 for x in xs)
    if denominator == 0:
        raise ValueError("a growth exponent needs two different sizes")
    numerator = math.fsum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys))
    return round(numerator / denominator, EXPONENT_DIGITS)


def flow_failure(flow):
    """Why a flow record failed, or None when it measured a cost."""
    if flow is None:
        return "missing at this size"
    if "error" in flow:
        return str(flow["error"])
    cost = flow.get("bazel")
    if not isinstance(cost, (int, float)) or not cost > 0:
        return "no cost measured"
    if flow.get("identical") is False:
        return "flow failed: %s" % flow.get("reason")
    return None


def action_count(flow):
    """Actions the flow ran: the sum of its chain's per-mnemonic counts."""
    steps = ((flow.get("chain") or {}).get("steps")) or {}
    return sum(int((entry or {}).get("count", 0)) for entry in steps.values())


def analysis_seconds(flow):
    """Analysis-only CPU seconds from the flow's profile, or None."""
    phases = (((flow.get("profile") or {}).get("jvm")) or {}).get(
        "phases") or {}
    return phases.get(ANALYSIS_PHASE)


def size_entry(point, flow):
    """One `scale.json` size record of a flow."""
    failure = flow_failure(flow)
    entry = {"packages": point["packages"], "plugins": point["plugins"],
             "failure": failure, "cost": None, "analysis_s": None,
             "actions": None, "actions_per_plugin": None}
    if flow is None or "error" in flow:
        return entry
    entry["cost"] = flow.get("bazel")
    entry["analysis_s"] = analysis_seconds(flow)
    entry["actions"] = action_count(flow)
    if point["plugins"] > 0:
        entry["actions_per_plugin"] = entry["actions"] / point["plugins"]
    return entry


def axis_series(entries, axis):
    """Entries varying along `axis` with the other axis held fixed.

    Picks the fixed value of the other axis with the most distinct sizes
    (ties go to the smallest); returns the entries sorted by size.
    """
    other = AXES[1 - AXES.index(axis)]
    best = []
    for fixed in sorted({e[other] for e in entries}):
        group = {e[axis]: e for e in entries if e[other] == fixed}
        if len(group) > len(best):
            best = [group[size] for size in sorted(group)]
    return best


def axis_exponent(entries, axis):
    """Growth exponent along `axis`, or None when it is not measured.

    The plugin axis includes a 0-plugin baseline by counting the app as
    one unit (size = plugins + 1); a log of zero is undefined.
    """
    series = axis_series([e for e in entries if e["cost"] is not None], axis)
    if len(series) < 2:
        return None
    sizes = [e[axis] for e in series]
    if axis == "plugins" and min(sizes) == 0:
        sizes = [size + 1 for size in sizes]
    return fit_exponent(sizes, [e["cost"] for e in series])


def flow_report(points, flows_by_point, flow):
    """The `scale.json` record of one flow across every point."""
    entries = [size_entry(p, flows[flow] if flow in flows else None)
               for p, flows in zip(points, flows_by_point)]
    failures = ["%dp/%dg: %s" % (e["packages"], e["plugins"], e["failure"])
                for e in entries if e["failure"] is not None]
    return {"sizes": entries,
            "exponents": {axis: axis_exponent(entries, axis)
                          for axis in AXES},
            "failures": failures}


def check_ceilings(report, ceilings):
    """Violation messages for failed flows, missing and exceeded ceilings."""
    problems = []
    for flow, record in sorted(report.items()):
        for failure in record["failures"]:
            problems.append("%s failed (%s)" % (flow, failure))
        ceiling = ceilings.get(flow)
        for axis, exponent in record["exponents"].items():
            if exponent is None:
                continue
            limit = (ceiling or {}).get(axis)
            if not isinstance(limit, (int, float)):
                problems.append("%s has no %s ceiling" % (flow, axis))
            elif exponent > limit:
                problems.append("%s %s exponent %.3f exceeds ceiling %.3f"
                                % (flow, axis, exponent, limit))
    return problems


def build_report(points, flows_by_point, ceilings):
    """The whole `scale.json` document."""
    names = sorted({name for flows in flows_by_point for name in flows})
    flows = {name: flow_report(points, flows_by_point, name)
             for name in names}
    problems = check_ceilings(flows, ceilings)
    if not names:
        problems.append("no flows in the results")
    return {"unit": "cpu_seconds",
            "points": [dict(p) for p in points],
            "flows": flows,
            "ceilings": ceilings,
            "problems": problems,
            "ok": not problems}


def parse_point(text):
    """`PACKAGES,PLUGINS,PATH` -> point dict (ValueError when malformed)."""
    parts = text.split(",", 2)
    if len(parts) != 3:
        raise ValueError("--point must be PACKAGES,PLUGINS,PATH: %r" % text)
    packages, plugins = int(parts[0]), int(parts[1])
    if packages < 1 or plugins < 0:
        raise ValueError("--point sizes out of range: %r" % text)
    return {"packages": packages, "plugins": plugins, "source": parts[2]}


def load_json(path):
    """A JSON file's content (OSError/ValueError on a bad file)."""
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def write_report(path, report):
    """Writes `scale.json` sorted and newline-terminated."""
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(report, indent=2, sort_keys=True) + "\n")


def main(argv=None):
    """CLI entry point; returns the process exit status."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--point", action="append", default=[],
                        help="PACKAGES,PLUGINS,SOL_JSON (repeatable)")
    parser.add_argument("--ceilings", default=DEFAULT_CEILINGS)
    parser.add_argument("--out", default="scale.json")
    args = parser.parse_args(argv)
    try:
        points = [parse_point(text) for text in args.point]
        if len(points) < 2:
            raise ValueError("at least two --point sizes are required")
        flows_by_point = [(load_json(p["source"]).get("flows") or {})
                          for p in points]
        ceilings = load_json(args.ceilings)
    except (OSError, ValueError) as exc:
        print("scale_report: %s" % exc, file=sys.stderr)
        return 2
    report = build_report(points, flows_by_point, ceilings)
    write_report(args.out, report)
    for problem in report["problems"]:
        print("scale_report: %s" % problem, file=sys.stderr)
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
