#!/usr/bin/env python3
"""Unit tests for traceprofile.py (Bazel JSON trace profiles, Linux)."""

import gzip
import json
import os
import shutil
import tempfile
import unittest

import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import traceprofile
from traceprofile import (
    attribute_phases,
    counter_samples,
    integrate_cpu,
    is_cpu_counter,
    is_phase_marker,
    marker_boundaries,
    parse_jvm_profile,
    read_trace_events,
)


def counter(ts, cpu):
    return {"name": "CPU usage (Bazel)", "ph": "C", "ts": ts, "pid": 1,
            "args": {"cpu": cpu}}


def marker(ts, name):
    return {"name": name, "ph": "X", "ts": ts, "dur": 10, "pid": 1,
            "cat": "build phase marker"}


class MarkerTest(unittest.TestCase):
    def test_counter_shape(self):
        self.assertTrue(is_cpu_counter(counter(0, 1.5)))
        self.assertFalse(is_cpu_counter(marker(0, "Initialize command")))
        self.assertFalse(is_cpu_counter({"name": "CPU usage (Bazel)",
                                         "ph": "X", "args": {}}))

    def test_category_marks_phase(self):
        self.assertTrue(is_phase_marker(marker(0, "Evaluate target patterns")))
        self.assertFalse(is_phase_marker(counter(0, 1.0)))
        self.assertFalse(is_phase_marker({"name": "Genrule", "ph": "X",
                                          "cat": "general"}))

    def test_known_name_without_category_marks_phase(self):
        self.assertTrue(is_phase_marker({"name": "Complete build",
                                         "ph": "X", "ts": 5}))
        self.assertFalse(is_phase_marker({"name": "Complete build",
                                          "ph": "C", "ts": 5,
                                          "args": {"cpu": 1.0}}))

    def test_missing_name_never_marks(self):
        self.assertFalse(is_phase_marker({"ph": "X", "ts": 5}))


class IntegrateTest(unittest.TestCase):
    def test_samples_weighted_by_interval(self):
        samples = [(0.0, 2.0), (1e6, 1.0), (3e6, 4.0)]
        self.assertAlmostEqual(integrate_cpu(samples), 2.0 + 2.0)

    def test_last_sample_contributes_nothing(self):
        self.assertAlmostEqual(integrate_cpu([(0.0, 9.0)]), 0.0)
        self.assertAlmostEqual(integrate_cpu([]), 0.0)

    def test_unordered_and_backward_guarded(self):
        events = [counter(3e6, 1.0), counter(1e6, 2.0), counter(1e6, 2.0),
                  counter(0.0, 1.0)]
        self.assertEqual(counter_samples(events),
                         [(0.0, 1.0), (1e6, 2.0), (1e6, 2.0), (3e6, 1.0)])
        self.assertAlmostEqual(
            integrate_cpu(counter_samples(events)), 1.0 + 0.0 + 4.0)

    def test_unusable_samples_skipped(self):
        events = [counter(0, 1.0), {"name": "CPU usage (Bazel)", "ph": "C",
                                    "ts": 1e6, "args": {}},
                  {"name": "CPU usage (Bazel)", "ph": "C", "args": {"cpu": 2}}]
        self.assertEqual(counter_samples(events), [(0.0, 1.0)])


class PhasesTest(unittest.TestCase):
    def test_intervals_attributed_to_latest_marker(self):
        samples = [(0.0, 1.0), (1e6, 2.0), (2e6, 4.0), (4e6, 8.0)]
        markers = [(0.0, "Initialize command"), (2e6, "Complete build")]
        self.assertEqual(attribute_phases(samples, markers),
                         {"Initialize command": 1.0 + 2.0,
                          "Complete build": 8.0})

    def test_before_first_marker_goes_to_first_phase(self):
        samples = [(0.0, 1.0), (2e6, 1.0)]
        markers = [(1e6, "Load and analyze dependencies")]
        self.assertEqual(attribute_phases(samples, markers),
                         {"Load and analyze dependencies": 2.0})

    def test_no_markers_no_phases(self):
        self.assertEqual(attribute_phases([(0.0, 1.0)], []), {})

    def test_boundaries_sorted(self):
        events = [marker(2e6, "Complete build"),
                  marker(0.0, "Initialize command")]
        self.assertEqual(marker_boundaries(events),
                         [(0.0, "Initialize command"),
                          (2e6, "Complete build")])


class ParseTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="traceprofile-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def write(self, name, payload, gz=False):
        path = os.path.join(self.tmp, name)
        data = json.dumps(payload).encode("utf-8")
        if gz:
            data = gzip.compress(data)
        with open(path, "wb") as fh:
            fh.write(data)
        return path

    def profile_events(self):
        return [
            marker(0, "Initialize command"),
            counter(0, 1.0),
            marker(2e6, "Evaluate target patterns"),
            counter(1e6, 1.0),
            counter(3e6, 2.0),
            counter(4e6, 2.0),
        ]

    def test_object_and_bare_list_shapes(self):
        events = self.profile_events()
        first = parse_jvm_profile(self.write("a.json",
                                             {"traceEvents": events}))
        second = parse_jvm_profile(self.write("b.json", events))
        self.assertEqual(first, second)
        self.assertAlmostEqual(first["total"], 1.0 + 2.0 + 2.0)
        self.assertAlmostEqual(
            first["phases"]["Initialize command"], 1.0 + 2.0)
        self.assertAlmostEqual(
            first["phases"]["Evaluate target patterns"], 2.0)

    def test_gzipped_profile(self):
        events = self.profile_events()
        plain = parse_jvm_profile(self.write("a.json",
                                             {"traceEvents": events}))
        zipped = parse_jvm_profile(self.write("b.json.gz",
                                              {"traceEvents": events}, gz=True))
        self.assertEqual(plain, zipped)

    def test_no_counter_is_none(self):
        path = self.write("a.json", {"traceEvents":
                                     [marker(0, "Initialize command")]})
        self.assertEqual(parse_jvm_profile(path),
                         {"total": None, "phases": {}})

    def test_no_markers_empty_phases(self):
        path = self.write("a.json", {"traceEvents": [counter(0, 1.0),
                                                     counter(1e6, 1.0)]})
        self.assertEqual(parse_jvm_profile(path),
                         {"total": 1.0, "phases": {}})

    def test_garbage_fails_closed(self):
        path = os.path.join(self.tmp, "bad.json")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("not json")
        with self.assertRaises(ValueError):
            read_trace_events(path)
        with self.assertRaises(ValueError):
            read_trace_events(self.write("c.json", {"otherData": {}}))
        with self.assertRaises(OSError):
            read_trace_events(os.path.join(self.tmp, "absent.json"))

    def test_phases_sum_to_total(self):
        parsed = traceprofile.parse_jvm_profile(
            self.write("a.json", {"traceEvents": self.profile_events()}))
        self.assertAlmostEqual(sum(parsed["phases"].values()),
                               parsed["total"])


if __name__ == "__main__":
    unittest.main()
