#!/usr/bin/env python3
"""Wall and peak-RSS ratio tests for ab.py (hand-written records)."""

import json
import math
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ab import pair_ratio, ratio_for_flow


def rec(cpu, wall, rss, identical=True):
    return {"identical": identical, "reason": "ok",
            "bazel": {"cpu_s": cpu, "real_s": wall, "peak_rss_mb": rss}}


class WallRssRatioTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ab-wall-rss-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def write(self, arm, rep, record):
        path = os.path.join(self.tmp, arm, "sol", "device_release",
                            "clean", "rep%d" % rep, "record.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(record))

    def entry(self, repeats):
        return ratio_for_flow(os.path.join(self.tmp, "c"),
                              os.path.join(self.tmp, "t"),
                              "device_release", "clean", repeats)

    def test_wall_and_rss_ratios_with_geomean(self):
        self.write("c", 1, rec(100.0, 10.0, 400.0))
        self.write("t", 1, rec(94.0, 8.0, 500.0))
        self.write("c", 2, rec(100.0, 20.0, 400.0))
        self.write("t", 2, rec(100.0, 10.0, 200.0))
        entry = self.entry(2)
        self.assertAlmostEqual(entry["median"], 1.0)
        self.assertEqual(entry["n"], 2)
        wall = entry["wall"]
        self.assertAlmostEqual(wall["median"], 0.8)
        self.assertAlmostEqual(wall["min"], 0.5)
        self.assertAlmostEqual(wall["max"], 0.8)
        self.assertAlmostEqual(wall["geomean"], math.sqrt(0.8 * 0.5))
        self.assertEqual(wall["n"], 2)
        rss = entry["peak_rss"]
        self.assertAlmostEqual(rss["median"], 1.25)
        self.assertAlmostEqual(rss["geomean"], math.sqrt(1.25 * 0.5))
        self.assertEqual(rss["unpaired"], [])

    def test_missing_value_is_unpaired_only_for_that_ratio(self):
        self.write("c", 1, rec(100.0, 10.0, None))
        self.write("t", 1, rec(110.0, 5.0, 100.0))
        entry = self.entry(1)
        self.assertEqual(entry["n"], 1)
        self.assertEqual(entry["unpaired"], [])
        self.assertEqual(entry["wall"]["n"], 1)
        self.assertEqual(entry["peak_rss"]["n"], 0)
        self.assertEqual(entry["peak_rss"]["unpaired"], [1])
        self.assertIsNone(entry["peak_rss"]["median"])

    def test_cpu_entries_equal_cpu_only_pairs(self):
        self.write("c", 1, rec(100.0, 10.0, 1.0))
        self.write("t", 1, rec(110.0, 1.0, 1.0))
        entry = self.entry(1)
        self.assertAlmostEqual(entry["median"], 1.1)
        self.assertAlmostEqual(
            pair_ratio(rec(100.0, 10.0, 1.0), rec(110.0, 1.0, 1.0)), 1.1)
        self.assertAlmostEqual(
            pair_ratio(rec(100.0, 10.0, 1.0), rec(110.0, 1.0, 1.0),
                       "real_s"), 0.1)

    def test_unproven_arm_leaves_all_ratios_unpaired(self):
        self.write("c", 1, rec(100.0, 10.0, 1.0, identical=False))
        self.write("t", 1, rec(100.0, 10.0, 1.0))
        entry = self.entry(1)
        for part in (entry, entry["wall"], entry["peak_rss"]):
            self.assertEqual(part["unpaired"], [1])


if __name__ == "__main__":
    unittest.main()
