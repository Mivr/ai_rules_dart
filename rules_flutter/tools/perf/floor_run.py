"""Runs a toolchain floor chain and measures its CPU (see floor.py).

CPU is measured with the same wait4 clock the replay chain uses
(``replay.run_tree``): whole process tree user+sys seconds. The resident
``frontend_server`` is a long-lived child, so its timed cost is its CPU at
exit (wait4) minus its CPU sampled after the untimed first compile. The
in-process payload replacement is timed with the process CPU clock.
"""

import dataclasses
import os
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from floor import FloorError  # noqa: E402
from floor import build_chain  # noqa: E402
from floor import resolve_tools  # noqa: E402
from floor_apk import entry_names  # noqa: E402
from floor_apk import replace_entry  # noqa: E402
from floor_check import check_package  # noqa: E402
from replay import run_tree  # noqa: E402


@dataclasses.dataclass
class FloorResult:
    """Outcome of one floor run: cpu_s is None unless identical."""

    cpu_s: object
    real_s: object
    identical: bool
    reason: str
    steps: dict


def real_runner(argv, timeout=1800.0):
    """(returncode, cpu_s, stderr) of argv, by the replay's wait4 clock."""
    code, user, system, _, err = run_tree(list(argv), None, None, timeout)
    return (code, user + system, err)


def process_cpu(pid):
    """user+sys CPU seconds of a live process (Linux /proc, else ps)."""
    try:
        with open("/proc/%d/stat" % pid, encoding="ascii") as fh:
            rest = fh.read().rsplit(")", 1)[1].split()
        return (int(rest[11]) + int(rest[12])) / os.sysconf("SC_CLK_TCK")
    except OSError:
        pass
    proc = subprocess.run(["ps", "-o", "time=", "-p", str(pid)],
                          stdout=subprocess.PIPE, text=True, check=False)
    minutes, _, seconds = proc.stdout.strip().rpartition(":")
    return 60 * float(minutes or 0) + float(seconds)


MAX_PRELUDE = 30
MAX_PRE_RESULT = MAX_PRELUDE
MAX_DIAGNOSTICS = 30
STDERR_TAIL = 20
MAX_MESSAGE = 4000


def cap_middle(text, limit):
    """text cut in the middle to at most limit characters."""
    if len(text) <= limit:
        return text
    mark = "\n...[cut]...\n"
    keep = limit - len(mark)
    return text[:keep // 2] + mark + text[len(text) - (keep - keep // 2):]


def error_message(fields, pre_result, diagnostics=None, stderr_tail=None):
    """Cause text: closing fields, prelude, diagnostics, stderr; <= MAX_MESSAGE."""
    if stderr_tail is None and isinstance(diagnostics, str):
        stderr_tail = diagnostics
        diagnostics = pre_result
        pre_result = []
    elif diagnostics is None:
        diagnostics = []
    if stderr_tail is None:
        stderr_tail = ""
    head = "frontend_server reported errors: %s" % (
        " ".join(fields) or "no output file")
    parts = []
    if pre_result:
        parts.append("before result:\n" + "\n".join(pre_result))
    if diagnostics:
        parts.append("diagnostics:\n" + "\n".join(diagnostics))
    if stderr_tail:
        parts.append("stderr:\n" + stderr_tail)
    if not parts:
        parts.append("the server printed no diagnostics and no stderr")
    body = cap_middle("\n".join(parts), MAX_MESSAGE - len(head) - 1)
    return head + ("\n" + body if body else "")


class FrontendServer:
    """Resident ``frontend_server`` speaking its incremental protocol."""

    def __init__(self, argv, popen=subprocess.Popen):
        self.argv = tuple(argv)
        self.errlog = tempfile.TemporaryFile("w+")
        self.proc = popen(list(argv), stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE, text=True,
                          stderr=self.errlog)
        self.baseline = None

    def _send(self, text):
        self.proc.stdin.write(text)
        self.proc.stdin.flush()

    def stderr_tail(self):
        """The last STDERR_TAIL stderr lines of the server, as text."""
        text = ""
        try:
            self.errlog.flush()
            size = os.fstat(self.errlog.fileno()).st_size
            text = os.pread(self.errlog.fileno(), size, 0).decode(
                "utf-8", "replace")
        except (OSError, ValueError):
            pass  # the log is only a diagnostic aid
        pipe = getattr(self.proc, "stderr", None)
        if not text and pipe is not None and hasattr(pipe, "read"):
            text = pipe.read() or ""
        return "\n".join(text.splitlines()[-STDERR_TAIL:])

    def _ended_head(self):
        """Closing line of a server that died: exit status and tool paths."""
        status = getattr(self.proc, "returncode", None)
        if status is None and hasattr(self.proc, "poll"):
            status = self.proc.poll()
        if status is None and hasattr(self.proc, "wait"):
            try:
                status = self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                status = "still running"
        argv = list(self.argv)
        return ("frontend_server ended without a result (exit status %s; "
                "dartaotruntime %s; snapshot %s)" % (
                    status, argv[0] if argv else "?",
                    argv[1] if len(argv) > 1 else "?"))

    def _read_result(self):
        """Waits for ``result <key>``; returns (fields, pre_result, diagnostics).

        Lines before ``result <key>`` are kept in order, at most the first
        MAX_PRELUDE. Diagnostics are the lines between ``result <key>``
        and the closing line, in order, at most the first MAX_DIAGNOSTICS.

        The server prints ``--print-incremental-dependencies`` by default:
        after the diagnostics a bare ``<key>`` line, the ``+``/``-`` source
        lines, then ``<key> <file> <error count>``. The bare line and the
        dependency lines are skipped; the fields come from the last line. A
        reply that ends after the bare line has no fields.
        """
        key = None
        bare = False
        pre_result = []
        diagnostics = []
        for line in self.proc.stdout:
            line = line.rstrip("\r\n")
            if key is None and line.startswith("result "):
                key = line.split(" ", 1)[1]
            elif key is None:
                if len(pre_result) < MAX_PRELUDE:
                    pre_result.append(line)
            elif line.startswith(key + " "):
                return line[len(key):].split(), pre_result, diagnostics
            elif line == key:
                bare = True
            elif bare and line.startswith(("+", "-")):
                continue
            elif len(diagnostics) < MAX_DIAGNOSTICS:
                diagnostics.append(line)
        if bare:
            return [], pre_result, diagnostics
        tail = self.stderr_tail()
        head = self._ended_head()
        parts = []
        if pre_result:
            parts.append("before result:\n" + "\n".join(pre_result))
        if tail:
            parts.append("stderr:\n" + tail)
        body = cap_middle("\n".join(parts), MAX_MESSAGE - len(head) - 1)
        raise FloorError(head + ("\n" + body if body else ""))

    def _checked(self):
        fields, pre_result, diagnostics = self._read_result()
        if len(fields) < 2 or fields[-1] != "0":
            raise FloorError(error_message(
                fields, pre_result, diagnostics, self.stderr_tail()))

    def compile(self, entry):
        """First full compile; accepted so the next one is incremental."""
        self._send("compile %s\n" % entry)
        self._checked()
        self._send("accept\n")
        self.baseline = process_cpu(self.proc.pid)

    def recompile(self, entry, invalidated):
        """Full kernel after the edit, reusing the unchanged libraries."""
        key = "floorkey%d" % time.monotonic_ns()
        self._send("reset\nrecompile %s %s\n%s\n%s\n" % (
            entry, key, "\n".join(invalidated), key))
        self._checked()

    def quit(self):
        """Stops the server; returns its CPU since the baseline."""
        self._send("quit\n")
        self.proc.stdin.close()
        _, status, usage = os.wait4(self.proc.pid, 0)
        self.proc.returncode = os.waitstatus_to_exitcode(status)
        total = usage.ru_utime + usage.ru_stime
        return total - (self.baseline or 0.0)


def payload_target(spec, names=None):
    """Path (iOS) or entry name (Android) the replace step swaps."""
    if spec.platform == "android":
        names = names if names is not None else entry_names(spec.package)
        wanted = "kernel_blob.bin" if spec.mode == "debug" else "/libapp.so"
        found = [name for name in names if name.endswith(wanted)]
    else:
        wanted = "kernel_blob.bin" if spec.mode == "debug" else "App"
        found = [os.path.join(dirpath, wanted)
                 for dirpath, _, files in os.walk(spec.package)
                 if wanted in files]
    if not found:
        raise FloorError("package has no %s payload to replace" % wanted)
    return sorted(found)[0]


def replace_payload(spec, source):
    """Swaps the compiled payload into the package in place."""
    target = payload_target(spec)
    if spec.platform == "android":
        with open(source, "rb") as fh:
            replace_entry(spec.package, target, fh.read())
    else:
        shutil.copyfile(source, target)


def _check_kernel_output(step, err):
    """Raises when aot-kernel exited 0 but left no kernel file."""
    out = step.argv[step.argv.index("--output-dill") + 1]
    if os.path.isfile(out) and os.path.getsize(out) > 0:
        return
    tail = "\n".join(str(err).strip().splitlines()[-STDERR_TAIL:])
    raise FloorError("%s exited 0 but wrote no output %s (empty or missing)"
                     "; stderr:\n%s" % (step.name, out, tail or "(none)"))


def _run_exec(step, runner, steps):
    code, cpu, err = runner(step.argv)
    steps[step.name] = cpu if step.timed else None
    if code != 0:
        raise FloorError("%s failed (exit %s): %s"
                         % (step.name, code, str(err).strip()[-200:]))
    if step.name == "aot-kernel":
        _check_kernel_output(step, err)
    return cpu if step.timed else 0.0


def _step(spec, step, ctx):
    """Runs one step; ctx is (runner, server_factory, swap, state)."""
    runner, server_factory, swap, state = ctx
    if step.kind == "exec":
        return _run_exec(step, runner, state["steps"])
    if step.detail[0] == "compile":
        swap.to_old()
        state["server"] = server_factory(step.argv)
        state["server"].compile(step.detail[1])
        swap.to_new()
        return 0.0
    if step.detail[0] == "recompile":
        state["server"].recompile(step.detail[1], swap.invalidated(spec.roots))
        cpu = state["server"].quit()
    else:
        start = time.process_time()
        replace_payload(spec, step.detail[0])
        cpu = time.process_time() - start
    state["steps"][step.name] = cpu
    return cpu


def run_chain_steps(spec, chain, runner, server_factory, swap):
    """Runs the steps in order; returns (timed cpu_s, per-step cpu).

    A resident compiler left running by a failure is killed, and the
    edited sources are always put back.
    """
    state = {"steps": {}, "server": None}
    total = 0.0
    try:
        for step in chain:
            total += _step(spec, step, (runner, server_factory, swap,
                                        state))
    finally:
        swap.to_new()
        server = state["server"]
        if server is not None and server.proc.poll() is None:
            server.proc.kill()
            server.proc.wait()
    return total, state["steps"]


def run_floor(spec, roots, swap, runner=real_runner,
              server_factory=FrontendServer):
    """Builds, runs and checks one floor chain; never raises.

    Any failure (a missing tool, a failed step, a package that fails its
    structural check) yields identical False, a reason and no cpu_s.
    """
    start = time.monotonic()
    steps = {}
    try:
        tools = resolve_tools(spec, roots)
        chain = build_chain(spec, tools)
        cpu, steps = run_chain_steps(spec, chain, runner, server_factory,
                                     swap)
        ok, reason = check_package(
            spec, tools, lambda argv: runner(argv)[::2])
    except (FloorError, OSError, KeyError, ValueError) as exc:
        return FloorResult(None, None, False, "floor: %s" % exc, steps)
    if not ok:
        return FloorResult(None, None, False, reason, steps)
    return FloorResult(cpu, time.monotonic() - start, True, "ok", steps)
