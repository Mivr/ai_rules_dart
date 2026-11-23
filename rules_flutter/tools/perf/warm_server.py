#!/usr/bin/env python3
"""Whole-tree CPU of one command run against a warm Bazel server.

The iOS bench's clean builds stay ``bazel --batch`` (measured with wait4
deltas), but an edit build is what a developer pays against a running
server: no JVM start, no cold load and analysis. This module measures one
such command so the Android and web benches can reuse the method.

The cost of one command is the sum of:

- the client process's own whole-tree CPU (wait4 / RUSAGE_CHILDREN of the
  client, as for batch builds);
- the server process's growth in its own CPU plus the CPU of the children
  it reaped (finished) during the command;
- the growth, for every live descendant of the server (persistent workers
  and their children), in its own CPU plus its reaped children's CPU. A
  descendant that appears during the command counts from zero.

Each value is sampled before and after the command. The return carries CPU
seconds (user and sys), real seconds, the server pid, a per-part breakdown
(``client`` / ``server_self`` / ``server_reaped`` / ``descendants``) and
the method name ``warm-server``.

Fail closed: a missing server pid, a server that restarts mid-command
(same pid, different start token), or a sample that cannot be read raises
``WarmServerError``, which the caller records as the flow's reason. A
partial number is never returned as if it were whole.

Backends: Linux reads ``/proc/<pid>/stat`` (utime, stime, cutime, cstime
in clock ticks, ``SC_CLK_TCK``) and finds children through ``/proc``.
macOS reads libproc through ctypes: ``proc_pid_rusage`` with
``RUSAGE_INFO_V2`` (``ri_user_time``, ``ri_system_time``,
``ri_child_user_time``, ``ri_child_system_time`` in Mach absolute-time
units, converted with ``mach_timebase_info``, which is not 1/1 on Apple
silicon) and ``proc_listchildpids`` for children. The backend interface
is one function per platform to read a pid's own and reaped-children CPU
(``linux_read`` / ``mac_read``) and one to list its children
(``linux_children`` / ``mac_children``), so another counter (e.g. Linux
instructions) can be added later behind the same shape.

Known limit: a descendant that exits during the command is counted
through its parent's reaped-children time over its whole life, including
CPU it used before the command. Exited processes cannot be sampled, so
their pre-command share cannot be subtracted.
"""

import os
import sys
import time

import peak_rss

METHOD = "warm-server"

# A vanished process is an exited descendant, not a broken sample: its CPU
# already sits in its parent's reaped-children time (see the known limit
# above), so the snapshot skips it. Anything else unreadable fails closed.
_VANISHED = (FileNotFoundError, ProcessLookupError)


class WarmServerError(RuntimeError):
    """A warm-server measurement that must not be reported as a number."""


class ProcTimes:
    """Own and reaped-children CPU of one process sample.

    ``user_s``/``sys_s`` are the process's own CPU seconds,
    ``child_user_s``/``child_sys_s`` the CPU of its reaped children.
    ``start`` identifies the process across snapshots (the Linux
    starttime field, or the macOS process start abstime): a reused pid
    shows a different start, which fails the measurement closed.
    """

    __slots__ = ("user_s", "sys_s", "child_user_s", "child_sys_s",
                 "start")

    def __init__(self, user_s, sys_s, child_user_s, child_sys_s,
                 start):
        self.user_s = user_s
        self.sys_s = sys_s
        self.child_user_s = child_user_s
        self.child_sys_s = child_sys_s
        self.start = start


def ticks_per_second():
    """Clock ticks per CPU second (SC_CLK_TCK, usually 100)."""
    return os.sysconf("SC_CLK_TCK")


def linux_stat(pid):
    """Raw ``/proc/<pid>/stat`` fields: ``(ppid, utime, stime, cutime,
    cstime, starttime)``.

    A vanished process raises ``FileNotFoundError`` for the snapshot to
    treat as an exited descendant; anything else unreadable or
    unparsable raises ``WarmServerError`` naming the pid.
    """
    try:
        with open("/proc/%d/stat" % pid, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        if isinstance(exc, _VANISHED):
            raise
        raise WarmServerError("cannot read /proc/%d/stat (%s)"
                              % (pid, exc))
    try:
        tail = text.rsplit(")", 1)[1].split()
        values = (int(tail[1]), int(tail[11]), int(tail[12]),
                  int(tail[13]), int(tail[14]), int(tail[19]))
    except (IndexError, ValueError) as exc:
        raise WarmServerError("cannot parse /proc/%d/stat (%s)"
                              % (pid, exc))
    return values


def linux_read(pid):
    """``ProcTimes`` of a Linux pid from ``/proc/<pid>/stat``."""
    _, utime, stime, cutime, cstime, start = linux_stat(pid)
    ticks = ticks_per_second()
    return ProcTimes(utime / ticks, stime / ticks, cutime / ticks,
                     cstime / ticks, start)


def linux_children(pid):
    """Direct child pids of a Linux pid, found through ``/proc``."""
    try:
        entries = os.listdir("/proc")
    except OSError as exc:
        raise WarmServerError("cannot list /proc (%s)" % exc)
    found = []
    for entry in entries:
        if not entry.isdigit():
            continue
        try:
            ppid = linux_stat(int(entry))[0]
        except _VANISHED:
            continue
        if ppid == pid:
            found.append(int(entry))
    return found


_RUSAGE_INFO_V2 = 2
_MAC_TIME_OFFSETS = (16, 24, 96, 104)
_MAC_START_OFFSET = 80
_MAC_BUFFER_SIZE = 4096


def mac_raw_times(pid, _rusage=None):
    """``(user, sys, child_user, child_sys, start)`` Mach absolute-time
    units of a macOS pid, through ``proc_pid_rusage`` (``RUSAGE_INFO_V2``).

    ``_rusage`` stubs the libproc call in tests; a vanished process
    raises ``FileNotFoundError``, anything else ``WarmServerError``.
    """
    if _rusage is not None:
        return _rusage(pid)
    import ctypes
    lib = ctypes.CDLL("libproc.dylib", use_errno=True)
    buf = ctypes.create_string_buffer(_MAC_BUFFER_SIZE)
    if lib.proc_pid_rusage(pid, _RUSAGE_INFO_V2, buf) != 0:
        errno = ctypes.get_errno()
        if errno == 3:
            raise FileNotFoundError("no such process %d" % pid)
        raise WarmServerError("proc_pid_rusage(%d) failed (errno %d)"
                              % (pid, errno))
    raw = buf.raw
    offsets = _MAC_TIME_OFFSETS + (_MAC_START_OFFSET,)
    return tuple(int.from_bytes(raw[o:o + 8], "little")
                 for o in offsets)


def mac_timebase(_timebase=None):
    """``(numerator, denominator)`` of mach_timebase_info, converting
    Mach absolute time to nanoseconds."""
    if _timebase is not None:
        if _timebase[1] == 0:
            raise WarmServerError(
                "Mach timebase has a zero denominator")
        return _timebase
    import ctypes

    class _Info(ctypes.Structure):
        _fields_ = [("numerator", ctypes.c_uint32),
                    ("denominator", ctypes.c_uint32)]

    lib = ctypes.CDLL("libSystem.dylib", use_errno=True)
    info = _Info()
    if lib.mach_timebase_info(ctypes.byref(info)) != 0:
        raise WarmServerError("mach_timebase_info failed")
    if info.denominator == 0:
        raise WarmServerError(
            "mach_timebase_info returned a zero denominator")
    return (info.numerator, info.denominator)


def mac_read(pid, _rusage=None, _timebase=None):
    """``ProcTimes`` of a macOS pid through libproc, in CPU seconds."""
    raw = mac_raw_times(pid, _rusage)
    numerator, denominator = mac_timebase(_timebase)
    scale = numerator / denominator / 1e9
    return ProcTimes(raw[0] * scale, raw[1] * scale, raw[2] * scale,
                     raw[3] * scale, raw[4])


def mac_children(pid, _list=None):
    """Direct child pids of a macOS pid through ``proc_listchildpids``."""
    if _list is not None:
        return list(_list(pid))
    import ctypes
    lib = ctypes.CDLL("libproc.dylib", use_errno=True)
    count = lib.proc_listchildpids(pid, None, 0)
    if count < 0:
        raise WarmServerError("proc_listchildpids(%d) failed" % pid)
    if count == 0:
        return []
    array = (ctypes.c_int32 * count)()
    got = lib.proc_listchildpids(pid, array, ctypes.sizeof(array))
    if got < 0:
        raise WarmServerError("proc_listchildpids(%d) failed" % pid)
    return [int(array[n]) for n in range(min(got, count))]


def is_macos():
    """Whether this host uses the libproc backend."""
    return sys.platform == "darwin"


def read_times(pid):
    """``ProcTimes`` of pid on this platform; ``WarmServerError`` when
    the sample cannot be read."""
    if is_macos():
        return mac_read(pid)
    return linux_read(pid)


def child_pids(pid):
    """Direct child pids of pid on this platform."""
    if is_macos():
        return mac_children(pid)
    return linux_children(pid)


class TreeSnapshot:
    """One whole-tree sample: per-pid ``ProcTimes`` plus the server pid."""

    def __init__(self, server_pid, samples):
        self.server_pid = server_pid
        self.samples = samples

    def server_times(self):
        """The server's own sample; the pid is always present."""
        return self.samples[self.server_pid]


def snapshot(server_pid, _read=None, _children=None):
    """Samples the server's whole tree; fails closed on a bad server.

    A descendant that exits mid-snapshot is skipped: its CPU already
    sits in its parent's reaped-children time (the documented limit), so
    it stays counted, whole-life, through the parent. A missing server
    raises ``WarmServerError``.
    """
    read = _read or read_times
    list_children = _children or child_pids
    try:
        samples = {server_pid: read(server_pid)}
    except _VANISHED as exc:
        raise WarmServerError("warm server pid %d is gone (%s)"
                              % (server_pid, exc))
    queue = [server_pid]
    while queue:
        for child in list_children(queue.pop()):
            if child in samples:
                continue
            try:
                samples[child] = read(child)
            except _VANISHED:
                continue
            except WarmServerError:
                raise
            except OSError as exc:
                raise WarmServerError("cannot read process %d (%s)"
                                      % (child, exc))
            queue.append(child)
    return TreeSnapshot(server_pid, samples)


def tree_delta(last, first):
    """``(user, sys)`` growth of one sample, own plus reaped.

    A sample with no before (a descendant born mid-command) counts from
    zero: its whole after value belongs to the command.
    """
    if first is None:
        return (last.user_s + last.child_user_s,
                last.sys_s + last.child_sys_s)
    return (last.user_s - first.user_s
            + last.child_user_s - first.child_user_s,
            last.sys_s - first.sys_s
            + last.child_sys_s - first.child_sys_s)


def summarize_deltas(server_pid, returncode, real_s, client_user_s,
                     client_sys_s, before, after, peak_rss_mb=None):
    """Result dict from two snapshots and the client's rusage delta."""
    first = before.server_times()
    last = after.server_times()
    parts = {
        "client": {"user_s": client_user_s, "sys_s": client_sys_s},
        "server_self": {"user_s": last.user_s - first.user_s,
                        "sys_s": last.sys_s - first.sys_s},
        "server_reaped": {"user_s": (last.child_user_s
                                     - first.child_user_s),
                          "sys_s": (last.child_sys_s
                                    - first.child_sys_s)},
        "descendants": {"user_s": 0.0, "sys_s": 0.0},
    }
    for pid, last_times in after.samples.items():
        if pid == server_pid:
            continue
        user_delta, sys_delta = tree_delta(
            last_times, before.samples.get(pid))
        parts["descendants"]["user_s"] += user_delta
        parts["descendants"]["sys_s"] += sys_delta
    user_s = sum(part["user_s"] for part in parts.values())
    sys_s = sum(part["sys_s"] for part in parts.values())
    return {"user_s": user_s, "sys_s": sys_s, "real_s": real_s,
            "returncode": returncode, "method": METHOD,
            "server_pid": server_pid, "parts": parts,
            "peak_rss_mb": peak_rss_mb}


def measure(argv, cwd, server_pid, _read=None, _children=None,
            _rss_read=None, deadline=None):
    """Runs argv (which must go through the server) and returns its
    whole-tree CPU.

    Samples the server tree before and after the command and adds the
    client process's own whole-tree CPU (wait4 deltas, as for batch
    builds). Raises ``WarmServerError`` when the server is missing,
    restarts mid-command, or any sample fails: the caller records the
    error instead of a number. A ``deadline`` kills the command with its
    process group when it passes (``DeadlineExceeded``).
    """
    import resource
    before = snapshot(server_pid, _read, _children)
    start = time.monotonic()
    rusage_before = resource.getrusage(resource.RUSAGE_CHILDREN)
    returncode, peak_rss_mb = peak_rss.run_peak(
        argv, cwd, server_pid, _rss_read, _children, deadline)
    rusage_after = resource.getrusage(resource.RUSAGE_CHILDREN)
    after = snapshot(server_pid, _read, _children)
    if after.server_times().start != before.server_times().start:
        raise WarmServerError(
            "warm server pid %d restarted during the command" % server_pid)
    return summarize_deltas(
        server_pid, returncode, time.monotonic() - start,
        rusage_after.ru_utime - rusage_before.ru_utime,
        rusage_after.ru_stime - rusage_before.ru_stime,
        before, after, peak_rss_mb)
