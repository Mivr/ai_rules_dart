#!/usr/bin/env python3
"""Unit tests for incr_kernel_ab.py (incremental kernel bench arms)."""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import incr_kernel_ab


class PlanTest(unittest.TestCase):
    def test_both_flows_both_settings_both_states(self):
        arms = incr_kernel_ab.plan()
        self.assertEqual(len(arms), 8)
        for flow in ("ios-debug-body-warm", "android-debug-body-warm"):
            for setting in ("incremental_kernel",
                            "dev_incremental_serialization"):
                for state in ("on", "off"):
                    self.assertEqual(
                        1, len([a for a in arms
                                if (a["flow"], a["setting"], a["state"])
                                == (flow, setting, state)]))

    def test_flows_map_to_debug_configs(self):
        configs = {a["flow"]: a["config"] for a in incr_kernel_ab.plan()}
        self.assertEqual(configs, {"ios-debug-body-warm": "sim_debug",
                                   "android-debug-body-warm":
                                   "android_debug"})

    def test_flags_validate_and_differ_per_state(self):
        on = incr_kernel_ab.arm_flags("incremental_kernel", "on")
        off = incr_kernel_ab.arm_flags("incremental_kernel", "off")
        self.assertEqual(
            on, ["--@rules_flutter//flutter:incremental_kernel=true"])
        self.assertEqual(
            off, ["--@rules_flutter//flutter:incremental_kernel=false"])

    def test_dev_arms_keep_the_worker_route(self):
        for state in ("on", "off"):
            flags = incr_kernel_ab.arm_flags(
                "dev_incremental_serialization", state)
            self.assertIn(
                "--@rules_flutter//flutter:incremental_kernel=true", flags)


class ReportTest(unittest.TestCase):
    def test_reports_every_arm_and_marks_missing(self):
        rows = [{"flow": "ios-debug-body-warm",
                 "setting": "incremental_kernel", "state": "on",
                 "wall_s": 12.34, "fkc_cpu_s": 5.0}]
        lines = incr_kernel_ab.report(rows)
        self.assertEqual(len(lines), 8)
        self.assertIn("ios-debug-body-warm incremental_kernel=on "
                      "wall_s=12.3 fkc_cpu_s=5.0", lines)
        self.assertIn("android-debug-body-warm incremental_kernel=off "
                      "wall_s=n/a fkc_cpu_s=n/a", lines)


if __name__ == "__main__":
    unittest.main()
