#!/usr/bin/env python3
"""Offline tests for android_overlay_phases.py with a fake executable."""

import io
import json
import os
import stat
import sys
import tempfile
import unittest
import zipfile
from contextlib import redirect_stderr, redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import android_overlay_phases as ph

FAKE = """#!/usr/bin/env python3
import sys, os
log = sys.argv[0] + ".log"
with open(log, "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\\n")
fail = os.path.exists(sys.argv[0] + ".fail")
if fail and "tiny" not in sys.argv[sys.argv.index("--base") + 1]:
    sys.stderr.write("boom")
    sys.exit(3)
"""
SMALL = [
    "--runs", "5", "--tiny-base-kib", "1", "--base-kib", "300",
    "--kernel-kib", "4", "--asset-files", "3", "--asset-kib", "2",
    "--so-count", "2", "--so-kib", "3",
]


def make_fake(tmp):
    path = os.path.join(tmp, "fake_bundle")
    with open(path, "w") as f:
        f.write(FAKE)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
    return path


class GeneratorTest(unittest.TestCase):
    def test_base_apk_is_zip_of_requested_size(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = os.path.join(tmp, "b.apk")
            ph.write_base_apk(p, 5000)
            with zipfile.ZipFile(p) as zf:
                self.assertIsNone(zf.testzip())
                total = sum(i.file_size for i in zf.infolist())
            self.assertGreaterEqual(total, 5000 * 1024)
            self.assertLess(total, 5000 * 1024 + 1024)

    def test_jar_has_stored_so_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = os.path.join(tmp, "l.jar")
            ph.write_native_libs_jar(p, 2, 3)
            with zipfile.ZipFile(p) as zf:
                infos = zf.infolist()
            self.assertEqual(len(infos), 2)
            for i in infos:
                self.assertTrue(i.filename.endswith(".so"))
                self.assertEqual(i.compress_type, zipfile.ZIP_STORED)
                self.assertEqual(i.file_size, 3 * 1024)

    def test_assets_sizes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "a")
            ph.write_assets(root, 4, 3, 2)
            self.assertEqual(os.path.getsize(root + "/kernel_blob.bin"), 4096)
            self.assertEqual(len(os.listdir(root)), 4)
            self.assertEqual(os.path.getsize(root + "/asset000.json"), 2048)


class RunTest(unittest.TestCase):
    def test_argv_median_and_arms(self):
        with tempfile.TemporaryDirectory() as tmp:
            exe = make_fake(tmp)
            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                rc = ph.main([exe] + SMALL)
            self.assertEqual(rc, 0, err.getvalue())
            with open(exe + ".log") as f:
                calls = [line.split() for line in f]
            self.assertEqual(len(calls), 20)
            for i, call in enumerate(calls):
                self.assertEqual(call[0], "apk-overlay")
                self.assertEqual(
                    [a for a in call if a.startswith("--")],
                    ["--base", "--native-libs-jar", "--flutter-assets",
                     "--output", "--debug"],
                )
                arm = i // 5
                self.assertEqual("tiny" in call[2], arm == 0)
                self.assertEqual("libs" in call[4], arm == 3)
                self.assertEqual(call[6].endswith("assets"), arm >= 2)
            data = json.loads(out.getvalue().split("\n\n")[0])
            self.assertEqual(list(data["median_wall_s"]), list(ph.ARMS))
            self.assertEqual(data["params"]["runs"], 5)
            self.assertIn("| arm | median wall (s) |", out.getvalue())

    def test_median_of_five(self):
        times = iter([0, 5, 0, 1, 0, 9, 0, 2, 0, 3])
        orig = ph.time.perf_counter
        ph.time.perf_counter = lambda: next(times)
        try:
            self.assertEqual(ph.median_wall([sys.executable, "-c", ""], "x", 5), 3)
        finally:
            ph.time.perf_counter = orig

    def test_nonzero_exit_names_arm(self):
        with tempfile.TemporaryDirectory() as tmp:
            exe = make_fake(tmp)
            open(exe + ".fail", "w").close()
            out, err = io.StringIO(), io.StringIO()
            with redirect_stdout(out), redirect_stderr(err):
                rc = ph.main([exe] + SMALL)
            self.assertEqual(rc, 1)
            self.assertIn(ph.ARMS[1], err.getvalue())
            self.assertIn("exited 3", err.getvalue())


if __name__ == "__main__":
    unittest.main()
