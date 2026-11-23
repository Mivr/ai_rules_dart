#!/usr/bin/env python3
"""Unit tests for attribution.py on checked-in fake profile and log."""

import gzip
import json
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import attribution
import sol
import sol_summary

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                    "testdata", "attribution")


def make_record(bazel=100.0):
    """Minimal record.json content for a summarizable repeat."""
    return {"flow": "f", "config": "c", "scenario": "s", "identical": True,
            "reason": "ok", "bazel": {"cpu_s": bazel, "real_s": 1.0},
            "sol": {"cpu_s": 90.0, "real_s": 0.9}, "n_sol_actions": 1,
            "chain": {}}


def put_rep(root, config, scenario, rep, with_log=True, with_trace=True,
            bazel=100.0, trace="trace", execlog="execlog"):
    """Rep dir holding record.json plus the gzipped fixture files."""
    rep_dir = os.path.join(root, "sol", config, scenario, "rep%d" % rep)
    os.makedirs(rep_dir)
    with open(os.path.join(rep_dir, "record.json"), "w") as fh:
        json.dump(make_record(bazel), fh)
    for present, name, dest in ((with_trace, trace, "trace"),
                                (with_log, execlog, "execlog")):
        if present:
            with open(os.path.join(DATA, name + ".json"), "rb") as fin:
                with open(os.path.join(rep_dir, dest + ".json.gz"),
                          "wb") as fout:
                    fout.write(gzip.compress(fin.read()))
    return rep_dir


class AttributionTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root)

    def test_each_part_is_computed(self):
        rep = put_rep(self.root, "sim_debug", "clean", 1)
        result = attribution.attribute_flow([rep], 100.0)
        parts = result["parts"]
        self.assertEqual(parts["fetch_extract"], 10.0)
        self.assertEqual(parts["module_resolution"], 5.0)
        # 8s package creation (nested Starlark counted once) + 10s analysis
        self.assertEqual(parts["loading_analysis"], 18.0)
        self.assertEqual(parts["sandbox"], 2.0)
        self.assertEqual(parts["target_actions"], 20.0)
        self.assertAlmostEqual(parts["host_tools"]["total"], 42.0)
        self.assertAlmostEqual(parts["unattributed"], 3.0)
        self.assertAlmostEqual(result["gap_s"], 3.0)
        self.assertTrue(result["ok"])

    def test_host_tools_top_ten_and_other(self):
        rep = put_rep(self.root, "sim_debug", "clean", 1)
        host = attribution.attribute_flow([rep], 100.0)["parts"][
            "host_tools"]
        for key in ("by_mnemonic", "by_repo"):
            self.assertEqual(len(host[key]), 11)
            self.assertAlmostEqual(host[key]["other"], 2.0)
            self.assertNotIn("M01", host[key])
        self.assertAlmostEqual(host["by_mnemonic"]["M12"], 6.25)
        self.assertAlmostEqual(host["by_repo"]["repo12"], 6.25)

    def test_gap_beyond_five_percent_is_not_ok(self):
        rep = put_rep(self.root, "sim_debug", "clean", 1)
        result = attribution.attribute_flow([rep], 150.0)
        self.assertFalse(result["ok"])
        self.assertAlmostEqual(result["gap_s"], 53.0)
        self.assertAlmostEqual(result["parts"]["unattributed"], 53.0)
        over = attribution.attribute_flow([rep], 90.0)
        self.assertFalse(over["ok"])
        self.assertAlmostEqual(over["gap_s"], -7.0)

    def test_missing_file_is_an_error(self):
        rep = put_rep(self.root, "sim_debug", "clean", 1, with_log=False)
        result = attribution.attribute_flow([rep], 100.0)
        self.assertFalse(result["ok"])
        self.assertIn("execlog.json.gz", result["error"])

    def test_medians_over_reps(self):
        reps = [put_rep(self.root, "sim_debug", "clean", n)
                for n in (1, 2)]
        result = attribution.attribute_flow(reps, 100.0)
        self.assertEqual(result["parts"]["fetch_extract"], 10.0)

    def test_summarize_flows_carry_split(self):
        for config, scenario in (("sim_debug", "clean"),
                                 ("sim_debug", "core_edit"),
                                 ("sim_debug", "app_edit"),
                                 ("android_debug", "core_edit"),
                                 ("android_debug", "clean")):
            put_rep(self.root, config, scenario, 1)
        flows = sol_summary.summarize_configs(
            self.root, {"sha": "x", "repeats": 1, "target_loc": 1,
                        "seed": 1},
            ["sim_debug", "android_debug"])["flows"]
        for flow in ("ios-debug-clean", "ios-debug-body",
                     "android-debug-body"):
            self.assertIn("attribution", flows[flow])
            self.assertIn("profile", flows[flow])
        self.assertIn("attribution", flows["ios-debug-app"])
        for flow in ("android-debug-clean",):
            self.assertNotIn("attribution", flows[flow])

    def _run_summarize(self, strict, bazel):
        shutil.rmtree(os.path.join(self.root, "sol"), ignore_errors=True)
        put_rep(self.root, "sim_debug", "clean", 1, bazel=bazel)
        out = os.path.join(self.root, "ios-sol.json")
        argv = ["summarize", "--results", self.root, "--sha", "x",
                "--repeats", "1", "--target-loc", "1", "--seed", "1",
                "--out", out]
        if strict:
            argv.append("--strict-attribution")
        with mock.patch("builtins.print"):
            return sol.main(argv)

    def test_strict_fails_only_when_not_ok(self):
        self.assertEqual(self._run_summarize(False, 500.0), 0)
        self.assertEqual(self._run_summarize(True, 500.0), 1)
        with open(os.path.join(self.root, "ios-sol.json")) as fh:
            flow = json.load(fh)["flows"]["ios-debug-clean"]
        self.assertFalse(flow["attribution"]["ok"])

    def test_strict_passes_when_ok(self):
        self.assertEqual(self._run_summarize(True, 100.0), 0)
        summaries = {"ios": {"flows": {"f": {"attribution": {"ok": True}},
                                       "g": {}}}}
        self.assertEqual(attribution.strict_attribution_exit(
            summaries, True), 0)

    def test_overlapping_threads_are_split_once(self):
        # fetch 0-10s on one thread, analysis 5-15s on another, 2 cores:
        # fetch keeps 0-10 (20 CPU s), analysis only 10-15 (10 CPU s).
        rep = put_rep(self.root, "sim_debug", "clean", 1,
                      trace="overlap_trace", execlog="execlog_host")
        result = attribution.attribute_flow([rep], 40.0)
        parts = result["parts"]
        self.assertAlmostEqual(parts["fetch_extract"], 20.0)
        self.assertAlmostEqual(parts["loading_analysis"], 10.0)
        summed = parts["fetch_extract"] + parts["loading_analysis"]
        self.assertLessEqual(summed, 40.0)
        self.assertTrue(result["ok"], result)

    def test_host_tools_and_target_from_exec_spawns(self):
        rep = put_rep(self.root, "sim_debug", "clean", 1,
                      trace="overlap_trace", execlog="execlog_host")
        parts = attribution.attribute_flow([rep], 40.0)["parts"]
        host = parts["host_tools"]
        self.assertAlmostEqual(host["total"], 8.0)
        self.assertEqual(host["by_repo"], {"tools": 4.0, "extra": 4.0, "other": 0})
        self.assertAlmostEqual(host["by_mnemonic"]["Host"], 8.0)
        self.assertAlmostEqual(parts["target_actions"], 4.0)

    def test_repo_owner_names_the_consuming_tool(self):
        rep = put_rep(self.root, "sim_debug", "clean", 1,
                      trace="overlap_trace", execlog="execlog_host")
        result = attribution.attribute_flow([rep], 40.0)
        host = result["parts"]["host_tools"]
        self.assertEqual(host["by_repo_owner"],
                         {"extra": ["@@tools//:h"], "tools": []})
        self.assertEqual(result["warnings"], [
            "no exec tool target found for repository tools"])

    def test_owner_keys_match_by_repo_without_other(self):
        rep = put_rep(self.root, "sim_debug", "clean", 1)
        host = attribution.attribute_flow([rep], 100.0)["parts"][
            "host_tools"]
        self.assertEqual(set(host["by_repo_owner"]),
                         set(host["by_repo"]) - {"other"})

    def test_owner_terminal_label_through_chain(self):
        rep = put_rep(self.root, "sim_debug", "clean", 1,
                      execlog="execlog_counts_a")
        result = attribution.attribute_flow([rep], 100.0)
        self.assertEqual(
            result["parts"]["host_tools"]["by_repo_owner"],
            {"cpplib": ["@@tools//:tool"], "tools": []})

    def test_spawns_by_mnemonic_median_and_required_names(self):
        reps = [put_rep(self.root, "sim_debug", "clean", n, execlog=name)
                for n, name in enumerate(("execlog_counts_a",
                                          "execlog_counts_b",
                                          "execlog_counts_c"), 1)]
        counts = attribution.attribute_flow(reps, 100.0)[
            "spawns_by_mnemonic"]
        self.assertEqual(counts["Compile"], {"executed": 3, "cache_hit": 2})
        for name in ("ImportedDynamicFrameworkProcessor", "ProcessAndSign",
                     "BundleApp"):
            self.assertEqual(counts[name], {"executed": 0, "cache_hit": 0})

    def test_log_without_inputs_names_the_gap(self):
        shutil.rmtree(os.path.join(self.root, "sol"), ignore_errors=True)
        rep = put_rep(self.root, "sim_debug", "clean", 1)
        log = os.path.join(rep, "execlog.json.gz")
        with gzip.open(log, "rt") as fh:
            data = json.load(fh)
        for spawn in data["spawns"]:
            spawn.pop("inputs", None)
        with gzip.open(log, "wt") as fh:
            json.dump(data, fh)
        result = attribution.attribute_flow([rep], 100.0)
        self.assertFalse(result["ok"])
        self.assertIn("inputs", result["error"])

    def _assert_missing(self, **kwargs):
        shutil.rmtree(os.path.join(self.root, "sol"), ignore_errors=True)
        rep = put_rep(self.root, "sim_debug", "clean", 1, **kwargs)
        result = attribution.attribute_flow([rep], 100.0)
        self.assertEqual(sorted(result), ["error", "ok"])
        self.assertFalse(result["ok"])
        return result["error"]

    def test_log_without_cpu_metrics_names_the_gap(self):
        self.assertIn("CPU metrics", self._assert_missing(
            execlog="execlog_no_metrics"))

    def test_log_without_outputs_names_the_gap(self):
        self.assertIn("lists no spawn outputs", self._assert_missing(
            execlog="execlog_no_outputs"))

    def test_trace_without_counter_names_the_gap(self):
        shutil.rmtree(os.path.join(self.root, "sol"), ignore_errors=True)
        rep = put_rep(self.root, "sim_debug", "clean", 1)
        empty = os.path.join(rep, "trace.json.gz")
        with open(empty, "wb") as fh:
            fh.write(gzip.compress(b'{"traceEvents": []}'))
        result = attribution.attribute_flow([rep], 100.0)
        self.assertFalse(result["ok"])
        self.assertNotIn("parts", result)

    def test_strict_exit_per_fixture(self):
        for execlog, code in (("execlog_no_metrics", 1),
                              ("execlog_no_outputs", 1),
                              ("execlog_wall", 1),
                              ("execlog", 0)):
            shutil.rmtree(os.path.join(self.root, "sol"),
                          ignore_errors=True)
            put_rep(self.root, "sim_debug", "clean", 1, execlog=execlog)
            argv = ["summarize", "--results", self.root, "--sha", "x",
                    "--repeats", "1", "--target-loc", "1", "--seed", "1",
                    "--out", os.path.join(self.root, "o.json"),
                    "--strict-attribution"]
            with mock.patch("builtins.print"):
                self.assertEqual(sol.main(argv), code, execlog)

    def test_host_tools_wall_when_cpu_metrics_missing(self):
        rep = put_rep(self.root, "sim_debug", "clean", 1,
                      trace="overlap_trace", execlog="execlog_wall")
        result = attribution.attribute_flow([rep], 100.0)
        self.assertFalse(result["ok"])
        self.assertIn("CPU metrics", result["error"])
        self.assertNotIn("parts", result)
        host = result["host_tools_wall"]
        self.assertEqual(host["unit"], "wall_s")
        self.assertAlmostEqual(host["total"], 7.0)
        self.assertEqual(host["by_mnemonic"], {"Host": 7.0, "other": 0})
        self.assertEqual(host["by_repo"],
                         {"tools": 4.0, "extra": 3.0, "other": 0})
        self.assertEqual(host["by_repo_owner"],
                         {"extra": ["@@tools//:h"], "tools": []})
        self.assertEqual(result["warnings"],
                         ["no exec tool target found for repository tools"])

    def test_log_with_cpu_metrics_has_no_host_tools_wall(self):
        rep = put_rep(self.root, "sim_debug", "clean", 1)
        result = attribution.attribute_flow([rep], 100.0)
        self.assertTrue(result["ok"])
        self.assertNotIn("host_tools_wall", result)

    def test_log_without_cpu_or_wall_metrics_has_no_host_tools_wall(self):
        rep = put_rep(self.root, "sim_debug", "clean", 1,
                      execlog="execlog_no_metrics")
        result = attribution.attribute_flow([rep], 100.0)
        self.assertFalse(result["ok"])
        self.assertIn("CPU metrics", result["error"])
        self.assertNotIn("host_tools_wall", result)
        self.assertEqual(sorted(result), ["error", "ok"])

    def test_wall_medians_over_reps(self):
        rep1 = put_rep(self.root, "sim_debug", "clean", 1,
                       trace="overlap_trace", execlog="execlog_wall")
        rep2 = put_rep(self.root, "sim_debug", "clean", 2,
                       trace="overlap_trace", execlog="execlog_wall")
        rep3 = put_rep(self.root, "sim_debug", "clean", 3,
                       trace="overlap_trace", execlog="execlog_wall")
        for rep, (t, e) in ((rep2, ("5.0s", "4.0s")), (rep3, ("6.0s", "5.0s"))):
            log = os.path.join(rep, "execlog.json.gz")
            with gzip.open(log, "rt") as fh:
                data = json.load(fh)
            data["spawns"][0]["metrics"]["executionWallTime"] = t
            data["spawns"][1]["metrics"]["executionWallTime"] = e
            with gzip.open(log, "wt") as fh:
                json.dump(data, fh)
        result = attribution.attribute_flow([rep1, rep2, rep3], 100.0)
        self.assertFalse(result["ok"])
        host = result["host_tools_wall"]
        self.assertAlmostEqual(host["total"], 9.0)
        self.assertEqual(host["by_repo"],
                         {"tools": 5.0, "extra": 4.0, "other": 0})
        self.assertEqual(host["by_mnemonic"], {"Host": 9.0, "other": 0})

    def test_wall_log_without_inputs_names_the_gap(self):
        shutil.rmtree(os.path.join(self.root, "sol"), ignore_errors=True)
        rep = put_rep(self.root, "sim_debug", "clean", 1,
                      execlog="execlog_wall")
        log = os.path.join(rep, "execlog.json.gz")
        with gzip.open(log, "rt") as fh:
            data = json.load(fh)
        for spawn in data["spawns"]:
            spawn.pop("inputs", None)
        with gzip.open(log, "wt") as fh:
            json.dump(data, fh)
        result = attribution.attribute_flow([rep], 100.0)
        self.assertFalse(result["ok"])
        self.assertIn("inputs", result["error"])
        self.assertNotIn("host_tools_wall", result)
        self.assertEqual(sorted(result), ["error", "ok"])


if __name__ == "__main__":
    unittest.main()
