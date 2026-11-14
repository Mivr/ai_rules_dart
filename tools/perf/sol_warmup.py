"""Unmeasured warm-ups of one config's server (split out of sol.py).

After the clean flow, a build on the config's server must execute zero
actions (the restore left the action cache undisturbed), then one app edit
and its build warm the persistent workers, so the first measured edit
flow measures a warm worker rather than a cold start. Neither build ever
enters a flow's chain, profile or replay: each has its own execution log.
"""

import os

from bench_flags import worker_steps as count_worker_steps
from execlog import load_spawns
from run_rep import CONFIGS
from run_rep import apply_edit
from sol_argv import build_argv
from sol_argv import out_base_of

WARM_UP_EDIT = "apply-app-edit"


def check_warmup_actions(log_path, target):
    """Fails the config when the warm-up build executed any action.

    The warm-up replays the clean build after its chain and replay
    restored every output: zero executed spawns proves the restore left
    the action cache undisturbed. Any spawn means the outputs were
    perturbed and the edit numbers would measure rebuild work the
    developer never pays.
    """
    try:
        n_spawns = len(load_spawns(log_path))
    except OSError as exc:
        raise RuntimeError(
            "warm-up build of %s left no execution log %s (%s)"
            % (target, log_path, exc))
    if n_spawns != 0:
        raise RuntimeError(
            "warm-up build of %s executed %d action(s): "
            "the clean outputs were perturbed" % (target, n_spawns))
    return n_spawns


def warm_up_server_build(args, config):
    """Unmeasured server-mode build proving the clean restore is exact.

    Runs the same target and flags through the config's server (never
    `--batch`) with an execution log that must list zero executed
    spawns; anything else fails the config with that reason.
    """
    spec = CONFIGS[config]
    log_path = os.path.join(args.work,
                            "execlog-sol-warmup-%s.json" % config)
    argv = build_argv(out_base_of(args, config), config, log_path, None,
                      False)
    proc = args.run(argv, cwd=args.work)
    if proc.returncode != 0:
        raise RuntimeError("warm-up bazel build %s failed (exit %s)"
                           % (spec["target"], proc.returncode))
    return check_warmup_actions(log_path, spec["target"])


def warm_up_edit_build(args, config):
    """Unmeasured app edit plus build on the server; returns its record.

    The build must execute at least one action, or the config fails with
    a reason naming the config and the target. The record carries the
    edit command, the executed action count and how many of those
    spawns ran in a persistent worker.
    """
    spec = CONFIGS[config]
    apply_edit(args.run, args.tools, args.work, WARM_UP_EDIT)
    log_path = os.path.join(args.work,
                            "execlog-sol-warmup-edit-%s.json" % config)
    argv = build_argv(out_base_of(args, config), config, log_path, None,
                      False)
    proc = args.run(argv, cwd=args.work)
    if proc.returncode != 0:
        raise RuntimeError("config %s: warm-up edit build of %s failed "
                           "(exit %s)" % (config, spec["target"],
                                          proc.returncode))
    try:
        spawns = load_spawns(log_path)
    except OSError as exc:
        raise RuntimeError(
            "config %s: warm-up edit build of %s left no execution log "
            "%s (%s)" % (config, spec["target"], log_path, exc))
    if not spawns:
        raise RuntimeError(
            "config %s: warm-up edit build of %s executed no action: the "
            "edit did not reach the build" % (config, spec["target"]))
    return {"edit": WARM_UP_EDIT, "executed_actions": len(spawns),
            "worker_spawns": sum(count_worker_steps(spawns).values())}


def run_warm_ups(args, config):
    """Both warm-ups of one config in order; returns the edit record."""
    warm_up_server_build(args, config)
    return warm_up_edit_build(args, config)
