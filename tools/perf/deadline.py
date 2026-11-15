"""Wall-clock deadline of a bench run (injectable clock).

`sol.py run` and `ab.py run` take an optional `--deadline-epoch`: once it
has passed, no new flow starts and a measured Bazel command still running
is killed with its whole process group. The unfinished flows are recorded
with the reason `timeout` and no numbers, so the summary and the artifact
upload still have something to write.
"""

import os
import signal
import time

TIMEOUT_REASON = "timeout"


class DeadlineExceeded(RuntimeError):
    """The run's deadline passed before a flow could finish."""


class Deadline:
    """A unix-seconds deadline read against an injectable clock."""

    def __init__(self, epoch, clock=time.time):
        self.epoch = float(epoch)
        self.clock = clock

    def remaining(self):
        """Seconds left; zero or negative once the deadline has passed."""
        return self.epoch - self.clock()

    def passed(self):
        return self.remaining() <= 0

    def check(self, what):
        """Raises DeadlineExceeded, naming what could not start."""
        if self.passed():
            raise DeadlineExceeded(
                "deadline %s passed before %s" % (self.epoch, what))


def add_deadline_arg(parser):
    """Adds the optional --deadline-epoch to a `run` sub-parser."""
    parser.add_argument(
        "--deadline-epoch", type=float, default=None,
        help="unix seconds: no flow starts after it and a running Bazel "
        "command is killed; unfinished flows are recorded as timeout")


def from_args(args):
    """The Deadline of parsed `run` args, or None when none was given."""
    epoch = getattr(args, "deadline_epoch", None)
    return None if epoch is None else Deadline(epoch)


def of(args):
    """The Deadline attached to run args, or None (also for old fakes)."""
    return getattr(args, "deadline", None)


def passed(args):
    deadline = of(args)
    return deadline is not None and deadline.passed()


def check(args, what):
    """Raises DeadlineExceeded when the run's deadline has passed."""
    deadline = of(args)
    if deadline is not None:
        deadline.check(what)


def kill_group(proc):
    """SIGKILLs proc's process group (it leads one: start_new_session)."""
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass  # the whole group already exited between timeout and kill


def communicate_until(proc, deadline):
    """proc.communicate() that kills the group at the deadline.

    Waits in slices of at most one second, so a clock that jumps is seen.
    Returns what communicate returns; raises DeadlineExceeded after the
    group is killed and reaped.
    """
    import subprocess
    while True:
        try:
            return proc.communicate(
                timeout=min(max(deadline.remaining(), 0), 1.0))
        except subprocess.TimeoutExpired:
            if deadline.passed():
                kill_group(proc)
                proc.communicate()
                raise DeadlineExceeded(
                    "killed %s at the deadline %s"
                    % (proc.args[:3], deadline.epoch))


def is_timeout_record(record):
    """True for a flow record the deadline wrote (reason `timeout...`)."""
    return str(record.get("reason") or "").startswith(TIMEOUT_REASON)


def install_measures(cmd, process_tree, warm):
    """Sets cmd.deadline and the measuring callables of a `run` command.

    process_tree(argv, cwd, deadline=) measures a batch build and
    warm(argv, cwd, server_pid, deadline=) a warm-server command; both
    kill the command at the deadline.
    """
    cmd.deadline = from_args(cmd)
    cmd.measure = lambda argv, cwd: process_tree(
        argv, cwd, deadline=cmd.deadline)
    cmd.measure_warm = lambda argv, cwd, server_pid: warm(
        argv, cwd, server_pid, deadline=cmd.deadline)
