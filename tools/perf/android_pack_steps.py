#!/usr/bin/env python3
"""Per-step wall of Android packaging after a Dart edit, from Bazel profiles.

After a Dart edit in a debug modular Android app, three actions rewrite the
whole APK in a chain: ``FlutterApkOverlay`` (payload inject),
``AndroidZipAlign`` and ``ApkSignerTool`` (sign). This tool reads Bazel
``--profile`` traces (Chrome trace format, ``action processing`` events) and
reports, per flow:

- the median wall of each of the three steps, kept apart per APK group:
  ``full`` (the one APK), ``base`` and ``payload`` (the debug split APKs,
  told apart by ``_base``/``_payload`` in the event's primary output or
  progress message), plus the kernel compile and link steps for reference;
- the flow wall (``Initialize command`` to ``Complete build`` markers, else
  the span of the action events) and each step's share of it;
- the bounded gain of three candidate fixes and the roadmap 10% rule:
  under 10% of the flow is ``close_with_numbers``, else ``later_item``.

``--apk-dir`` adds output APK byte sizes, ``--signer`` the cold-JVM floor
(median of five ``<signer> --version`` runs). A step is matched by its
mnemonic or, failing that, by its progress message (the event name). An
unreadable trace, or one with none of the three steps, is an error naming the trace (exit 2).

Usage: android_pack_steps.py [--format json|markdown|both] [--apk-dir DIR]
       [--signer PATH] [FLOW=]TRACE...   (traces of one FLOW are its reps)
"""

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from traceprofile import read_trace_events

ACTION_CAT = "action processing"
STEPS = (("overlay", "FlutterApkOverlay"),
         ("zipalign", "AndroidZipAlign"),
         ("sign", "ApkSignerTool"))
MESSAGES = (("overlay", "Injecting Flutter payload into base APK"),
            ("zipalign", "Zipaligning APK with Flutter payload"),
            ("sign", "Signing APK with Flutter payload"))
REFERENCE = (("kernel_compile", "DartKernel"),
             ("kernel_link", "DartKernelLink"))
GROUPS = ("full", "base", "payload")
THRESHOLD_PERCENT = 10.0
FLOOR_RUNS = 5
START_MARKER = "Initialize command"
END_MARKER = "Complete build"
SPLIT_RE = re.compile(r"_(base|payload)(?:_unsigned)?(?:\.apk|\b)|"
                      r"\b(base|payload) split", re.IGNORECASE)
CANDIDATES = (
    ("persistent_signing", "sign",
     "persistent or in-process signing (no cold JVM per edit)"),
    ("skip_zipalign", "zipalign",
     "skip zipalign of a payload the overlay already aligned"),
    ("reuse_payload_entries", "overlay",
     "store or reuse unchanged payload entries instead of deflating again"),
)


class PackStepsError(Exception):
    """A trace or input that cannot be measured; the message names it."""


def event_group(event):
    """APK group of an action event: base, payload or full."""
    texts = [str(event.get("name", ""))]
    args = event.get("args")
    if isinstance(args, dict):
        texts += [v for v in args.values() if isinstance(v, str)]
    for text in texts:
        found = SPLIT_RE.search(text)
        if found:
            return (found.group(1) or found.group(2)).lower()
    return "full"


def mnemonic_of(event):
    """Mnemonic of an action event, or empty."""
    args = event.get("args")
    value = args.get("mnemonic") if isinstance(args, dict) else None
    return value if isinstance(value, str) else ""


def step_key(event):
    """(step name, group) of a packaging or reference event, else None."""
    mnemonic = mnemonic_of(event)
    for name, wanted in STEPS:
        if mnemonic == wanted:
            return name, event_group(event)
    for name, wanted in REFERENCE:
        if mnemonic == wanted:
            return name, "full"
    message = str(event.get("name", ""))
    for name, prefix in MESSAGES:
        if message.startswith(prefix):
            return name, event_group(event)
    return None


def trace_wall(events):
    """(seconds, source) of one trace's flow wall."""
    marks = {e.get("name"): e.get("ts") for e in events
             if e.get("cat") == "build phase marker"}
    start, end = marks.get(START_MARKER), marks.get(END_MARKER)
    if isinstance(start, (int, float)) and isinstance(end, (int, float)):
        if end > start:
            return (end - start) / 1e6, "phase_markers"
    acts = [e for e in events if e.get("cat") == ACTION_CAT
            and isinstance(e.get("ts"), (int, float))
            and isinstance(e.get("dur"), (int, float))]
    if not acts:
        return 0.0, "none"
    low = min(e["ts"] for e in acts)
    high = max(e["ts"] + e["dur"] for e in acts)
    return (high - low) / 1e6, "action_span"


def measure_trace(path):
    """Step walls (seconds) of one trace: ``{(step, group): seconds}``."""
    try:
        events = read_trace_events(path)
    except (OSError, ValueError) as exc:
        raise PackStepsError("unreadable trace %s: %s" % (path, exc))
    walls = {}
    for event in events:
        dur = event.get("dur")
        if event.get("cat") != ACTION_CAT or not isinstance(dur, (int, float)):
            continue
        key = step_key(event)
        if key is None:
            continue
        seconds = dur / 1e6
        if key[0] == "kernel_compile":
            walls[key] = max(walls.get(key, 0.0), seconds)
        else:
            walls[key] = walls.get(key, 0.0) + seconds
    if not any(name in dict(STEPS) for name, _ in walls):
        raise PackStepsError(
            "trace %s has no FlutterApkOverlay, AndroidZipAlign or "
            "ApkSignerTool action (by mnemonic or progress message)" % path)
    wall, source = trace_wall(events)
    return {"steps": walls, "wall": wall, "wall_source": source}


def median(values):
    """Median rounded to microseconds."""
    return round(statistics.median(values), 6)


def jvm_floor(signer, runs=FLOOR_RUNS, runner=subprocess.run,
              clock=time.perf_counter):
    """Median wall of ``<signer> --version`` runs: the cold-JVM floor."""
    walls = []
    for _ in range(runs):
        began = clock()
        try:
            done = runner([signer, "--version"], capture_output=True,
                          check=False)
        except OSError as exc:
            raise PackStepsError("cannot run signer %s: %s" % (signer, exc))
        if done.returncode != 0:
            raise PackStepsError("signer %s --version exited %d"
                                 % (signer, done.returncode))
        walls.append(clock() - began)
    return median(walls)


def apk_size(apk_dir, step, group):
    """Byte size of the step's output APK under apk_dir, or None."""
    suffix = "" if group == "full" else "_" + group
    sizes = []
    for root, _dirs, files in os.walk(apk_dir):
        for name in files:
            if name.endswith(".apk") and _is_output(name, step, suffix):
                sizes.append(os.path.getsize(os.path.join(root, name)))
    return max(sizes) if sizes else None


def _is_output(name, step, suffix):
    """Whether file name is the output APK of step in the group suffix."""
    stem = name[:-len(".apk")]
    has_group = any(stem.endswith(s) or stem.endswith(s + "_unsigned")
                    for s in ("_base", "_payload"))
    if step == "overlay":
        want = stem.endswith(suffix + "_unsigned") if suffix else (
            stem.endswith("_unsigned") and not has_group)
        return want
    if step == "zipalign":
        return stem.startswith("zipaligned_") and (
            stem.endswith(suffix) if suffix else not has_group)
    plain = not stem.startswith("zipaligned_") and "_unsigned" not in stem
    return plain and (stem.endswith(suffix) if suffix else not has_group)


def step_table(measures):
    """Median wall per (step, group) over a flow's traces."""
    keys = sorted({k for m in measures for k in m["steps"]})
    return {k: median([m["steps"][k] for m in measures if k in m["steps"]])
            for k in keys}


def classify(seconds, wall):
    """Bounded gain record under the 10% rule."""
    percent = round(100.0 * seconds / wall, 3) if wall > 0 else 0.0
    verdict = ("later_item" if percent >= THRESHOLD_PERCENT
               else "close_with_numbers")
    return {"seconds": round(seconds, 6), "percent_of_flow": percent,
            "verdict": verdict}


def rank_candidates(walls, wall, floor):
    """Candidates of one group, largest bound first."""
    ranked = []
    for name, step, text in CANDIDATES:
        bound = walls.get(step, 0.0)
        if name == "persistent_signing" and floor is not None:
            bound = max(0.0, bound - floor)
        ranked.append(dict(candidate=name, step=step, description=text,
                           **classify(bound, wall)))
    return sorted(ranked, key=lambda c: -c["seconds"])


def flow_report(name, paths, apk_dir, floor):
    """Full report of one flow from its traces."""
    measures = [measure_trace(p) for p in paths]
    wall = median([m["wall"] for m in measures])
    table = step_table(measures)
    groups = {}
    for (step, group), seconds in table.items():
        entry = {"median_s": seconds,
                 "share_of_flow": round(seconds / wall, 6) if wall else 0.0}
        if apk_dir and step in dict(STEPS):
            entry["apk_bytes"] = apk_size(apk_dir, step, group)
        groups.setdefault(group, {})[step] = entry
    if floor is not None and "sign" in groups.get("full", {}):
        _split_sign(groups["full"]["sign"], floor)
    packed = [g for g in GROUPS if set(groups.get(g, {})) & set(dict(STEPS))]
    primary = packed[0]
    per_group = {g: rank_candidates(
        {s: v["median_s"] for s, v in groups[g].items()}, wall, floor)
        for g in packed}
    return {"flow": name, "traces": len(paths), "wall_s": wall,
            "wall_source": measures[0]["wall_source"], "groups": groups,
            "primary_group": primary, "candidates": per_group[primary],
            "candidates_by_group": per_group}


def _split_sign(entry, floor):
    """Adds the JVM-start and signing-work split to a sign entry."""
    entry["jvm_start_s"] = floor
    entry["signing_work_s"] = round(max(0.0, entry["median_s"] - floor), 6)


def flow_name_of(path):
    """Flow label of a bare trace path: its dir, minus a rep directory."""
    parent = os.path.dirname(os.path.abspath(path))
    if re.fullmatch(r"rep\d+", os.path.basename(parent)):
        parent = os.path.dirname(parent)
    return "/".join(parent.split(os.sep)[-2:])


def group_specs(specs):
    """Ordered ``{flow: [paths]}`` of ``[FLOW=]TRACE`` arguments."""
    flows = {}
    for spec in specs:
        name, sep, path = spec.partition("=")
        if not sep or not name or os.path.exists(spec):
            name, path = flow_name_of(spec), spec
        flows.setdefault(name, []).append(path)
    return flows


def build_report(specs, apk_dir=None, signer=None):
    """The report of every flow named by the trace specs."""
    floor = jvm_floor(signer) if signer else None
    report = {"threshold_percent": THRESHOLD_PERCENT,
              "flows": [flow_report(n, p, apk_dir, floor)
                        for n, p in group_specs(specs).items()]}
    if floor is not None:
        report["jvm_floor_s"] = floor
    return report


def markdown(report):
    """Markdown tables of a report."""
    lines = []
    for flow in report["flows"]:
        lines += ["### %s (wall %.3f s, %d trace(s))"
                  % (flow["flow"], flow["wall_s"], flow["traces"]), "",
                  "| group | step | median s | share of flow | apk bytes |",
                  "|---|---|---|---|---|"]
        for group, steps in flow["groups"].items():
            for step, v in steps.items():
                share = "%.1f%%" % (100 * v["share_of_flow"])
                size = v.get("apk_bytes")
                lines.append("| %s | %s | %.3f | %s | %s |" % (
                    group, step, v["median_s"], share,
                    "" if size is None else size))
        lines += ["", "| candidate (%s) | bound s | percent of flow | "
                  "verdict |" % flow["primary_group"], "|---|---|---|---|"]
        for c in flow["candidates"]:
            lines.append("| %s | %.3f | %.1f%% | %s |" % (
                c["candidate"], c["seconds"], c["percent_of_flow"],
                c["verdict"]))
        lines.append("")
    return "\n".join(lines)


def main(argv=None):
    """CLI entry; returns the exit code."""
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("traces", nargs="+", metavar="[FLOW=]TRACE")
    ap.add_argument("--apk-dir")
    ap.add_argument("--signer")
    ap.add_argument("--format", choices=("json", "markdown", "both"),
                    default="both")
    args = ap.parse_args(argv)
    try:
        report = build_report(args.traces, args.apk_dir, args.signer)
    except PackStepsError as exc:
        print("android_pack_steps: %s" % exc, file=sys.stderr)
        return 2
    if args.format in ("json", "both"):
        print(json.dumps(report, indent=2, sort_keys=True))
    if args.format in ("markdown", "both"):
        print(markdown(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
