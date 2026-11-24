#!/usr/bin/env python3
"""CocoaPods real-plugin fetch and iOS build matrix runner (POD-11).

Fetch mode reads ``expected_pods.json`` and queries each pinned plugin spoke in
the ``deps_pods`` hub (``@deps_pods__<plugin>//:all``), checking for exit 0 on
``ok`` and a non-zero exit with a case-sensitive substring match on refusals.
Build mode compiles every fetch-``ok`` spoke for ``ios_arm64`` via
``--platforms=@rules_flutter//flutter/platforms:ios_arm64``; entries present in
``build_expected_pods.json`` gate the step while ungated ``ok`` plugins print
``RECORD`` without failing. Every failing build prints its command and the last
30 output lines. Before either mode runs, ``pubspec.yaml`` is read and every
pinned plugin must have a row in ``expected_pods.json``.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import subprocess
import sys
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
EXPECTED_PODS_FILENAME = "expected_pods.json"
BUILD_EXPECTED_PODS_FILENAME = "build_expected_pods.json"
PUBSPEC_FILENAME = "pubspec.yaml"
IOS_ARM64_PLATFORM = "--platforms=@rules_flutter//flutter/platforms:ios_arm64"
FAILED_BUILD_TAIL_LINES = 30


@dataclass(frozen=True)
class CommandOutput:
    """Exit status and merged stdout/stderr captured from one subprocess call."""

    returncode: int
    output: str


@dataclass(frozen=True)
class PluginCheck:
    """Outcome row for a single plugin in fetch or build mode."""

    plugin: str
    verdict: str
    note: str = ""


CommandRunner = Callable[[list[str]], CommandOutput]


def resolve_workspace_dir() -> Path:
    """Prefer the current directory when it carries expected_pods.json, else SCRIPT_DIR."""
    cwd = Path.cwd()
    if (cwd / EXPECTED_PODS_FILENAME).is_file():
        return cwd
    return SCRIPT_DIR


def invoke_bazel(workspace: Path, subcommand_args: list[str]) -> CommandOutput:
    """Execute ``bazel <subcommand_args>`` without shell expansion in ``workspace``."""
    try:
        proc = subprocess.run(
            ["bazel", "--max_idle_secs=60", *subcommand_args],
            cwd=workspace,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as exc:
        raise SystemExit(f"run_pods_matrix: failed to execute bazel: {exc}") from exc
    combined = (proc.stdout or "") + (proc.stderr or "")
    return CommandOutput(proc.returncode, combined)


def read_expectations(path: Path, allow_empty: bool) -> dict[str, str]:
    """Load and validate a string-valued JSON mapping from ``path``."""
    label = path.name
    try:
        raw_text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise SystemExit(f"run_pods_matrix: unable to read {label} ({path}): {exc}") from exc
    try:
        parsed = json.loads(raw_text)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"run_pods_matrix: invalid JSON in {label} ({path}): {exc}") from exc
    if not isinstance(parsed, dict):
        raise SystemExit(f"run_pods_matrix: {label} ({path}) must contain a JSON object")
    if not allow_empty and not parsed:
        raise SystemExit(f"run_pods_matrix: {label} ({path}) must not be empty")
    validated: dict[str, str] = {}
    for plugin, expectation in parsed.items():
        if not isinstance(plugin, str) or not plugin:
            raise SystemExit(f"run_pods_matrix: {label} ({path}) contains an invalid plugin key")
        if not isinstance(expectation, str) or not expectation:
            raise SystemExit(
                f"run_pods_matrix: {label} ({path}) maps {plugin!r} to an empty or non-string value"
            )
        validated[plugin] = expectation
    return validated


def _strip_yaml_comment(line: str) -> str:
    """Drop a trailing ``#`` comment and surrounding whitespace from one YAML line."""
    return line.split("#", 1)[0].rstrip()


def _dependency_blocks(text: str) -> dict[str, list[str]]:
    """Map each entry under top-level ``dependencies:`` to its nested lines."""
    blocks: dict[str, list[str]] = {}
    in_section = False
    current: list[str] | None = None
    for raw in text.splitlines():
        line = _strip_yaml_comment(raw)
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent == 0:
            in_section = line.strip() == "dependencies:"
            current = None
        elif in_section and indent == 2 and ":" in line:
            name, _, rest = line.strip().partition(":")
            current = blocks.setdefault(name.strip(), [])
            if rest.strip():
                current.append(f"value: {rest.strip()}")
        elif in_section and current is not None:
            current.append(line.strip())
    return blocks


def parse_pubspec_plugins(text: str) -> list[str]:
    """List non-SDK package names declared under ``dependencies:`` in pubspec text."""
    blocks = _dependency_blocks(text)
    return [
        name
        for name, nested in blocks.items()
        if not any(entry.startswith("sdk:") for entry in nested)
    ]


def check_pubspec_coverage(pubspec: Path, expectations: dict[str, str]) -> None:
    """Fail closed unless ``expectations`` has a row for every plugin in ``pubspec``."""
    try:
        text = pubspec.read_text(encoding="utf-8")
    except OSError as exc:
        raise SystemExit(
            f"run_pods_matrix: unable to read {PUBSPEC_FILENAME} ({pubspec}): {exc}"
        ) from exc
    plugins = parse_pubspec_plugins(text)
    if not plugins:
        raise SystemExit(
            f"run_pods_matrix: {PUBSPEC_FILENAME} ({pubspec}) declares no plugin dependencies"
        )
    missing = [plugin for plugin in plugins if plugin not in expectations]
    if missing:
        raise SystemExit(
            f"run_pods_matrix: {EXPECTED_PODS_FILENAME} lacks rows for plugins pinned in "
            f"{PUBSPEC_FILENAME}: {', '.join(missing)}"
        )


def evaluate_expectation(expectation: str, captured: CommandOutput) -> tuple[bool, str]:
    """Check whether ``captured`` satisfies ``expectation`` (``ok`` or refusal substring)."""
    if expectation == "ok":
        if captured.returncode == 0:
            return True, ""
        return False, f"expected exit 0, got {captured.returncode}"
    if not expectation:
        return False, "refusal expectation must be non-empty"
    if captured.returncode == 0:
        return False, f"expected non-zero exit containing {expectation!r}, got exit 0"
    if expectation not in captured.output:
        return False, f"missing expected refusal substring {expectation!r}"
    return True, ""


def execute_fetch_matrix(
    expectations: dict[str, str],
    runner: CommandRunner,
) -> list[PluginCheck]:
    """Query ``@deps_pods__<plugin>//:all`` once per plugin and evaluate expectations."""
    checks: list[PluginCheck] = []
    for plugin, want in expectations.items():
        target = f"@deps_pods__{plugin}//:all"
        captured = runner(["query", target])
        matched, reason = evaluate_expectation(want, captured)
        checks.append(PluginCheck(plugin, "PASS" if matched else "FAIL", reason))
    return checks


def report_failed_build(args: list[str], captured: CommandOutput) -> None:
    """Print the ``bazel`` command line and the output tail of a non-zero build."""
    print("bazel " + " ".join(args))
    tail = captured.output.splitlines()[-FAILED_BUILD_TAIL_LINES:]
    print("\n".join(tail))


def execute_build_matrix(
    fetch_expectations: dict[str, str],
    build_gates: dict[str, str],
    runner: CommandRunner,
) -> list[PluginCheck]:
    """Build each fetch-``ok`` plugin for ``ios_arm64`` and gate entries in ``build_gates``."""
    ok_plugins = [plugin for plugin, want in fetch_expectations.items() if want == "ok"]
    ok_set = set(ok_plugins)
    checks: list[PluginCheck] = []
    for plugin in ok_plugins:
        target = f"@deps_pods__{plugin}//:{plugin}_apple_ios"
        build_args = ["build", IOS_ARM64_PLATFORM, target]
        captured = runner(build_args)
        if captured.returncode != 0:
            report_failed_build(build_args, captured)
        if plugin not in build_gates:
            observed = "ok" if captured.returncode == 0 else "fail"
            checks.append(PluginCheck(plugin, "RECORD", f"build {observed}"))
            continue
        matched, reason = evaluate_expectation(build_gates[plugin], captured)
        checks.append(PluginCheck(plugin, "PASS" if matched else "FAIL", reason))
    for gated_plugin in build_gates:
        if gated_plugin not in ok_set:
            checks.append(
                PluginCheck(
                    gated_plugin,
                    "FAIL",
                    "plugin in build_expected_pods.json is not ok in expected_pods.json",
                )
            )
    return checks


def emit_summary(checks: list[PluginCheck], mode_label: str) -> int:
    """Print per-plugin lines and a mode summary; return 1 when any plugin failed."""
    failures = 0
    for item in checks:
        if item.verdict == "FAIL":
            failures += 1
        suffix = f": {item.note}" if item.note else ""
        print(f"{item.verdict} {item.plugin}{suffix}")
    passed_or_recorded = len(checks) - failures
    print(f"\n{mode_label}: {passed_or_recorded} passed, {failures} failed, {len(checks)} total")
    return 1 if failures else 0


def _check_comparator_unit_cases() -> list[str]:
    """Exercise evaluate_expectation across ok, refusal, exit-code and case checks."""
    table = [
        ("ok with exit 0", "ok", CommandOutput(0, ""), True),
        ("false ok on non-zero exit", "ok", CommandOutput(7, "ERROR: failed"), False),
        (
            "matching refusal substring",
            'depends on pod "SamplePod"',
            CommandOutput(7, 'Error in fail: Flutter plugin "p" depends on pod "SamplePod"'),
            True,
        ),
        (
            "refusal with wrong exit 0",
            'depends on pod "SamplePod"',
            CommandOutput(0, 'depends on pod "SamplePod"'),
            False,
        ),
        (
            "refusal missing substring",
            'depends on pod "SamplePod"',
            CommandOutput(7, 'depends on pod "OtherPod"'),
            False,
        ),
        (
            "case-sensitive refusal mismatch",
            'depends on pod "samplepod"',
            CommandOutput(7, 'depends on pod "SamplePod"'),
            False,
        ),
        ("empty refusal expectation", "", CommandOutput(7, "error"), False),
        ("literal dots are not wildcards", "a...b", CommandOutput(7, "aXXXb"), False),
    ]
    errors: list[str] = []
    for label, want, captured, expected_ok in table:
        actual_ok, detail = evaluate_expectation(want, captured)
        if actual_ok != expected_ok:
            errors.append(f"{label}: expected {expected_ok}, got {actual_ok} ({detail})")
    return errors


def _check_fetch_unit_cases() -> list[str]:
    """Verify execute_fetch_matrix invokes bazel query per plugin and classifies outcomes."""
    recorded_calls: list[list[str]] = []
    responses = {
        "@deps_pods__alpha_plugin//:all": CommandOutput(0, "@deps_pods__alpha_plugin//:lib\n"),
        "@deps_pods__beta_plugin//:all": CommandOutput(1, "Error: unresolved SampleKit"),
        "@deps_pods__gamma_plugin//:all": CommandOutput(1, "Error: unresolved samplekit"),
    }

    def fake_runner(cmd: list[str]) -> CommandOutput:
        recorded_calls.append(cmd)
        return responses[cmd[1]]

    expectations = {
        "alpha_plugin": "ok",
        "beta_plugin": "unresolved SampleKit",
        "gamma_plugin": "unresolved SampleKit",
    }
    checks = execute_fetch_matrix(expectations, fake_runner)
    errors: list[str] = []
    if [c.verdict for c in checks] != ["PASS", "PASS", "FAIL"]:
        errors.append(f"unexpected fetch verdicts: {checks}")
    expected_calls = [
        ["query", "@deps_pods__alpha_plugin//:all"],
        ["query", "@deps_pods__beta_plugin//:all"],
        ["query", "@deps_pods__gamma_plugin//:all"],
    ]
    if recorded_calls != expected_calls:
        errors.append(f"unexpected fetch commands: {recorded_calls}")
    return errors


def _check_build_unit_cases() -> list[str]:
    """Run the build cases with their failing-build dumps silenced."""
    errors, _ = _capture_stdout(_check_build_cases_verbose)
    return errors


def _check_build_cases_verbose() -> list[str]:
    """Verify execute_build_matrix passes ios_arm64, emits RECORD ungated, and gates entries."""
    recorded_calls: list[list[str]] = []

    def fake_ok_runner(cmd: list[str]) -> CommandOutput:
        recorded_calls.append(cmd)
        return CommandOutput(0, "")

    fetch_map = {"alpha_plugin": "ok", "beta_plugin": "unresolved pod"}
    ungated = execute_build_matrix(fetch_map, {}, fake_ok_runner)
    errors: list[str] = []
    if len(ungated) != 1 or ungated[0].verdict != "RECORD":
        errors.append(f"ungated ok plugin must RECORD: {ungated}")
    want_cmd = ["build", IOS_ARM64_PLATFORM, "@deps_pods__alpha_plugin//:alpha_plugin_apple_ios"]
    if recorded_calls != [want_cmd]:
        errors.append(f"build command mismatch: got {recorded_calls}, want {[want_cmd]}")

    gated_pass = execute_build_matrix(fetch_map, {"alpha_plugin": "ok"}, lambda _: CommandOutput(0, ""))
    if [c.verdict for c in gated_pass] != ["PASS"]:
        errors.append(f"gated ok exit 0 should PASS: {gated_pass}")

    gated_fail = execute_build_matrix(fetch_map, {"alpha_plugin": "ok"}, lambda _: CommandOutput(1, "err"))
    if [c.verdict for c in gated_fail] != ["FAIL"]:
        errors.append(f"gated ok exit 1 should FAIL: {gated_fail}")

    refusal_pass = execute_build_matrix(
        fetch_map,
        {"alpha_plugin": "Undefined symbol: _OBJC_CLASS_"},
        lambda _: CommandOutput(1, "ld: Undefined symbol: _OBJC_CLASS_$_Foo"),
    )
    if [c.verdict for c in refusal_pass] != ["PASS"]:
        errors.append(f"gated refusal match should PASS: {refusal_pass}")

    refusal_case = execute_build_matrix(
        fetch_map,
        {"alpha_plugin": "undefined symbol: _objc_class_"},
        lambda _: CommandOutput(1, "ld: Undefined symbol: _OBJC_CLASS_$_Foo"),
    )
    if [c.verdict for c in refusal_case] != ["FAIL"]:
        errors.append(f"gated wrong-case refusal should FAIL: {refusal_case}")

    non_ok_gated = execute_build_matrix(
        fetch_map,
        {"beta_plugin": "ok"},
        lambda _: CommandOutput(0, ""),
    )
    if not any(c.verdict == "FAIL" and c.plugin == "beta_plugin" for c in non_ok_gated):
        errors.append(f"gating a non-ok fetch plugin should FAIL: {non_ok_gated}")
    return errors


def _capture_stdout(action: Callable[[], Any]) -> tuple[Any, str]:
    """Run ``action`` and return its result with everything it printed."""
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        result = action()
    return result, buffer.getvalue()


def _check_summary_unit_cases() -> list[str]:
    """Verify emit_summary exit codes and printed lines for PASS, RECORD and FAIL rows."""
    errors: list[str] = []
    good = [
        PluginCheck("a", "PASS"),
        PluginCheck("b", "RECORD", "build ok"),
        PluginCheck("c", "RECORD", "build fail"),
    ]
    code, out = _capture_stdout(lambda: emit_summary(good, "build"))
    if code != 0:
        errors.append(f"PASS/RECORD rows must exit 0, got {code}")
    for want in ("RECORD c: build fail", "RECORD b: build ok", "build: 3 passed, 0 failed, 3 total"):
        if want not in out:
            errors.append(f"summary output lacks {want!r}: {out!r}")
    bad = [PluginCheck("a", "PASS"), PluginCheck("d", "FAIL", "boom")]
    code, out = _capture_stdout(lambda: emit_summary(bad, "build"))
    if code != 1:
        errors.append(f"a FAIL row must exit 1, got {code}")
    if "FAIL d: boom" not in out or "build: 1 passed, 1 failed, 2 total" not in out:
        errors.append(f"failing summary output unexpected: {out!r}")
    return errors


def _check_failing_build_output_cases() -> list[str]:
    """Verify only non-zero builds print their command and the last 30 output lines."""
    errors: list[str] = []
    fetch_map = {"alpha_plugin": "ok"}
    command = f"bazel build {IOS_ARM64_PLATFORM} @deps_pods__alpha_plugin//:alpha_plugin_apple_ios"
    noisy = "\n".join(f"line {n}" for n in range(1, 41))
    for gates, label in (({}, "ungated"), ({"alpha_plugin": "ok"}, "gated"), ({"alpha_plugin": "line 40"}, "expected")):
        _, out = _capture_stdout(
            lambda g=gates: execute_build_matrix(fetch_map, g, lambda _: CommandOutput(1, noisy))
        )
        if command not in out.splitlines():
            errors.append(f"{label} failing build must print its command: {out!r}")
        lines = out.splitlines()
        tail = [ln for ln in lines if ln.startswith("line ")]
        if tail != [f"line {n}" for n in range(11, 41)]:
            errors.append(f"{label} failing build must print exactly the last 30 lines: {tail}")
    _, quiet = _capture_stdout(
        lambda: execute_build_matrix(fetch_map, {}, lambda _: CommandOutput(0, noisy))
    )
    if quiet:
        errors.append(f"passing build must not print output: {quiet!r}")
    return errors


def _check_pubspec_unit_cases() -> list[str]:
    """Verify pubspec parsing, coverage enforcement and the empty-gate-file rejection."""
    text = (
        "name: demo\ndependencies:\n  flutter:\n    sdk: flutter\n"
        "  # a comment\n  alpha: 1.0.0\n  beta: ^2.0.0  # pinned\n"
        "dev_dependencies:\n  flutter_test:\n    sdk: flutter\n  gamma: 1.0.0\n"
    )
    errors: list[str] = []
    plugins = parse_pubspec_plugins(text)
    if plugins != ["alpha", "beta"]:
        errors.append(f"pubspec plugin parse mismatch: {plugins}")
    with TemporaryDirectory() as tmp:
        pubspec = Path(tmp) / PUBSPEC_FILENAME
        pubspec.write_text(text, encoding="utf-8")
        check_pubspec_coverage(pubspec, {"alpha": "ok", "beta": "ok", "extra": "ok"})
        try:
            check_pubspec_coverage(pubspec, {})
            errors.append("coverage check accepted an empty expectations map")
        except SystemExit as exc:
            if "alpha" not in str(exc) or "beta" not in str(exc) or PUBSPEC_FILENAME not in str(exc):
                errors.append(f"coverage error must name missing plugins: {exc}")
        try:
            check_pubspec_coverage(Path(tmp) / "absent.yaml", {"alpha": "ok"})
            errors.append("coverage check accepted an unreadable pubspec")
        except SystemExit as exc:
            if PUBSPEC_FILENAME not in str(exc):
                errors.append(f"unreadable pubspec error must name {PUBSPEC_FILENAME}: {exc}")
        pubspec.write_text("name: demo\ndependencies:\n  flutter:\n    sdk: flutter\n", encoding="utf-8")
        try:
            check_pubspec_coverage(pubspec, {"alpha": "ok"})
            errors.append("coverage check accepted a pubspec without plugins")
        except SystemExit:
            pass
        empty = Path(tmp) / BUILD_EXPECTED_PODS_FILENAME
        empty.write_text("{}", encoding="utf-8")
        try:
            read_expectations(empty, allow_empty=False)
            errors.append("empty gate file accepted with allow_empty=False")
        except SystemExit as exc:
            if BUILD_EXPECTED_PODS_FILENAME not in str(exc):
                errors.append(f"empty gate error must name the file: {exc}")
    return errors


def _check_compile_error_gating_cases() -> list[str]:
    """Verify the ``file not found`` gate accepts Clang output and rejects Bazel refusals."""
    errors: list[str] = []
    clang = "fatal error: 'PermissionHandlerEnums.h' file not found"
    table = [
        ("clang diagnostic", CommandOutput(1, clang), "PASS"),
        ("clang diagnostic with exit 0", CommandOutput(0, clang), "FAIL"),
        (
            "incompatible platform",
            CommandOutput(1, "ERROR: //x:y is not compatible with target platform"),
            "FAIL",
        ),
        ("missing target", CommandOutput(1, "ERROR: no such target '//x:y'"), "FAIL"),
    ]
    for label, captured, verdict in table:
        with contextlib.redirect_stdout(io.StringIO()):
            checks = execute_build_matrix({"p": "ok"}, {"p": "file not found"}, lambda _, c=captured: c)
        if [c.verdict for c in checks] != [verdict]:
            errors.append(f"{label}: expected {verdict}, got {checks}")
    return errors


def run_self_test() -> int:
    """Run all offline unit checks without touching Bazel, files or network."""
    errors = (
        _check_comparator_unit_cases()
        + _check_fetch_unit_cases()
        + _check_build_unit_cases()
        + _check_summary_unit_cases()
        + _check_failing_build_output_cases()
        + _check_pubspec_unit_cases()
        + _check_compile_error_gating_cases()
    )
    if errors:
        for err in errors:
            print(f"SELF-TEST FAIL: {err}")
        return 1
    print("SELF-TEST OK")
    return 0


def build_arg_parser() -> argparse.ArgumentParser:
    """Construct the CLI argument parser for fetch, build and self-test modes."""
    parser = argparse.ArgumentParser(description="Run the CocoaPods real-plugin iOS matrix.")
    parser.add_argument("--mode", choices=("fetch", "build"), default="fetch")
    parser.add_argument("--self-test", action="store_true", dest="self_test")
    return parser


def main(argv: list[str] | None = None) -> int:
    """Entry point for CLI execution."""
    parsed = build_arg_parser().parse_args(sys.argv[1:] if argv is None else argv)
    if parsed.self_test:
        return run_self_test()
    workspace = resolve_workspace_dir()
    fetch_expectations = read_expectations(workspace / EXPECTED_PODS_FILENAME, allow_empty=False)
    check_pubspec_coverage(workspace / PUBSPEC_FILENAME, fetch_expectations)
    runner: CommandRunner = lambda cmd_args: invoke_bazel(workspace, cmd_args)
    if parsed.mode == "fetch":
        return emit_summary(execute_fetch_matrix(fetch_expectations, runner), "fetch")
    build_gates = read_expectations(workspace / BUILD_EXPECTED_PODS_FILENAME, allow_empty=False)
    return emit_summary(execute_build_matrix(fetch_expectations, build_gates, runner), "build")


if __name__ == "__main__":
    sys.exit(main())
