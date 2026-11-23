#!/usr/bin/env python3
"""Unit tests for android_pack_steps.py on synthetic traces."""

import contextlib
import gzip
import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import android_pack_steps as aps

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                    "testdata", "android_pack_steps")


def fixture(name):
    return os.path.join(DATA, name)


def action(mnemonic, dur_us, **args):
    return {"cat": "action processing", "name": mnemonic, "ph": "X",
            "ts": 0, "dur": dur_us, "args": dict(mnemonic=mnemonic, **args)}


def write_trace(path, steps, wall_s):
    """Gzip trace with the (mnemonic, seconds) steps and a flow wall."""
    events = [{"cat": "build phase marker", "name": "Initialize command",
               "ph": "i", "ts": 0},
              {"cat": "build phase marker", "name": "Complete build",
               "ph": "i", "ts": int(wall_s * 1e6)}]
    events += [action(m, int(s * 1e6)) for m, s in steps]
    with gzip.open(path, "wt") as fh:
        json.dump({"traceEvents": events}, fh)
    return path


class FlowTest(unittest.TestCase):
    def report(self, names, **kw):
        return aps.build_report(["f=" + fixture(n) for n in names], **kw)

    def test_medians_over_two_reps(self):
        flow = self.report(["full_rep1.json", "full_rep2.json"])["flows"][0]
        full = flow["groups"]["full"]
        self.assertEqual(flow["traces"], 2)
        self.assertAlmostEqual(full["overlay"]["median_s"], 1.2)
        self.assertAlmostEqual(full["zipalign"]["median_s"], 0.4)
        self.assertAlmostEqual(full["sign"]["median_s"], 1.0)
        self.assertAlmostEqual(full["kernel_compile"]["median_s"], 2.0)
        self.assertAlmostEqual(full["kernel_link"]["median_s"], 0.5)

    def test_share_arithmetic(self):
        flow = self.report(["full_rep1.json", "full_rep2.json"])["flows"][0]
        self.assertAlmostEqual(flow["wall_s"], 11.0)
        self.assertEqual(flow["wall_source"], "phase_markers")
        full = flow["groups"]["full"]
        self.assertAlmostEqual(full["overlay"]["share_of_flow"], 1.2 / 11, places=5)
        self.assertAlmostEqual(full["sign"]["share_of_flow"], 1.0 / 11, places=5)

    def test_base_payload_split(self):
        flow = self.report(["split.json"])["flows"][0]
        self.assertEqual(sorted(flow["groups"]), ["base", "full", "payload"])
        self.assertEqual(sorted(flow["groups"]["full"]),
                         ["kernel_compile", "kernel_link"])
        base, payload = flow["groups"]["base"], flow["groups"]["payload"]
        self.assertEqual(flow["primary_group"], "base")
        self.assertEqual(sorted(flow["candidates_by_group"]),
                         ["base", "payload"])
        self.assertAlmostEqual(base["overlay"]["median_s"], 0.1)
        self.assertAlmostEqual(payload["overlay"]["median_s"], 0.4)
        self.assertAlmostEqual(base["zipalign"]["median_s"], 0.05)
        self.assertAlmostEqual(payload["zipalign"]["median_s"], 0.15)
        self.assertAlmostEqual(base["sign"]["median_s"], 0.2)
        self.assertAlmostEqual(payload["sign"]["median_s"], 0.6)

    def test_wall_falls_back_to_action_span(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "t.json")
            with open(path, "w") as fh:
                json.dump([action("ApkSignerTool", 2_000_000)], fh)
            m = aps.measure_trace(path)
        self.assertEqual(m["wall_source"], "action_span")
        self.assertAlmostEqual(m["wall"], 2.0)


class CandidateTest(unittest.TestCase):
    def candidates(self, overlay, zipalign, sign, wall, floor=None):
        with tempfile.TemporaryDirectory() as tmp:
            path = write_trace(os.path.join(tmp, "t.json.gz"),
                               [("FlutterApkOverlay", overlay),
                                ("AndroidZipAlign", zipalign),
                                ("ApkSignerTool", sign)], wall)
            flow = aps.flow_report("f", [path], None, floor)
        return {c["candidate"]: c for c in flow["candidates"]}, flow

    def test_bounds_and_ranking(self):
        cands, flow = self.candidates(2.0, 1.0, 4.0, 100.0)
        self.assertAlmostEqual(cands["persistent_signing"]["seconds"], 4.0)
        self.assertAlmostEqual(cands["skip_zipalign"]["seconds"], 1.0)
        self.assertAlmostEqual(cands["reuse_payload_entries"]["seconds"], 2.0)
        self.assertAlmostEqual(
            cands["persistent_signing"]["percent_of_flow"], 4.0)
        names = [c["candidate"] for c in flow["candidates"]]
        self.assertEqual(names, ["persistent_signing",
                                 "reuse_payload_entries", "skip_zipalign"])

    def test_ten_percent_line(self):
        below, _ = self.candidates(1.0, 1.0, 9.9, 100.0)
        self.assertEqual(below["persistent_signing"]["verdict"],
                         "close_with_numbers")
        at, _ = self.candidates(1.0, 1.0, 10.0, 100.0)
        self.assertEqual(at["persistent_signing"]["verdict"], "later_item")
        above, _ = self.candidates(10.5, 1.0, 1.0, 100.0)
        self.assertEqual(above["reuse_payload_entries"]["verdict"],
                         "later_item")
        self.assertEqual(above["skip_zipalign"]["verdict"],
                         "close_with_numbers")

    def test_floor_lowers_sign_bound(self):
        cands, flow = self.candidates(1.0, 1.0, 12.0, 100.0, floor=3.0)
        self.assertAlmostEqual(cands["persistent_signing"]["seconds"], 9.0)
        self.assertEqual(cands["persistent_signing"]["verdict"],
                         "close_with_numbers")
        sign = flow["groups"]["full"]["sign"]
        self.assertAlmostEqual(sign["jvm_start_s"], 3.0)
        self.assertAlmostEqual(sign["signing_work_s"], 9.0)


class OptionalFieldsTest(unittest.TestCase):
    def test_absent_without_options(self):
        report = aps.build_report([fixture("full_rep1.json")])
        self.assertNotIn("jvm_floor_s", report)
        sign = report["flows"][0]["groups"]["full"]["sign"]
        self.assertNotIn("apk_bytes", sign)
        self.assertNotIn("jvm_start_s", sign)

    def test_apk_sizes(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name, size in (("app_unsigned.apk", 10),
                               ("zipaligned_app.apk", 20), ("app.apk", 30),
                               ("app_payload_unsigned.apk", 1)):
                with open(os.path.join(tmp, name), "wb") as fh:
                    fh.write(b"x" * size)
            report = aps.build_report([fixture("full_rep1.json")],
                                      apk_dir=tmp)
        full = report["flows"][0]["groups"]["full"]
        self.assertEqual(full["overlay"]["apk_bytes"], 10)
        self.assertEqual(full["zipalign"]["apk_bytes"], 20)
        self.assertEqual(full["sign"]["apk_bytes"], 30)

    def test_split_apk_sizes_and_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            with open(os.path.join(tmp, "app_payload.apk"), "wb") as fh:
                fh.write(b"x" * 7)
            report = aps.build_report([fixture("split.json")], apk_dir=tmp)
        groups = report["flows"][0]["groups"]
        self.assertEqual(groups["payload"]["sign"]["apk_bytes"], 7)
        self.assertIsNone(groups["base"]["sign"]["apk_bytes"])

    def test_jvm_floor_is_median_of_five(self):
        ticks = iter([0, 5, 10, 12, 20, 21, 30, 39, 40, 41])
        calls = []

        def runner(argv, **_kw):
            calls.append(argv)
            return type("R", (), {"returncode": 0})()

        floor = aps.jvm_floor("/x/apksigner", runner=runner,
                              clock=lambda: next(ticks))
        self.assertEqual(floor, 2)  # walls 5, 2, 1, 9, 1
        self.assertEqual(len(calls), 5)
        self.assertEqual(calls[0], ["/x/apksigner", "--version"])

    def test_jvm_floor_failure_is_named(self):
        def runner(argv, **_kw):
            return type("R", (), {"returncode": 3})()

        with self.assertRaises(aps.PackStepsError) as ctx:
            aps.jvm_floor("/x/apksigner", runner=runner)
        self.assertIn("/x/apksigner", str(ctx.exception))


class ProgressMessageTest(unittest.TestCase):
    MESSAGES = (
        "Injecting Flutter payload into base APK @@//app:o",
        "Zipaligning APK with Flutter payload @@//app:o",
        "Signing APK with Flutter payload @@//app:o")

    def trace(self, tmp, with_mnemonic):
        events = []
        for message, mnemonic, dur in zip(
                self.MESSAGES,
                ("FlutterApkOverlay", "AndroidZipAlign", "ApkSignerTool"),
                (1000000, 300000, 900000)):
            args = {"mnemonic": mnemonic} if with_mnemonic else {}
            events.append({"cat": "action processing", "name": message,
                           "ph": "X", "ts": 0, "dur": dur, "args": args})
        path = os.path.join(tmp, "t.json")
        with open(path, "w") as fh:
            json.dump({"traceEvents": events}, fh)
        return path

    def test_message_only_matches_each_step(self):
        with tempfile.TemporaryDirectory() as tmp:
            flow = aps.build_report([self.trace(tmp, False)])["flows"][0]
        full = flow["groups"]["full"]
        self.assertAlmostEqual(full["overlay"]["median_s"], 1.0)
        self.assertAlmostEqual(full["zipalign"]["median_s"], 0.3)
        self.assertAlmostEqual(full["sign"]["median_s"], 0.9)

    def test_both_fields_do_not_double_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            both = aps.build_report([self.trace(tmp, True)])["flows"][0]
            only = aps.build_report([self.trace(tmp, False)])["flows"][0]
        self.assertEqual(both["groups"], only["groups"])


class ErrorTest(unittest.TestCase):
    def run_main(self, args):
        err = io.StringIO()
        out = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
            code = aps.main(args)
        return code, out.getvalue(), err.getvalue()

    def test_no_packaging_step_names_trace(self):
        path = fixture("no_packaging.json")
        code, out, err = self.run_main([path])
        self.assertEqual(code, 2)
        self.assertEqual(out, "")
        self.assertIn(path, err)

    def test_unreadable_trace_names_trace(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "bad.json")
            with open(path, "w") as fh:
                fh.write("not json")
            code, _out, err = self.run_main([path])
        self.assertEqual(code, 2)
        self.assertIn(path, err)

    def test_missing_trace_names_trace(self):
        code, _out, err = self.run_main(["/nonexistent/t.json.gz"])
        self.assertEqual(code, 2)
        self.assertIn("/nonexistent/t.json.gz", err)

    def test_cli_json_and_markdown(self):
        code, out, _err = self.run_main(
            ["--format", "json", "f=" + fixture("full_rep1.json")])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["flows"][0]["flow"], "f")
        code, out, _err = self.run_main(
            ["--format", "markdown", "f=" + fixture("full_rep1.json")])
        self.assertIn("| full | sign |", out)
        self.assertIn("later_item", out)


if __name__ == "__main__":
    unittest.main()
