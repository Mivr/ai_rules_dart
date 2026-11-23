#!/usr/bin/env python3
"""Same-runner A/B for the iOS speed-of-light bench.

Two 100k runs of the same commit on two free macOS runners differed
1.3-1.7x on flows no flag could touch, so comparing two separate runs
does not measure a flag. An A/B must run both arms on the same runner,
interleaved: repeat 1 runs control first, repeat 2 treatment first, and
so on alternating. Each arm runs the full sol scenario sequence (clean
batch, warm-up, warm edits, chains) in its own output base and work
directory, exactly as a single sol run does, and every server and worker
of one arm is gone before the other arm starts.

Two A/B shapes (sol mode only):

- ``flags``: control is the workspace with the ``lockfile`` setting and
  no flags; treatment adds ``bazel_flags`` (which must be non-empty).
- ``lockfile``: both arms get ``bazel_flags``; control has no lockfile
  and treatment carries the committed one (``lockfile`` input must be
  ``none`` here; the committed lock is still generated once for the
  treatment arm).

The committed lockfile models a real team's checkout: it is generated
on the runner, before any measured build, by an unmeasured Bazel run
with the workspace's default lockfile mode and its own output base.
That run builds every bench target for both configs (analysis only, so
it is fast) to evaluate everything the measured builds need. Its output
base is deleted afterwards and its server shut down. Every measured
build still starts from a fresh output base. The lock is generated once
per job and every repeat gets the same bytes.

Only the Python 3 standard library is used. Module and repository names
are never hard-coded: targets and flags come from the shared CONFIGS
table and the validated flag list.
"""

import argparse
import json
import math
import os
import shutil
import stat
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run_rep import (  # noqa: E402
    CONFIGS,
    DEFAULT_MIN_CLEAN_ACTIONS,
    IOS_CONFIGS,
    SCENARIOS,
    shutdown,
)
from summarize import summarize_values  # noqa: E402
import sol  # noqa: E402
import sol_summary  # noqa: E402
import warm_server  # noqa: E402
import deadline  # noqa: E402

AB_CHOICES = ("off", "flags", "lockfile")
LOCKFILE_CHOICES = ("none", "committed")
LOCK_REL_PATH = "MODULE.bazel.lock"
PLATFORM_CHOICES = ("ios", "android", "web")
DEFAULT_PLATFORM = "ios"
CONTROL = "control"
TREATMENT = "treatment"


def platform_configs(platform):
    """The platform's two bench configs, in sol_summary's table order."""
    if platform not in PLATFORM_CHOICES:
        raise ValueError("invalid platform %r: expected one of %s"
                         % (platform, "/".join(PLATFORM_CHOICES)))
    return sol_summary.configs_for_platform(platform)


def validate_ab(mode, ab, lockfile, flags):
    """Checks A/B inputs; returns the flag list or raises ValueError.

    Every refusal names the offending input plainly so the job fails at
    once with a clear message before anything is generated or built.
    """
    if ab not in AB_CHOICES:
        raise ValueError("invalid ab %r: expected one of %s"
                         % (ab, "/".join(AB_CHOICES)))
    if lockfile not in LOCKFILE_CHOICES:
        raise ValueError("invalid lockfile %r: expected one of %s"
                         % (lockfile, "/".join(LOCKFILE_CHOICES)))
    if ab != "off" and mode != "sol":
        raise ValueError("ab=%s needs mode=sol (got mode=%s): A/B arms "
                         "only run in sol mode" % (ab, mode))
    if ab == "flags" and not list(flags):
        raise ValueError("ab=flags needs a non-empty bazel_flags input: "
                         "the treatment arm is the flags")
    if ab == "lockfile" and lockfile != "none":
        raise ValueError("ab=lockfile needs lockfile=none (got %r): "
                         "control has no lockfile, treatment the "
                         "committed one" % (lockfile,))
    return list(flags)


def first_arm(rep):
    """Which arm runs first in a 1-based repeat (alternating)."""
    return CONTROL if rep % 2 == 1 else TREATMENT


def arm_order(repeats):
    """Per-repeat arm order, e.g. 3 repeats is control/treatment/control."""
    return [("control-first" if first_arm(rep) == CONTROL
             else "treatment-first")
            for rep in range(1, repeats + 1)]


def remove_tree(path):
    """Removes a tree, restoring write permission first; fails loudly.

    Bazel leaves read-only directories behind, so a plain rmtree can
    silently keep them (or raise halfway). Every bit is made writable
    first, then the tree is deleted, and a survivor fails loudly instead
    of letting the next build reuse a stale output base.
    """
    if not os.path.lexists(path):
        return
    for dirpath, dirnames, filenames in os.walk(path, followlinks=False):
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                continue
            try:
                mode = os.stat(full).st_mode
                extra = stat.S_IWUSR
                if os.path.isdir(full):
                    extra |= stat.S_IXUSR
                if mode & extra != extra:
                    os.chmod(full, mode | extra)
            except OSError:
                continue
    try:
        shutil.rmtree(path)
    except OSError as exc:
        raise RuntimeError("cannot remove %s (%s)" % (path, exc))
    if os.path.lexists(path):
        raise RuntimeError("cannot remove %s" % path)


def lock_path(workspace):
    """Absolute path of the workspace's committed lockfile."""
    return os.path.join(workspace, LOCK_REL_PATH)


def read_lock_bytes(workspace):
    """Committed lock bytes, or None when the workspace has no lock."""
    try:
        with open(lock_path(workspace), "rb") as fh:
            return fh.read()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise RuntimeError("cannot read %s (%s)"
                           % (lock_path(workspace), exc))


def write_lock_bytes(workspace, data):
    """Writes committed lock bytes into a workspace copy."""
    try:
        with open(lock_path(workspace), "wb") as fh:
            fh.write(data)
    except OSError as exc:
        raise RuntimeError("cannot write %s (%s)"
                           % (lock_path(workspace), exc))


def remove_lock(workspace):
    """Removes a workspace copy's lockfile, if it has one."""
    try:
        os.remove(lock_path(workspace))
    except FileNotFoundError:
        pass
    except OSError as exc:
        raise RuntimeError("cannot remove %s (%s)"
                           % (lock_path(workspace), exc))


def lock_build_argv(lock_out, config):
    """Analysis-only build argv generating the lock for one config.

    No lockfile flag (the workspace default applies), its own output
    base, ``--nobuild`` so only loading and analysis run: fast, and it
    still evaluates the module extensions whose results Bazel stores in
    the lockfile.
    """
    spec = CONFIGS[config]
    return (["bazel", "--output_base=" + lock_out, "build"]
            + list(spec["build_flags"]) + [spec["target"], "--nobuild"])


def generate_committed_lock(pristine, lock_out, run):
    """Generates the committed lock once; returns its bytes.

    Runs an unmeasured analysis-only build of every bench target (both
    configs, same output base), shuts that server down, deletes the
    output base, and proves the lock exists. Loud on any failure: a
    missing lock or a failed build raises instead of measuring without
    one. Nothing measured is touched, so the step is unmeasured.
    """
    remove_tree(lock_out)
    try:
        for config in IOS_CONFIGS:
            proc = run(lock_build_argv(lock_out, config), cwd=pristine)
            if proc.returncode != 0:
                raise RuntimeError(
                    "lockfile build for %s failed (exit %s)"
                    % (config, proc.returncode))
    finally:
        try:
            shutdown(run, pristine, lock_out)
        finally:
            remove_tree(lock_out)
    data = read_lock_bytes(pristine)
    if not data:
        raise RuntimeError("lockfile run left no %s in %s"
                           % (LOCK_REL_PATH, pristine))
    return data


def load_arm_rep_record(results_arm, config, scenario, rep):
    """One arm's record for one repeat, or None when it never ran."""
    path = os.path.join(results_arm, "sol", config, scenario,
                        "rep%d" % rep, "record.json")
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def pair_ratio(control, treatment, key="cpu_s"):
    """Treatment/control bazel ratio, or None when the pair is unusable.

    A pair needs both records present, both identical, and both Bazel
    numbers (``bazel[key]``: CPU by default) present with a non-zero
    control: anything else (a missing repeat, a failed proof in either
    arm) has no pair for that repeat.
    """
    if control is None or treatment is None:
        return None
    if not control.get("identical") or not treatment.get("identical"):
        return None
    control_value = (control.get("bazel") or {}).get(key)
    treatment_value = (treatment.get("bazel") or {}).get(key)
    if control_value is None or treatment_value is None:
        return None
    if control_value == 0:
        return None
    return treatment_value / control_value


def geomean(values):
    """Geometric mean of positive ratios, or None when there are none."""
    if not values:
        return None
    if any(v is None or v <= 0 for v in values):
        return None
    return math.exp(sum(math.log(v) for v in values) / len(values))


def _ratio_summary(ratios, unpaired):
    """median / min / max / geomean / n / unpaired of paired ratios."""
    summary = summarize_values(ratios)
    return {"median": summary["median"], "min": summary["min"],
            "max": summary["max"], "geomean": geomean(ratios),
            "n": summary["n"], "unpaired": unpaired}


def ratio_for_flow(results_control, results_treatment, config, scenario,
                   repeats):
    """Paired per-repeat ratios for one flow (same repeat pairs only).

    The top-level keys are the CPU ratios; ``wall`` (``bazel.real_s``) and
    ``peak_rss`` (``bazel.peak_rss_mb``) are sibling objects with the same
    shape, paired by the same rule.
    """
    keys = {"cpu_s": ([], []), "real_s": ([], []),
            "peak_rss_mb": ([], [])}
    for rep in range(1, repeats + 1):
        control = load_arm_rep_record(results_control, config, scenario,
                                      rep)
        treatment = load_arm_rep_record(results_treatment, config,
                                        scenario, rep)
        for key, (ratios, unpaired) in keys.items():
            value = pair_ratio(control, treatment, key)
            if value is None:
                unpaired.append(rep)
            else:
                ratios.append(value)
    entry = _ratio_summary(*keys["cpu_s"])
    entry["wall"] = _ratio_summary(*keys["real_s"])
    entry["peak_rss"] = _ratio_summary(*keys["peak_rss_mb"])
    return entry


def summarize_arm_flows(results_arm, platform=DEFAULT_PLATFORM):
    """{flow: flow record} medians over one arm's repeats (sol schema)."""
    flows = {}
    for config in platform_configs(platform):
        for scenario, _ in SCENARIOS:
            flow = sol.flow_id(config, scenario)
            records = sol.load_sol_records(results_arm, config, scenario)
            if records:
                flows[flow] = sol.summarize_flow(records, "cpu_seconds")
            else:
                flows[flow] = {"error": "missing repeats"}
    return flows


def arm_records(results_dirs, platform):
    """Per-flow record lists of every arm (for the timeout marker)."""
    return [sol.load_sol_records(results, config, scenario)
            for results in results_dirs
            for config in platform_configs(platform)
            for scenario, _ in SCENARIOS]


def summarize_ab(results_control, results_treatment, meta):
    """<platform>-ab.json dict: per-arm medians plus paired ratios."""
    platform = meta.get("platform", DEFAULT_PLATFORM)
    control_flows = summarize_arm_flows(results_control, platform)
    treatment_flows = summarize_arm_flows(results_treatment, platform)
    ratios = {}
    for config in platform_configs(platform):
        for scenario, _ in SCENARIOS:
            flow = sol.flow_id(config, scenario)
            ratios[flow] = ratio_for_flow(results_control,
                                          results_treatment, config,
                                          scenario, meta["repeats"])
    order = list(meta["order"])
    ab_meta = {"repeats": meta["repeats"],
               "target_loc": meta["target_loc"], "seed": meta["seed"],
               "ab": meta["ab"],
               "bazel_flags": list(meta.get("bazel_flags", [])),
               "lockfile": meta.get("lockfile", "none"),
               "order": order}
    if sol_summary.any_timeout(arm_records(
            (results_control, results_treatment), platform)):
        ab_meta["timed_out"] = True
    return {"rules_flutter": meta["sha"], "unit": "cpu_seconds",
            "runner": sol.collect_runner_info(),
            "meta": ab_meta,
            "arms": {CONTROL: control_flows, TREATMENT: treatment_flows},
            "ratio": dict(ratios)}


def child_args(args, pristine, work, out_base, results):
    """Per-arm sol args sharing the parent's measurement functions."""
    return argparse.Namespace(
        tools=args.tools, pristine=pristine, work=work,
        out_base=out_base, results=results, rep=0,
        timeout=args.timeout, min_clean_actions=args.min_clean_actions,
        run=args.run, capture=args.capture,
        capture_server=args.capture_server, measure=args.measure,
        measure_warm=args.measure_warm,
        deadline=deadline.of(args))


def arm_paths(args, arm, rep):
    """Per-repeat work and output-base paths for one arm (fresh paths).

    Every (arm, repeat) pair measures in directories no earlier repeat
    ever used, exactly as a single sol run gets a fresh path per repeat.
    """
    if arm == CONTROL:
        roots = (args.work_root_control, args.out_base_root_control)
    else:
        roots = (args.work_root_treatment, args.out_base_root_treatment)
    return (os.path.join(roots[0], "rep%d" % rep),
            os.path.join(roots[1], "rep%d" % rep))


def run_ab_measure(args, configs):
    """Every repeat, both arms, alternating which runs first.

    Each arm runs the full sol scenario sequence through sol's own
    repeat driver in a work directory and output base no earlier repeat
    used (both emptied before use, loudly); sol shuts each config's
    server down, so every server and worker of one arm is gone before
    the other arm starts. Returns True when any arm erred.
    """
    had_errors = False
    for rep in range(1, args.repeats + 1):
        first = first_arm(rep)
        second = TREATMENT if first == CONTROL else CONTROL
        for arm in (first, second):
            if arm == CONTROL:
                pristine = args.pristine_control
            else:
                pristine = args.pristine_treatment
            work, out_base = arm_paths(args, arm, rep)
            remove_tree(work)
            remove_tree(out_base)
            child = child_args(args, pristine, work, out_base,
                               os.path.join(args.results, arm))
            _, arm_errors = sol.run_sol_rep(child, rep, configs)
            had_errors = had_errors or arm_errors
            print("rep=%d arm=%s errors=%s" % (rep, arm, arm_errors))
    return had_errors


def main_validate(cmd):
    from bench_flags import parse_bazel_flags  # noqa: E402
    from bench_flags import validate_bazel_flags  # noqa: E402
    flags = validate_bazel_flags(parse_bazel_flags(cmd.flags))
    validate_ab(cmd.mode, cmd.ab, cmd.lockfile, flags)
    print("ab inputs ok: mode=%s ab=%s lockfile=%s flags=%s"
          % (cmd.mode, cmd.ab, cmd.lockfile, flags))
    return 0


def main_lock(cmd):
    from run_rep import real_run  # noqa: E402
    data = generate_committed_lock(cmd.pristine, cmd.lock_out, real_run)
    print("lockfile %s bytes=%d out_base_removed=1"
          % (LOCK_REL_PATH, len(data)))
    return 0


def main_run(cmd):
    from run_rep import real_run  # noqa: E402
    cmd.run = real_run
    cmd.capture = sol.capture_bazel_output
    cmd.capture_server = sol.capture_bazel_output
    deadline.install_measures(cmd, sol.measure_process_tree,
                              warm_server.measure)
    configs = (list(cmd.config) if cmd.config
               else list(platform_configs(cmd.platform)))
    unknown = [c for c in configs if c not in CONFIGS]
    if unknown:
        raise ValueError("unknown config(s): %s" % ", ".join(unknown))
    had_errors = run_ab_measure(cmd, configs)
    return 1 if had_errors else 0


def arm_pair(summary, flow, key):
    """``control,treatment`` medians of one flow value, for a line."""
    values = []
    for arm in (CONTROL, TREATMENT):
        entry = summary["arms"][arm].get(flow) or {}
        values.append(entry.get(key))
    return "%s,%s" % tuple(values)


def print_ratio_line(summary, flow):
    """One stdout line per flow: CPU ratios, then wall and peak RSS as
    ``control,treatment`` medians with their paired median ratios."""
    entry = summary["ratio"][flow]
    print("flow=%s n=%s median=%s geomean=%s min=%s max=%s "
          "unpaired=%s wall_s=%s peak_rss_mb=%s wall_ratio=%s "
          "peak_rss_ratio=%s" % (
              flow, entry["n"], entry["median"], entry["geomean"],
              entry["min"], entry["max"], entry["unpaired"],
              arm_pair(summary, flow, "wall_s"),
              arm_pair(summary, flow, "peak_rss_mb"),
              entry["wall"]["median"], entry["peak_rss"]["median"]))


def main_summarize(cmd):
    from bench_flags import parse_bazel_flags  # noqa: E402
    from bench_flags import validate_bazel_flags  # noqa: E402
    flags = validate_bazel_flags(parse_bazel_flags(cmd.bazel_flags))
    validate_ab("sol", cmd.ab, cmd.lockfile, flags)
    if cmd.ab == "off":
        raise ValueError("ab=summarize needs ab=flags or ab=lockfile")
    meta = {"sha": cmd.sha, "repeats": cmd.repeats,
            "target_loc": cmd.target_loc, "seed": cmd.seed, "ab": cmd.ab,
            "bazel_flags": flags, "lockfile": cmd.lockfile,
            "order": arm_order(cmd.repeats), "platform": cmd.platform}
    summary = summarize_ab(os.path.join(cmd.results, CONTROL),
                           os.path.join(cmd.results, TREATMENT), meta)
    with open(cmd.out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    for flow in sorted(summary["ratio"]):
        print_ratio_line(summary, flow)
    return 0


def build_parser():
    parser = argparse.ArgumentParser(
        description="Same-runner A/B for the SOL bench (iOS, Android, "
                    "Web).")
    sub = parser.add_subparsers(dest="command", required=True)
    valid = sub.add_parser("validate", help="fail fast on bad A/B inputs")
    valid.add_argument("--mode", required=True)
    valid.add_argument("--ab", required=True)
    valid.add_argument("--lockfile", required=True)
    valid.add_argument("--flags", default="")
    lock = sub.add_parser("lock", help="generate one committed lockfile")
    lock.add_argument("--pristine", required=True)
    lock.add_argument("--lock-out", required=True)
    run = sub.add_parser("run", help="measure every repeat, both arms")
    run.add_argument("--tools", required=True)
    run.add_argument("--pristine-control", required=True)
    run.add_argument("--pristine-treatment", required=True)
    run.add_argument("--work-root-control", required=True)
    run.add_argument("--work-root-treatment", required=True)
    run.add_argument("--out-base-root-control", required=True)
    run.add_argument("--out-base-root-treatment", required=True)
    run.add_argument("--results", required=True)
    run.add_argument("--repeats", type=int, required=True)
    run.add_argument("--config", action="append", default=[],
                     choices=sorted(CONFIGS))
    run.add_argument("--platform", choices=PLATFORM_CHOICES,
                     default=DEFAULT_PLATFORM)
    run.add_argument("--timeout", type=float, default=1800.0)
    run.add_argument("--min-clean-actions", type=int,
                     default=DEFAULT_MIN_CLEAN_ACTIONS)
    run.add_argument("--time-bin", default=sol.TIME_BIN)
    deadline.add_deadline_arg(run)
    summ = sub.add_parser("summarize",
                          help="write <platform>-ab.json medians")
    summ.add_argument("--platform", choices=PLATFORM_CHOICES,
                      default=DEFAULT_PLATFORM)
    summ.add_argument("--results", required=True)
    summ.add_argument("--sha", required=True)
    summ.add_argument("--repeats", type=int, required=True)
    summ.add_argument("--target-loc", type=int, required=True)
    summ.add_argument("--seed", type=int, required=True)
    summ.add_argument("--ab", required=True)
    summ.add_argument("--bazel-flags", default="")
    summ.add_argument("--lockfile", default="none")
    summ.add_argument("--out", required=True)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.command == "validate":
        return main_validate(args)
    if args.command == "lock":
        return main_lock(args)
    if args.command == "run":
        return main_run(args)
    return main_summarize(args)


if __name__ == "__main__":
    sys.exit(main())
