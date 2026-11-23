#!/usr/bin/env python3
"""Text checks for the manual Android/Web perf workflow.

The workflow runs on GitHub's free Linux runners, so the things that keep
it cheap and dispatchable are part of its contract: a manual-only trigger,
the exact dispatch inputs, no caches, a small artifact that is still
uploaded after a failed configuration, and a timeout under five hours.
These checks read `.github/workflows/perf-linux.yaml` as text; they never
run the workflow and never touch the network.
"""

import os
import re
import unittest

_KEY = re.compile(
    r"^(?:\"([^\"]+)\"|'([^']+)'|([A-Za-z0-9_.-]+)):(.*)$")
_ITEM = re.compile(r"^(\s*)-(?:\s+(.*))?$")

_STRING_INPUTS = ("head_ref", "target_loc", "seed", "repeats", "bazel_flags")
_EXPECTED_INPUTS = {
    "head_ref": {"type": "string", "required": "true",
                 "default": None, "options": []},
    "platform": {"type": "choice", "required": None,
                 "default": None, "options": ["android", "web"]},
    "target_loc": {"type": "string", "required": None,
                   "default": '"500000"', "options": []},
    "seed": {"type": "string", "required": None,
             "default": '"1"', "options": []},
    "repeats": {"type": "string", "required": None,
                "default": '"3"', "options": []},
    "lockfile": {"type": "choice", "required": None,
                 "default": "committed",
                 "options": ["none", "committed"]},
    "bazel_flags": {"type": "string", "required": None,
                    "default": '""', "options": []},
    "ab": {"type": "choice", "required": None,
           "default": '"off"', "options": ["\"off\"", "flags"]},
}
_CONFIGS = {
    "android": ("android_release", "android_debug", "android_payload"),
    "web": ("web_release", "web_debug"),
}
_STEP_SCRIPT_INPUTS = {
    "Generate pristine monorepo": ("target_loc", "seed"),
    "Generate committed lockfile": ("platform",),
    "Measure speed-of-light": ("repeats", "platform"),
    "Summarize speed-of-light": (
        "repeats", "target_loc", "seed", "lockfile", "platform"),
    "Validate bazel_flags": ("bazel_flags",),
    "Validate A/B inputs": ("ab", "bazel_flags", "lockfile"),
    "Apply bazel_flags to the measured workspace": ("bazel_flags",),
    "Prepare A/B workspaces": ("bazel_flags", "lockfile"),
    "Measure A/B": ("platform", "repeats"),
    "Summarize A/B": ("ab", "bazel_flags", "lockfile", "platform",
                      "repeats", "seed", "target_loc"),
}


def workflow_path():
    """The perf-linux workflow beside this checkout's tools/perf."""
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(here, "..", "..", ".github", "workflows",
                        "perf-linux.yaml")


def key_line(line):
    """(indent, key, rest) for one mapping line, or None."""
    text = line.strip()
    if not text or text.startswith("#"):
        return None
    match = _KEY.match(text)
    if match is None:
        return None
    key = next(group for group in match.groups()[:3] if group is not None)
    return len(line) - len(line.lstrip(" ")), key, match.group(4)


def keys_under(lines, start, parent_indent):
    """(index, indent, key, rest) for mapping lines below a parent key."""
    found = []
    for index in range(start + 1, len(lines)):
        line = lines[index]
        parsed = key_line(line)
        if parsed is not None:
            if parsed[0] <= parent_indent:
                break
            found.append((index,) + parsed)
            continue
        if not line.strip():
            continue
        if len(line) - len(line.lstrip(" ")) <= parent_indent:
            break
    return found


def direct_keys(lines, start, parent_indent):
    """Mapping entries at the first level below a parent key."""
    found = keys_under(lines, start, parent_indent)
    if not found:
        return []
    child_indent = min(entry[1] for entry in found)
    return [entry for entry in found if entry[1] == child_indent]


def child(lines, start, parent_indent, name):
    """The first direct child entry named name, or None."""
    for entry in direct_keys(lines, start, parent_indent):
        if entry[2] == name:
            return entry
    return None


def top_level(lines):
    """(index, indent, key, rest) for every top-level mapping line."""
    found = []
    for index, line in enumerate(lines):
        parsed = key_line(line)
        if parsed is not None and parsed[0] == 0:
            found.append((index,) + parsed)
    return found


def block_items(lines, start, parent_indent):
    """Virtual mapping lines for each `- ` item below a parent key."""
    items = []
    item_indent = None
    current = None
    for line in lines[start + 1:]:
        stripped = line.strip()
        if not stripped:
            if current is not None:
                current.append("")
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent <= parent_indent:
            break
        match = _ITEM.match(line)
        if match is not None:
            here = len(match.group(1))
            if item_indent is None or here < item_indent:
                item_indent = here
            if here == item_indent:
                if current is not None:
                    items.append(current)
                current = [" " * (here + 2) + (match.group(2) or "")]
                continue
        if current is not None:
            current.append(line)
    if current is not None:
        items.append(current)
    return items


def text_under(block, start, parent_indent):
    """The dedented block scalar that follows a `key: |` line."""
    body = []
    for line in block[start + 1:]:
        if not line.strip():
            body.append("")
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent <= parent_indent:
            break
        body.append(line)
    indents = [len(line) - len(line.lstrip(" "))
               for line in body if line.strip()]
    cut = min(indents) if indents else 0
    return "\n".join(line[cut:] if line.strip() else "" for line in body)


def mapping_entries(lines):
    """(index, indent, key, rest) for every mapping line in a block."""
    found = []
    for index, line in enumerate(lines):
        parsed = key_line(line)
        if parsed is not None:
            found.append((index,) + parsed)
    return found


def parse_step(block):
    """One workflow step as a dict, with `with:` and `env:` fields nested."""
    entries = mapping_entries(block)
    if not entries:
        return {}
    base = min(entry[1] for entry in entries)
    step = {}
    nested = {}
    for index, indent, key, rest in entries:
        if indent != base:
            continue
        value = rest.strip()
        if key in ("with", "env"):
            nested[key] = (index, indent)
        elif value in ("|", ">", "|-", ">-"):
            step[key] = text_under(block, index, indent)
        else:
            step[key] = value
    for key, (index, indent) in nested.items():
        step[key] = parse_fields(block, index, indent)
    return step


def parse_fields(lines, start, parent_indent):
    """Mapping fields at the first level below a parent key."""
    end = start + 1
    while end < len(lines):
        line = lines[end]
        if line.strip() and (len(line) - len(line.lstrip(" "))
                             <= parent_indent):
            break
        end += 1
    region = lines[start + 1:end]
    entries = [entry for entry in mapping_entries(region)
               if entry[1] > parent_indent]
    if not entries:
        return {}
    child_indent = min(entry[1] for entry in entries)
    return {key: rest.strip()
            for _, indent, key, rest in entries if indent == child_indent}


def steps(lines):
    """Every job step as a parsed dict."""
    jobs = None
    for entry in top_level(lines):
        if entry[2] == "jobs":
            jobs = entry
            break
    if jobs is None:
        return []
    bench = child(lines, jobs[0], jobs[1], "bench")
    if bench is None:
        return []
    steps_entry = child(lines, bench[0], bench[1], "steps")
    if steps_entry is None:
        return []
    return [parse_step(block)
            for block in block_items(lines, steps_entry[0], steps_entry[1])]


def inputs(lines):
    """The workflow_dispatch inputs as name -> fields."""
    dispatch = None
    for entry in top_level(lines):
        if entry[2] != "on" or entry[3].strip():
            continue
        for trigger in direct_keys(lines, entry[0], entry[1]):
            if trigger[2] == "workflow_dispatch":
                dispatch = trigger
                break
    if dispatch is None:
        return {}
    inputs_entry = child(lines, dispatch[0], dispatch[1], "inputs")
    if inputs_entry is None:
        return {}
    result = {}
    for index, indent, name, _ in direct_keys(lines, inputs_entry[0],
                                              inputs_entry[1]):
        result[name] = parse_fields(lines, index, indent)
    return result


class PerfLinuxWorkflowTest(unittest.TestCase):
    """The Linux bench stays manual, cheap and able to explain a failure."""

    @classmethod
    def setUpClass(cls):
        with open(workflow_path(), encoding="utf-8") as handle:
            cls.text = handle.read()
        cls.lines = cls.text.splitlines()

    def test_trigger_is_workflow_dispatch_only(self):
        on_entries = [entry for entry in top_level(self.lines)
                      if entry[2] == "on"]
        self.assertEqual(len(on_entries), 1)
        on_entry = on_entries[0]
        self.assertEqual(on_entry[3].strip(), "",
                         "on: must be a block, not an inline trigger")
        triggers = [entry[2] for entry in
                    direct_keys(self.lines, on_entry[0], on_entry[1])]
        self.assertEqual(triggers, ["workflow_dispatch"])
        self.assertNotIn("push", self.text)
        self.assertNotIn("pull_request", self.text)
        self.assertNotIn("schedule", self.text)
        self.assertNotIn("workflow_run", self.text)

    def test_dispatch_inputs_types_and_defaults(self):
        found = inputs(self.lines)
        self.assertEqual(sorted(found), sorted(_EXPECTED_INPUTS))
        for name, expected in _EXPECTED_INPUTS.items():
            with self.subTest(input=name):
                fields = found[name]
                if name == "head_ref":
                    self.assertEqual(fields.get("required"), "true")
                else:
                    self.assertNotIn("required", fields)
                if name in _STRING_INPUTS:
                    self.assertEqual(fields.get("type"), "string")
                else:
                    self.assertEqual(fields.get("type"), "choice")
                self.assertEqual(fields.get("default"), expected["default"])
                if expected["options"]:
                    self.assertEqual(options(fields), expected["options"])
                else:
                    self.assertNotIn("options", fields)

    def test_deadline_step_first_and_every_run_call_passes_it(self):
        all_steps = steps(self.lines)
        self.assertEqual(all_steps[0]["name"], "Record bench deadline")
        record = all_steps[0]["run"]
        self.assertIn("BENCH_DEADLINE=", record)
        self.assertIn("270 * 60", record)
        self.assertIn('>> "$GITHUB_ENV"', record)
        for name in ("Measure speed-of-light", "Measure A/B"):
            with self.subTest(step=name):
                script = self.step(name)["run"]
                self.assertIn('--deadline-epoch "$BENCH_DEADLINE"', script)
                calls = script.count("sol.py\" run") + script.count(
                    "ab.py\" run")
                self.assertEqual(
                    script.count('--deadline-epoch "$BENCH_DEADLINE"'),
                    calls)

    def test_measuring_steps_time_out_before_the_job_and_reports_run(self):
        job = [int(e[3].strip()) for e in self.mapping_entries()
               if e[2] == "timeout-minutes"
               and e[1] == 4]
        self.assertEqual(job, [300])
        for name in ("Measure speed-of-light", "Measure A/B"):
            self.assertEqual(self.step(name)["timeout-minutes"], "280", name)
        for name in ("Summarize speed-of-light", "Summarize A/B",
                     "Upload platform sol", "Upload platform ab",
                     "Upload platform profile"):
            self.assertIn("!cancelled()", self.step(name)["if"], name)
            self.assertNotIn("timeout-minutes", self.step(name), name)

    def test_runner_timeout_and_no_cache(self):
        runs_on = [entry[3].strip() for entry in self.mapping_entries()
                   if entry[2] == "runs-on"]
        self.assertEqual(runs_on, ["ubuntu-latest"])
        timeouts = [int(entry[3].strip()) for entry in self.mapping_entries()
                    if entry[2] == "timeout-minutes"]
        self.assertTrue(timeouts)
        for timeout in timeouts:
            self.assertLessEqual(timeout, 300)
        self.assertNotIn("actions/cache", self.text)
        for entry in self.mapping_entries():
            if "cache" in entry[2].lower():
                self.fail("cache input %r must not be set" % entry[2])

    def uploads(self):
        """Every upload-artifact step by its artifact name expression."""
        return {step["with"]["name"]: step for step in steps(self.lines)
                if step.get("uses", "").startswith(
                    "actions/upload-artifact")}

    def test_upload_is_one_small_result_even_after_failure(self):
        upload = self.uploads()["${{ inputs.platform }}-sol"]
        fields = upload["with"]
        self.assertEqual(fields.get("path"),
                         "${{ inputs.platform }}-sol.json")
        self.assertEqual(fields.get("retention-days"), "3")
        condition = upload.get("if", "")
        self.assertIn("!cancelled()", condition)
        self.assertNotIn("success()", condition)
        self.assertIn("inputs.ab == 'off'", condition)

    def test_uploads_are_sol_ab_and_profile_only(self):
        uploads = self.uploads()
        self.assertEqual(sorted(uploads), [
            "${{ inputs.platform }}-ab", "${{ inputs.platform }}-profile",
            "${{ inputs.platform }}-sol"])
        ab_up = uploads["${{ inputs.platform }}-ab"]
        self.assertEqual(ab_up["with"]["path"],
                         "${{ inputs.platform }}-ab.json")
        self.assertIn("inputs.ab == 'flags'", ab_up["if"])
        profile = uploads["${{ inputs.platform }}-profile"]
        for upload in uploads.values():
            self.assertIn("!cancelled()", upload["if"])
            self.assertNotIn("success()", upload["if"])
            self.assertEqual(upload["with"]["retention-days"], "3")
        # The step parser keeps block scalars out of `with:`, so read
        # the profile step's path list from the text after its name.
        paths = self.text[self.text.index("name: Upload platform profile"):]
        for arm in ("sol-results", "ab-results/control",
                    "ab-results/treatment"):
            for name in ("trace.json.gz", "execlog.json.gz"):
                self.assertIn("%s/**/%s" % (arm, name), paths)
        self.assertNotIn("bazel-out", paths)

    def step(self, name):
        """The one step with this name."""
        found = [s for s in steps(self.lines) if s.get("name") == name]
        self.assertEqual(len(found), 1, name)
        return found[0]

    def test_validate_steps_run_before_anything_is_built(self):
        names = [s.get("name") for s in steps(self.lines)]
        for name in ("Validate bazel_flags", "Validate A/B inputs"):
            self.assertLess(names.index(name),
                            names.index("Generate pristine monorepo"))
        flags = self.step("Validate bazel_flags")["run"]
        self.assertIn("bench_flags.py", flags)
        self.assertIn('--flags="$BAZEL_FLAGS"', flags)
        validate = self.step("Validate A/B inputs")["run"]
        self.assertRegex(validate, r"ab\.py\" validate")
        for fragment in ("--mode sol", '--ab "$AB"',
                         '--lockfile "$LOCKFILE"',
                         '--flags="$BAZEL_FLAGS"'):
            self.assertIn(fragment, validate)

    def test_ab_flags_prepares_two_workspaces_and_flags_treatment(self):
        step = self.step("Prepare A/B workspaces")
        self.assertEqual(step["if"], "inputs.ab == 'flags'")
        script = step["run"]
        self.assertIn('cp -a "$RUNNER_TEMP/ws-head-pristine" '
                      '"$RUNNER_TEMP/ws-control-pristine"', script)
        self.assertIn('cp -a "$RUNNER_TEMP/ws-head-pristine" '
                      '"$RUNNER_TEMP/ws-treatment-pristine"', script)
        self.assertIn('[ "$LOCKFILE" = "none" ]', script)
        self.assertIn("ws-control-pristine/MODULE.bazel.lock", script)
        self.assertIn("ws-treatment-pristine/MODULE.bazel.lock", script)
        flagged = re.findall(r"--workspace\s+(\S+)", script)
        self.assertEqual(flagged, ['"$RUNNER_TEMP/ws-treatment-pristine"'])
        names = [s.get("name") for s in steps(self.lines)]
        self.assertGreater(names.index("Prepare A/B workspaces"),
                           names.index("Generate committed lockfile"))
        self.assertLess(names.index("Prepare A/B workspaces"),
                        names.index("Measure A/B"))

    def test_ab_flags_measures_through_ab_py_per_platform(self):
        step = self.step("Measure A/B")
        self.assertEqual(step["if"], "inputs.ab == 'flags'")
        script = step["run"]
        self.assertIn('ab.py" run', script)
        self.assertIn('--platform "$PLATFORM"', script)
        self.assertIn("ab-results", script)
        self.assertIn('--repeats "$REPEATS"', script)
        self.assertIn("|| failed=1", script)
        self.assertIn('exit "$failed"', script)
        self.assertNotIn("--config", script)
        names = [s.get("name") for s in steps(self.lines)]
        self.assertLess(
            names.index("Point Bazel at the runner's Android SDK and NDK"),
            names.index("Measure A/B"))

    def test_ab_flags_summarizes_even_after_a_failed_arm(self):
        step = self.step("Summarize A/B")
        self.assertEqual(step["if"],
                         "${{ !cancelled() && inputs.ab == 'flags' }}")
        script = step["run"]
        self.assertRegex(script, r"ab\.py\" summarize")
        self.assertIn('--platform "$PLATFORM"', script)
        self.assertIn('--out "$GITHUB_WORKSPACE/$PLATFORM-ab.json"', script)
        self.assertIn('>> "$GITHUB_STEP_SUMMARY"', script)

    def test_ab_off_steps_stay_the_single_run(self):
        measure = self.step("Measure speed-of-light")
        self.assertEqual(measure["if"], "inputs.ab == 'off'")
        self.assertIn("sol.py", measure["run"])
        summarize = self.step("Summarize speed-of-light")
        self.assertEqual(summarize["if"],
                         "${{ !cancelled() && inputs.ab == 'off' }}")
        apply = self.step("Apply bazel_flags to the measured workspace")
        self.assertIn("inputs.ab == 'off'", apply["if"])
        self.assertIn("inputs.bazel_flags != ''", apply["if"])
        self.assertIn("ws-head-pristine", apply["run"])

    def test_measurement_runs_both_configurations_per_platform(self):
        measure = [step.get("run", "") for step in steps(self.lines)
                   if re.search(r"sol\.py[^\n]*\srun(?:\s|$)",
                                step.get("run", ""))]
        self.assertEqual(len(measure), 1)
        script = measure[0]
        for platform, configs in _CONFIGS.items():
            with self.subTest(platform=platform):
                chain = " ".join("--config " + c for c in configs)
                self.assertIn(chain, script)

    def test_generates_head_and_summarizes_to_platform_file(self):
        all_steps = steps(self.lines)
        generate = [step.get("run", "") for step in all_steps
                    if "gen_monorepo.py" in step.get("run", "")]
        self.assertEqual(len(generate), 1)
        self.assertIn("--rules-flutter", generate[0])
        self.assertIn("rules-head", generate[0])
        summarize = [step for step in all_steps
                     if re.search(r"sol\.py[^\n]*\s+summarize\b",
                                  step.get("run", ""))]
        self.assertEqual(len(summarize), 1)
        self.assertEqual(summarize[0].get("env", {}).get("PLATFORM"),
                         "${{ inputs.platform }}")
        self.assertIn(
            '--out "$GITHUB_WORKSPACE/$PLATFORM-sol.json"',
            summarize[0]["run"])

    def test_no_workflow_inputs_in_run_blocks(self):
        violations = []
        for step in steps(self.lines):
            script = step.get("run", "")
            if not script:
                continue
            step_name = step.get("name", "<unnamed>")
            for match in re.finditer(
                r"\$\{\{\s*(?:github\.event\.)?inputs\.([A-Za-z0-9_]+)"
                r"|github\.event\.inputs\.([A-Za-z0-9_]+)",
                script,
            ):
                input_name = match.group(1) or match.group(2)
                violations.append(
                    "step %r contains input %r in run: script"
                    % (step_name, input_name))
        self.assertEqual(violations, [])

    def test_script_inputs_bound_in_env_and_referenced_as_variables(self):
        step_map = {step.get("name"): step for step in steps(self.lines)
                    if step.get("name")}
        for step_name, expected_inputs in _STEP_SCRIPT_INPUTS.items():
            self.assertIn(step_name, step_map)
            step = step_map[step_name]
            env = step.get("env", {})
            script = step.get("run", "")
            self.assertTrue(script, "step %r has run: script" % step_name)
            for input_name in expected_inputs:
                var_name = input_name.upper()
                with self.subTest(step=step_name, input=input_name):
                    self.assertIn(
                        var_name, env,
                        "step %r missing env: entry %r"
                        % (step_name, var_name))
                    self.assertEqual(
                        env[var_name],
                        "${{ inputs.%s }}" % input_name,
                        "step %r env[%r] must bind inputs.%s"
                        % (step_name, var_name, input_name))
                    self.assertIn(
                        "$%s" % var_name, script,
                        "step %r script must reference $%s"
                        % (step_name, var_name))
                    self.assertNotIn(
                        "inputs.%s" % input_name, script,
                        "step %r script must not reference inputs.%s"
                        % (step_name, input_name))

    def mapping_entries(self):
        """Every mapping line in the workflow, nested ones included."""
        entries = []
        for index, line in enumerate(self.lines):
            parsed = key_line(line)
            if parsed is not None:
                entries.append((index,) + parsed)
        return entries


def options(fields):
    """The option list of one input, inline or block form."""
    value = fields.get("options", "")
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        return [item.strip() for item in inner.split(",")] if inner else []
    return []


if __name__ == "__main__":
    unittest.main()
