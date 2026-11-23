#!/usr/bin/env python3
"""The real-plugin iOS fetch and build matrix (POD-2).

Fetch mode reads ``expected.json`` and runs one ``bazel query`` per pinned
plugin, comparing the result with the recorded expectation. Build mode reads
the plugins ``expected.json`` records as ``ok`` and builds each spoke's device
library for the iOS device platform; ``build_expected.json`` names the builds
that are gated today, each by ``ok`` or a compile-error substring.

The runner holds no plugin names: both modes are driven entirely by the JSON
data files beside it, so a later item changes a behaviour by editing one entry
and not this file.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parent
EXPECTED_PATH = ROOT / "expected.json"
BUILD_EXPECTED_PATH = ROOT / "build_expected.json"
BAZEL = ("bazel", "--max_idle_secs=60")
FETCH_TARGET = "@deps__{plugin}//:all"
BUILD_TARGET = "@deps__{plugin}//:{plugin}_apple_ios"
IOS_ARM64_PLATFORM = "--platforms=@rules_flutter//flutter/platforms:ios_arm64"
IOS_ARM64_CPU = "--ios_multi_cpus=arm64"
IOS_BUILD_FLAGS = (IOS_ARM64_PLATFORM, IOS_ARM64_CPU)
OUTPUT_TAIL_LINES = 30


@dataclass(frozen=True)
class Outcome:
    """One command's exit code and combined standard output and error."""

    returncode: int
    output: str


@dataclass(frozen=True)
class Result:
    """One PASS, FAIL or RECORD line in a mode's report."""

    name: str
    status: str
    detail: str = ""


Runner = Callable[[list[str]], Outcome]


def run_bazel(args: list[str]) -> Outcome:
    """Run one Bazel command in this workspace and return its combined output."""
    try:
        completed = subprocess.run(
            [*BAZEL, *args],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError as error:
        raise SystemExit(f"run_matrix: cannot run bazel: {error}") from error
    return Outcome(completed.returncode, (completed.stdout or "") + (completed.stderr or ""))


def load_json(path: Path, what: str) -> dict[str, str]:
    """Read a JSON object of string values, naming the file on every failure."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise SystemExit(f"run_matrix: cannot read {what} {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise SystemExit(f"run_matrix: {what} {path} is not valid JSON: {error}") from error
    if not isinstance(data, dict) or not data:
        raise SystemExit(f"run_matrix: {what} {path} must be a non-empty JSON object")
    for key, value in data.items():
        if not isinstance(key, str) or not key:
            raise SystemExit(f"run_matrix: {what} {path} has an empty or non-string key")
        if not isinstance(value, str) or not value:
            raise SystemExit(f"run_matrix: {what} {path} entry {key!r} must be a non-empty string")
    return data


def compare(expected: str, outcome: Outcome) -> tuple[bool, str]:
    """Whether one outcome satisfies one expectation, with a reason when it does not.

    ``ok`` requires exit 0. Anything else is a refusal substring: the command
    must exit non-zero and print the substring in its combined output.
    """
    if expected == "ok":
        if outcome.returncode == 0:
            return True, ""
        return False, f"expected exit 0, got {outcome.returncode}"
    if not expected:
        return False, "the expected refusal substring is empty"
    if outcome.returncode == 0:
        return False, f"expected a refusal containing {expected!r}, but the command exited 0"
    if expected not in outcome.output:
        return False, f"refusal substring {expected!r} is missing from the output"
    return True, ""


def build_command(plugin: str) -> list[str]:
    """The Bazel arguments that build one plugin's generated iOS device library."""
    return ["build", *IOS_BUILD_FLAGS, BUILD_TARGET.format(plugin=plugin)]


def print_build_failure(args: list[str], outcome: Outcome) -> None:
    """Print a failing build's command and the tail of its combined output."""
    print(f"build command: {' '.join([*BAZEL, *args])}")
    lines = outcome.output.splitlines()
    print(f"build output (last {OUTPUT_TAIL_LINES} lines):")
    if not lines:
        print("<no output>")
        return
    for line in lines[-OUTPUT_TAIL_LINES:]:
        print(line)


def run_fetch(expected: dict[str, str], runner: Runner) -> list[Result]:
    """Query every pinned plugin once and compare each result with its expectation."""
    results = []
    for plugin, want in expected.items():
        outcome = runner(["query", FETCH_TARGET.format(plugin=plugin)])
        ok, detail = compare(want, outcome)
        results.append(Result(plugin, "PASS" if ok else "FAIL", detail))
    return results


def run_build(expected: dict[str, str], gated: dict[str, str], runner: Runner) -> list[Result]:
    """Build every expected-ok plugin for iOS, gating only the entries build_expected.json names."""
    plugins = [name for name, value in expected.items() if value == "ok"]
    results = []
    for plugin in plugins:
        args = build_command(plugin)
        outcome = runner(args)
        if outcome.returncode != 0:
            print_build_failure(args, outcome)
        if plugin not in gated:
            actual = "ok" if outcome.returncode == 0 else "fail"
            results.append(Result(plugin, "RECORD", f"build {actual}"))
            continue
        ok, detail = compare(gated[plugin], outcome)
        results.append(Result(plugin, "PASS" if ok else "FAIL", detail))
    for plugin in gated:
        if plugin not in plugins:
            results.append(Result(plugin, "FAIL", "gated build plugin is not an expected-ok plugin"))
    return results


def report(results: list[Result], mode: str) -> int:
    """Print one line per result, then the summary; return 1 when one failed."""
    for result in results:
        line = f"{result.status} {result.name}"
        if result.detail:
            line += f": {result.detail}"
        print(line)
    failed = sum(1 for result in results if result.status == "FAIL")
    print(f"\n{mode}: {len(results) - failed} passed, {failed} failed, {len(results)} total")
    return 1 if failed else 0


def _run_build_captured(gated: dict[str, str], outcome: Outcome) -> tuple[list[Result], str]:
    """Run one fake build with stdout captured, returning its results and printed text."""
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        results = run_build({"alpha_plugin": "ok"}, gated, lambda _args: outcome)
    return results, buffer.getvalue()


def _self_test_build_cases() -> tuple[list[str], int]:
    """Exercise build flags, substring gating and failure output with fake outcomes."""
    errors: list[str] = []
    command = build_command("alpha_plugin")
    if IOS_ARM64_PLATFORM not in command:
        errors.append(f"build command lacks {IOS_ARM64_PLATFORM!r}: {command}")
    if IOS_ARM64_CPU not in command:
        errors.append(f"build command lacks {IOS_ARM64_CPU!r}: {command}")

    compile_error = "ios/Classes/Foo.swift:12:9: error: cannot find 'FLTMaxSize' in scope"
    table = [
        ("compile error with the gated substring", "error:", Outcome(1, compile_error), "PASS"),
        ("compile error that exited 0", "error:", Outcome(0, compile_error), "FAIL"),
        (
            "incompatible platform refusal",
            "error:",
            Outcome(1, "ERROR: target is not compatible with target platform @platforms//os:ios"),
            "FAIL",
        ),
        (
            "missing target refusal",
            "error:",
            Outcome(1, "ERROR: no such target '@deps__alpha_plugin//:alpha_plugin_apple_ios'"),
            "FAIL",
        ),
        ("empty gated substring", "", Outcome(1, compile_error), "FAIL"),
        ("gated ok with exit 0", "ok", Outcome(0, ""), "PASS"),
        ("gated ok with a non-zero exit", "ok", Outcome(1, "ERROR: analysis failed"), "FAIL"),
    ]
    for name, want, outcome, expected_status in table:
        results, _ = _run_build_captured({"alpha_plugin": want}, outcome)
        if results[0].status != expected_status:
            errors.append(f"{name}: expected {expected_status}, got {results[0].status} ({results[0].detail})")

    recorded, _ = _run_build_captured({}, Outcome(1, "compile failed"))
    if recorded[0].status != "RECORD" or recorded[0].detail != "build fail":
        errors.append(f"ungated failing build must RECORD build fail: {recorded}")

    tail_source = "\n".join(f"line {number}" for number in range(1, OUTPUT_TAIL_LINES + 6))
    tail_source += f"\n{compile_error}"
    _, printed = _run_build_captured({"alpha_plugin": "error:"}, Outcome(1, tail_source))
    if "build command: " not in printed or "@deps__alpha_plugin//:alpha_plugin_apple_ios" not in printed:
        errors.append(f"failing build did not print its command: {printed!r}")
    if "line 1\n" in printed or compile_error not in printed:
        errors.append(f"failing build did not print the output tail: {printed!r}")
    return errors, len(table) + 1


def self_test() -> int:
    """Exercise fetch and build comparisons with fake outcomes; no Bazel, network or workspace needed."""
    cases = [
        ("matching ok", "ok", Outcome(0, ""), True),
        ("false ok", "ok", Outcome(1, "fetch refused"), False),
        ("passing refusal", "variables are not supported", Outcome(1, "Error: variables are not supported"), True),
        ("wrong exit for a refusal", "variables are not supported", Outcome(0, "variables are not supported"), False),
        ("missing refusal substring", "variables are not supported", Outcome(1, "another refusal"), False),
        ("empty refusal substring", "", Outcome(1, ""), False),
    ]
    failures = []
    for name, expected, outcome, want in cases:
        got, detail = compare(expected, outcome)
        if got != want:
            failures.append(f"{name}: expected {want}, got {got} ({detail})")
    build_failures, build_case_count = _self_test_build_cases()
    failures.extend(build_failures)
    if failures:
        for failure in failures:
            print(f"SELF-TEST FAIL {failure}")
        return 1
    print(f"SELF-TEST OK ({len(cases) + build_case_count} cases)")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    """Parse the mode and the offline self-test flag."""
    parser = argparse.ArgumentParser(description="Run the iOS plugin matrix")
    parser.add_argument("--mode", choices=("fetch", "build"), default="fetch")
    parser.add_argument("--self-test", action="store_true", dest="self_test")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    """Run the selected mode and return its exit status."""
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.self_test:
        return self_test()
    expected = load_json(EXPECTED_PATH, "expected.json")
    if args.mode == "fetch":
        return report(run_fetch(expected, run_bazel), "fetch")
    gated = load_json(BUILD_EXPECTED_PATH, "build_expected.json")
    return report(run_build(expected, gated, run_bazel), "build")


if __name__ == "__main__":
    sys.exit(main())
