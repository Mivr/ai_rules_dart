#!/usr/bin/env python3
"""Wall time and peak-RSS tests for sol.py, warm_server and sol_summary."""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from sol import measure_process_tree
from sol_summary import print_flow_lines, summarize_flow
from warm_server import measure
from warm_server_test import ScriptedTree, times

MIB = 1024 * 1024


def record(cpu, real_s=1.0, rss=None, identical=True):
    bazel = {"cpu_s": cpu, "real_s": real_s}
    if rss is not None:
        bazel["peak_rss_mb"] = rss
    return {"flow": "f", "config": "c", "scenario": "clean",
            "identical": identical, "reason": "ok", "bazel": bazel,
            "sol": {"cpu_s": cpu / 2.0, "real_s": 0.5},
            "n_sol_actions": 1, "chain": None}


class MeasurePeakTest(unittest.TestCase):
    def test_process_tree_returns_peak_rss_mb(self):
        sizes = {}

        def read(pid):
            sizes.setdefault(pid, 12 * MIB)
            return sizes[pid]

        cost = measure_process_tree(
            [sys.executable, "-c", "pass"], tempfile.gettempdir(),
            _rss_read=read, _children=lambda _pid: [])
        self.assertEqual(cost["peak_rss_mb"], 12.0)
        self.assertEqual(cost["returncode"], 0)
        self.assertEqual(cost["method"], "rusage-children")

    def test_warm_measure_returns_server_tree_peak(self):
        tree = ScriptedTree(100, [{100: (None, times(1.0, 0.5)),
                                   101: (100, times(0.5, 0.1))}])
        sizes = {100: 300 * MIB, 101: 80 * MIB}
        result = measure([sys.executable, "-c", "pass"],
                         tempfile.gettempdir(), 100, _read=tree.read,
                         _children=tree.children,
                         _rss_read=lambda pid: sizes[pid])
        self.assertEqual(result["peak_rss_mb"], 380.0)
        self.assertEqual(result["method"], "warm-server")
        self.assertIn("parts", result)


class SummaryWallRssTest(unittest.TestCase):
    def test_medians_and_spreads(self):
        flow = summarize_flow([record(3.0, 9.0, 300.0),
                               record(1.0, 7.0, 100.0),
                               record(2.0, 8.0, 200.0)], "cpu_seconds")
        self.assertEqual(flow["wall_s"], 8.0)
        self.assertEqual(flow["peak_rss_mb"], 200.0)
        self.assertEqual(flow["spread"]["wall_s"], [7.0, 9.0])
        self.assertEqual(flow["spread"]["peak_rss_mb"], [100.0, 300.0])
        self.assertEqual(flow["bazel"], 2.0)
        self.assertEqual(flow["spread"]["bazel"], [1.0, 3.0])

    def test_old_records_give_null(self):
        flow = summarize_flow([record(1.0), record(2.0)], "cpu_seconds")
        self.assertIsNone(flow["peak_rss_mb"])
        self.assertIsNone(flow["spread"]["peak_rss_mb"])
        self.assertEqual(flow["wall_s"], 1.0)

    def test_flow_line_prints_both_keys(self):
        flow = summarize_flow([record(1.0, 4.0, 50.0)], "cpu_seconds")
        from contextlib import redirect_stdout
        import io
        out = io.StringIO()
        with redirect_stdout(out):
            print_flow_lines({"unit": "cpu_seconds", "flows": {"f": flow}})
        self.assertIn("wall_s=4.0 peak_rss_mb=50.0", out.getvalue())


if __name__ == "__main__":
    unittest.main()
