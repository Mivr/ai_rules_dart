#!/usr/bin/env python3
"""Phase breakdown of the ``apk-overlay`` action of ``android_bundle``.

Given a built ``android_bundle`` executable, generates a synthetic unsigned
base APK and payload in a temporary directory and runs ``apk-overlay`` several
times per arm. Prints the median wall time of each arm as JSON and markdown.

Arms:
  1. tiny base, kernel-only payload (the process floor);
  2. full-size base, kernel-only payload (adds reading and writing the base);
  3. as 2 plus compressible ``flutter_assets`` (adds deflating assets);
  4. as 3 plus a native-libs jar of stored ``.so`` entries.

Every arm passes a native-libs jar (the base shape requires one); arms 1-3
use an empty jar. Only the Python 3 standard library is used. Nothing is read
from the environment, and files are written only under the temp directory.
"""

import argparse
import json
import os
import random
import statistics
import subprocess
import sys
import tempfile
import time
import zipfile

ARMS = (
    "1 tiny base, kernel only",
    "2 full base, kernel only",
    "3 full base, kernel + assets",
    "4 full base, kernel + assets + native libs",
)
KIB = 1024
ENTRY_KIB = 4096


class ArmError(RuntimeError):
    """An apk-overlay run failed; the message names the arm."""


def _blob(seed, size):
    return random.Random(seed).randbytes(size)


def write_base_apk(path, size_kib):
    """Write an unsigned APK-like zip of stored random entries (~size_kib)."""
    remaining = size_kib * KIB
    index = 0
    with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as zf:
        zf.writestr("AndroidManifest.xml", b"<manifest/>")
        while remaining > 0:
            chunk = min(remaining, ENTRY_KIB * KIB)
            zf.writestr("res/blob%d.bin" % index, _blob(index, chunk))
            remaining -= chunk
            index += 1
        if index == 0:
            zf.writestr("classes.dex", b"dex\n035\0")


def write_native_libs_jar(path, so_count, so_kib):
    """Write a jar of ``so_count`` stored ``lib/arm64-v8a/*.so`` entries."""
    with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as zf:
        for i in range(so_count):
            name = "lib/arm64-v8a/libsynthetic%d.so" % i
            zf.writestr(name, _blob(1000 + i, so_kib * KIB))


def write_assets(root, kernel_kib, files, file_kib):
    """Write kernel_blob.bin and ``files`` compressible text assets."""
    os.makedirs(root)
    with open(os.path.join(root, "kernel_blob.bin"), "wb") as f:
        f.write(_blob(7, kernel_kib * KIB))
    line = b"synthetic flutter asset line, compressible text %05d\n"
    for i in range(files):
        body = b"".join(line % (i + n) for n in range(file_kib * KIB // 54 + 1))
        with open(os.path.join(root, "asset%03d.json" % i), "wb") as f:
            f.write(body[: file_kib * KIB])


def arm_argv(exe, base, jar, assets, output):
    """The argv of one apk-overlay run."""
    return [
        exe,
        "apk-overlay",
        "--base",
        base,
        "--native-libs-jar",
        jar,
        "--flutter-assets",
        assets,
        "--output",
        output,
        "--debug",
    ]


def median_wall(argv, name, runs):
    """Median wall seconds of ``runs`` executions of argv."""
    walls = []
    for _ in range(runs):
        start = time.perf_counter()
        proc = subprocess.run(argv, capture_output=True, text=True, check=False)
        walls.append(time.perf_counter() - start)
        if proc.returncode != 0:
            raise ArmError(
                "arm %r exited %d: %s"
                % (name, proc.returncode, proc.stderr.strip()[-400:])
            )
    return statistics.median(walls)


def build_inputs(tmp, args):
    """Generate every input file; returns a dict of paths."""
    paths = {k: os.path.join(tmp, k) for k in (
        "tiny.apk", "full.apk", "empty.jar", "libs.jar", "kernel", "assets",
    )}
    write_base_apk(paths["tiny.apk"], args.tiny_base_kib)
    write_base_apk(paths["full.apk"], args.base_kib)
    write_native_libs_jar(paths["empty.jar"], 0, 0)
    write_native_libs_jar(paths["libs.jar"], args.so_count, args.so_kib)
    write_assets(paths["kernel"], args.kernel_kib, 0, 0)
    write_assets(paths["assets"], args.kernel_kib, args.asset_files, args.asset_kib)
    return paths


def run_arms(exe, args, tmp):
    """Median wall seconds per arm, in ARMS order."""
    p = build_inputs(tmp, args)
    out = os.path.join(tmp, "out.apk")
    plans = (
        (p["tiny.apk"], p["empty.jar"], p["kernel"]),
        (p["full.apk"], p["empty.jar"], p["kernel"]),
        (p["full.apk"], p["empty.jar"], p["assets"]),
        (p["full.apk"], p["libs.jar"], p["assets"]),
    )
    return [
        median_wall(arm_argv(exe, b, j, a, out), name, args.runs)
        for name, (b, j, a) in zip(ARMS, plans)
    ]


def to_markdown(medians, params):
    """Markdown: parameters, then arm / median wall (s) / delta (s)."""
    lines = ["Size flags: " + ", ".join("%s=%s" % kv for kv in params.items()), ""]
    lines.append("| arm | median wall (s) | added over previous arm (s) |")
    lines.append("| --- | --- | --- |")
    prev = None
    for name, wall in zip(ARMS, medians):
        added = "-" if prev is None else "%.3f" % (wall - prev)
        lines.append("| %s | %.3f | %s |" % (name, wall, added))
        prev = wall
    return "\n".join(lines)


def parse_args(argv):
    """Parse the command line; defaults are echoed in the output."""
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("executable", help="built android_bundle executable")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--tiny-base-kib", type=int, default=16)
    ap.add_argument("--base-kib", type=int, default=65536)
    ap.add_argument("--kernel-kib", type=int, default=16384)
    ap.add_argument("--asset-files", type=int, default=40)
    ap.add_argument("--asset-kib", type=int, default=256)
    ap.add_argument("--so-count", type=int, default=3)
    ap.add_argument("--so-kib", type=int, default=8192)
    return ap.parse_args(argv)


def main(argv=None):
    """Run the four arms and print JSON then markdown."""
    args = parse_args(sys.argv[1:] if argv is None else argv)
    params = {k: v for k, v in vars(args).items() if k != "executable"}
    with tempfile.TemporaryDirectory(prefix="overlay_phases_") as tmp:
        try:
            medians = run_arms(args.executable, args, tmp)
        except ArmError as err:
            print("error: %s" % err, file=sys.stderr)
            return 1
    result = {
        "params": params,
        "median_wall_s": dict(zip(ARMS, medians)),
    }
    print(json.dumps(result, indent=2))
    print()
    print(to_markdown(medians, params))
    return 0


if __name__ == "__main__":
    sys.exit(main())
