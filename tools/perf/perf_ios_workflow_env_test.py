#!/usr/bin/env python3
"""Checks that perf-ios.yaml passes workflow inputs via env variables.

GitHub Actions substitutes workflow_dispatch `${{ inputs.<name> }}` expressions
before shell parsing. Passing inputs through step `env:` entries and referencing
them as quoted shell variables (`"$NAME"`) prevents code injection in runner jobs
that hold repository tokens.
"""

import os
import re
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from perf_linux_workflow_test import (
    block_items, child, mapping_entries, parse_fields, text_under, top_level)

_INPUT_EXPR_PATTERN = re.compile(
    r"(?:\$\{\{\s*(?:github\.event\.)?inputs\.|\bgithub\.event\.inputs\.)"
    r"([A-Za-z0-9_]+)"
)

_ENV_INPUT_BINDING = re.compile(
    r"^\$\{\{\s*(?:github\.event\.)?inputs\.([A-Za-z0-9_]+)"
    r"(?:\s*\|\|.*)?\s*\}\}$"
)

_EXPECTED_STEP_INPUTS = {
    "Validate bazel_flags": {"bazel_flags"},
    "Validate A/B inputs": {"ab", "bazel_flags", "lockfile", "mode"},
    "Generate pristine monorepos": {
        "ab", "bazel_flags", "lockfile", "mode", "seed", "target_loc"},
    "Build, edit, replay": {"repeats"},
    "Summarize repeats": {
        "base_ref", "bazel_flags", "head_ref", "repeats", "seed", "target_loc"},
    "Measure speed-of-light (head only)": {"ab", "repeats"},
    "Summarize speed-of-light": {
        "ab", "bazel_flags", "lockfile", "repeats", "seed", "target_loc"},
}


def workflow_path():
    """The perf-ios workflow beside this checkout's tools/perf."""
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(here, "..", "..", ".github", "workflows",
                        "perf-ios.yaml")


def load_steps():
    """Return all steps in the bench job as list of dicts."""
    path = workflow_path()
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    jobs = [e for e in top_level(lines) if e[2] == "jobs"][0]
    bench = child(lines, jobs[0], jobs[1], "bench")
    steps_entry = child(lines, bench[0], bench[1], "steps")
    blocks = block_items(lines, steps_entry[0], steps_entry[1])
    parsed_steps = []
    for idx, block in enumerate(blocks):
        entries = mapping_entries(block)
        name_entry = next((e for e in entries if e[2] == "name"), None)
        step_name = name_entry[3].strip() if name_entry else "step-%d" % (idx + 1)
        run_entry = next((e for e in entries if e[2] == "run"), None)
        run_text = None
        if run_entry is not None:
            val = run_entry[3].strip()
            if val in ("|", ">", "|-", ">-"):
                run_text = text_under(block, run_entry[0], run_entry[1])
            else:
                run_text = val
        env_entry = next((e for e in entries if e[2] == "env"), None)
        env_dict = {}
        if env_entry is not None:
            env_dict = parse_fields(block, env_entry[0], env_entry[1])
        parsed_steps.append({
            "name": step_name,
            "run": run_text,
            "env": env_dict,
        })
    return parsed_steps


class PerfIosWorkflowEnvTest(unittest.TestCase):
    """Workflow inputs must pass to scripts through step env mappings."""

    def test_no_run_block_contains_inputs_expressions(self):
        steps = load_steps()
        violations = []
        for step in steps:
            run_text = step["run"]
            if not run_text:
                continue
            matches = sorted(set(_INPUT_EXPR_PATTERN.findall(run_text)))
            for match in matches:
                violations.append(
                    "Step %r contains input %r in run block"
                    % (step["name"], match))
        self.assertEqual(violations, [], "\n".join(violations))

    def test_script_inputs_bound_in_env_and_used_as_variable(self):
        steps = load_steps()
        violations = []
        for step in steps:
            run_text = step["run"]
            if not run_text:
                continue
            step_name = step["name"]
            env_dict = step["env"]

            bound_inputs = {}
            for var_name, expr in env_dict.items():
                m = _ENV_INPUT_BINDING.match(expr.strip())
                if m:
                    bound_inputs[m.group(1)] = var_name

            expected = _EXPECTED_STEP_INPUTS.get(step_name, set())
            missing = expected - set(bound_inputs.keys())
            if missing:
                violations.append(
                    "Step %r missing env binding for inputs: %s"
                    % (step_name, sorted(missing)))

            for inp in expected:
                if inp in bound_inputs:
                    var = bound_inputs[inp]
                    var_pattern = re.compile(
                        r"\$(?:" + var + r"\b|\{" + var + r"\})|"
                        r"os\.environ(?:\.get)?\([\'\"]" + var)
                    if not var_pattern.search(run_text):
                        violations.append(
                            "Step %r does not reference variable $%s"
                            % (step_name, var))

                expr_pattern = re.compile(
                    r"(?:\$\{\{\s*(?:github\.event\.)?inputs\." + inp + r"\b|"
                    r"\bgithub\.event\.inputs\." + inp + r"\b)")
                if expr_pattern.search(run_text):
                    violations.append(
                        "Step %r refers to expression for input %r"
                        % (step_name, inp))

            unbound_matches = _INPUT_EXPR_PATTERN.findall(run_text)
            for raw_inp in set(unbound_matches):
                if raw_inp not in bound_inputs:
                    violations.append(
                        "Step %r uses input %r in run text without env binding"
                        % (step_name, raw_inp))

        self.assertEqual(violations, [], "\n".join(violations))


    def test_deadline_is_computed_in_the_first_step_without_inputs(self):
        first = load_steps()[0]
        self.assertEqual(first["name"], "Record bench deadline")
        self.assertIn("BENCH_DEADLINE=", first["run"])
        self.assertNotIn("inputs.", first["run"])


if __name__ == "__main__":
    unittest.main()
