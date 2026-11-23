#!/usr/bin/env python3
"""Unit tests for warm_server.py (warm Bazel server measurement)."""

import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import warm_server
from warm_server import (
    METHOD,
    ProcTimes,
    WarmServerError,
    child_pids,
    is_macos,
    linux_children,
    linux_read,
    linux_stat,
    mac_children,
    mac_read,
    mac_timebase,
    measure,
    read_times,
    snapshot,
    ticks_per_second,
    tree_delta,
)


def times(user, sys_cpu, child_user=0.0, child_sys=0.0, start=1):
    """A canned ProcTimes sample."""
    return ProcTimes(user, sys_cpu, child_user, child_sys, start)


class ScriptedTree:
    """Canned backend with one tree generation per snapshot.

    generations[k] is {pid: (ppid, ProcTimes or exception)} as seen by
    the k-th snapshot. The server read opens each snapshot, so before
    and after differ exactly as scripted.
    """

    def __init__(self, server_pid, generations):
        self.server_pid = server_pid
        self.generations = generations
        self.snapshots = 0

    def _at(self, index):
        return self.generations[
            min(max(index, 0), len(self.generations) - 1)]

    def read(self, pid):
        if pid == self.server_pid:
            gen = self._at(self.snapshots)
            self.snapshots += 1
        else:
            gen = self._at(self.snapshots - 1)
        if pid not in gen:
            raise FileNotFoundError("no such process %d" % pid)
        item = gen[pid][1]
        if isinstance(item, BaseException):
            raise item
        return item

    def children(self, pid):
        gen = self._at(self.snapshots - 1)
        return sorted(p for p, (pp, _) in gen.items() if pp == pid)


def scripted_measure(generations, server_pid=100):
    """measure() against a scripted tree with a trivial real client."""
    tree = ScriptedTree(server_pid, generations)
    return measure([sys.executable, "-c", "pass"], tempfile.gettempdir(),
                   server_pid, _read=tree.read, _children=tree.children)


class LinuxBackendTest(unittest.TestCase):
    def test_ticks_per_second_positive(self):
        self.assertGreater(ticks_per_second(), 0)

    def test_stat_self_matches_parent(self):
        ppid, utime, stime, _, _, start = linux_stat(os.getpid())
        self.assertEqual(ppid, os.getppid())
        self.assertGreaterEqual(utime, 0)
        self.assertGreaterEqual(stime, 0)
        self.assertGreater(start, 0)

    def test_stat_missing_raises_vanished(self):
        with self.assertRaises(FileNotFoundError):
            linux_stat(1 << 30)

    def test_read_self_nonnegative(self):
        sample = linux_read(os.getpid())
        self.assertGreaterEqual(sample.user_s, 0.0)
        self.assertGreaterEqual(sample.sys_s, 0.0)

    def test_children_finds_live_child(self):
        child = subprocess.Popen(
            ["sleep", "5"], stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            self.assertIn(child.pid, linux_children(os.getpid()))
        finally:
            child.terminate()
            child.wait()

    def test_snapshot_contains_server(self):
        snap = snapshot(os.getpid())
        self.assertIn(os.getpid(), snap.samples)
        self.assertEqual(snap.server_times().start,
                         linux_stat(os.getpid())[5])

    @unittest.skipIf(is_macos(), "Linux /proc backend only")
    def test_dispatch_uses_linux_backend(self):
        sample = read_times(os.getpid())
        self.assertGreaterEqual(sample.user_s, 0.0)
        child = subprocess.Popen(
            ["sleep", "5"], stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            self.assertIn(child.pid, child_pids(os.getpid()))
        finally:
            child.terminate()
            child.wait()


# A stand-in server: two short children that exit (and are reaped) during
# the command, one long-lived child burning throughout, and self CPU
# throughout. Exercises own, reaped and descendant accounting at once.
SERVER_BURN = """\
import subprocess
import sys
import time
ready_path, self_s, child_s, short_s, n_short = sys.argv[1:6]
burn = ("import time\\nend = time.time() + %s\\nx = 0\\n"
        "while time.time() < end:\\n x += 1\\n")
shorts = [subprocess.Popen(
    [sys.executable, "-c", burn % short_s]) for _ in range(int(n_short))]
child = subprocess.Popen([sys.executable, "-c", burn % child_s])
with open(ready_path, "w") as fh:
    fh.write("ready\\n")
for proc in shorts:
    proc.wait()
end = time.time() + float(self_s)
x = 0
while time.time() < end:
    x += 1
child.wait()
"""

CLIENT_BURN = ("import time\nend = time.time() + 2.0\nx = 0\n"
               "while time.time() < end:\n x += 1\n")


class RealTreeTest(unittest.TestCase):
    """The Linux backend against a real burning process tree."""

    @unittest.skipIf(is_macos(), "Linux /proc backend only")
    def test_server_self_child_and_reaped_counted(self):
        tmp = tempfile.mkdtemp(prefix="warm-real-")
        self.addCleanup(__import__("shutil").rmtree, tmp, True)
        server_path = os.path.join(tmp, "server_burn.py")
        with open(server_path, "w", encoding="utf-8") as fh:
            fh.write(SERVER_BURN)
        ready_path = os.path.join(tmp, "ready")
        server = subprocess.Popen(
            [sys.executable, server_path, ready_path, "4", "4", "1.0",
             "2"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL)
        try:
            deadline = time.time() + 30.0
            while not os.path.exists(ready_path):
                self.assertLess(time.time(), deadline)
                time.sleep(0.05)
            result = measure([sys.executable, "-c", CLIENT_BURN], tmp,
                             server.pid)
        finally:
            try:
                kids = linux_children(server.pid)
            except WarmServerError:
                kids = []
            server.terminate()
            for pid in kids:
                try:
                    os.kill(pid, signal.SIGTERM)
                except OSError:
                    pass
            server.wait()
        self.assertEqual(result["method"], METHOD)
        self.assertEqual(result["server_pid"], server.pid)
        self.assertEqual(result["returncode"], 0)
        self.assertGreaterEqual(result["real_s"], 2.0)
        parts = result["parts"]
        self.assertEqual(
            sorted(parts), ["client", "descendants", "server_reaped",
                            "server_self"])
        for name, part in parts.items():
            self.assertGreaterEqual(part["user_s"], 0.0, name)
            self.assertGreaterEqual(part["sys_s"], 0.0, name)
        # Each part burned ~1-2 s during the window; quarter shares are
        # far below reality but far above a dropped part.
        client = parts["client"]["user_s"] + parts["client"]["sys_s"]
        self.assertGreaterEqual(client, 0.5)
        own = (parts["server_self"]["user_s"]
               + parts["server_self"]["sys_s"])
        self.assertGreaterEqual(own, 0.5)
        reaped = (parts["server_reaped"]["user_s"]
                  + parts["server_reaped"]["sys_s"])
        self.assertGreaterEqual(reaped, 0.5)
        desc = (parts["descendants"]["user_s"]
                + parts["descendants"]["sys_s"])
        self.assertGreaterEqual(desc, 0.5)
        self.assertAlmostEqual(result["user_s"] + result["sys_s"],
                               client + own + reaped + desc)


class MacBackendTest(unittest.TestCase):
    """macOS arithmetic and timebase conversion with stubbed libproc."""

    def raw(self, pid):
        del pid
        return (1000000, 2000000, 4000000, 8000000, 7)

    def test_silicon_timebase_conversion(self):
        sample = mac_read(4242, _rusage=self.raw, _timebase=(125, 3))
        scale = 125 / 3 / 1e9
        self.assertAlmostEqual(sample.user_s, 1000000 * scale)
        self.assertAlmostEqual(sample.sys_s, 2000000 * scale)
        self.assertAlmostEqual(sample.child_user_s, 4000000 * scale)
        self.assertAlmostEqual(sample.child_sys_s, 8000000 * scale)
        self.assertEqual(sample.start, 7)

    def test_unity_timebase(self):
        sample = mac_read(4242, _rusage=self.raw, _timebase=(1, 1))
        self.assertAlmostEqual(sample.user_s, 0.001)
        self.assertAlmostEqual(sample.sys_s, 0.002)

    def test_silicon_timebase_is_not_unity(self):
        # Apple silicon runs numer/denom 125/3: assuming 1/1 would report
        # barely 2% of the true CPU. The conversion must be applied.
        sample = mac_read(4242, _rusage=self.raw, _timebase=(125, 3))
        self.assertNotAlmostEqual(sample.user_s, 0.001, delta=0.01)
        self.assertAlmostEqual(sample.user_s, 0.001 * 125 / 3)

    def test_zero_denominator_fails_closed(self):
        with self.assertRaises(WarmServerError):
            mac_read(4242, _rusage=self.raw, _timebase=(5, 0))
        with self.assertRaises(WarmServerError):
            mac_timebase((5, 0))

    def test_children_stub(self):
        self.assertEqual(
            mac_children(9, _list=lambda pid: [10, 11] if pid == 9
                         else []),
            [10, 11])

    def test_vanished_propagates_for_snapshot(self):
        def gone(pid):
            raise FileNotFoundError("no such process %d" % pid)

        with self.assertRaises(FileNotFoundError):
            mac_read(4242, _rusage=gone, _timebase=(1, 1))


class SnapshotScriptedTest(unittest.TestCase):
    def test_new_descendant_counts_from_zero(self):
        before = {100: (None, times(1.0, 0.5, 0.0, 0.0)),
                  101: (100, times(0.5, 0.5))}
        after = {100: (None, times(1.5, 0.7, 0.5, 0.2)),
                 101: (100, times(1.0, 1.0, 0.5, 0.5)),
                 102: (100, times(0.4, 0.1))}
        result = scripted_measure([before, after])
        parts = result["parts"]
        self.assertAlmostEqual(parts["server_self"]["user_s"], 0.5)
        self.assertAlmostEqual(parts["server_self"]["sys_s"], 0.2)
        self.assertAlmostEqual(parts["server_reaped"]["user_s"], 0.5)
        self.assertAlmostEqual(parts["server_reaped"]["sys_s"], 0.2)
        # Worker 101 grew by (0.5 + 0.5) user and sys; newcomer 102
        # counts its whole after value.
        self.assertAlmostEqual(parts["descendants"]["user_s"], 1.4)
        self.assertAlmostEqual(parts["descendants"]["sys_s"], 1.1)

    def test_exited_descendant_counted_through_parent(self):
        # The documented limit: worker 101 burns 10 s before the command
        # and 0.5 s during it, then exits and is reaped. The reaped delta
        # carries its whole life (10.5), including the pre-command share.
        before = {100: (None, times(1.0, 0.0, 5.0, 0.0)),
                  101: (100, times(10.0, 0.0))}
        after = {100: (None, times(2.0, 0.0, 15.5, 0.0))}
        result = scripted_measure([before, after])
        parts = result["parts"]
        self.assertAlmostEqual(parts["server_self"]["user_s"], 1.0)
        self.assertAlmostEqual(parts["server_reaped"]["user_s"], 10.5)
        self.assertAlmostEqual(parts["descendants"]["user_s"], 0.0)

    def test_vanished_mid_snapshot_skipped(self):
        tree = ScriptedTree(100, [{100: (None, times(1.0, 0.5))}])
        snap = snapshot(100, _read=tree.read,
                        _children=lambda pid: [103] if pid == 100
                        else [])
        self.assertEqual(sorted(snap.samples), [100])

    def test_unreadable_descendant_fails_closed(self):
        boom = PermissionError("denied")
        tree = ScriptedTree(100, [{100: (None, times(1.0, 0.5)),
                                   103: (100, boom)}])
        with self.assertRaises(WarmServerError):
            snapshot(100, _read=tree.read, _children=tree.children)

    def test_tree_delta_from_zero(self):
        self.assertEqual(tree_delta(times(0.4, 0.1), None), (0.4, 0.1))
        user_delta, sys_delta = tree_delta(times(1.5, 0.7, 0.5, 0.2),
                                           times(1.0, 0.5, 0.0, 0.0))
        self.assertAlmostEqual(user_delta, 1.0)
        self.assertAlmostEqual(sys_delta, 0.4)


class FailClosedTest(unittest.TestCase):
    def test_missing_server_pid(self):
        with self.assertRaises(WarmServerError):
            snapshot(1 << 30)
        with self.assertRaises(WarmServerError):
            measure([sys.executable, "-c", "pass"],
                    tempfile.gettempdir(), 1 << 30)

    def test_server_restart_fails(self):
        before = {100: (None, times(1.0, 0.5, start=11))}
        after = {100: (None, times(0.1, 0.0, start=95))}
        with self.assertRaisesRegex(WarmServerError, "restarted"):
            scripted_measure([before, after])

    def test_method_name(self):
        self.assertEqual(warm_server.METHOD, "warm-server")
        result = scripted_measure([{100: (None, times(1.0, 0.5))}])
        self.assertEqual(result["method"], "warm-server")
        self.assertEqual(result["server_pid"], 100)
        self.assertEqual(result["returncode"], 0)
        self.assertGreaterEqual(result["real_s"], 0.0)


if __name__ == "__main__":
    unittest.main()
