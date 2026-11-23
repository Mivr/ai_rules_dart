#!/usr/bin/env python3
"""Unit tests for bench_flags.py (iOS bench A/B Bazel flags)."""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bench_flags
from bench_flags import (
    append_flags,
    check_token,
    is_worker_spawn,
    parse_bazel_flags,
    validate_bazel_flags,
    worker_steps,
)


class ParseTest(unittest.TestCase):
    def test_empty_gives_empty(self):
        self.assertEqual(parse_bazel_flags(""), [])
        self.assertEqual(parse_bazel_flags("   "), [])
        self.assertEqual(parse_bazel_flags(None), [])

    def test_whitespace_split(self):
        self.assertEqual(
            parse_bazel_flags("--a=1  --b\n--c"),
            ["--a=1", "--b", "--c"])


class AcceptTest(unittest.TestCase):
    def test_plain_and_value_flags_accepted(self):
        good = [
            "--host_compilation_mode=fastbuild",
            "--jobs=100",
            "--foo_bar=abcXYZ019_@/:.,+=-",
            "--verbose",
        ]
        self.assertEqual(validate_bazel_flags(good), good)

    def test_starlark_labels_with_and_without_repo(self):
        good = [
            "--@rules_flutter//flutter:incremental_kernel",
            "--//flutter:incremental_kernel",
            "--@repo//pkg/sub:name=v1",
        ]
        self.assertEqual(validate_bazel_flags(good), good)

    def test_each_refusal_rule(self):
        refused = [
            "--disk_cache=/tmp/x",
            "--repository_cache=/tmp/x",
            "--remote_cache=1",
            "--remote_executor=1",
            "--experimental_remote_foo=1",
            "--bes_backend=1",
            "--google_credentials=1",
            "--output_base=/tmp/x",
            "--output_user_root=/tmp/x",
            "--install_base=/tmp/x",
            "--symlink_prefix=x",
            "--profile=/tmp/x",
            "--generate_json_trace_profile=/tmp/x",
            "--execution_log_json_file=/tmp/x",
            "--experimental_execution_log_file=/tmp/x",
            "--config=ios",
            "--bazelrc=/tmp/x",
            "--ignore_all_rc_files",
            "--lockfile_mode=off",
            "--override_module=rules_dart=/tmp/x",
            "--override_repository=foo=/tmp/x",
            "--registry=1",
            "--batch",
            "--host_jvm_args=-Xmx1g",
            "--max_idle_secs=10",
        ]
        for token in refused:
            with self.subTest(token=token):
                self.assertIsNotNone(check_token(token))
                with self.assertRaises(ValueError) as ctx:
                    validate_bazel_flags([token])
                self.assertIn(token, str(ctx.exception))

    def test_no_negation_forms_refused(self):
        for token in ["--noconfig", "--nobatch",
                      "--noremote_cache", "--nolockfile_mode"]:
            with self.subTest(token=token):
                self.assertIsNotNone(check_token(token))

    def test_injection_characters_refused(self):
        bad = ["--a'b", '--a"b', "--a$b", "--a`b", "--a;b", "--a|b",
               "--a&b", "--a<b", "--a>b", "--a\\b", "--a#b",
               "--a\tb", "--a\nb", "--a\x01b", "--a b"]
        for token in bad:
            with self.subTest(token=token):
                with self.assertRaises(ValueError) as ctx:
                    validate_bazel_flags([token])
                self.assertIn(repr(token), str(ctx.exception))

    def test_malformed_tokens_refused(self):
        for token in ["-a", "a", "--", "--=v", "--foo=",
                      "--foo bar", "--foo$=1", "--foo=has space"]:
            with self.subTest(token=token):
                self.assertIsNotNone(check_token(token))

    def test_error_names_token(self):
        with self.assertRaises(ValueError) as ctx:
            validate_bazel_flags(["--ok=1", "--config=x"])
        self.assertIn("--config=x", str(ctx.exception))


class AppendTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="bench-flags-")
        self.head = os.path.join(self.tmp, "ws-head-pristine")
        self.base = os.path.join(self.tmp, "ws-base-pristine")
        for workspace in (self.head, self.base):
            os.makedirs(workspace)
            with open(os.path.join(workspace, ".bazelrc"), "w",
                      encoding="utf-8", newline="\n") as fh:
                fh.write("common --announce_rc\n")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def read(self, workspace):
        with open(os.path.join(workspace, ".bazelrc"),
                  encoding="utf-8") as fh:
            return fh.read()

    def test_appended_lines(self):
        count = append_flags(
            self.head, ["--host_compilation_mode=fastbuild",
                        "--@rules_flutter//flutter:incremental_kernel"])
        self.assertEqual(count, 2)
        self.assertEqual(
            self.read(self.head),
            "common --announce_rc\n"
            "common --host_compilation_mode=fastbuild\n"
            "common --@rules_flutter//flutter:incremental_kernel\n")

    def test_empty_leaves_file_byte_identical(self):
        before = self.read(self.head)
        self.assertEqual(append_flags(self.head, []), 0)
        self.assertEqual(append_flags(self.head, parse_bazel_flags("")), 0)
        self.assertEqual(self.read(self.head), before)

    def test_head_only_placement(self):
        append_flags(self.head, ["--jobs=8"])
        self.assertIn("common --jobs=8", self.read(self.head))
        self.assertNotIn("--jobs=8", self.read(self.base))


class MetaTest(unittest.TestCase):
    def test_compare_meta_defaults_and_records(self):
        import summarize
        summary = summarize.build_summary(
            tempfile.mkdtemp(), "base", "head", {})
        self.assertEqual(summary["meta"]["bazel_flags"], [])
        md = summarize.render_markdown({
            "base_ref": "b", "head_ref": "h",
            "meta": {"bazel_flags": []}, "configs": {}})
        self.assertNotIn("bazel_flags", md)
        md = summarize.render_markdown({
            "base_ref": "b", "head_ref": "h",
            "meta": {"bazel_flags": ["--jobs=8"]}, "configs": {}})
        self.assertIn("--jobs=8", md)

    def test_sol_meta_records(self):
        import sol
        summary = sol.summarize_sol(
            tempfile.mkdtemp(),
            {"sha": "a" * 40, "repeats": 1, "target_loc": 1, "seed": 1})
        self.assertEqual(summary["meta"]["bazel_flags"], [])
        summary = sol.summarize_sol(
            tempfile.mkdtemp(),
            {"sha": "a" * 40, "repeats": 1, "target_loc": 1,
             "seed": 1, "bazel_flags": ["--jobs=8"]})
        self.assertEqual(summary["meta"]["bazel_flags"], ["--jobs=8"])


class WorkerChainTest(unittest.TestCase):
    def worker_spawn(self):
        return {
            "commandArgs": ["sh", "-c", "exit 0"],
            "environmentVariables": [],
            "listedOutputs": ["bazel-out/x/out.bin"],
            "inputs": {},
            "mnemonic": "FlutterKernelCompile",
            "runner": "worker pool (persistent)",
            "exitCode": 0,
            "targetLabel": "//pkg:p",
        }

    def test_runner_names_worker(self):
        self.assertTrue(is_worker_spawn({"runner": "worker pool"}))
        self.assertTrue(is_worker_spawn({"runner": "persistent Worker"}))
        self.assertFalse(is_worker_spawn({"runner": "local"}))
        self.assertFalse(is_worker_spawn({}))

    def test_worker_step_replays_one_shot_and_counted(self):
        import shutil
        import subprocess
        tmp = tempfile.mkdtemp(prefix="bench-flags-worker-")
        try:
            out = os.path.join(tmp, "bazel-out", "x", "out.bin")
            os.makedirs(os.path.dirname(out))
            with open(out, "w", encoding="utf-8") as fh:
                fh.write("old-bytes")
            spawn = self.worker_spawn()
            self.assertEqual(worker_steps([spawn]),
                             {"FlutterKernelCompile": 1})
            from replay import chain_all
            calls = []

            def fake_runner(spawn):
                calls.append(list(spawn["commandArgs"]))
                out_path = os.path.join(
                    tmp, "bazel-out", "x", "out.bin")
                with open(out_path, "w", encoding="utf-8") as fh:
                    fh.write("new-bytes")
                proc = subprocess.run(
                    ["true"], stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL)
                del proc
                return {"mnemonic": spawn["mnemonic"], "target": "",
                        "instructions": None, "real_s": 0.1,
                        "user_s": 0.08, "sys_s": 0.02,
                        "exit_code": 0, "stderr_tail": None,
                        "command": []}

            report = chain_all([spawn], tmp, 60.0, runner=fake_runner)
            self.assertEqual(report["n_replayed"], 1)
            self.assertEqual(report["failed"], [])
            self.assertEqual(calls, [["sh", "-c", "exit 0"]])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_sol_record_and_summary_carry_worker_steps(self):
        import sol
        records = [
            {"identical": True, "method": "batch",
             "scenario": "clean",
             "bazel": {"cpu_s": 1.0}, "sol": {"cpu_s": 0.5},
             "reason": "ok", "worker_steps": {"Genrule": 2},
             "chain": {"steps": {}, "skipped": {}, "failed": [],
                       "ordering_failed": None,
                       "verify_differ": {"n": 0, "differ": []},
                       "output_drift": {"n": 0, "paths": []},
                       "sol_cpu_s": 0.5, "status": "ok"},
             "profile": {"jvm": {"total": 0.1, "phases": {}},
                         "host_tools": {"total": 0.0, "by_mnemonic": {},
                                        "by_target": {}, "failed": []},
                         "sol_cpu_s": 0.5, "sol_source": "sol",
                         "residual": 0.4}},
        ]
        flow = sol.summarize_flow(records, "cpu_seconds")
        self.assertEqual(flow["worker_steps"], {"Genrule": 2})
        self.assertEqual(
            sol.error_record(
                "device_release", "clean", "boom")["worker_steps"], {})


class SingleFlagTest(unittest.TestCase):
    """One raw token must never read as an argparse option (equals form)."""

    def run_main(self, argv):
        import contextlib
        import io
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code = bench_flags.main(argv)
        return (code, err.getvalue())

    def test_single_valid_tokens(self):
        for token in ["--host_compilation_mode=fastbuild",
                      "--@rules_flutter//flutter:incremental_kernel"]:
            with self.subTest(token=token):
                code, _ = self.run_main(["--flags=" + token])
                self.assertEqual(code, 0)

    def test_single_refused_token_names_it(self):
        code, err = self.run_main(["--flags=--config=x"])
        self.assertEqual(code, 1)
        self.assertIn("--config=x", err)

    def test_single_no_negation_names_it(self):
        code, err = self.run_main(["--flags=--noconfig"])
        self.assertEqual(code, 1)
        self.assertIn("--noconfig", err)

    def test_summarize_single_valid_token(self):
        import json
        import shutil
        import sol
        tmp = tempfile.mkdtemp(prefix="bench-flags-sol-")
        try:
            out = os.path.join(tmp, "ios-sol.json")
            code = sol.main([
                "summarize", "--results", tmp, "--sha", "a" * 40,
                "--repeats", "1", "--target-loc", "100", "--seed", "7",
                "--bazel-flags=--host_compilation_mode=fastbuild",
                "--out", out])
            self.assertEqual(code, 0)
            with open(out, encoding="utf-8") as fh:
                summary = json.load(fh)
            self.assertEqual(summary["meta"]["bazel_flags"],
                             ["--host_compilation_mode=fastbuild"])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_summarize_single_refused_token_names_it(self):
        import shutil
        import sol
        tmp = tempfile.mkdtemp(prefix="bench-flags-sol-")
        try:
            with self.assertRaises(ValueError) as ctx:
                sol.main([
                    "summarize", "--results", tmp, "--sha", "a" * 40,
                    "--repeats", "1", "--target-loc", "100",
                    "--seed", "7", "--bazel-flags=--noconfig",
                    "--out", os.path.join(tmp, "ios-sol.json")])
            self.assertIn("--noconfig", str(ctx.exception))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class WorkflowTest(unittest.TestCase):
    def path(self):
        here = os.path.dirname(os.path.abspath(__file__))
        return os.path.join(here, "..", "..", ".github", "workflows",
                            "perf-ios.yaml")

    def text(self):
        with open(self.path(), encoding="utf-8") as fh:
            return fh.read()

    def test_bazel_flags_input_exists_with_empty_default(self):
        text = self.text()
        self.assertIn("bazel_flags:", text)
        self.assertRegex(text, r"bazel_flags:\n(\s+\S.*\n)+?.*default: \"\"")

    def test_input_only_through_env(self):
        text = self.text()
        run_blocks = []
        current = None
        for line in text.splitlines():
            if line.strip().startswith("run: |"):
                current = []
            elif current is not None:
                if line and not line.startswith(" ") \
                        and not line.startswith("\t"):
                    run_blocks.append("\n".join(current))
                    current = None
                else:
                    current.append(line)
        if current is not None:
            run_blocks.append("\n".join(current))
        for block in run_blocks:
            self.assertNotIn("inputs.bazel_flags", block)
        self.assertGreaterEqual(text.count("BAZEL_FLAGS: ${{ inputs.bazel_flags }}"), 3)

    def test_head_only_append_and_validation_steps(self):
        text = self.text()
        self.assertIn("Validate bazel_flags", text)
        self.assertIn("bench_flags.py", text)
        self.assertIn("ws-head-pristine", text)
        self.assertNotIn("ws-base-pristine", text)
        # The raw input reaches argparse only in --opt=<value> form, so a
        # single token starting with -- never reads as an option.
        self.assertIn('--flags="$BAZEL_FLAGS"', text)
        self.assertIn('--bazel-flags="$BAZEL_FLAGS"', text)
        self.assertNotIn('--flags "$BAZEL_FLAGS"', text)
        self.assertNotIn('--bazel-flags "$BAZEL_FLAGS"', text)


if __name__ == "__main__":
    unittest.main()
