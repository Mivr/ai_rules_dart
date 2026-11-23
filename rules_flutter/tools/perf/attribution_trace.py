#!/usr/bin/env python3
"""Bazel CPU seconds per activity from a JSON trace profile.

Complete events (``ph`` ``"X"``, ``dur`` in microseconds) are classified
by category into the attribution parts that the profile shows directly:
repository fetch and extract, module resolution, loading and analysis,
sandbox setup and teardown. Each wall-clock instant goes once to the most
specific part active on any thread (sandbox, then fetch, then module
resolution, then loading and analysis), so nested and parallel events
never count twice. The part's seconds are the "CPU usage (Bazel)" counter
(cores) integrated over its instants: CPU of the bazel process, the unit
of the flow total.
"""

from traceprofile import counter_samples
from traceprofile import read_trace_events



class MissingData(Exception):
    """An attribution input lacks the data the split needs."""


# Most specific first; an instant covered by several goes to the first.
TRACE_PARTS = ("sandbox", "fetch_extract", "module_resolution",
               "loading_analysis")

_CATEGORY_WORDS = (
    ("sandbox", ("sandbox",)),
    ("fetch_extract", ("fetch", "repository", "vendor")),
    ("module_resolution", ("module", "bzlmod")),
    ("loading_analysis", ("package creation", "analysis", "loading",
                          "configured target", "starlark", "skyframe",
                          "skyfunction")),
)


def classify_event(event):
    """Attribution part of a complete event, or None."""
    if event.get("ph") != "X":
        return None
    category = event.get("cat")
    if not isinstance(category, str):
        return None
    text = category.lower()
    for part, words in _CATEGORY_WORDS:
        if any(word in text for word in words):
            return part
    return None


def _interval(event):
    """(tid, start, end) in microseconds, or None for unusable events."""
    ts, dur = event.get("ts"), event.get("dur")
    for value in (ts, dur):
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None
    if dur <= 0:
        return None
    return (event.get("tid"), float(ts), float(ts) + float(dur))


def _segments(spans):
    """Disjoint [(start, end, part)] covering the union of all spans.

    Every instant goes to the most specific part active on any thread,
    so time two categories (or two threads) claim is assigned once.
    """
    points = []
    for start, end, part in spans:
        points.append((start, 1, part))
        points.append((end, -1, part))
    points.sort()
    active = dict.fromkeys(TRACE_PARTS, 0)
    segments = []
    previous = None
    for ts, delta, part in points:
        if previous is not None and ts > previous:
            for name in TRACE_PARTS:
                if active[name] > 0:
                    segments.append((previous, ts, name))
                    break
        active[part] += delta
        previous = ts
    return segments


def _cpu_by_part(segments, samples):
    """{part: CPU seconds}: the counter's cores integrated over segments."""
    totals = dict.fromkeys(TRACE_PARTS, 0.0)
    first = 0
    for (start, cpu), (end, _) in zip(samples, samples[1:]):
        while first < len(segments) and segments[first][1] <= start:
            first += 1
        index = first
        while index < len(segments) and segments[index][0] < end:
            seg_start, seg_end, part = segments[index]
            overlap = min(end, seg_end) - max(start, seg_start)
            if overlap > 0:
                totals[part] += cpu * overlap / 1e6
            index += 1
    return totals


def trace_part_seconds(path):
    """{part: Bazel CPU seconds} of a trace profile.

    Raises MissingData when the profile lacks the CPU counter or any
    classifiable event; OSError/ValueError as the reader does.
    """
    events = read_trace_events(path)
    spans = []
    for event in events:
        part = classify_event(event)
        span = _interval(event) if part else None
        if span is not None:
            spans.append((span[1], span[2], part))
    if not spans:
        raise MissingData("trace has no fetch, module, loading or "
                          "analysis events: %s" % path)
    samples = counter_samples(events)
    if len(samples) < 2:
        raise MissingData("trace has no 'CPU usage (Bazel)' counter "
                          "samples: %s" % path)
    return _cpu_by_part(_segments(spans), samples)
