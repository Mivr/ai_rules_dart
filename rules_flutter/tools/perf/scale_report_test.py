#!/usr/bin/env python3
"""Tests for scale_report.py (fake results, no Bazel)."""

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import scale_report
from scale_report import fit_exponent

FLOW = "android-release-clean"


def flow(cost, actions=10, analysis=1.0, **extra):
    """A summarized flow record shaped like sol_summary.summarize_flow."""
    record = {"bazel": cost, "identical": True, "reason": "ok",
              "chain": {"steps": {"A": {"count": actions - 1, "cpu_s": 1},
                                  "B": {"count": 1, "cpu_s": 1}}},
              "profile": {"jvm": {"phases": {
                  scale_report.ANALYSIS_PHASE: analysis}}}}
    record.update(extra)
    return record


class FitTest(unittest.TestCase):
    def test_linear_is_one(self):
        self.assertEqual(fit_exponent([1, 2, 4, 8], [3, 6, 12, 24]), 1.0)
        self.assertEqual(fit_exponent([200, 2000], [5, 50]), 1.0)

    def test_quadratic_is_two(self):
        self.assertEqual(fit_exponent([1, 2, 3, 4], [1, 4, 9, 16]), 2.0)
        self.assertEqual(fit_exponent([10, 100], [7, 700]), 2.0)

    def test_constant_is_zero(self):
        self.assertEqual(fit_exponent([2, 4, 8], [5, 5, 5]), 0.0)

    def test_errors(self):
        for sizes, costs in (([1], [1]), ([], []), ([1, 2], [0, 1]),
                             ([0, 2], [1, 1]), ([1, 2], [-1, 1]),
                             ([3, 3], [1, 2]), ([1, 2], [1])):
            with self.subTest(sizes=sizes, costs=costs), \
                    self.assertRaises(ValueError):
                fit_exponent(sizes, costs)


class ReportTest(unittest.TestCase):
    POINTS = [{"packages": 200, "plugins": 0, "source": "a"},
              {"packages": 2000, "plugins": 0, "source": "b"},
              {"packages": 200, "plugins": 30, "source": "c"}]

    def build(self, ceilings, flows=None):
        flows = flows or [{FLOW: flow(10.0, 100)},
                          {FLOW: flow(100.0, 1000)},
                          {FLOW: flow(40.0, 400, analysis=2.0)}]
        return scale_report.build_report(self.POINTS, flows, ceilings)

    def test_sizes_hold_cost_analysis_actions_per_plugin(self):
        report = self.build({FLOW: {"packages": 1.5, "plugins": 1.5}})
        sizes = report["flows"][FLOW]["sizes"]
        self.assertEqual([s["cost"] for s in sizes], [10.0, 100.0, 40.0])
        self.assertEqual([s["analysis_s"] for s in sizes], [1.0, 1.0, 2.0])
        self.assertEqual([s["actions"] for s in sizes], [100, 1000, 400])
        self.assertEqual([s["actions_per_plugin"] for s in sizes],
                         [None, None, 400 / 30])
        exponents = report["flows"][FLOW]["exponents"]
        self.assertEqual(exponents["packages"], 1.0)
        self.assertAlmostEqual(
            exponents["plugins"], scale_report.math.log(4) /
            scale_report.math.log(31), places=9)
        self.assertTrue(report["ok"])

    def test_ceiling_exceeded(self):
        report = self.build({FLOW: {"packages": 0.9, "plugins": 1.5}})
        self.assertFalse(report["ok"])
        self.assertIn("exceeds", report["problems"][0])

    def test_missing_ceiling(self):
        self.assertFalse(self.build({})["ok"])
        self.assertFalse(self.build({FLOW: {"packages": 2.0}})["ok"])

    def test_failed_flow(self):
        flows = [{FLOW: flow(10.0)}, {FLOW: {"error": "boom"}},
                 {FLOW: flow(12.0, identical=False, reason="differs")}]
        report = self.build({FLOW: {"packages": 9, "plugins": 9}}, flows)
        self.assertFalse(report["ok"])
        self.assertEqual(len(report["flows"][FLOW]["failures"]), 2)

    def test_flow_missing_at_a_size_fails(self):
        flows = [{FLOW: flow(10.0)}, {}, {FLOW: flow(12.0)}]
        report = self.build({FLOW: {"packages": 9, "plugins": 9}}, flows)
        self.assertFalse(report["ok"])


class CliTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="scale-report-test-")

    def write(self, name, data):
        path = os.path.join(self.tmp, name)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        return path

    def run_cli(self, ceilings, packages_costs=(10.0, 100.0)):
        points = []
        for i, (pkgs, cost) in enumerate(zip((200, 2000), packages_costs)):
            path = self.write("p%d.json" % i, {"flows": {FLOW: flow(cost)}})
            points += ["--point", "%d,0,%s" % (pkgs, path)]
        out = os.path.join(self.tmp, "scale.json")
        with contextlib.redirect_stderr(io.StringIO()):
            code = scale_report.main(
                points + ["--ceilings", self.write("c.json", ceilings),
                          "--out", out])
        return code, out

    def test_exit_zero_and_report_written(self):
        code, out = self.run_cli({FLOW: {"packages": 1.5, "plugins": 1.5}})
        self.assertEqual(code, 0)
        with open(out, encoding="utf-8") as fh:
            self.assertTrue(json.load(fh)["ok"])

    def test_exit_one_above_ceiling_after_writing(self):
        code, out = self.run_cli({FLOW: {"packages": 0.5, "plugins": 1.5}})
        self.assertEqual(code, 1)
        self.assertTrue(os.path.isfile(out))

    def test_exit_one_with_missing_ceiling(self):
        code, out = self.run_cli({})
        self.assertEqual(code, 1)
        self.assertTrue(os.path.isfile(out))

    def test_single_point_is_a_usage_error(self):
        path = self.write("p.json", {"flows": {FLOW: flow(1.0)}})
        with contextlib.redirect_stderr(io.StringIO()):
            code = scale_report.main(["--point", "200,0," + path])
        self.assertEqual(code, 2)

    def test_checked_in_ceilings_cover_the_bench_flows(self):
        with open(scale_report.DEFAULT_CEILINGS, encoding="utf-8") as fh:
            ceilings = json.load(fh)
        for platform in ("ios", "android"):
            for mode in ("release", "debug"):
                for scenario in ("clean", "app", "body"):
                    entry = ceilings["%s-%s-%s" % (platform, mode, scenario)]
                    self.assertGreater(entry["packages"], 0)
                    self.assertGreater(entry["plugins"], 0)


if __name__ == "__main__":
    unittest.main()
