#!/usr/bin/env python3
"""Bench plan and report for the Android debug APK overlay settings.

Reports the Android (``android_debug``) debug body-edit warm flow
(``android-debug-body-warm``) before and after the overlay optimization in
one session. Measures CPU for ``FlutterApkOverlay``, ``AndroidZipAlign`` and
``ApkSignerTool``. ``plan`` prints the benchmark arms; ``report`` formats
the measured CPU seconds.

Only the Python 3 standard library is used.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

FLOW = "android-debug-body-warm"
CONFIG = "android_debug"
ACTIONS = ("FlutterApkOverlay", "AndroidZipAlign", "ApkSignerTool")
STATES = ("before", "after")


def plan():
    """Every arm of the session: (flow, state, description)."""
    return [
        {
            "flow": FLOW,
            "config": CONFIG,
            "state": "before",
            "kernel_blob_storage": "deflated",
            "signing_scheme": "v1_v2",
        },
        {
            "flow": FLOW,
            "config": CONFIG,
            "state": "after",
            "kernel_blob_storage": "stored",
            "signing_scheme": "v2",
        },
    ]


def _cell(value):
    return "n/a" if value is None else "%.3f" % value


def report(rows):
    """Report lines: one per arm, n/a for an arm without data.

    rows is a list of dicts with flow, state, overlay_cpu_s,
    zipalign_cpu_s, signer_cpu_s, and total_cpu_s.
    """
    by_arm = {(r.get("flow"), r.get("state")): r for r in rows}
    lines = []
    for arm in plan():
        row = by_arm.get((arm["flow"], arm["state"]))
        overlay = None if row is None else row.get("overlay_cpu_s")
        align = None if row is None else row.get("zipalign_cpu_s")
        signer = None if row is None else row.get("signer_cpu_s")
        total = None if row is None else row.get("total_cpu_s")
        lines.append(
            "%s state=%s FlutterApkOverlay_cpu_s=%s AndroidZipAlign_cpu_s=%s "
            "ApkSignerTool_cpu_s=%s total_cpu_s=%s" % (
                arm["flow"], arm["state"],
                _cell(overlay), _cell(align), _cell(signer), _cell(total),
            )
        )
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
