#!/usr/bin/env python3
"""Tests for `gen_monorepo.py generate --packages/--plugins` (no Bazel)."""

import contextlib
import hashlib
import io
import json
import os
import re
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gen_monorepo
import gen_plugins
from gen_monorepo_test import tree_hash
from gen_scale_args import layers_and_fanout

# Digest of the base generator's output for BASE_ARGS (empty rules dir),
# MODULE.bazel left out because it names the temporary rules directory.
BASE_HASH = "36b699ac98ffc7855ddb3f5332322da3fd64f4762866d0d65ffeb7d4a5d5e42a"
BASE_ARGS = ["--target-loc", "20000", "--layers", "4", "--fanout", "2",
             "--files-per-package", "8", "--seed", "7"]


def stable_hash(root):
    """sha256 over every file but MODULE.bazel, paths included."""
    digest = hashlib.sha256()
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            if os.path.relpath(full, root) == "MODULE.bazel":
                continue
            digest.update(os.path.relpath(full, root).encode() + b"\0")
            with open(full, "rb") as fh:
                digest.update(fh.read() + b"\0")
    return digest.hexdigest()


class GenerateCase(unittest.TestCase):
    """Runs the real CLI into temporary directories."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="gen-scale-test-")
        self.rules = os.path.join(self.tmp, "rules")
        os.makedirs(self.rules)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def generate(self, name, *flags):
        out = os.path.join(self.tmp, name)
        with contextlib.redirect_stdout(io.StringIO()):
            code = gen_monorepo.main(
                ["generate", "--rules-flutter", self.rules, "--out", out]
                + list(flags))
        self.assertEqual(code, 0)
        return out

    def refused(self, *flags):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), \
                self.assertRaises(SystemExit) as caught:
            gen_monorepo.main(
                ["generate", "--rules-flutter", self.rules, "--out",
                 os.path.join(self.tmp, "refused")] + list(flags))
        self.assertEqual(caught.exception.code, 2)
        self.assertNotEqual(err.getvalue().strip(), "")
        return err.getvalue()

    def read(self, root, rel):
        with open(os.path.join(root, rel), encoding="utf-8") as fh:
            return fh.read()


class PackagesTest(GenerateCase):
    def count(self, root):
        return len(os.listdir(os.path.join(root, "packages")))

    def test_exact_package_counts(self):
        for n in (2, 3, 7, 200, 2000):
            with self.subTest(packages=n):
                root = self.generate(
                    "p%d" % n, "--packages", str(n), "--files-per-package",
                    "1")
                self.assertEqual(self.count(root), n)
                stats = json.loads(self.read(
                    root, "bench-workspace-stats.json"))
                self.assertEqual(stats["packages"], n)

    def test_layers_times_fanout_covers_packages(self):
        for n in (2, 3, 4, 5, 31, 200, 2000):
            layers, fanout = layers_and_fanout(n)
            self.assertGreaterEqual(layers * fanout, n)
            self.assertGreaterEqual(layers, 2)

    def test_refusals_exit_2(self):
        self.refused("--packages=0")
        self.refused("--packages=1")
        self.refused("--packages=-5")
        self.refused("--packages=10", "--layers=3")
        self.refused("--packages=10", "--fanout=3")
        self.refused("--target-loc=20000", "--plugins=-1")
        self.refused("--plugins=2")

    def test_output_without_new_flags_is_unchanged(self):
        root = self.generate("base", *BASE_ARGS)
        self.assertEqual(stable_hash(root), BASE_HASH)
        self.assertFalse(os.path.exists(os.path.join(root, "plugins")))
        explicit = self.generate("zero", *BASE_ARGS, "--plugins=0")
        self.assertEqual(stable_hash(explicit), BASE_HASH)


class PluginsTest(GenerateCase):
    FLAGS = ("--packages=6", "--files-per-package=1")

    def plugin_dirs(self, root):
        base = os.path.join(root, "plugins")
        return sorted(d for d in os.listdir(base) if d.startswith("bench"))

    def kinds(self, root):
        found = set()
        for name in self.plugin_dirs(root):
            files = []
            for dirpath, _, names in os.walk(
                    os.path.join(root, "plugins", name)):
                files += [os.path.join(dirpath, n) for n in names]
            joined = " ".join(files)
            if "Package.swift" in joined:
                found.add("swiftpm")
            elif "build.gradle" in joined:
                found.add("maven")
            elif ".podspec" in joined:
                found.add("source")
        return found

    def test_thirty_plugins_of_all_three_kinds(self):
        root = self.generate("p30", *self.FLAGS, "--plugins=30")
        self.assertEqual(len(self.plugin_dirs(root)), 30)
        self.assertEqual(self.kinds(root), {"source", "swiftpm", "maven"})
        app = self.read(root, "app/BUILD.bazel")
        for i in range(30):
            self.assertEqual(
                app.count('"@deps//:benchplugin%d"' % i), 3)
        stats = json.loads(self.read(root, "bench-workspace-stats.json"))
        self.assertEqual(stats["plugins"], 30)
        self.assertEqual(sum(stats["kinds"].values()), 30)

    def test_every_kind_from_three_plugins(self):
        for seed in ("1", "2", "99"):
            root = self.generate("s" + seed, *self.FLAGS, "--plugins=3",
                                 "--seed", seed)
            self.assertEqual(self.kinds(root),
                             {"source", "swiftpm", "maven"})

    def test_maven_coordinates_are_sha256_pinned(self):
        root = self.generate("m", *self.FLAGS, "--plugins=30")
        pins = json.loads(self.read(root, gen_plugins.MAVEN_PINS_REL))
        self.assertTrue(pins)
        by_coordinate = {p["coordinate"]: p["sha256"] for p in pins.values()}
        seen = 0
        for name in self.plugin_dirs(root):
            gradle = os.path.join(root, "plugins", name, "android",
                                  "build.gradle")
            if not os.path.isfile(gradle):
                continue
            for coordinate in re.findall(
                    r"implementation '([^']+)'", self.read(root, gradle)):
                seen += 1
                self.assertRegex(by_coordinate[coordinate],
                                 gen_plugins.SHA256_RE)
        self.assertGreater(seen, 0)

    def test_swiftpm_pins_are_recorded_and_checksummed(self):
        root = self.generate("s", *self.FLAGS, "--plugins=30")
        resolved = json.loads(self.read(root, "plugins/swiftpm/Package.resolved"))
        module = self.read(root, "MODULE.bazel")
        self.assertIn("swift_package_sha256", module)
        for pin in resolved["pins"]:
            self.assertRegex(pin["state"]["revision"], r"^[0-9a-f]{40}$")
            self.assertIn('"%s": "' % pin["identity"], module)
        for sha in re.findall(r'"[a-z-]+": "([0-9a-f]{64})"', module):
            self.assertRegex(sha, gen_plugins.SHA256_RE)

    def test_declared_in_the_pub_files(self):
        root = self.generate("l", *self.FLAGS, "--plugins=4")
        self.assertIn("path: plugins/benchplugin3",
                      self.read(root, "pubspec.lock"))
        self.assertIn("benchplugin0:", self.read(root, "pubspec.yaml"))

    def test_equal_seeds_equal_trees_and_seeds_differ(self):
        a = self.generate("a", *self.FLAGS, "--plugins=12", "--seed=5")
        b = self.generate("b", *self.FLAGS, "--plugins=12", "--seed=5")
        c = self.generate("c", *self.FLAGS, "--plugins=12", "--seed=6")
        self.assertEqual(tree_hash(a), tree_hash(b))
        self.assertNotEqual(tree_hash(a), tree_hash(c))

    def test_wrong_maven_checksum_is_refused(self):
        pins = {"androidx.core:core:aar": {
            "coordinate": "androidx.core:core:1.17.0", "sha256": "0" * 64}}
        install = json.dumps({"artifacts": {"androidx.core:core:aar": {
            "shasums": {"jar": "1" * 64}, "version": "1.17.0"}}})
        with self.assertRaises(ValueError):
            gen_plugins.verify_maven_pins(install, pins)
        with self.assertRaises(ValueError):
            gen_plugins.verify_maven_pins("{}", pins)
        pins["androidx.core:core:aar"]["sha256"] = "1" * 64
        gen_plugins.verify_maven_pins(install, pins)


if __name__ == "__main__":
    unittest.main()
