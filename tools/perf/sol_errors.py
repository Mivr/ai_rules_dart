"""Failed-flow records of the sol driver (split out of sol.py).

A config that fails unexpectedly records its remaining flows as
failed-with-reason, loudly but alive, so one failure never loses a run.
"""

import json
import os

from sol_summary import BATCH_METHOD
from sol_summary import WARM_METHOD
from sol_summary import _RECORD
from run_rep import SCENARIOS
from sol_summary import flow_id
from deadline import TIMEOUT_REASON, DeadlineExceeded


def error_record(config, scenario, reason):
    """Flow record for a scenario an unexpected error kept from running."""
    return {"flow": flow_id(config, scenario), "config": config,
            "scenario": scenario,
            "method": (BATCH_METHOD if scenario == "clean"
                       else WARM_METHOD),
            "bazel": {"cpu_s": None, "real_s": None},
            "sol": None,
            "identical": False,
            "reason": reason,
            "n_sol_actions": 0,
            "worker_steps": {},
            "verify": {"before": {}, "after": {}},
            "profile": {"jvm": {"total": None, "phases": {}},
                        "host_tools": {"total": None, "by_mnemonic": {},
                                       "top_targets": [], "failed": []},
                        "sol_cpu_s": None, "sol_source": "none",
                        "residual": None},
            "chain": {"steps": {}, "skipped": {}, "failed": [],
                      "ordering_failed": None,
                      "verify_differ": {"n": 0, "differ": []},
                      "output_drift": {"n": 0, "paths": []},
                      "sol_cpu_s": None, "status": "error"}}


def write_error_records(args, config, scenarios, reason):
    """Records remaining flows as failed-with-reason, loudly but alive."""
    records = {}
    short = reason if len(reason) <= 300 else reason[:297] + "..."
    for scenario in scenarios:
        record = error_record(config, scenario, short)
        record_dir = os.path.join(args.results, "sol", config, scenario,
                                  "rep%d" % args.rep)
        os.makedirs(record_dir, exist_ok=True)
        with open(os.path.join(record_dir, _RECORD), "w", encoding="utf-8",
                  newline="\n") as fh:
            fh.write(json.dumps(record, indent=2, sort_keys=True) + "\n")
        records[scenario] = record
    return records


def record_unfinished(args, config, flows, exc=None):
    """Records the config's flows not in `flows` and returns all flows.

    A deadline stop (or none given: the deadline had already passed)
    records the reason `timeout`; any other error names what failed.
    """
    if exc is None or isinstance(exc, DeadlineExceeded):
        reason = TIMEOUT_REASON
    else:
        reason = "config %s failed: %s" % (config, exc)
    remaining = [scenario for scenario, _ in SCENARIOS
                 if scenario not in flows]
    flows.update(write_error_records(args, config, remaining, reason))
    return flows
