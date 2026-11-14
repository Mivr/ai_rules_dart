#!/usr/bin/env python3
"""Unit tests for ab.py (iOS bench same-runner A/B, Linux fixtures)."""

import io
import json
import os
import shutil
import signal
import stat
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import ab
from ab import (
    arm_order,
    first_arm,
    generate_committed_lock,
    geomean,
    load_arm_rep_record,
    lock_build_argv,
    pair_ratio,
    ratio_for_flow,
    read_lock_bytes,
    remove_lock,
    summarize_ab,
    summarize_arm_flows,
    validate_ab,
    write_lock_bytes,
)
from sol_test import FAKE_BAZEL
from sol_test import STUB_GEN
from run_rep import CONFIG_ORDER, IOS_CONFIGS
import sol


class ValidateTest(unittest.TestCase):
    def test_defaults_pass(self):
        self.assertEqual(validate_ab("sol", "off", "none", []), [])
        self.assertEqual(validate_ab("compare", "off", "none", []), [])
        self.assertEqual(
            validate_ab("sol", "flags", "none", ["--jobs=8"]), ["--jobs=8"])
        self.assertEqual(
            validate_ab("sol", "flags", "committed", ["--jobs=8"]),
            ["--jobs=8"])
        self.assertEqual(validate_ab("sol", "lockfile", "none", []), [])
        self.assertEqual(
            validate_ab("sol", "lockfile", "none", ["--jobs=8"]),
            ["--jobs=8"])

    def test_non_sol_with_ab_fails_at_once(self):
        for mode in ("compare", "other"):
            for value in ("flags", "lockfile"):
                with self.subTest(mode=mode, ab=value):
                    with self.assertRaisesRegex(ValueError, "sol"):
                        validate_ab(mode, value, "none", ["--jobs=8"])

    def test_flags_arm_needs_non_empty_flags(self):
        with self.assertRaisesRegex(ValueError, "non-empty"):
            validate_ab("sol", "flags", "none", [])
        with self.assertRaisesRegex(ValueError, "non-empty"):
            validate_ab("sol", "flags", "committed", [])

    def test_lockfile_arm_needs_lockfile_none(self):
        with self.assertRaisesRegex(ValueError, "lockfile=none"):
            validate_ab("sol", "lockfile", "committed", [])

    def test_bad_choices_fail(self):
        with self.assertRaises(ValueError):
            validate_ab("sol", "nope", "none", [])
        with self.assertRaises(ValueError):
            validate_ab("sol", "off", "nope", [])

    def test_cli_validate(self):
        self.assertEqual(
            ab.main(["validate", "--mode", "sol", "--ab", "off",
                     "--lockfile", "none", "--flags", ""]), 0)
        with self.assertRaises(ValueError):
            ab.main(["validate", "--mode", "compare", "--ab", "flags",
                     "--lockfile", "none", "--flags=--jobs=8"])


class ArmOrderTest(unittest.TestCase):
    def test_first_arm_alternates(self):
        self.assertEqual(first_arm(1), "control")
        self.assertEqual(first_arm(2), "treatment")
        self.assertEqual(first_arm(3), "control")
        self.assertEqual(first_arm(4), "treatment")

    def test_order_control_first_then_alternating(self):
        self.assertEqual(arm_order(1), ["control-first"])
        self.assertEqual(arm_order(2),
                         ["control-first", "treatment-first"])
        self.assertEqual(arm_order(3),
                         ["control-first", "treatment-first",
                          "control-first"])


class LockStepTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ab-lock-")
        self.pristine = os.path.join(self.tmp, "ws")
        os.makedirs(self.pristine)
        with open(os.path.join(self.pristine, "src.txt"), "w",
                  encoding="utf-8") as fh:
            fh.write("v1\n")
        self.lock_out = os.path.join(self.tmp, "lock-out")
        self.results = os.path.join(self.tmp, "results")
        os.makedirs(self.results)
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def fake_run(self, writes_lock=True):
        calls = []

        def run(argv, cwd=None):
            calls.append(list(argv))
            if writes_lock and "build" in argv:
                with open(os.path.join(cwd, "MODULE.bazel.lock"), "w",
                          encoding="utf-8") as fh:
                    fh.write("lock-bytes-v1")
            return mock.Mock(returncode=0)
        run.calls = calls
        return run

    def test_lock_argv_default_mode_and_own_base(self):
        for config in ("device_release", "sim_debug"):
            argv = lock_build_argv(self.lock_out, config)
            self.assertEqual(argv[0], "bazel")
            self.assertIn("--output_base=" + self.lock_out, argv)
            self.assertIn("--nobuild", argv)
            self.assertNotIn("--batch", argv)
            joined = " ".join(argv)
            self.assertNotIn("lockfile_mode", joined)

    def test_generate_once_unmeasured_reused_deleted(self):
        run = self.fake_run()
        data = generate_committed_lock(
            self.pristine, self.lock_out, run)
        self.assertEqual(data, b"lock-bytes-v1")
        # Both configs evaluated on the lock output base, then shutdown.
        kinds = ["build" if "build" in a else
                 "shutdown" if "shutdown" in a else "?" for a in run.calls]
        self.assertEqual(kinds, ["build", "build", "shutdown"])
        bases = [a[a.index("--output_base=" + self.lock_out)]
                 for a in run.calls]
        self.assertEqual(len(bases), 3)
        # Unmeasured: nothing written under results.
        self.assertEqual(os.listdir(self.results), [])
        # Its output base is gone afterwards.
        self.assertFalse(os.path.exists(self.lock_out))
        # One lock reused by every repeat: copies carry the same bytes.
        first = os.path.join(self.tmp, "rep1")
        second = os.path.join(self.tmp, "rep2")
        shutil.copytree(self.pristine, first)
        shutil.copytree(self.pristine, second)
        self.assertEqual(read_lock_bytes(first), data)
        self.assertEqual(read_lock_bytes(second), data)

    def test_missing_lock_fails_closed(self):
        with self.assertRaisesRegex(RuntimeError, "no MODULE"):
            generate_committed_lock(
                self.pristine, self.lock_out, self.fake_run(
                    writes_lock=False))
        self.assertFalse(os.path.exists(self.lock_out))

    def test_failed_build_still_cleans_up(self):
        def run(argv, cwd=None):
            if "build" in argv:
                return mock.Mock(returncode=1)
            return mock.Mock(returncode=0)
        with self.assertRaisesRegex(RuntimeError, "failed"):
            generate_committed_lock(self.pristine, self.lock_out, run)
        self.assertFalse(os.path.exists(self.lock_out))

    def test_read_only_leftovers_removed_not_reused(self):
        import stat
        stale = os.path.join(self.lock_out, "stale-dir")
        os.makedirs(stale)
        leaf = os.path.join(stale, "stale.txt")
        with open(leaf, "w", encoding="utf-8") as fh:
            fh.write("stale")
        os.chmod(leaf, stat.S_IRUSR)
        os.chmod(stale, stat.S_IRUSR | stat.S_IXUSR)
        data = generate_committed_lock(
            self.pristine, self.lock_out, self.fake_run())
        self.assertEqual(data, b"lock-bytes-v1")
        self.assertFalse(os.path.lexists(self.lock_out))

    def test_unremovable_base_fails_loudly(self):
        os.makedirs(self.lock_out, exist_ok=True)
        with mock.patch("shutil.rmtree",
                        side_effect=OSError("denied")):
            with self.assertRaisesRegex(RuntimeError, "cannot remove"):
                generate_committed_lock(
                    self.pristine, self.lock_out, self.fake_run())
            with self.assertRaisesRegex(RuntimeError, "cannot remove"):
                ab.remove_tree(self.lock_out)

    def test_lock_helpers(self):
        self.assertIsNone(read_lock_bytes(self.pristine))
        remove_lock(self.pristine)
        write_lock_bytes(self.pristine, b"bytes")
        self.assertEqual(read_lock_bytes(self.pristine), b"bytes")
        remove_lock(self.pristine)
        self.assertIsNone(read_lock_bytes(self.pristine))


class PlacementTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ab-place-")
        self.control = os.path.join(self.tmp, "ws-control-pristine")
        self.treatment = os.path.join(self.tmp, "ws-treatment-pristine")
        for workspace in (self.control, self.treatment):
            os.makedirs(workspace)
            with open(os.path.join(workspace, ".bazelrc"), "w",
                      encoding="utf-8", newline="\n") as fh:
                fh.write("common --announce_rc\n")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def read_rc(self, workspace):
        with open(os.path.join(workspace, ".bazelrc"),
                  encoding="utf-8") as fh:
            return fh.read()

    def test_flags_reach_only_treatment(self):
        import bench_flags
        bench_flags.append_flags(self.treatment, ["--jobs=8"])
        self.assertNotIn("--jobs=8", self.read_rc(self.control))
        self.assertIn("common --jobs=8", self.read_rc(self.treatment))

    def test_lock_only_in_treatment(self):
        write_lock_bytes(self.treatment, b"lock-bytes")
        self.assertIsNone(read_lock_bytes(self.control))
        self.assertEqual(read_lock_bytes(self.treatment), b"lock-bytes")

    def test_no_workspace_file_shared(self):
        marker = os.path.join(self.control, "marker.txt")
        with open(marker, "w", encoding="utf-8") as fh:
            fh.write("control-only")
        self.assertFalse(os.path.exists(
            os.path.join(self.treatment, "marker.txt")))


def flow_record(bazel_cpu, identical=True, reason="ok"):
    return {"flow": "f", "config": "c", "scenario": "s",
            "identical": identical, "reason": reason,
            "bazel": {"cpu_s": bazel_cpu, "real_s": 1.0},
            "sol": (None if bazel_cpu is None
                    else {"cpu_s": bazel_cpu / 2.0, "real_s": 0.5}),
            "n_sol_actions": 1}


class RatioTest(unittest.TestCase):
    def test_pairs_divide_treatment_by_control(self):
        self.assertAlmostEqual(
            pair_ratio(flow_record(2.0), flow_record(1.0)), 0.5)
        self.assertIsNone(pair_ratio(None, flow_record(1.0)))
        self.assertIsNone(pair_ratio(flow_record(1.0), None))

    def test_non_identical_or_missing_has_no_pair(self):
        self.assertIsNone(pair_ratio(
            flow_record(1.0, identical=False), flow_record(1.0)))
        self.assertIsNone(pair_ratio(
            flow_record(1.0), flow_record(1.0, identical=False)))
        self.assertIsNone(pair_ratio(flow_record(None), flow_record(1.0)))
        self.assertIsNone(pair_ratio(flow_record(1.0), flow_record(None)))
        self.assertIsNone(pair_ratio(flow_record(0), flow_record(1.0)))

    def test_geomean_of_known_pairs(self):
        import math
        pairs = [0.649, 1.16]
        self.assertAlmostEqual(
            geomean(pairs), math.exp(sum(math.log(v) for v in pairs) / 2))
        self.assertAlmostEqual(geomean(pairs), 0.86766, places=4)

    def test_geomean_empty_is_none(self):
        self.assertIsNone(geomean([]))

    def test_geomean_single_pair(self):
        self.assertAlmostEqual(geomean([1.25]), 1.25)

    def test_ratio_summarizes_pairs_and_names_unpaired(self):
        tmp = tempfile.mkdtemp(prefix="ab-ratio-")
        self.addCleanup(shutil.rmtree, tmp, True)
        control = os.path.join(tmp, "control")
        treatment = os.path.join(tmp, "treatment")

        def write(results, rep, record):
            path = os.path.join(results, "sol", "device_release",
                                "clean", "rep%d" % rep, "record.json")
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(json.dumps(record))

        write(control, 1, flow_record(100.0))
        write(treatment, 1, flow_record(110.0))
        write(control, 2, flow_record(200.0))
        write(treatment, 2, flow_record(100.0))
        # Repeat 3: one arm proves nothing, so it has no pair.
        write(control, 3, flow_record(100.0, identical=False,
                                      reason="step Genrule failed"))
        write(treatment, 3, flow_record(100.0))
        entry = ratio_for_flow(control, treatment, "device_release",
                               "clean", 3)
        self.assertEqual(entry["n"], 2)
        self.assertAlmostEqual(entry["median"], 1.1)
        self.assertAlmostEqual(entry["min"], 0.5)
        self.assertAlmostEqual(entry["max"], 1.1)
        self.assertAlmostEqual(entry["geomean"], 0.7416198, places=5)
        self.assertEqual(entry["unpaired"], [3])

    def test_empty_pairs_say_so(self):
        tmp = tempfile.mkdtemp(prefix="ab-ratio-empty-")
        self.addCleanup(shutil.rmtree, tmp, True)
        entry = ratio_for_flow(os.path.join(tmp, "c"),
                               os.path.join(tmp, "t"),
                               "device_release", "clean", 2)
        self.assertEqual(entry["n"], 0)
        self.assertIsNone(entry["median"])
        self.assertIsNone(entry["min"])
        self.assertIsNone(entry["max"])
        self.assertIsNone(entry["geomean"])
        self.assertEqual(entry["unpaired"], [1, 2])


class SummarizeAbTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ab-summary-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def write(self, arm, config, scenario, rep, record):
        path = os.path.join(self.tmp, arm, "sol", config, scenario,
                            "rep%d" % rep, "record.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(record))

    def full_record(self, flow, bazel_cpu, sol_cpu):
        return {"flow": flow, "config": "device_release",
                "scenario": "clean", "method": "batch",
                "identical": True, "reason": "ok",
                "bazel": {"cpu_s": bazel_cpu, "real_s": 1.0},
                "sol": {"cpu_s": sol_cpu, "real_s": 0.5},
                "n_sol_actions": 1, "worker_steps": {},
                "verify": {"before": {}, "after": {}},
                "chain": {"steps": {}, "skipped": {}, "failed": [],
                          "ordering_failed": None,
                          "verify_differ": {"n": 0, "differ": []},
                          "output_drift": {"n": 0, "paths": []},
                          "sol_cpu_s": sol_cpu, "status": "ok"},
                "profile": {"jvm": {"total": 0.1, "phases": {}},
                            "host_tools": {"total": 0.0, "by_mnemonic": {},
                                           "by_target": {}, "failed": []},
                            "sol_cpu_s": sol_cpu, "sol_source": "sol",
                            "residual": 0.1}}

    def test_arms_use_sol_flow_schema_and_ratios_pair(self):
        for rep, cpu in ((1, 100.0), (2, 200.0)):
            self.write("control", "device_release", "clean", rep,
                       self.full_record("ios-release-clean", cpu, cpu / 2))
            self.write("treatment", "device_release", "clean", rep,
                       self.full_record("ios-release-clean", cpu, cpu / 2))
        meta = {"sha": "b" * 40, "repeats": 2, "target_loc": 100,
                "seed": 7, "ab": "flags", "bazel_flags": ["--jobs=8"],
                "lockfile": "none", "order": arm_order(2)}
        summary = summarize_ab(os.path.join(self.tmp, "control"),
                               os.path.join(self.tmp, "treatment"), meta)
        for arm in ("control", "treatment"):
            entry = summary["arms"][arm]["ios-release-clean"]
            # Upper median over the two repeats, as summarize_values does.
            self.assertEqual(entry["bazel"], 200.0)
            self.assertEqual(entry["sol"], 100.0)
            self.assertTrue(entry["identical"])
            self.assertIn("chain", entry)
            self.assertIn("profile", entry)
        ratio = summary["ratio"]["ios-release-clean"]
        self.assertEqual(ratio["n"], 2)
        self.assertAlmostEqual(ratio["median"], 1.0)
        self.assertAlmostEqual(ratio["min"], 1.0)
        self.assertAlmostEqual(ratio["max"], 1.0)
        self.assertAlmostEqual(ratio["geomean"], 1.0)
        self.assertEqual(ratio["unpaired"], [])
        self.assertNotIn("ratios", summary)
        self.assertEqual(summary["meta"]["ab"], "flags")
        self.assertEqual(summary["meta"]["bazel_flags"], ["--jobs=8"])
        self.assertEqual(summary["meta"]["lockfile"], "none")
        self.assertEqual(summary["meta"]["order"], arm_order(2))
        self.assertNotIn("arm_order", summary["meta"])
        self.assertEqual(summary["unit"], "cpu_seconds")

    def test_api_flow_in_both_arms_with_a_paired_ratio(self):
        for arm, cpu in (("control", 100.0), ("treatment", 50.0)):
            for scenario, flow in (("app_edit", "ios-release-app"),
                                   ("api_edit", "ios-release-api")):
                record = self.full_record(flow, cpu, cpu / 2)
                record["scenario"] = scenario
                self.write(arm, "device_release", scenario, 1, record)
        meta = {"sha": "b" * 40, "repeats": 1, "target_loc": 100,
                "seed": 7, "ab": "flags", "bazel_flags": ["--jobs=8"],
                "lockfile": "none", "order": arm_order(1)}
        summary = summarize_ab(os.path.join(self.tmp, "control"),
                               os.path.join(self.tmp, "treatment"), meta)
        for arm, cpu in (("control", 100.0), ("treatment", 50.0)):
            flows = list(summary["arms"][arm])
            self.assertEqual(flows.index("ios-release-api"),
                             flows.index("ios-release-body") + 1)
            self.assertEqual(summary["arms"][arm]["ios-release-api"]["bazel"],
                             cpu)
            self.assertEqual(summary["arms"][arm]["ios-release-app"]["bazel"],
                             cpu)
        self.assertEqual(list(summary["arms"]["control"]),
                         list(summary["arms"]["treatment"]))
        for flow in ("ios-release-api", "ios-release-app"):
            self.assertEqual(summary["ratio"][flow]["n"], 1, flow)
            self.assertAlmostEqual(summary["ratio"][flow]["median"], 0.5)
        self.assertEqual(summary["ratio"]["ios-release-body"]["n"], 0)

    def test_missing_flow_records_say_so(self):
        meta = {"sha": "b" * 40, "repeats": 1, "target_loc": 100,
                "seed": 7, "ab": "lockfile", "bazel_flags": [],
                "lockfile": "none", "order": arm_order(1)}
        summary = summarize_ab(os.path.join(self.tmp, "control"),
                               os.path.join(self.tmp, "treatment"), meta)
        self.assertEqual(summary["arms"]["control"]["ios-release-clean"],
                         {"error": "missing repeats"})
        self.assertEqual(summary["ratio"]["ios-release-clean"]["n"], 0)

    def test_cli_summarize_writes_ios_ab(self):
        self.write("control", "device_release", "clean", 1,
                   self.full_record("ios-release-clean", 10.0, 5.0))
        self.write("treatment", "device_release", "clean", 1,
                   self.full_record("ios-release-clean", 10.0, 5.0))
        out = os.path.join(self.tmp, "ios-ab.json")
        with mock.patch("sys.stdout",
                         new_callable=io.StringIO) as stdout:
            code = ab.main(["summarize", "--results", self.tmp,
                            "--sha", "b" * 40, "--repeats", "1",
                            "--target-loc", "100", "--seed", "7",
                            "--ab", "flags", "--bazel-flags=--jobs=8",
                            "--lockfile", "none", "--out", out])
        self.assertEqual(code, 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        self.assertEqual(summary["meta"]["ab"], "flags")
        self.assertEqual(summary["ratio"]["ios-release-clean"]["n"], 1)
        self.assertAlmostEqual(
            summary["ratio"]["ios-release-clean"]["geomean"], 1.0)
        line = [ln for ln in stdout.getvalue().splitlines()
                if ln.startswith("flow=ios-release-clean ")]
        self.assertEqual(len(line), 1)
        self.assertIn("median=1.0", line[0])
        self.assertIn("geomean=1.0", line[0])

    def test_cli_summarize_refuses_ab_off(self):
        with self.assertRaises(ValueError):
            ab.main(["summarize", "--results", self.tmp,
                     "--sha", "b" * 40, "--repeats", "1",
                     "--target-loc", "100", "--seed", "7", "--ab", "off",
                     "--out", os.path.join(self.tmp, "x.json")])


class AbEndToEndTest(unittest.TestCase):
    """Both arms through the stand-in Bazel: order, isolation, parity."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ab-e2e-")
        self.bindir = os.path.join(self.tmp, "bin")
        os.makedirs(self.bindir)
        self.fake = os.path.join(self.bindir, "fake-bazel.py")
        with open(self.fake, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(FAKE_BAZEL)
        bazel = os.path.join(self.bindir, "bazel")
        with open(bazel, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("#!/bin/sh\n"
                     "out=\"\"\n"
                     "for a in \"$@\"; do\n"
                     "  case \"$a\" in\n"
                     "    --output_base=*) out=\"${a#--output_base=}\" ;;\n"
                     "  esac\n"
                     "done\n"
                     "case \"$out\" in\n"
                     "  \"$AB_OUT_TREATMENT\"/*) "
                     "work=\"$AB_WORK_TREATMENT\" ;;\n"
                     "  *) work=\"$AB_WORK_CONTROL\" ;;\n"
                     "esac\n"
                     "rep=$(basename \"$(dirname \"$out\")\")\n"
                     "SOL_SRC=\"$work/$rep/src.txt\"\n"
                     "export SOL_SRC\n"
                     "exec python3 \"$AB_FAKE\" \"$@\"\n")
        os.chmod(bazel, os.stat(bazel).st_mode
                 | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        self.tools = os.path.join(self.tmp, "tools")
        os.makedirs(self.tools)
        with open(os.path.join(self.tools, "gen_monorepo.py"), "w",
                  encoding="utf-8", newline="\n") as fh:
            fh.write(STUB_GEN)
        self.pristine_control = os.path.join(self.tmp, "pristine-control")
        self.pristine_treatment = os.path.join(
            self.tmp, "pristine-treatment")
        for pristine in (self.pristine_control, self.pristine_treatment):
            os.makedirs(pristine)
            with open(os.path.join(pristine, "src.txt"), "w",
                      encoding="utf-8", newline="\n") as fh:
                fh.write("v1\n")
        self.work_control = os.path.join(self.tmp, "work-control")
        self.work_treatment = os.path.join(self.tmp, "work-treatment")
        self.out_control = os.path.join(self.tmp, "out-control")
        self.out_treatment = os.path.join(self.tmp, "out-treatment")
        self.results = os.path.join(self.tmp, "results")
        self.env = {"PATH": self.bindir + os.pathsep + os.environ["PATH"],
                    "AB_FAKE": self.fake,
                    "AB_WORK_CONTROL": self.work_control,
                    "AB_WORK_TREATMENT": self.work_treatment,
                    "AB_OUT_CONTROL": self.out_control,
                    "AB_OUT_TREATMENT": self.out_treatment}

    def tearDown(self):
        for dirpath, _, filenames in os.walk(self.tmp):
            if (os.path.basename(dirpath) == "sol-server"
                    and "pid" in filenames):
                try:
                    with open(os.path.join(dirpath, "pid")) as fh:
                        pid = int(fh.read().strip())
                except (OSError, ValueError):
                    continue
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
        shutil.rmtree(self.tmp, ignore_errors=True)

    def live_server_pids(self):
        pids = []
        for dirpath, _, filenames in os.walk(self.tmp):
            if (os.path.basename(dirpath) == "sol-server"
                    and "pid" in filenames):
                try:
                    with open(os.path.join(dirpath, "pid")) as fh:
                        pid = int(fh.read().strip())
                except (OSError, ValueError):
                    continue
                try:
                    os.kill(pid, 0)
                except OSError:
                    continue
                pids.append(pid)
        return pids

    def run_argv(self):
        return ["run", "--tools", self.tools,
                "--pristine-control", self.pristine_control,
                "--pristine-treatment", self.pristine_treatment,
                "--work-root-control", self.work_control,
                "--work-root-treatment", self.work_treatment,
                "--out-base-root-control", self.out_control,
                "--out-base-root-treatment", self.out_treatment,
                "--results", self.results, "--repeats", "2",
                "--config", "device_release",
                "--min-clean-actions", "1",
                "--time-bin", os.path.join(self.tmp, "absent")]

    def test_both_arms_identical_alternating_isolated(self):
        import stat
        # A stale read-only tree where rep 1 will measure: the repeat
        # must start empty, not reuse it.
        stale = os.path.join(self.work_control, "rep1", "stale-dir")
        os.makedirs(stale)
        leaf = os.path.join(stale, "stale.txt")
        with open(leaf, "w", encoding="utf-8") as fh:
            fh.write("stale")
        os.chmod(leaf, stat.S_IRUSR)
        os.chmod(stale, stat.S_IRUSR | stat.S_IXUSR)
        out = os.path.join(self.tmp, "ios-ab.json")
        with mock.patch.dict(os.environ, self.env):
            self.assertEqual(ab.main(self.run_argv()), 0)
            self.assertEqual(ab.main(
                ["summarize", "--results", self.results,
                 "--sha", "b" * 40, "--repeats", "2",
                 "--target-loc", "100", "--seed", "7", "--ab", "flags",
                 "--bazel-flags=--jobs=8", "--lockfile", "none",
                 "--out", out]), 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        self.assertEqual(summary["meta"]["order"], arm_order(2))
        for flow in ("ios-release-clean", "ios-release-app",
                     "ios-release-body"):
            control = summary["arms"]["control"][flow]
            treatment = summary["arms"]["treatment"][flow]
            self.assertTrue(control["identical"], flow)
            self.assertTrue(treatment["identical"], flow)
            self.assertGreater(control["bazel"], 0.0, flow)
            self.assertGreater(treatment["bazel"], 0.0, flow)
            ratio = summary["ratio"][flow]
            self.assertEqual(ratio["n"], 2, flow)
            # Same work on the same runner: paired ratios hover near 1.
            self.assertAlmostEqual(ratio["median"], 1.0, delta=0.5,
                                   msg=flow)
            self.assertEqual(ratio["unpaired"], [], flow)
        # Per-arm output bases and servers: nothing shared, none left.
        self.assertNotEqual(self.out_control, self.out_treatment)
        self.assertTrue(os.path.isdir(
            os.path.join(self.results, "control", "sol")))
        self.assertTrue(os.path.isdir(
            os.path.join(self.results, "treatment", "sol")))
        # Every (arm, repeat) measured in its own fresh directories.
        for root in (self.work_control, self.work_treatment,
                     self.out_control, self.out_treatment):
            first = os.path.join(root, "rep1")
            second = os.path.join(root, "rep2")
            self.assertTrue(os.path.isdir(first), first)
            self.assertTrue(os.path.isdir(second), second)
            self.assertNotEqual(first, second)
        # The stale tree did not survive into the repeat's workspace.
        self.assertFalse(os.path.lexists(os.path.join(
            self.work_control, "rep1", "stale-dir")))
        self.assertEqual(self.live_server_pids(), [])
        # No workspace file shared: a marker in one arm is absent after.
        with open(os.path.join(
                self.pristine_control, "arm-marker.txt"), "w",
                encoding="utf-8") as fh:
            fh.write("control")
        self.assertFalse(os.path.exists(os.path.join(
            self.pristine_treatment, "arm-marker.txt")))


class PlatformAbEndToEndTest(AbEndToEndTest):
    """--platform web through the stand-in Bazel; default stays iOS."""

    test_both_arms_identical_alternating_isolated = None

    def run_argv(self):
        argv = super().run_argv()
        at = argv.index("--config")
        # No --config: the platform names the configs.
        return argv[:at] + ["--platform", "web"] + argv[at + 2:]

    def test_web_run_then_summarize_uses_web_flows(self):
        out = os.path.join(self.tmp, "web-ab.json")
        with mock.patch.dict(os.environ, self.env):
            self.assertEqual(ab.main(self.run_argv()), 0)
            self.assertEqual(ab.main(
                ["summarize", "--platform", "web",
                 "--results", self.results, "--sha", "b" * 40,
                 "--repeats", "2", "--target-loc", "100", "--seed", "7",
                 "--ab", "flags", "--bazel-flags=--jobs=8",
                 "--lockfile", "none", "--out", out]), 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        self.assertEqual(sorted(summary), [
            "arms", "meta", "ratio", "rules_flutter", "runner", "unit"])
        self.assertEqual(sorted(summary["meta"]), [
            "ab", "bazel_flags", "lockfile", "order", "repeats", "seed",
            "target_loc"])
        flows = {"web-%s-%s" % (cfg, name) for cfg in ("release", "debug")
                 for name in ("clean", "app", "body", "api")}
        self.assertEqual(set(summary["ratio"]), flows)
        for arm in ("control", "treatment"):
            self.assertEqual(set(summary["arms"][arm]), flows)
        for flow in ("web-release-clean", "web-release-app",
                     "web-release-body", "web-release-api"):
            self.assertTrue(summary["arms"]["control"][flow]["identical"])
            self.assertEqual(summary["ratio"][flow]["n"], 2, flow)
        self.assertEqual(self.live_server_pids(), [])


class PlatformSummaryTest(unittest.TestCase):
    """Platform plumbing: configs, flow ids and the default stay put."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ab-platform-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def test_platform_configs_come_from_sol_summary(self):
        self.assertEqual(ab.platform_configs("ios"), list(IOS_CONFIGS))
        self.assertEqual(ab.platform_configs("android"),
                         ["android_release", "android_debug"])
        self.assertEqual(ab.platform_configs("web"),
                         ["web_release", "web_debug"])
        with self.assertRaises(ValueError):
            ab.platform_configs("tvos")

    def test_arm_flows_per_platform_and_default_is_ios(self):
        self.assertEqual(set(summarize_arm_flows(self.tmp, "android")), {
            "android-release-clean", "android-release-app",
            "android-release-body", "android-debug-clean",
            "android-debug-app", "android-debug-body",
            "android-release-api", "android-debug-api"})
        self.assertEqual(summarize_arm_flows(self.tmp),
                         summarize_arm_flows(self.tmp, "ios"))

    def write(self, arm, config, scenario, flow, cpu):
        path = os.path.join(self.tmp, arm, "sol", config, scenario,
                            "rep1", "record.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        record = SummarizeAbTest.full_record(None, flow, cpu, 5.0)
        record["config"] = config
        record["scenario"] = scenario
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(record, fh)

    def test_android_summarize_writes_android_ab(self):
        for arm in ("control", "treatment"):
            self.write(arm, "android_release", "clean",
                       "android-release-clean", 10.0)
        out = os.path.join(self.tmp, "android-ab.json")
        code = ab.main(["summarize", "--platform", "android",
                        "--results", self.tmp, "--sha", "b" * 40,
                        "--repeats", "1", "--target-loc", "100",
                        "--seed", "7", "--ab", "flags",
                        "--bazel-flags=--jobs=8", "--lockfile", "none",
                        "--out", out])
        self.assertEqual(code, 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        self.assertEqual(summary["meta"]["bazel_flags"], ["--jobs=8"])
        self.assertEqual(len(summary["ratio"]), 8)
        self.assertEqual(summary["ratio"]["android-release-clean"]["n"], 1)
        self.assertEqual(summary["ratio"]["android-debug-clean"]["n"], 0)
        self.assertNotIn("ios-release-clean", summary["arms"]["control"])

    def test_run_defaults_to_the_platforms_configs(self):
        seen = []

        def fake_rep(_child, rep, configs):
            seen.append((rep, list(configs)))
            return None, False

        base = ["run", "--tools", self.tmp,
                "--pristine-control", self.tmp,
                "--pristine-treatment", self.tmp,
                "--work-root-control", os.path.join(self.tmp, "wc"),
                "--work-root-treatment", os.path.join(self.tmp, "wt"),
                "--out-base-root-control", os.path.join(self.tmp, "out-c"),
                "--out-base-root-treatment", os.path.join(self.tmp, "out-t"),
                "--results", self.tmp, "--repeats", "1"]
        for extra, expected in (
                ([], ["device_release", "sim_debug"]),
                (["--platform", "android"],
                 ["android_release", "android_debug"]),
                (["--platform", "web"], ["web_release", "web_debug"])):
            seen.clear()
            with mock.patch.object(sol, "run_sol_rep", fake_rep):
                self.assertEqual(ab.main(base + extra), 0)
            self.assertEqual(seen, [(1, expected), (1, expected)], extra)


class DefaultPathTest(unittest.TestCase):
    def test_sol_meta_defaults_to_lockfile_none(self):
        tmp = tempfile.mkdtemp(prefix="ab-default-")
        try:
            summary = sol.summarize_sol(
                tmp, {"sha": "a" * 40, "repeats": 1, "target_loc": 1,
                      "seed": 1})
            self.assertEqual(summary["meta"]["lockfile"], "none")
            self.assertEqual(summary["meta"]["bazel_flags"], [])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_sol_summarize_accepts_lockfile(self):
        tmp = tempfile.mkdtemp(prefix="ab-default-")
        try:
            out = os.path.join(tmp, "ios-sol.json")
            code = sol.main(["summarize", "--results", tmp,
                             "--sha", "a" * 40, "--repeats", "1",
                             "--target-loc", "100", "--seed", "7",
                             "--lockfile", "committed", "--out", out])
            self.assertEqual(code, 0)
            with open(out, encoding="utf-8") as fh:
                summary = json.load(fh)
            self.assertEqual(summary["meta"]["lockfile"], "committed")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_sol_summarize_rejects_bad_lockfile(self):
        tmp = tempfile.mkdtemp(prefix="ab-default-")
        try:
            with self.assertRaises(ValueError):
                sol.main(["summarize", "--results", tmp,
                          "--sha", "a" * 40, "--repeats", "1",
                          "--target-loc", "100", "--seed", "7",
                          "--lockfile", "nope",
                          "--out", os.path.join(tmp, "x.json")])
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

    def input_names(self):
        import re
        return re.findall(r"^      ([a-z_]+):", self.text(),
                          flags=re.MULTILINE)

    def test_inputs_stay_at_most_ten(self):
        names = self.input_names()
        self.assertIn("lockfile", names)
        self.assertIn("ab", names)
        self.assertLessEqual(len(names), 10)

    def test_lockfile_and_ab_choices(self):
        text = self.text()
        self.assertIn("lockfile:", text)
        self.assertIn("ab:", text)
        self.assertRegex(text, r"lockfile:\n(\s+\S.*\n)+?.*default: none")
        self.assertIn("committed", text)
        self.assertRegex(text, r'ab:\n(\s+\S.*\n)+?.*default: "off"')
        self.assertRegex(text, r'options: \["off", flags, lockfile\]')
        self.assertIn("lockfile", text)

    def test_ab_validation_and_lock_step(self):
        text = self.text()
        self.assertIn("ab.py", text)
        self.assertIn("validate", text)
        self.assertIn("ios-ab.json", text)
        self.assertIn("ios-ab", text)

    def test_ab_off_still_writes_ios_sol(self):
        text = self.text()
        self.assertIn("ios-sol.json", text)
        self.assertIn("name: ios-sol", text)

    def test_profile_keeps_both_arms(self):
        text = self.text()
        self.assertIn("control", text)
        self.assertIn("treatment", text)


class IosScopeTest(unittest.TestCase):
    """The A/B bench keeps its iOS-only scope when SOL gains platforms."""

    def test_ab_flow_set_stays_ios(self):
        tmp = tempfile.mkdtemp(prefix="ab-ios-")
        self.addCleanup(shutil.rmtree, tmp, True)
        flows = summarize_arm_flows(tmp)
        self.assertEqual(set(flows), {
            "ios-release-clean", "ios-release-app", "ios-release-body",
            "ios-debug-clean", "ios-debug-app", "ios-debug-body",
            "ios-release-api", "ios-debug-api",
        })

    def test_lock_builds_only_the_ios_configs(self):
        # CONFIG_ORDER carries the Android and Web SOL benches; the A/B
        # lock build and ios-ab.json stay on the two iOS configurations.
        self.assertEqual(len(CONFIG_ORDER), 6)
        self.assertEqual(list(IOS_CONFIGS), ["device_release", "sim_debug"])
        targets = {lock_build_argv("/lock", config)[-2]
                   for config in IOS_CONFIGS}
        self.assertEqual(targets, {"//app:__app_framework_framework",
                                   "//app:app_ios"})


from sol_ab_ratio_test import WallRssRatioTest  # noqa: E402,F401


if __name__ == "__main__":
    unittest.main()
