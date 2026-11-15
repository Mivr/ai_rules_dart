#!/usr/bin/env python3
"""Tests of the bench deadline: clock, process-group kill, partial run.

Fake clocks and tiny injected deadlines only; nothing here depends on the
speed of the host.
"""

import argparse
import json
import os
import shutil
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import ab
import deadline
import sol_test
import peak_rss
import sol
import sol_errors
import sol_summary
import warm_server
from deadline import Deadline, DeadlineExceeded
from run_rep import SCENARIOS

CONFIGS = ["device_release", "sim_debug"]


class FakeClock:
    def __init__(self, now):
        self.now = now

    def __call__(self):
        return self.now


class DeadlineClockTest(unittest.TestCase):
    def test_remaining_and_passed_follow_the_injected_clock(self):
        clock = FakeClock(100.0)
        limit = Deadline(160, clock)
        self.assertEqual(limit.remaining(), 60)
        self.assertFalse(limit.passed())
        clock.now = 160.0
        self.assertTrue(limit.passed())
        with self.assertRaises(DeadlineExceeded):
            limit.check("a flow")

    def test_no_deadline_never_passes(self):
        args = argparse.Namespace()
        self.assertFalse(deadline.passed(args))
        deadline.check(args, "anything")
        args.deadline = None
        self.assertFalse(deadline.passed(args))

    def test_both_run_parsers_take_deadline_epoch_and_default_to_none(self):
        base = ["--tools", "t", "--pristine", "p", "--work", "w",
                "--out-base", "o", "--results", "r", "--rep", "1"]
        got = sol.build_parser().parse_args(
            ["run"] + base + ["--deadline-epoch", "1700000000"])
        self.assertEqual(deadline.from_args(got).epoch, 1700000000.0)
        got = sol.build_parser().parse_args(["run"] + base)
        self.assertIsNone(deadline.from_args(got))
        ab_args = ["run", "--tools", "t", "--pristine-control", "a",
                   "--pristine-treatment", "b", "--work-root-control", "c",
                   "--work-root-treatment", "d",
                   "--out-base-root-control", "e",
                   "--out-base-root-treatment", "f", "--results", "r",
                   "--repeats", "1"]
        got = ab.build_parser().parse_args(ab_args + ["--deadline-epoch", "5"])
        self.assertEqual(deadline.from_args(got).epoch, 5.0)
        self.assertIsNone(deadline.from_args(
            ab.build_parser().parse_args(ab_args)))


class KillTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="deadline-kill-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def alive(self, pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        return True

    def test_running_command_and_its_children_die_at_the_deadline(self):
        pidfile = os.path.join(self.tmp, "child.pid")
        script = "sleep 60 & echo $! > %s; wait" % pidfile
        limit = Deadline(time.time() + 1.0)
        start = time.monotonic()
        with self.assertRaises(DeadlineExceeded):
            peak_rss.run_peak(["sh", "-c", script], self.tmp,
                              deadline=limit)
        self.assertLess(time.monotonic() - start, 30)
        with open(pidfile, encoding="utf-8") as fh:
            child = int(fh.read())
        for _ in range(50):
            if not self.alive(child):
                break
            time.sleep(0.1)
        self.assertFalse(self.alive(child))

    def test_passed_deadline_starts_nothing(self):
        marker = os.path.join(self.tmp, "started")
        with self.assertRaises(DeadlineExceeded):
            peak_rss.run_peak(["sh", "-c", "touch %s" % marker], self.tmp,
                              deadline=Deadline(time.time() - 1))
        self.assertFalse(os.path.exists(marker))

    def test_command_ending_before_the_deadline_is_measured(self):
        code, peak = peak_rss.run_peak(
            ["sh", "-c", "exit 3"], self.tmp,
            deadline=Deadline(time.time() + 600))
        self.assertEqual(code, 3)
        self.assertIsNotNone(peak)

    def test_warm_server_measure_kills_the_client_too(self):
        # The test process stands in for the server whose tree is sampled.
        with self.assertRaises(DeadlineExceeded):
            warm_server.measure(
                ["sleep", "60"], self.tmp, os.getpid(),
                deadline=Deadline(time.time() + 0.5))

    def test_measure_process_tree_kills_too(self):
        with self.assertRaises(DeadlineExceeded):
            sol.measure_process_tree(
                ["sleep", "60"], self.tmp,
                deadline=Deadline(time.time() + 0.5))


class RepDriverTest(unittest.TestCase):
    """run_sol_rep under a fake clock with fake flows."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="deadline-rep-")
        self.clock = FakeClock(1000.0)
        self.started = []
        self.shutdowns = []

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def args(self, limit):
        return argparse.Namespace(
            pristine=self.tmp, work=os.path.join(self.tmp, "work"),
            out_base=os.path.join(self.tmp, "out"),
            results=os.path.join(self.tmp, "results"), rep=1,
            run=lambda *a, **k: None, capture_server=None,
            deadline=limit)

    def fake_scenario(self, args, config, scenario, batch,
                      server_pid=None, warm_up=None):
        self.started.append((config, scenario))
        deadline.check(args, "flow %s" % scenario)
        if (config, scenario) == self.hang_at:
            self.clock.now += 100
            raise DeadlineExceeded("killed at the deadline")
        self.clock.now += 1
        return {"flow": "%s-%s" % (config, scenario), "reason": "ok"}

    def run_rep(self, limit, hang_at=None):
        self.hang_at = hang_at
        args = self.args(limit)
        with mock.patch.object(sol, "run_sol_scenario",
                               self.fake_scenario), \
                mock.patch.object(sol, "reset_work"), \
                mock.patch.object(sol, "server_pid_of", return_value=7), \
                mock.patch.object(sol, "run_warm_ups", return_value={}), \
                mock.patch.object(
                    sol, "shutdown",
                    lambda run, work, base: self.shutdowns.append(base)):
            return sol.run_sol_rep(args, 1, CONFIGS), args

    def reason_of(self, args, config, scenario):
        path = os.path.join(args.results, "sol", config, scenario, "rep1",
                            "record.json")
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)

    def test_deadline_already_passed_times_out_every_flow(self):
        (records, had_errors), args = self.run_rep(
            Deadline(900, self.clock))
        self.assertTrue(had_errors)
        self.assertEqual(self.started, [])
        self.assertEqual(self.shutdowns, [])
        for config in CONFIGS:
            for scenario, _ in SCENARIOS:
                record = self.reason_of(args, config, scenario)
                self.assertEqual(record["reason"], "timeout")
                self.assertIsNone(record["bazel"]["cpu_s"])
                self.assertIsNone(record["sol"])
                self.assertEqual(records[config][scenario]["reason"],
                                 "timeout")

    def test_deadline_mid_flow_keeps_finished_and_times_out_the_rest(self):
        (records, had_errors), args = self.run_rep(
            Deadline(1000.5, self.clock), hang_at=None)
        self.assertTrue(had_errors)
        self.assertEqual(self.started, [("device_release", "clean"),
                                        ("device_release", "app_edit")])
        self.assertEqual(
            records["device_release"]["clean"]["reason"], "ok")
        self.assertEqual(
            self.reason_of(args, "device_release", "app_edit")["reason"],
            "timeout")
        self.assertEqual(
            self.reason_of(args, "sim_debug", "clean")["reason"], "timeout")
        self.assertEqual(len(self.shutdowns), 1)

    def test_kill_inside_a_warm_flow_records_it_and_shuts_the_server_down(
            self):
        (records, had_errors), args = self.run_rep(
            Deadline(1100.5, self.clock),
            hang_at=("device_release", "app_edit"))
        self.assertTrue(had_errors)
        self.assertEqual(records["device_release"]["clean"]["reason"], "ok")
        for scenario in ("app_edit", "core_edit", "api_edit"):
            self.assertEqual(
                self.reason_of(args, "device_release", scenario)["reason"],
                "timeout", scenario)
        self.assertEqual(len(self.shutdowns), 1)
        self.assertEqual(
            self.reason_of(args, "sim_debug", "clean")["reason"], "timeout")
        self.assertNotIn(("sim_debug", "clean"), self.started)

    def test_no_deadline_runs_every_flow_as_before(self):
        (records, had_errors), _ = self.run_rep(None)
        self.assertFalse(had_errors)
        self.assertEqual(len(self.started), 2 * len(SCENARIOS))
        self.assertEqual(len(self.shutdowns), 2)

    def test_other_errors_keep_their_reason(self):
        args = self.args(None)
        flows = sol_errors.record_unfinished(
            args, "device_release", {}, RuntimeError("boom"))
        self.assertIn("boom", flows["clean"]["reason"])


def finished(config, scenario, cpu):
    record = sol_errors.error_record(config, scenario, "ok")
    record["identical"] = True
    record["bazel"] = {"cpu_s": cpu, "real_s": cpu, "peak_rss_mb": 1.0}
    record["sol"] = {"cpu_s": cpu / 2, "real_s": cpu / 2}
    record["chain"]["status"] = "ok"
    return record


def put(results, record, rep=1):
    path = os.path.join(results, "sol", record["config"],
                        record["scenario"], "rep%d" % rep)
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, "record.json"), "w",
              encoding="utf-8") as fh:
        json.dump(record, fh)


META = {"sha": "a" * 40, "repeats": 2, "target_loc": 1, "seed": 1}


class SummaryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="deadline-sum-")
        self.results = os.path.join(self.tmp, "results")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def partial(self, results, cpu=4.0):
        for scenario, _ in SCENARIOS:
            put(results, finished("device_release", scenario, cpu))
        args = argparse.Namespace(results=results, rep=2)
        sol_errors.write_error_records(
            args, "device_release", [s for s, _ in SCENARIOS], "timeout")

    def test_sol_summary_marks_unfinished_flows(self):
        for scenario, _ in SCENARIOS:
            put(self.results, finished("device_release", scenario, 4.0))
        args = argparse.Namespace(results=self.results, rep=2)
        sol_errors.write_error_records(
            args, "device_release", ["app_edit", "core_edit", "api_edit"],
            "timeout")
        summary = sol_summary.summarize_configs(
            self.results, META, ["device_release"])
        self.assertTrue(summary["meta"]["timed_out"])
        clean = summary["flows"]["ios-release-clean"]
        self.assertEqual(clean["bazel"], 4.0)
        self.assertEqual(clean["reason"], "ok")
        app = summary["flows"]["ios-release-app"]
        self.assertIn("timeout", app["reason"])

    def test_flow_with_only_timeout_records_has_no_numbers(self):
        args = argparse.Namespace(results=self.results, rep=1)
        sol_errors.write_error_records(
            args, "device_release", ["clean"], "timeout")
        summary = sol_summary.summarize_configs(
            self.results, META, ["device_release"])
        flow = summary["flows"]["ios-release-clean"]
        self.assertIn("timeout", flow["reason"])
        self.assertIsNone(flow["bazel"])
        self.assertIsNone(flow["sol"])
        self.assertTrue(summary["meta"]["timed_out"])

    def test_complete_tree_has_no_timed_out_key(self):
        for scenario, _ in SCENARIOS:
            put(self.results, finished("device_release", scenario, 4.0))
        summary = sol_summary.summarize_configs(
            self.results, META, ["device_release"])
        self.assertNotIn("timed_out", summary["meta"])

    def test_ab_lists_unfinished_repeats_as_unpaired(self):
        control = os.path.join(self.tmp, "control")
        treatment = os.path.join(self.tmp, "treatment")
        for arm, cpu in ((control, 4.0), (treatment, 2.0)):
            for scenario, _ in SCENARIOS:
                put(arm, finished("device_release", scenario, cpu))
        sol_errors.write_error_records(
            argparse.Namespace(results=treatment, rep=2), "device_release",
            [s for s, _ in SCENARIOS], "timeout")
        meta = dict(META, ab="flags", order=["control", "treatment"],
                    platform="ios")
        summary = ab.summarize_ab(control, treatment, meta)
        self.assertTrue(summary["meta"]["timed_out"])
        ratio = summary["ratio"]["ios-release-clean"]
        self.assertEqual(ratio["n"], 1)
        self.assertEqual(ratio["unpaired"], [2])
        flow = summary["arms"]["treatment"]["ios-release-clean"]
        self.assertEqual(flow["bazel"], 2.0)

    def test_ab_complete_tree_has_no_timed_out_key(self):
        control = os.path.join(self.tmp, "control")
        treatment = os.path.join(self.tmp, "treatment")
        for arm in (control, treatment):
            for scenario, _ in SCENARIOS:
                put(arm, finished("device_release", scenario, 4.0))
        meta = dict(META, ab="flags", order=["control", "treatment"],
                    platform="ios")
        summary = ab.summarize_ab(control, treatment, meta)
        self.assertNotIn("timed_out", summary["meta"])


# Wraps the fake bazel of sol_test: a measured (profiled) warm-server
# build records that it started and then hangs, as a stuck build would.
HANGING_BAZEL = """\
#!/bin/sh
case " $* " in
  *" build "*--profile=*) case " $* " in *" --batch "*) ;; *)
    touch "$SOL_HANG_MARKER"; exec sleep 600 ;;
  esac ;;
esac
exec "$SOL_REAL_BAZEL" "$@"
"""


class DeadlineEndToEndTest(unittest.TestCase):
    """sol.py run/summarize with the fake bazel of sol_test."""

    setUp = sol_test.SolEndToEndTest.setUp
    tearDown = sol_test.SolEndToEndTest.tearDown
    live_server_pids = sol_test.SolEndToEndTest.live_server_pids
    run_argv = sol_test.SolEndToEndTest.run_argv
    summarize_argv = sol_test.SolEndToEndTest.summarize_argv

    def summary(self):
        out = os.path.join(self.tmp, "ios-sol.json")
        with mock.patch.dict(os.environ, self.env):
            sol.main(self.summarize_argv(out))
        with open(out, encoding="utf-8") as fh:
            return json.load(fh)

    def test_passed_deadline_starts_no_bazel_and_times_out_all(self):
        argv_log = os.path.join(self.tmp, "argv.log")
        env = dict(self.env, SOL_ARGV_LOG=argv_log)
        with mock.patch.dict(os.environ, env):
            code = sol.main(self.run_argv(CONFIGS) + [
                "--deadline-epoch", str(time.time() - 5)])
        self.assertEqual(code, 1)
        self.assertFalse(os.path.exists(argv_log))
        summary = self.summary()
        self.assertTrue(summary["meta"]["timed_out"])
        self.assertEqual(len(summary["flows"]), 8)
        for flow, entry in summary["flows"].items():
            self.assertIn("timeout", entry["reason"], flow)
            self.assertIsNone(entry["bazel"], flow)
            self.assertIsNone(entry["sol"], flow)

    def test_hung_warm_build_is_killed_and_the_run_still_writes(self):
        real = os.path.join(self.bindir, "bazel-real")
        os.rename(os.path.join(self.bindir, "bazel"), real)
        wrapper = os.path.join(self.bindir, "bazel")
        with open(wrapper, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(HANGING_BAZEL)
        os.chmod(wrapper, 0o755)
        marker = os.path.join(self.tmp, "hang-started")
        self.env.update(SOL_HANG_MARKER=marker, SOL_REAL_BAZEL=real)
        epoch = time.time() + 1e6

        def clock():
            return time.time() + (2e6 if os.path.exists(marker) else 0)

        with mock.patch.dict(os.environ, self.env), \
                mock.patch.object(deadline, "from_args",
                                  return_value=Deadline(epoch, clock)):
            code = sol.main(self.run_argv(["device_release"]))
        self.assertEqual(code, 1)
        self.assertEqual(self.live_server_pids(), [])
        summary = self.summary()
        self.assertTrue(summary["meta"]["timed_out"])
        flows = summary["flows"]
        self.assertTrue(flows["ios-release-clean"]["identical"])
        self.assertEqual(flows["ios-release-clean"]["reason"], "ok")
        for name in ("app", "body", "api"):
            self.assertEqual(flows["ios-release-" + name]["reason"],
                             "timeout")
            self.assertIsNone(flows["ios-release-" + name]["bazel"])


if __name__ == "__main__":
    unittest.main()
