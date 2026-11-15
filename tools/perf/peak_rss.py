#!/usr/bin/env python3
"""Peak summed resident set of a process tree while a command runs.

A sampler walks a root pid and all its descendants (persistent workers
included) every ``INTERVAL_S`` seconds at most and sums their resident
sets. The peak is the largest sum; one final sample is taken at stop, so a
command shorter than the interval still gets a reading.

Linux reads ``/proc/<pid>/statm`` (resident pages times the page size),
macOS ``ps -o rss= -p <pid>`` (KiB). Children come from
``warm_server.child_pids``. A process that vanished between listing and
reading adds 0; any other unreadable sample raises ``PeakRssError`` naming
the pid. The reader, the child lister and the clock are injectable.
"""

import os
import subprocess
import threading
import time

import warm_server
from deadline import communicate_until

INTERVAL_S = 0.5
_MIB = 1024 * 1024
_VANISHED = (FileNotFoundError, ProcessLookupError)


class PeakRssError(RuntimeError):
    """A resident-set sample that must not be reported as a number."""


def parse_statm(text, pid, page_size):
    """Resident bytes from ``/proc/<pid>/statm`` text (second field)."""
    try:
        return int(text.split()[1]) * page_size
    except (IndexError, ValueError) as exc:
        raise PeakRssError("cannot parse /proc/%d/statm (%s)"
                           % (pid, exc))


def parse_ps_rss(text, pid):
    """Resident bytes from ``ps -o rss=`` output (KiB); an empty output
    means the process is gone."""
    text = text.strip()
    if not text:
        raise FileNotFoundError("no such process %d" % pid)
    try:
        return int(text) * 1024
    except ValueError as exc:
        raise PeakRssError("cannot parse ps rss of pid %d (%s)"
                           % (pid, exc))


def linux_rss(pid):
    """Resident bytes of a Linux pid."""
    with open("/proc/%d/statm" % pid, encoding="utf-8") as fh:
        text = fh.read()
    return parse_statm(text, pid, os.sysconf("SC_PAGE_SIZE"))


def mac_rss(pid):
    """Resident bytes of a macOS pid, through ``ps``."""
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)],
                         capture_output=True, text=True, check=False)
    return parse_ps_rss(out.stdout, pid)


def read_rss(pid):
    """Resident bytes of pid on this platform."""
    return mac_rss(pid) if warm_server.is_macos() else linux_rss(pid)


def tree_rss(root_pid, read, children):
    """Summed resident bytes of root_pid and its descendants."""
    total = 0
    seen = {root_pid}
    queue = [root_pid]
    while queue:
        pid = queue.pop()
        try:
            total += read(pid)
        except _VANISHED:
            continue
        except PeakRssError:
            raise
        except OSError as exc:
            raise PeakRssError("cannot read resident set of pid %d (%s)"
                               % (pid, exc))
        for child in children(pid):
            if child not in seen:
                seen.add(child)
                queue.append(child)
    return total


class PeakSampler:
    """Samples a tree's resident set on a thread; ``stop`` gives the peak."""

    def __init__(self, root_pid, interval=INTERVAL_S, read=None,
                 children=None, clock=None, wait=None):
        if interval > INTERVAL_S or interval <= 0:
            raise ValueError("sampling interval %r must be in (0, %s] s"
                             % (interval, INTERVAL_S))
        self.root_pid = root_pid
        self.interval = interval
        self._read = read or read_rss
        self._children = children or warm_server.child_pids
        self._clock = clock or time.monotonic
        self._halt = threading.Event()
        self._wait = wait or self._halt.wait
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self.peak_bytes = 0
        self._error = None

    def sample(self):
        """Takes one sample and folds it into the peak."""
        total = tree_rss(self.root_pid, self._read, self._children)
        self.peak_bytes = max(self.peak_bytes, total)

    def _loop(self):
        due = self._clock()
        while True:
            try:
                self.sample()
            except PeakRssError as exc:
                self._error = exc
                return
            due += self.interval
            if self._wait(max(0.0, due - self._clock())):
                return

    def start(self):
        """Starts sampling."""
        self._thread.start()

    def stop(self):
        """Stops, takes the final sample, returns the peak in MiB."""
        self._halt.set()
        self._thread.join()
        if self._error is not None:
            raise self._error
        self.sample()
        return self.peak_bytes / _MIB


def run_peak(argv, cwd, root_pid=None, read=None, children=None,
             deadline=None):
    """Runs argv as ``subprocess.run`` would (stdin and stdout discarded,
    stderr piped); returns ``(returncode, peak_rss_mb)`` of the tree under
    root_pid (default: the spawned process).

    With a deadline the command leads its own process group and is killed
    with it when the deadline passes (``DeadlineExceeded``); one already
    passed starts nothing.
    """
    if deadline is not None:
        deadline.check("starting %s" % list(argv)[:3])
    proc = subprocess.Popen(
        list(argv), cwd=cwd, stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
        start_new_session=deadline is not None)
    sampler = PeakSampler(proc.pid if root_pid is None else root_pid,
                          read=read, children=children)
    sampler.start()
    try:
        if deadline is None:
            proc.communicate()
        else:
            communicate_until(proc, deadline)
    finally:
        peak = sampler.stop()
    return proc.returncode, peak
