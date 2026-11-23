#!/usr/bin/env python3
"""Unit tests for sol_warmup.py and its place in run_sol_rep (offline)."""

import argparse
import json
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sol
import sol_warmup
from run_rep import CONFIGS, SCENARIOS

_TARGET = CONFIGS["device_release"]["target"]


class Proc:
    returncode = 0
    stdout = ""


class FakeBazel:
    """args.run double: logs each command and writes the next exec log.

    Builds pop their spawn list from `logs` (one per build, in order);
    edit commands are recorded by their gen_monorepo subcommand.
    """

    def __init__(self, logs):
        self.logs = list(logs)
        self.events = []
        self.log_paths = []

    def __call__(self, argv, cwd=None, capture_output=False):
        if argv[0] == "bazel" and "build" in argv:
            path = [a for a in argv
                    if a.startswith("--execution_log_json_file=")][0]
            path = path.split("=", 1)[1]
            self.log_paths.append(path)
            self.events.append("build-batch" if "--batch" in argv
                               else "build")
            with open(path, "w", encoding="utf-8") as fh:
                for spawn in self.logs.pop(0):
                    fh.write(json.dumps(spawn) + "\n")
        elif argv[0] == "bazel":
            self.events.append("bazel-" + argv[-1])
        else:
            self.events.append(argv[2])
        return Proc()


def spawn(worker=False):
    return {"mnemonic": "FlutterKernelCompile",
            "runner": "worker" if worker else "linux-sandbox",
            "commandArgs": ["x"], "listedOutputs": ["o"]}


class WarmUpEditTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-warmup-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def args(self, fake):
        return argparse.Namespace(
            work=self.tmp, out_base=os.path.join(self.tmp, "ob"),
            tools="/tools", run=fake)

    def test_record_counts_actions_and_worker_spawns(self):
        fake = FakeBazel([[spawn(True), spawn(True), spawn(False)]])
        record = sol_warmup.warm_up_edit_build(self.args(fake),
                                               "device_release")
        self.assertEqual(record, {"edit": "apply-app-edit",
                                  "executed_actions": 3,
                                  "worker_spawns": 2})
        self.assertEqual(fake.events, ["apply-app-edit", "build"])

    def test_release_may_report_no_worker_spawns(self):
        fake = FakeBazel([[spawn(False)]])
        record = sol_warmup.warm_up_edit_build(self.args(fake),
                                               "device_release")
        self.assertEqual(record["worker_spawns"], 0)

    def test_no_executed_action_names_config_and_target(self):
        fake = FakeBazel([[]])
        with self.assertRaises(RuntimeError) as ctx:
            sol_warmup.warm_up_edit_build(self.args(fake), "device_release")
        self.assertIn("device_release", str(ctx.exception))
        self.assertIn(_TARGET, str(ctx.exception))

    def test_missing_log_is_a_loud_error(self):
        def run(argv, cwd=None, capture_output=False):
            return Proc()
        with self.assertRaises(RuntimeError) as ctx:
            sol_warmup.warm_up_edit_build(self.args(run), "device_release")
        self.assertIn("device_release", str(ctx.exception))
        self.assertIn(_TARGET, str(ctx.exception))


class RunSolRepWarmUpTest(unittest.TestCase):
    """The warm-up edit sits between the zero-action build and app_edit."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-warmup-rep-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.pristine = os.path.join(self.tmp, "pristine")
        os.makedirs(self.pristine)

    def drive(self, logs):
        fake = FakeBazel(logs)
        args = argparse.Namespace(
            work=os.path.join(self.tmp, "work"), pristine=self.pristine,
            out_base=os.path.join(self.tmp, "ob"),
            results=os.path.join(self.tmp, "res"), tools="/tools",
            run=fake, capture_server=None, rep=1)
        calls = []

        def scenario(_args, config, name, batch, server_pid=None,
                     warm_up=None):
            fake.events.append("flow:" + name)
            calls.append((name, batch, warm_up))
            return {"scenario": name, "warm_up": warm_up}

        with mock.patch.object(sol, "run_sol_scenario", scenario), \
                mock.patch.object(sol, "server_pid_of",
                                  lambda *a: 4242):
            records, had_errors = sol.run_sol_rep(
                args, 1, ["device_release"])
        return fake, calls, records["device_release"], had_errors

    def test_warm_up_edit_between_zero_build_and_app_edit(self):
        fake, calls, flows, errors = self.drive(
            [[], [spawn(True)]])
        self.assertFalse(errors)
        self.assertEqual(
            fake.events,
            ["flow:clean", "build", "apply-app-edit", "build",
             "flow:app_edit", "flow:core_edit", "flow:api_edit",
             "bazel-shutdown"])
        self.assertNotIn("build-batch", fake.events)
        self.assertEqual([c[0] for c in calls],
                         [s for s, _ in SCENARIOS])
        warm = {"edit": "apply-app-edit", "executed_actions": 1,
                "worker_spawns": 1}
        for name, batch, warm_up in calls:
            if name == "clean":
                self.assertTrue(batch)
                self.assertIsNone(warm_up)
            else:
                self.assertFalse(batch)
                self.assertEqual(warm_up, warm, name)
        self.assertEqual(len(set(fake.log_paths)), 2)

    def test_warm_up_without_action_fails_the_config(self):
        fake, calls, flows, errors = self.drive([[], []])
        self.assertTrue(errors)
        self.assertEqual([c[0] for c in calls], ["clean"])
        for name in ("app_edit", "core_edit", "api_edit"):
            reason = flows[name]["reason"]
            self.assertIn("device_release", reason)
            self.assertIn(_TARGET, reason)
            self.assertNotIn("warm_up", flows[name])
        self.assertEqual(fake.events[-1], "bazel-shutdown")


if __name__ == "__main__":
    unittest.main()
