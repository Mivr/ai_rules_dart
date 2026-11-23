#!/usr/bin/env python3
"""Unit tests for android_overlay_ab.py."""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import android_overlay_ab


class PlanTest(unittest.TestCase):
    def test_arms_include_before_and_after(self):
        arms = android_overlay_ab.plan()
        self.assertEqual(len(arms), 2)
        states = {a["state"] for a in arms}
        self.assertEqual(states, {"before", "after"})
        for arm in arms:
            self.assertEqual(arm["flow"], "android-debug-body-warm")
            self.assertEqual(arm["config"], "android_debug")


class ReportTest(unittest.TestCase):
    def test_reports_arms_with_measured_numbers(self):
        rows = [
            {
                "flow": "android-debug-body-warm",
                "state": "before",
                "overlay_cpu_s": 0.720,
                "zipalign_cpu_s": 0.150,
                "signer_cpu_s": 0.680,
                "total_cpu_s": 1.550,
            },
            {
                "flow": "android-debug-body-warm",
                "state": "after",
                "overlay_cpu_s": 0.650,
                "zipalign_cpu_s": 0.120,
                "signer_cpu_s": 0.340,
                "total_cpu_s": 1.110,
            },
        ]
        lines = android_overlay_ab.report(rows)
        self.assertEqual(len(lines), 2)
        self.assertIn("state=before FlutterApkOverlay_cpu_s=0.720", lines[0])
        self.assertIn("state=after FlutterApkOverlay_cpu_s=0.650", lines[1])

    def test_reports_na_for_missing_rows(self):
        lines = android_overlay_ab.report([])
        self.assertEqual(len(lines), 2)
        self.assertIn("FlutterApkOverlay_cpu_s=n/a", lines[0])


if __name__ == "__main__":
    unittest.main()
