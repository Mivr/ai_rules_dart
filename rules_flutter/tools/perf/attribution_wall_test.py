#!/usr/bin/env python3
"""Unit tests for attribution_wall.py functions."""

import gzip
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import attribution_wall
from attribution_trace import MissingData

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                    "testdata", "attribution")


def _write_gz_json(path, data):
    with gzip.open(path, "wt") as fh:
        json.dump(data, fh)


class AttributionWallTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root)

    def test_spawn_wall(self):
        self.assertAlmostEqual(
            attribution_wall.spawn_wall(
                {"metrics": {"executionWallTime": "3.5s"}}),
            3.5)
        self.assertEqual(
            attribution_wall.spawn_wall(
                {"cacheHit": True,
                 "metrics": {"executionWallTime": "3.5s"}}),
            0.0)
        self.assertEqual(
            attribution_wall.spawn_wall({}),
            0.0)

    def test_has_wall_metrics(self):
        spawns = [{"metrics": {"executionWallTime": "1.0s"}}]
        self.assertTrue(attribution_wall.has_wall_metrics(spawns))
        no_wall = [{"metrics": {"userTime": "1.0s"}}]
        self.assertFalse(attribution_wall.has_wall_metrics(no_wall))
        cache_hit_only = [{"cacheHit": True,
                           "metrics": {"executionWallTime": "1.0s"}}]
        self.assertFalse(attribution_wall.has_wall_metrics(cache_hit_only))

    def test_check_wall_outputs(self):
        with self.assertRaises(MissingData) as ctx:
            attribution_wall.check_wall_outputs([{"mnemonic": "Host"}])
        self.assertIn("lists no spawn outputs", str(ctx.exception))

    def test_accumulate_host_costs(self):
        spawns = [
            {"listedOutputs": ["bazel-out/k8-opt-exec-ST-1/bin/h"],
             "mnemonic": "Host", "targetLabel": "@@tools//:h",
             "metrics": {"executionWallTime": "4.0s"}},
            {"listedOutputs": ["bazel-out/k8-fastbuild/bin/t"],
             "mnemonic": "Compile", "targetLabel": "//app:t",
             "metrics": {"executionWallTime": "2.0s"}},
        ]
        host = attribution_wall.accumulate_host_costs(
            spawns, attribution_wall.spawn_wall)
        self.assertAlmostEqual(host["total"], 4.0)
        self.assertEqual(host["by_mnemonic"], {"Host": 4.0})
        self.assertEqual(host["by_repo"], {"tools": 4.0})

    def test_summarize_host_tools_unit(self):
        hosts = [{"total": 5.0, "by_mnemonic": {"Host": 5.0},
                  "by_repo": {"tools": 5.0},
                  "owners": {"tools": ["@@tools//:h"]}}]
        summary = attribution_wall.summarize_host_tools(hosts, unit="wall_s")
        self.assertEqual(summary["unit"], "wall_s")
        self.assertAlmostEqual(summary["total"], 5.0)
        self.assertEqual(summary["by_repo_owner"], {"tools": ["@@tools//:h"]})

    def test_try_wall_attribution_when_wall_metrics_available(self):
        rep = os.path.join(self.root, "rep1")
        os.makedirs(rep)
        with open(os.path.join(DATA, "execlog_wall.json"), "rb") as fin:
            with open(os.path.join(rep, "execlog.json.gz"), "wb") as fout:
                fout.write(gzip.compress(fin.read()))
        record = attribution_wall.try_wall_attribution([rep], "cpu error")
        self.assertIsNotNone(record)
        self.assertFalse(record["ok"])
        self.assertEqual(record["error"], "cpu error")
        self.assertIn("host_tools_wall", record)
        self.assertEqual(record["host_tools_wall"]["unit"], "wall_s")

    def test_try_wall_attribution_when_wall_metrics_missing(self):
        rep = os.path.join(self.root, "rep1")
        os.makedirs(rep)
        with open(os.path.join(DATA, "execlog_no_metrics.json"), "rb") as fin:
            with open(os.path.join(rep, "execlog.json.gz"), "wb") as fout:
                fout.write(gzip.compress(fin.read()))
        self.assertIsNone(
            attribution_wall.try_wall_attribution([rep], "cpu error"))


if __name__ == "__main__":
    unittest.main()
