#!/usr/bin/env python3
"""Tests of `sol.py run --clean-replay`: the clean flow replays once per run.

Offline: the build, the chain proof and the host-tool replay are fakes that
count the spawns they are asked to replay, so no test depends on host speed.
"""

import argparse
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sol
from sol import summarize_flow

# Spawn count of each flow, in SCENARIOS order (clean, app, core, api).
SPAWNS = {"device_release": [208, 4, 4, 4], "sim_debug": [435, 5, 5, 136]}
CONFIGS = ["device_release", "sim_debug"]
SCENARIO_ORDER = ["clean", "app_edit", "core_edit", "api_edit"]


class FakeSol:
    """Stands in for the build, chain proof and replays of sol.py."""

    def __init__(self, tmp, fail_rep=None):
        self.tmp = tmp
        self.fail_rep = fail_rep
        self.replayed_spawns = 0
        self.proofs = []
        self.host_calls = 0
        self.builds = []

    def build(self, args, config, scenario, batch, server_pid=None):
        count = SPAWNS[config][SCENARIO_ORDER.index(scenario)]
        record_dir = os.path.join(args.results, "sol", config, scenario,
                                  "rep%d" % args.rep)
        os.makedirs(record_dir, exist_ok=True)
        self.builds.append((args.rep, config, scenario))
        return argparse.Namespace(
            bazel_cost={"cpu_s": 0.0, "user_s": 10.0 + args.rep,
                        "sys_s": 0.0, "real_s": 20.0,
                        "peak_rss_mb": 100.0, "parts": {}},
            log_path="log:%d" % count, profile_path=os.path.join(
                self.tmp, "absent-profile"),
            execroot=self.tmp, bazel_out=self.tmp, plan=None,
            record_dir=record_dir, swap=None, report_path="report",
            scenario=scenario)

    def prove(self, args, built, chainable, before, backup_dir):
        if self.fail_rep == args.rep and built.scenario == "clean":
            raise RuntimeError("chain exploded")
        self.proofs.append((args.rep, built.scenario))
        self.replayed_spawns += len(chainable)
        chain = {"failed": [], "status": "ok", "sol_cpu_s": 2.0,
                 "verify_differ": {"n": 0, "differ": []}}
        return (chain, dict(before), 0, {"n_replayed": len(chainable),
                                         "sol_real_s": 3.0})

    def host(self, spawns, execroot, timeout, backup_dir, runner=None):
        self.host_calls += 1
        return {"total": 0.5, "by_mnemonic": {}, "top_targets": [],
                "by_target": {}, "failed": [], "count": 0, "skipped": {}}

    def run(self, results, reps, policy, configs=None):
        """Runs the given repeats; returns the run_sol_rep results."""
        out = []
        for rep in reps:
            args = argparse.Namespace(
                results=results, rep=rep, work=self.tmp,
                pristine=self.tmp, out_base=self.tmp, timeout=1.0,
                clean_replay=policy, capture=None, capture_server=None,
                run=None)
            out.append(sol.run_sol_rep(args, rep, configs or CONFIGS)[0])
        return out

    def patches(self):
        return [
            mock.patch.object(sol, "measure_scenario_build", self.build),
            mock.patch.object(sol, "read_verify_snapshot",
                              lambda plan: {"out": "h"}),
            mock.patch.object(sol, "load_spawns", lambda log: list(
                range(int(log.split(":")[1])))),
            mock.patch.object(sol, "select_sol_spawns",
                              lambda spawns: (spawns, {})),
            mock.patch.object(sol, "count_worker_steps", lambda s: {}),
            mock.patch.object(sol, "prove_chain_outputs", self.prove),
            mock.patch.object(sol, "replay_host_spawns", self.host),
            mock.patch.object(sol, "floor_fields",
                              lambda *a, **k: {}),
            mock.patch.object(sol, "reset_work", lambda *a: None),
            mock.patch.object(sol, "server_pid_of", lambda *a: 1),
            mock.patch.object(sol, "run_warm_ups", lambda *a: {}),
            mock.patch.object(sol, "shutdown", lambda *a: None),
        ]


class CleanReplayRunTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name
        self.results = os.path.join(self.tmp, "results")
        self.fake = FakeSol(self.tmp)

    def tearDown(self):
        self._tmp.cleanup()

    def run_reps(self, policy, reps=(1, 2, 3), fake=None):
        fake = fake or self.fake
        for patch in fake.patches():
            patch.start()
            self.addCleanup(patch.stop)
        return fake.run(self.results, reps, policy)

    def test_default_replays_clean_once(self):
        self.run_reps("first")
        self.assertEqual(self.fake.replayed_spawns, 801 + 2 * 158)
        self.assertEqual(self.fake.replayed_spawns, 1117)
        clean_proofs = [p for p in self.fake.proofs if p[1] == "clean"]
        self.assertEqual(clean_proofs, [(1, "clean")] * 2)
        self.assertEqual(self.fake.host_calls, 3 * 8 - 2 * 2)

    def test_every_replays_every_repeat(self):
        self.run_reps("every")
        self.assertEqual(self.fake.replayed_spawns, 3 * 801)
        self.assertEqual(self.fake.replayed_spawns, 2403)

    def test_parser_default_is_first(self):
        args = sol.build_parser().parse_args([
            "run", "--tools", "t", "--pristine", "p", "--work", "w",
            "--out-base", "o", "--results", "r", "--rep", "1"])
        self.assertEqual(args.clean_replay, "first")
        args = sol.build_parser().parse_args([
            "run", "--tools", "t", "--pristine", "p", "--work", "w",
            "--out-base", "o", "--results", "r", "--rep", "1",
            "--clean-replay", "every"])
        self.assertEqual(args.clean_replay, "every")

    def test_skipped_record_shape(self):
        reps = self.run_reps("first")
        skipped = reps[1]["sim_debug"]["clean"]
        self.assertIs(skipped["sol_replayed"], False)
        self.assertIsNone(skipped["sol"])
        self.assertNotIn("chain", skipped)
        self.assertNotIn("host_tools", skipped["profile"])
        self.assertIn("skipped", skipped["reason"])
        self.assertIn("rep1", skipped["reason"])
        self.assertEqual(skipped["bazel"]["peak_rss_mb"], 100.0)
        with open(os.path.join(self.results, "sol", "sim_debug", "clean",
                               "rep3", "record.json"),
                  encoding="utf-8") as fh:
            self.assertEqual(json.load(fh)["sol_replayed"], False)
        for record in (reps[0]["sim_debug"]["clean"],
                       reps[1]["sim_debug"]["api_edit"]):
            self.assertIs(record["sol_replayed"], True)
            self.assertEqual(record["sol"]["cpu_s"], 2.0)

    def test_first_repeat_failure_makes_next_replay(self):
        fake = FakeSol(self.tmp, fail_rep=1)
        reps = self.run_reps("first", reps=(1, 2, 3), fake=fake)
        self.assertEqual(reps[0]["device_release"]["clean"]["reason"][:6],
                         "config")
        replayed = [p for p in fake.proofs if p[1] == "clean"]
        self.assertEqual(replayed, [(2, "clean")] * 2)
        self.assertIs(reps[1]["sim_debug"]["clean"]["sol_replayed"], True)
        self.assertIs(reps[2]["sim_debug"]["clean"]["sol_replayed"], False)
        self.assertIn("rep2", reps[2]["sim_debug"]["clean"]["reason"])


def record(sol_cpu, bazel, replayed=True, identical=True, wall=10.0,
           floor=1.0, host=2.0):
    """One clean-flow record, replayed or skipped."""
    rec = {"flow": "ios-debug-clean", "scenario": "clean",
           "method": "batch",
           "bazel": {"cpu_s": bazel, "real_s": wall, "peak_rss_mb": 5.0},
           "floor_identical": True,
           "toolchain_floor": {"cpu_s": floor},
           "profile": {"jvm": {"total": 3.0, "phases": {}}}}
    if replayed:
        rec.update({"sol": {"cpu_s": sol_cpu}, "identical": identical,
                    "reason": "ok" if identical else "step failed",
                    "chain": {"status": "ok"}})
        rec["profile"].update({
            "host_tools": {"total": host, "by_mnemonic": {},
                           "by_target": {}, "failed": []},
            "sol_cpu_s": sol_cpu})
    else:
        rec.update({"sol": None, "identical": None, "sol_replayed": False,
                    "reason": "clean replay skipped: replayed in rep1"})
        rec["profile"].update({"sol_cpu_s": None})
    return rec


class CleanReplaySummaryTest(unittest.TestCase):
    def test_one_replayed_two_skipped(self):
        records = [record(20.0, 100.0), record(None, 110.0, False,
                                               wall=11.0, floor=2.0),
                   record(None, 130.0, False, wall=12.0, floor=3.0)]
        flow = summarize_flow(records, "cpu_seconds")
        self.assertEqual(flow["sol"], 20.0)
        self.assertEqual(flow["sol_reps"], 1)
        self.assertIs(flow["identical"], True)
        self.assertEqual(flow["reason"], "ok")
        self.assertEqual(flow["bazel"], 110.0)
        self.assertEqual(flow["wall_s"], 11.0)
        self.assertEqual(flow["toolchain_floor"], 2.0)
        self.assertEqual(flow["bazel_over_toolchain_floor"], 55.0)
        self.assertEqual(flow["spread"]["sol"], [20.0, 20.0])
        self.assertEqual(flow["spread"]["bazel"], [100.0, 130.0])
        self.assertEqual(flow["spread"]["n"], 3)
        self.assertEqual(flow["chain"], {"status": "ok"})
        profile = flow["profile"]
        self.assertEqual(profile["host_tools"]["total"], 2.0)
        self.assertEqual(profile["sol_cpu_s"], 20.0)
        # Residual: the replayed repeat's Bazel number, not the median.
        self.assertEqual(profile["residual"], 100.0 - 3.0 - 20.0 - 2.0)

    def test_records_without_key_summarize_as_before(self):
        records = [record(20.0, 100.0), record(22.0, 110.0),
                   record(24.0, 130.0)]
        flow = summarize_flow(records, "cpu_seconds")
        self.assertEqual(flow["sol"], 22.0)
        self.assertEqual(flow["sol_reps"], 3)
        self.assertEqual(flow["spread"]["sol"], [20.0, 24.0])
        self.assertEqual(flow["profile"]["residual"],
                         110.0 - 3.0 - 22.0 - 2.0)
        explicit = [dict(rec, sol_replayed=True) for rec in records]
        self.assertEqual(summarize_flow(explicit, "cpu_seconds"), flow)

    def test_replayed_non_identical_still_fails_flow(self):
        records = [record(20.0, 100.0, identical=False),
                   record(None, 110.0, False), record(None, 130.0, False)]
        records[0]["sol"] = None
        flow = summarize_flow(records, "cpu_seconds")
        self.assertIs(flow["identical"], False)
        self.assertIsNone(flow["sol"])
        self.assertEqual(flow["reason"], "step failed")
        self.assertEqual(flow["bazel"], 110.0)


if __name__ == "__main__":
    unittest.main()
