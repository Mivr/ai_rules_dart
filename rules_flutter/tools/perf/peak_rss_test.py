#!/usr/bin/env python3
"""Unit tests for peak_rss.py (fake process tables, no real sampling)."""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import peak_rss
from peak_rss import (
    PeakRssError,
    PeakSampler,
    parse_ps_rss,
    parse_statm,
    tree_rss,
)

MIB = 1024 * 1024
# server 10, workers 11 and 12, grandchild 13 under 11, unrelated 99.
PARENTS = {10: 1, 11: 10, 12: 10, 13: 11, 99: 1}


class FakeTable:
    """Process table whose resident sizes change per sampling round."""

    def __init__(self, rounds):
        self.rounds = rounds
        self.round = 0

    def read(self, pid):
        table = self.rounds[min(self.round, len(self.rounds) - 1)]
        if pid not in table:
            raise FileNotFoundError("no such process %d" % pid)
        value = table[pid]
        if isinstance(value, BaseException):
            raise value
        return value * MIB

    def children(self, pid):
        return sorted(p for p, parent in PARENTS.items() if parent == pid)

    def advance(self, _seconds):
        self.round += 1
        return False


class TreeRssTest(unittest.TestCase):
    def test_sums_tree_and_excludes_unrelated(self):
        table = FakeTable([{10: 100, 11: 50, 12: 30, 13: 5, 99: 1000}])
        total = tree_rss(10, table.read, table.children)
        self.assertEqual(total, 185 * MIB)

    def test_vanished_worker_adds_zero(self):
        table = FakeTable([{10: 100, 11: 50, 13: 5, 99: 1000}])
        total = tree_rss(10, table.read, table.children)
        self.assertEqual(total, 155 * MIB)

    def test_unreadable_sample_names_the_pid(self):
        table = FakeTable([{10: 100, 11: PermissionError("denied"),
                            12: 1, 13: 1}])
        with self.assertRaisesRegex(PeakRssError, "pid 11"):
            tree_rss(10, table.read, table.children)

    def test_unparsable_sample_names_the_pid(self):
        with self.assertRaisesRegex(PeakRssError, "/proc/42/statm"):
            parse_statm("garbage", 42, 4096)


class PeakSamplerTest(unittest.TestCase):
    def sampler(self, table, **kwargs):
        return PeakSampler(10, read=table.read, children=table.children,
                           wait=table.advance, **kwargs)

    def test_peak_is_max_of_sums(self):
        table = FakeTable([
            {10: 100, 11: 50, 12: 30, 13: 5, 99: 9000},
            {10: 100, 11: 400, 12: 30, 13: 5, 99: 1},
            {10: 100, 11: 50, 12: 30, 13: 5},
        ])
        sampler = self.sampler(table)
        for _ in range(3):
            sampler.sample()
            table.advance(0)
        self.assertEqual(sampler.peak_bytes, 535 * MIB)

    def test_final_sample_taken_at_stop(self):
        # The thread's single sample sees 100 MiB, the wait then stops it;
        # only the final sample at stop sees the 700 MiB of the new round.
        table = FakeTable([{10: 100}, {10: 700}])
        sampler = self.sampler(table)
        sampler._wait = lambda _s: True
        sampler.start()
        sampler._thread.join()
        table.round = 1
        self.assertEqual(sampler.stop(), 700.0)

    def test_vanished_worker_in_peak(self):
        table = FakeTable([{10: 100, 11: 50, 12: 30, 13: 5},
                           {10: 100, 11: 50, 13: 5}])
        sampler = self.sampler(table)
        sampler.sample()
        table.advance(0)
        sampler.sample()
        self.assertEqual(sampler.peak_bytes, 185 * MIB)

    def test_interval_above_half_second_refused(self):
        with self.assertRaises(ValueError):
            PeakSampler(10, interval=0.6, read=lambda _p: 0,
                        children=lambda _p: [])
        PeakSampler(10, interval=0.5, read=lambda _p: 0,
                    children=lambda _p: [])

    def test_sampler_error_surfaces_on_stop(self):
        table = FakeTable([{10: PermissionError("denied")}])
        sampler = self.sampler(table)
        sampler.start()
        with self.assertRaisesRegex(PeakRssError, "pid 10"):
            sampler.stop()

    def test_run_peak_real_command(self):
        code, peak = peak_rss.run_peak(
            [sys.executable, "-c", "import sys; sys.exit(3)"], None,
            read=lambda _p: 7 * MIB, children=lambda _p: [])
        self.assertEqual(code, 3)
        self.assertEqual(peak, 7.0)


class ParserTest(unittest.TestCase):
    def test_ps_reads_kib(self):
        self.assertEqual(parse_ps_rss("  2048\n", 5), 2048 * 1024)

    def test_ps_empty_is_vanished(self):
        with self.assertRaises(FileNotFoundError):
            parse_ps_rss("\n", 5)

    def test_ps_garbage_names_the_pid(self):
        with self.assertRaisesRegex(PeakRssError, "pid 5"):
            parse_ps_rss("abc", 5)

    def test_statm_reads_pages_times_page_size(self):
        self.assertEqual(parse_statm("100 25 3 1 0 9 0", 1, 4096),
                         25 * 4096)


if __name__ == "__main__":
    unittest.main()
