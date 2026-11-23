#!/usr/bin/env python3
"""Bench plan and report for the incremental kernel settings.

Reports the iOS (``sim_debug``) and Android (``android_debug``) debug
body-edit warm flows with each of ``//flutter:incremental_kernel`` and
``//flutter:dev_incremental_serialization`` on and off, in one session.
``plan`` prints the arms (flow, setting, state, Bazel flags to hand
``sol.py`` as ``bazel_flags``); ``report`` reads measured rows and prints
wall time and ``FlutterKernelCompile`` CPU for every arm, naming an arm that
was not measured instead of leaving it out.

Only the Python 3 standard library is used.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from bench_flags import validate_bazel_flags  # noqa: E402 -- needs sys.path set above

FLOWS = {
    "ios-debug-body-warm": "sim_debug",
    "android-debug-body-warm": "android_debug",
}
_PREFIX = "--@rules_flutter//flutter:"
SETTINGS = {
    "incremental_kernel": {
        "on": ["incremental_kernel=true"],
        "off": ["incremental_kernel=false"],
    },
    # The dev setting only acts with the worker route, so both arms keep it.
    "dev_incremental_serialization": {
        "on": ["incremental_kernel=true",
               "dev_incremental_serialization=true"],
        "off": ["incremental_kernel=true",
                "dev_incremental_serialization=false"],
    },
}
STATES = ("on", "off")


def arm_flags(setting, state):
    """Validated Bazel flag tokens for one setting in one state."""
    flags = [_PREFIX + item for item in SETTINGS[setting][state]]
    return validate_bazel_flags(flags)


def plan():
    """Every arm of the session: flow x setting x state."""
    arms = []
    for flow, config in FLOWS.items():
        for setting in SETTINGS:
            for state in STATES:
                arms.append({
                    "flow": flow,
                    "config": config,
                    "setting": setting,
                    "state": state,
                    "bazel_flags": arm_flags(setting, state),
                })
    return arms


def _cell(row, key):
    value = None if row is None else row.get(key)
    return "n/a" if value is None else "%.1f" % value


def report(rows):
    """Report lines: one per arm, ``n/a`` for an arm without a row.

    rows is a list of dicts with flow, setting, state, wall_s and
    fkc_cpu_s (``FlutterKernelCompile`` CPU seconds).
    """
    by_arm = {(r["flow"], r["setting"], r["state"]): r for r in rows}
    lines = []
    for arm in plan():
        row = by_arm.get((arm["flow"], arm["setting"], arm["state"]))
        lines.append("%s %s=%s wall_s=%s fkc_cpu_s=%s" % (
            arm["flow"], arm["setting"], arm["state"],
            _cell(row, "wall_s"), _cell(row, "fkc_cpu_s")))
    return lines


def main(argv=None):
    """Print the plan as JSON, or the report for ``--rows``."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "report"))
    parser.add_argument("--rows", default="",
                        help="JSON list of measured rows (report)")
    args = parser.parse_args(argv)
    if args.command == "plan":
        print(json.dumps(plan(), indent=2))
        return 0
    rows = []
    if args.rows:
        with open(args.rows, encoding="utf-8") as fh:
            rows = json.load(fh)
    print("\n".join(report(rows)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
