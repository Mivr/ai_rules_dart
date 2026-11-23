#!/usr/bin/env python3
"""Bazel JSON trace-profile parsing for the iOS SOL bench: JVM CPU by phase.

Reads the ``--profile`` output of a ``bazel --batch build`` (Chrome trace
format, ``{"traceEvents": [...]}``) and reports Bazel's own CPU seconds:

- The "CPU usage (Bazel)" counter (``ph`` ``"C"``, ``args.cpu`` in cores,
  sampled about once a second) is integrated over time: each sample
  contributes ``cpu * (next_ts - ts) / 1e6`` seconds. The last sample
  contributes nothing (no interval follows it).
- ``phases`` splits that CPU at the build phase marker events present in
  the profile (Bazel 9.3 emits "Initialize command", "Evaluate target
  patterns", "Load and analyze dependencies", "Complete build", ... with
  category "build phase marker"): each counter interval is attributed to
  the latest marker at or before the interval's start. Intervals before
  the first marker go to the first marker's phase.

The counter starts after "Launch Blaze" (JVM start), so launch CPU is not
in ``jvm``; it lands in the flow's residual (see docs/perf-ios-bench.md).
"""

import gzip
import json

CPU_COUNTER_NAME = "CPU usage (Bazel)"

# Fallback phase names (Bazel 9.3) for profiles whose markers carry no
# category: the primary rule is the "build phase marker" category below.
KNOWN_PHASES = frozenset([
    "Launch Blaze",
    "Initialize command",
    "Evaluate target patterns",
    "Load and analyze dependencies",
    "Prepare for build",
    "Complete build",
])

MARKER_CATEGORY = "build phase marker"

# Event kinds that can mark a phase boundary (complete, begin/end, instant).
MARKER_PHASES = frozenset(["X", "B", "E", "i", "I"])


def read_trace_events(path):
    """Trace-event list of a Bazel JSON profile (gzipped or plain).

    Accepts the ``{"traceEvents": [...]}`` object or a bare [...] list.
    Raises OSError when unreadable, ValueError when not a trace profile.
    """
    with open(path, "rb") as fh:
        raw = fh.read()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise ValueError("trace profile %s is not JSON (%s)" % (path, exc))
    if isinstance(data, dict):
        events = data.get("traceEvents")
    elif isinstance(data, list):
        events = data
    else:
        events = None
    if not isinstance(events, list):
        raise ValueError("trace profile %s holds no traceEvents" % path)
    return [e for e in events if isinstance(e, dict)]


def is_cpu_counter(event):
    """Whether the event is Bazel's own-CPU counter sample."""
    return (event.get("ph") == "C"
            and event.get("name") == CPU_COUNTER_NAME)


def cpu_of(event):
    """Cores of a counter sample, or None when unreported."""
    args = event.get("args")
    if not isinstance(args, dict):
        return None
    value = args.get("cpu")
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def is_phase_marker(event):
    """Whether the event opens a Bazel build phase.

    Primary rule: the "build phase marker" category. Fallback: a known
    Bazel 9.3 phase name on a boundary-like event kind. The CPU counter
    itself never marks a phase.
    """
    name = event.get("name")
    if not isinstance(name, str) or not name:
        return False
    if is_cpu_counter(event):
        return False
    category = event.get("cat") or ""
    if isinstance(category, str) and MARKER_CATEGORY in category.lower():
        return True
    return name in KNOWN_PHASES and event.get("ph") in MARKER_PHASES


def counter_samples(events):
    """Sorted [(ts, cpu)] of the profile's counter samples."""
    samples = []
    for event in events:
        if not is_cpu_counter(event):
            continue
        cpu = cpu_of(event)
        ts = event.get("ts")
        if cpu is None or isinstance(ts, bool) or not isinstance(
                ts, (int, float)):
            continue
        samples.append((float(ts), cpu))
    samples.sort()
    return samples


def marker_boundaries(events):
    """Sorted [(ts, name)] of the profile's phase markers, names unique."""
    markers = []
    for event in events:
        if not is_phase_marker(event):
            continue
        ts = event.get("ts")
        if isinstance(ts, bool) or not isinstance(ts, (int, float)):
            continue
        markers.append((float(ts), event["name"]))
    markers.sort()
    seen = []
    for ts, name in markers:
        if not seen or seen[-1][1] != name or ts != seen[-1][0]:
            seen.append((ts, name))
    return seen


def integrate_cpu(samples):
    """CPU seconds of sorted (ts, cpu) samples (microsecond ts)."""
    total = 0.0
    for (start, cpu), (end, _) in zip(samples, samples[1:]):
        if end > start:
            total += cpu * (end - start) / 1e6
    return total


def attribute_phases(samples, markers):
    """{phase name: CPU seconds}, splitting samples at markers."""
    phases = {}
    if not markers:
        return phases
    for name in [name for _, name in markers]:
        phases.setdefault(name, 0.0)
    for (start, cpu), (end, _) in zip(samples, samples[1:]):
        if end <= start:
            continue
        phase = markers[0][1]
        for ts, name in markers:
            if ts <= start:
                phase = name
            else:
                break
        phases[phase] += cpu * (end - start) / 1e6
    return phases


def parse_jvm_profile(path):
    """{"total": cpu seconds, "phases": {name: cpu seconds}} of a profile.

    total is None when the profile carries no usable counter samples;
    phases is empty when it carries no phase markers. Raises OSError or
    ValueError (callers record those, never swallow them).
    """
    events = read_trace_events(path)
    samples = counter_samples(events)
    if not samples:
        return {"total": None, "phases": {}}
    markers = marker_boundaries(events)
    return {"total": integrate_cpu(samples),
            "phases": attribute_phases(samples, markers)}
