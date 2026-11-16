#!/usr/bin/env python3
"""Text checks for the scale-bench workflows.

`perf-scale-linux.yaml` (Android flows) runs on a schedule and by hand;
`perf-scale-ios.yaml` (iOS flows) runs by hand only, so it never takes one
of the account's few macOS runners from Full. Neither runs on push or pull
request. They read as text here; nothing runs and nothing touches the
network.
"""

import os
import re
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import workflow_inputs_test
from perf_linux_workflow_test import (
    block_items, child, direct_keys, mapping_entries, parse_fields,
    parse_step, top_level)

WORKFLOWS = ("perf-scale-linux.yaml", "perf-scale-ios.yaml")
SETUP_BAZEL = ("bazel-contrib/setup-bazel@"
               "c5acdfb288317d0b5c0bbd7a396a3dc868bb0f86")
_SHA_PIN = re.compile(r"^[^@]+@[0-9a-f]{40}$")
_FLOWS = {"perf-scale-linux.yaml": "--config android_release "
                                   "--config android_debug",
          "perf-scale-ios.yaml": "--config device_release "
                                 "--config sim_debug"}
_RUNS_ON_MACOS = {"perf-scale-linux.yaml": False,
                  "perf-scale-ios.yaml": True}
_INPUT_INJECTION = re.compile(
    r"(?:\$\{\{\s*(?:github\.event\.)?inputs\.|\bgithub\.event\.inputs\.)"
    r"([A-Za-z0-9_]+)"
)


def workflow_text(name):
    """Contents of one workflow beside this checkout's tools/perf."""
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "..", "..", ".github", "workflows", name)
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _step_env(block):
    """The `env:` mapping of one step block, or {}."""
    entries = mapping_entries(block)
    if not entries:
        return {}
    base = min(entry[1] for entry in entries)
    for index, indent, key, _ in entries:
        if indent == base and key == "env":
            return parse_fields(block, index, indent)
    return {}


def _parse_step(block):
    """One workflow step as a dict, with `with:` and `env:` fields nested."""
    step = parse_step(block)
    env = _step_env(block)
    if env:
        step["env"] = env
    return step


def steps(lines):
    """Every step of the `measure` and `report` jobs as parsed dicts."""
    jobs = [e for e in top_level(lines) if e[2] == "jobs"][0]
    parsed = []
    for name in ("measure", "report"):
        job = child(lines, jobs[0], jobs[1], name)
        entry = child(lines, job[0], job[1], "steps")
        parsed += [_parse_step(block)
                   for block in block_items(lines, entry[0], entry[1])]
    return parsed


class ScaleWorkflowTest(unittest.TestCase):
    def each(self):
        """(name, text, lines) per workflow; callers loop and subTest."""
        return [(name, workflow_text(name), workflow_text(name).splitlines())
                for name in WORKFLOWS]

    def test_triggers_are_dispatch_and_linux_schedule_only(self):
        for name, text, lines in self.each():
            on_entry = [e for e in top_level(lines) if e[2] == "on"][0]
            triggers = [e[2] for e in
                        direct_keys(lines, on_entry[0], on_entry[1])]
            if _RUNS_ON_MACOS[name]:
                # macOS benches run on demand only.
                self.assertEqual(triggers, ["workflow_dispatch"], name)
                self.assertNotIn("cron:", text, name)
            else:
                self.assertEqual(triggers, ["schedule", "workflow_dispatch"],
                                 name)
                self.assertIn("cron:", text, name)
            for banned in ("push", "pull_request", "workflow_run"):
                self.assertNotRegex(text, r"(?m)^\s*%s\s*:" % banned)

    def test_no_continue_on_error(self):
        for _, text, _ in self.each():
            self.assertNotIn("continue-on-error", text)

    def test_actions_are_pinned_like_the_perf_workflows(self):
        for _, _, lines in self.each():
            uses = [s["uses"] for s in steps(lines) if "uses" in s]
            self.assertTrue(uses)
            for ref in uses:
                action = ref.split(" ")[0]
                if action.startswith(SETUP_BAZEL):
                    continue
                self.assertRegex(action, r"^actions/(checkout|upload-artifact"
                                         r"|download-artifact)@v\d+$")

    def test_setup_bazel_uses_the_pinned_sha(self):
        for _, text, _ in self.each():
            self.assertIn("uses: %s # 0.19.0" % SETUP_BAZEL, text)
            for line in text.splitlines():
                if "bazel-contrib/setup-bazel@" in line:
                    self.assertRegex(line.split("uses:")[1].split("#")[0]
                                     .strip(), _SHA_PIN)

    def test_report_uploads_even_after_failure_and_job_fails_on_report(self):
        for _, _, lines in self.each():
            uploads = [s for s in steps(lines)
                       if s.get("uses", "").startswith(
                           "actions/upload-artifact")
                       and s.get("with", {}).get("path") == "scale.json"]
            self.assertEqual(len(uploads), 1)
            self.assertIn("!cancelled()", uploads[0].get("if", ""))
            self.assertNotIn("success()", uploads[0].get("if", ""))
            report = [s for s in steps(lines)
                      if "scale_report.py" in s.get("run", "")]
            self.assertEqual(len(report), 1)
            self.assertIn('--out "$GITHUB_WORKSPACE/scale.json"',
                          report[0]["run"])
            self.assertNotIn("|| true", report[0]["run"])
            self.assertIn("set -euo pipefail", report[0]["run"])

    def test_sizes_cover_both_axes(self):
        for _, text, _ in self.each():
            self.assertIn("--packages", text)
            self.assertIn("--plugins", text)
            sizes = re.findall(
                r"- packages: (\d+)\n\s+plugins: (\d+)", text)
            self.assertEqual(sorted(sizes), [("200", "0"), ("200", "30"),
                                             ("2000", "0")])

    def test_each_measures_its_platform_flows(self):
        for name, text, _ in self.each():
            self.assertIn(_FLOWS[name], text)

    def test_dispatch_inputs_are_quoted(self):
        for name, text, _ in self.each():
            self.assertEqual(
                workflow_inputs_test.find_unquoted_scalars(text), [], name)

    def test_no_workflow_inputs_in_run_blocks(self):
        text = workflow_text("perf-scale-ios.yaml")
        lines = text.splitlines()
        pattern = re.compile(
            r"(?:\$\{\{\s*(?:github\.event\.)?inputs\.|"
            r"(?:\$\{\{|\b)github\.event\.inputs\.)([A-Za-z0-9_]+)"
        )
        violations = []
        for step in steps(lines):
            run_script = step.get("run")
            if not run_script:
                continue
            matches = pattern.findall(run_script)
            for inp in matches:
                step_name = step.get("name", "<unnamed>")
                violations.append(
                    f"step {step_name!r} contains input {inp!r} in run: script"
                )
        self.assertEqual(
            violations,
            [],
            "Workflow inputs must not appear in run: scripts:\n"
            + "\n".join(violations),
        )

    def test_script_inputs_are_bound_in_env_and_referenced_as_variables(self):
        text = workflow_text("perf-scale-ios.yaml")
        lines = text.splitlines()
        parsed_steps = {s.get("name"): s for s in steps(lines) if "name" in s}

        expected = {
            "Generate pristine monorepo": {
                "SEED": ("seed", "${{ inputs.seed || '1' }}"),
            },
            "Measure speed-of-light": {
                "REPEATS": ("repeats", "${{ inputs.repeats || '1' }}"),
            },
            "Summarize speed-of-light": {
                "REPEATS": ("repeats", "${{ inputs.repeats || '1' }}"),
                "SEED": ("seed", "${{ inputs.seed || '1' }}"),
            },
        }

        for step_name, env_bindings in expected.items():
            self.assertIn(step_name, parsed_steps)
            step = parsed_steps[step_name]
            step_env = step.get("env", {})
            script = step.get("run", "")

            for var_name, (input_name, expected_val) in env_bindings.items():
                self.assertIn(
                    var_name,
                    step_env,
                    f"step {step_name!r} must bind input {input_name!r} "
                    f"in env as {var_name}",
                )
                self.assertEqual(
                    step_env.get(var_name),
                    expected_val,
                    f"step {step_name!r} env entry for {var_name}",
                )
                self.assertIn(
                    f'"${var_name}"',
                    script,
                    f"step {step_name!r} script must reference \"${var_name}\"",
                )
                self.assertNotIn(
                    f"inputs.{input_name}",
                    script,
                    f"step {step_name!r} script must not contain "
                    f"expression for {input_name}",
                )

    def test_linux_run_blocks_contain_no_inputs(self):
        lines = workflow_text("perf-scale-linux.yaml").splitlines()
        violations = []
        for step in steps(lines):
            run = step.get("run")
            if not run:
                continue
            step_name = step.get("name", "<unnamed>")
            for match in _INPUT_INJECTION.finditer(run):
                violations.append(
                    f"step '{step_name}' contains input '{match.group(1)}' "
                    "in run script"
                )
        self.assertEqual(violations, [])

    def test_linux_script_inputs_bound_in_step_env(self):
        lines = workflow_text("perf-scale-linux.yaml").splitlines()
        step_inputs = {
            "Generate pristine monorepo": {
                "SEED": ("seed", "${{ inputs.seed || '1' }}", '"$SEED"'),
            },
            "Measure speed-of-light": {
                "REPEATS": (
                    "repeats", "${{ inputs.repeats || '1' }}", '"$REPEATS"'),
            },
            "Summarize speed-of-light": {
                "REPEATS": (
                    "repeats", "${{ inputs.repeats || '1' }}", '"$REPEATS"'),
                "SEED": ("seed", "${{ inputs.seed || '1' }}", '"$SEED"'),
            },
        }
        all_steps = {s.get("name"): s for s in steps(lines) if s.get("name")}
        for step_name, bindings in step_inputs.items():
            self.assertIn(step_name, all_steps)
            step = all_steps[step_name]
            env = step.get("env", {})
            self.assertIsInstance(
                env, dict, f"step {step_name!r} is missing env: mapping"
            )
            run = step.get("run", "")
            for env_var, (input_name, expected_env, quoted_ref) in (
                    bindings.items()):
                with self.subTest(step=step_name, var=env_var):
                    self.assertIn(
                        env_var, env,
                        f"step {step_name!r} env missing {env_var}"
                    )
                    self.assertEqual(
                        env[env_var], expected_env,
                        f"step {step_name!r} env {env_var} must match "
                        f"{expected_env}"
                    )
                    self.assertIn(
                        quoted_ref, run,
                        f"step {step_name!r} script must refer to {quoted_ref}"
                    )
                    self.assertNotIn(
                        f"inputs.{input_name}", run,
                        f"step {step_name!r} script must not contain "
                        f"inputs.{input_name}"
                    )


if __name__ == "__main__":
    unittest.main()
