#!/usr/bin/env python3
"""Unit tests for gen_monorepo.py (run: python3 -m unittest discover -s tools/perf)."""

import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import gen_monorepo
from gen_monorepo import (
    Options,
    SplitMix64,
    _LibSpec,
    _apply_pin_replacement,
    _check_fixture_text,
    _lib_class_lines,
    _lib_import_lines,
    _lib_method_lines,
    _package_build_text,
    _package_test_build_text,
    _PinReplacement,
    _write_package_builds,
    _write_root_files,
    _ScaffoldFiles,
    apply_api_edit,
    apply_app_edit,
    apply_body_edit,
    bazelrc_text,
    build_dag,
    fan_in_counts,
    generate_flutter_monorepo,
    lib_skeleton_lines,
    method_count_range,
    module_bazel_text,
    pad_file,
    render_lib_file,
)
from gen_pub import (
    copy_pub_files,
    strip_lock_path_packages,
    strip_pubspec_path_deps,
)


def small_opts(**kwargs):
    params = {
        "target_loc": 20000,
        "layers": 4,
        "fanout": 2,
        "files_per_package": 8,
        "seed": 7,
        "test_ratio": 0.0,
        "edit_layer": 0,
    }
    params.update(kwargs)
    return Options(**params)


def tree_hash(root):
    digest = hashlib.sha256()
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            digest.update(os.path.relpath(full, root).encode())
            digest.update(b"\0")
            with open(full, "rb") as fh:
                digest.update(fh.read())
            digest.update(b"\0")
    return digest.hexdigest()


def count_dart_lines(root):
    total = 0
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            if name.endswith(".dart"):
                with open(os.path.join(dirpath, name), encoding="utf-8") as fh:
                    total += fh.read().count("\n")
    return total


class SplitMix64Test(unittest.TestCase):
    def test_deterministic_stream(self):
        a = SplitMix64(12345)
        b = SplitMix64(12345)
        self.assertEqual([a.next() for _ in range(10)],
                         [b.next() for _ in range(10)])

    def test_different_seeds_differ(self):
        a = SplitMix64(1)
        b = SplitMix64(2)
        self.assertNotEqual([a.next() for _ in range(5)],
                            [b.next() for _ in range(5)])

    def test_64bit_wrapping(self):
        rng = SplitMix64((1 << 64) - 1)
        for _ in range(100):
            self.assertLess(rng.next(), 1 << 64)

    def test_below_range(self):
        rng = SplitMix64(99)
        for _ in range(200):
            self.assertLess(rng.below(7), 7)
        with self.assertRaises(ValueError):
            rng.below(0)


class DagTest(unittest.TestCase):
    def test_acyclic_layered_fanout(self):
        dag = build_dag(20, 4, 3, 11)
        self.assertEqual(len(dag["deps"]), 20)
        for layer_idx, members in enumerate(dag["layers"]):
            lower = {p for lower in dag["layers"][:layer_idx] for p in lower}
            for pkg in members:
                self.assertEqual(dag["layer_of"][pkg], layer_idx)
                for dep in dag["deps"][pkg]:
                    self.assertIn(dep, lower)
                # Fanout floor from the seeded pass; orphan repair (v2) may
                # add edges above it so every package stays reachable.
                self.assertGreaterEqual(
                    len(dag["deps"][pkg]), min(3, len(lower)))
                self.assertEqual(dag["deps"][pkg], sorted(dag["deps"][pkg]))
                self.assertEqual(len(set(dag["deps"][pkg])),
                                 len(dag["deps"][pkg]))

    def test_layer_zero_has_no_deps(self):
        dag = build_dag(9, 3, 4, 1)
        for pkg in dag["layers"][0]:
            self.assertEqual(dag["deps"][pkg], [])

    def test_single_package(self):
        dag = build_dag(1, 8, 4, 5)
        self.assertEqual(len(dag["layers"]), 1)
        self.assertEqual(dag["deps"], [[]])


class RepairTest(unittest.TestCase):
    def test_no_orphans_below_top_layer(self):
        shapes = [(1, 8, 4), (9, 3, 4), (20, 4, 3), (40, 8, 4),
                  (60, 8, 4)]
        for n, layers, fanout in shapes:
            for seed in [1, 2, 3, 11, 99]:
                dag = build_dag(n, layers, fanout, seed)
                fan_in = fan_in_counts(dag)
                top = set(dag["layers"][-1])
                for p in range(n):
                    if p not in top:
                        self.assertGreaterEqual(
                            fan_in[p], 1,
                            "pkg%d orphaned (n=%d seed=%d)" % (p, n, seed))

    def test_repair_keeps_dag_shaped(self):
        for seed in [1, 7, 42]:
            dag = build_dag(30, 6, 3, seed)
            for layer_idx, members in enumerate(dag["layers"]):
                lower = {p for lower in dag["layers"][:layer_idx]
                         for p in lower}
                for pkg in members:
                    for dep in dag["deps"][pkg]:
                        self.assertIn(dep, lower)
                    self.assertEqual(dag["deps"][pkg],
                                     sorted(dag["deps"][pkg]))
                    self.assertEqual(len(set(dag["deps"][pkg])),
                                     len(dag["deps"][pkg]))

    def test_repair_deterministic(self):
        self.assertEqual(build_dag(30, 6, 3, 9), build_dag(30, 6, 3, 9))
        self.assertNotEqual(build_dag(30, 6, 3, 9), build_dag(30, 6, 3, 10))


class ReachabilityTest(unittest.TestCase):
    def make_plan(self, **kwargs):
        opts = small_opts(**kwargs)
        return (opts, gen_monorepo.MonorepoPlan(opts, 12))

    def test_main_calls_every_top_layer_entry(self):
        opts, plan = self.make_plan()
        main = gen_monorepo.render_app_main(plan.top_layer())
        for a in plan.top_layer():
            self.assertIn("entry%d(3, probe)" % a, main)
        # Unfoldable-but-false-at-runtime guard source.
        self.assertIn("int.tryParse('probe') ?? 0", main)
        # Entry results flow to a reachable use.
        self.assertIn("$reach", main)

    def test_entry_calls_deps_and_own_functions(self):
        opts, plan = self.make_plan()
        n = len(plan.dag["deps"])
        for p in range(n):
            body = gen_monorepo.render_entrypoint(
                p, opts.files_per_package, plan.dag["deps"][p])
            self.assertIn("int entry%d(int x, int probe)" % p, body)
            for d in plan.dag["deps"][p]:
                self.assertIn("entry%d(x, probe)" % d, body)
            if plan.dag["deps"][p]:
                self.assertIn("if (probe != 0) {", body)
            for f in range(opts.files_per_package):
                self.assertIn("fn%dx%d(x)" % (p, f), body)
                self.assertIn("value%dx%d()" % (p, f), body)
                widget = "W" if f % 2 == 0 else "S"
                self.assertIn(
                    "%s%dx%d(value: 1)" % (widget, p, f), body)
        self.assertTrue(
            any(plan.dag["deps"]),
            "expected at least one package with dependencies")

    def test_entry_imports_dependency_entries(self):
        opts, plan = self.make_plan()
        for p, deps in enumerate(plan.dag["deps"]):
            body = gen_monorepo.render_entrypoint(
                p, opts.files_per_package, deps)
            for d in deps:
                self.assertIn(
                    "import 'package:pkg%d/pkg%d.dart';" % (d, d), body)

    def test_every_package_reachable_from_main_through_dag(self):
        for seed in [1, 7, 42]:
            opts = small_opts(seed=seed)
            plan = gen_monorepo.MonorepoPlan(opts, 15)
            seen = set(plan.top_layer())
            stack = list(plan.top_layer())
            while stack:
                pkg = stack.pop()
                for dep in plan.dag["deps"][pkg]:
                    if dep not in seen:
                        seen.add(dep)
                        stack.append(dep)
            self.assertEqual(seen, set(range(len(plan.dag["deps"]))),
                             "seed %d" % seed)

    def test_edit_target_reachable(self):
        tmp = tempfile.mkdtemp(prefix="gen-mono-reach-")
        try:
            rules_dir = os.path.join(tmp, "rules")
            os.makedirs(rules_dir)
            ws = os.path.join(tmp, "ws")
            generate_flutter_monorepo(ws, rules_dir, [], small_opts())
            with open(os.path.join(ws, "bench-edit-manifest.json"),
                      encoding="utf-8") as fh:
                rel = json.load(fh)["body_edit"]
            pkg = int(rel.split("/")[1].replace("pkg", ""))
            with open(os.path.join(ws, "packages/pkg%d/lib/pkg%d.dart"
                                    % (pkg, pkg)),
                      encoding="utf-8") as fh:
                entry = fh.read()
            # The edited file is f0: its value function is called from the
            # package entry, and the package is reachable from main.
            self.assertIn("value%dx0()" % pkg, entry)
            with open(os.path.join(ws, "bench-workspace-stats.json"),
                      encoding="utf-8") as fh:
                n_packages = json.load(fh)["packages"]
            opts = small_opts()
            plan = gen_monorepo.MonorepoPlan(opts, n_packages)
            seen = set(plan.top_layer())
            stack = list(plan.top_layer())
            while stack:
                member = stack.pop()
                for dep in plan.dag["deps"][member]:
                    if dep not in seen:
                        seen.add(dep)
                        stack.append(dep)
            self.assertIn(pkg, seen)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


class SizingTest(unittest.TestCase):
    def test_pad_file_width(self):
        self.assertEqual(pad_file(8, 0), "0")
        self.assertEqual(pad_file(8, 7), "7")
        self.assertEqual(pad_file(12, 8), "08")
        self.assertEqual(pad_file(40, 39), "39")
        self.assertEqual(pad_file(200, 7), "007")

    def test_method_count_range_in_100_to_150(self):
        for dep_count in range(5):
            for flags in range(8):
                skeleton = lib_skeleton_lines(
                    bool(flags & 1), dep_count, bool(flags & 2),
                    bool(flags & 4))
                min_m, max_m = method_count_range(skeleton)
                self.assertGreaterEqual(min_m, 1)
                self.assertGreaterEqual(max_m, min_m)
                self.assertGreaterEqual(skeleton + 8 * min_m, 100)
                self.assertLessEqual(skeleton + 8 * max_m, 150)

    def test_skeleton_matches_template_for_every_shape(self):
        shapes = [
            (0, []), (0, [0]), (1, []), (1, [0, 1]), (1, [0, 1, 2]),
            (8, [0]), (9, [1, 3]),
        ]
        for file, deps in shapes:
            skeleton = lib_skeleton_lines(
                file > 0, len(deps), file % 8 == 0, file % 2 == 1)
            for methods in [1, 3, 7]:
                rendered = render_lib_file(5, file, 12, deps, methods)
                self.assertEqual(
                    rendered.count("\n"), skeleton + 8 * methods,
                    "shape f%d deps%s methods%d" % (file, deps, methods))

    def test_rendered_files_in_100_to_150(self):
        opts = small_opts()
        plan = gen_monorepo.MonorepoPlan(opts, 12)
        for p in range(12):
            for f in range(opts.files_per_package):
                content = render_lib_file(
                    p, f, opts.files_per_package, plan.dag["deps"][p],
                    plan.method_counts[p][f])
                lines = content.count("\n")
                self.assertGreaterEqual(lines, 100, "pkg%d f%d" % (p, f))
                self.assertLessEqual(lines, 150, "pkg%d f%d" % (p, f))


class GenerationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="gen-mono-test-")
        self.rules_dir = os.path.join(self.tmp, "rules")
        os.makedirs(self.rules_dir)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def generate(self, name, **kwargs):
        out = os.path.join(self.tmp, name)
        stats = generate_flutter_monorepo(
            out, self.rules_dir, [], small_opts(**kwargs))
        return (out, stats)

    def test_byte_identical_for_same_inputs(self):
        out1, _ = self.generate("a")
        out2, _ = self.generate("b")
        self.assertEqual(tree_hash(out1), tree_hash(out2))

    def test_different_seed_differs(self):
        out1, _ = self.generate("a", seed=7)
        out2, _ = self.generate("b", seed=8)
        self.assertNotEqual(tree_hash(out1), tree_hash(out2))

    def test_loc_within_tolerance(self):
        for target in [20000, 60000]:
            out, stats = self.generate("t%d" % target, target_loc=target)
            lines = count_dart_lines(out)
            self.assertEqual(lines, stats["lines"])
            self.assertGreaterEqual(lines, int(target * 0.95))
            self.assertLessEqual(lines, int(target * 1.05))

    def test_stats_and_manifest(self):
        out, stats = self.generate("a")
        self.assertEqual(stats["generator"], "flutter-monorepo")
        self.assertEqual(stats["generator_version"], 2)
        self.assertGreater(stats["packages"], 0)
        self.assertGreater(stats["files"], 0)
        self.assertGreater(stats["targets"], 0)
        with open(os.path.join(out, "bench-workspace-stats.json"),
                  encoding="utf-8") as fh:
            on_disk = json.load(fh)
        self.assertEqual(on_disk, stats)
        with open(os.path.join(out, "bench-edit-manifest.json"),
                  encoding="utf-8") as fh:
            manifest = json.load(fh)
        for key in ["body_edit", "api_edit", "app_main"]:
            self.assertIn(key, manifest)
            full = os.path.join(out, manifest[key])
            self.assertTrue(os.path.isfile(full), key)
        # Edit target lives in layer 0 with maximal fan-in.
        dag = build_dag(stats["packages"], 4, 2, 7)
        fan_in = fan_in_counts(dag)
        layer0 = dag["layers"][0]
        best = max(fan_in[p] for p in layer0)
        edited_pkg = int(
            manifest["body_edit"].split("/")[1].replace("pkg", ""))
        self.assertIn(edited_pkg, layer0)
        self.assertEqual(fan_in[edited_pkg], best)

    def test_api_edit_target_is_imported_by_two_other_packages(self):
        for seed in (1, 7, 11):
            out, stats = self.generate("fan%d" % seed, seed=seed)
            with open(os.path.join(out, "bench-edit-manifest.json"),
                      encoding="utf-8") as fh:
                rel = json.load(fh)["api_edit"]
            edited = int(rel.split("/")[1].replace("pkg", ""))
            importers = set()
            for pkg in range(stats["packages"]):
                if pkg == edited:
                    continue
                entry = os.path.join(out, "packages", "pkg%d" % pkg, "lib",
                                     "pkg%d.dart" % pkg)
                with open(entry, encoding="utf-8") as fh:
                    if "package:pkg%d/pkg%d.dart" % (
                            edited, edited) in fh.read():
                        importers.add(pkg)
            self.assertGreaterEqual(len(importers), 2, seed)
            with open(os.path.join(out, rel), encoding="utf-8") as fh:
                original = fh.read()
            apply_api_edit(out)
            with open(os.path.join(out, rel), encoding="utf-8") as fh:
                self.assertNotEqual(fh.read(), original)

    def test_scaffolding_layout(self):
        out, _ = self.generate("a")
        for rel in ["MODULE.bazel", "BUILD.bazel", ".bazelrc",
                    ".bazelversion", "pubspec.yaml", "pubspec.lock",
                    "analysis_options.yaml", "app/BUILD.bazel",
                    "app/lib/main.dart"]:
            self.assertTrue(os.path.isfile(os.path.join(out, rel)), rel)
        with open(os.path.join(out, "app/BUILD.bazel"),
                  encoding="utf-8") as fh:
            app_build = fh.read()
        for target in ["flutter_application", "flutter_ios_app",
                       "flutter_ios_framework_gen",
                       "flutter_ios_simulator_build_test",
                       "flutter_android_app", "flutter_web_app"]:
            self.assertIn(target, app_build)
        self.assertIn("name = \"app_framework\"", app_build)
        self.assertIn("name = \"app_android\"", app_build)
        self.assertIn("name = \"app_web\"", app_build)

    def test_android_and_web_scaffolding_registered(self):
        out, _ = self.generate("platforms")
        with open(os.path.join(out, "MODULE.bazel"),
                  encoding="utf-8") as fh:
            module = fh.read()
        self.assertIn("android_sdk_repository_extension.configure(", module)
        self.assertIn("api_level = 35", module)
        self.assertIn("use_repo(android_sdk_repository_extension, "
                      "\"androidsdk\")", module)
        self.assertIn("\"@androidsdk//:sdk-toolchain\"", module)
        self.assertIn("\"@androidsdk//:all\"", module)
        self.assertIn("use_repo(android_ndk_repository_extension, "
                      "\"androidndk\")", module)
        self.assertIn("register_toolchains(\"@androidndk//:all\")", module)
        for rel in [
                "app/android/app/src/main/AndroidManifest.xml",
                "app/android/app/src/main/kotlin/com/example/bench/"
                "MainActivity.kt",
                "app/android/app/src/debug/AndroidManifest.xml",
                "app/android/app/src/main/res/values/styles.xml",
        ]:
            self.assertTrue(os.path.isfile(os.path.join(out, rel)), rel)

    def test_generated_workspace_has_default_lockfile_mode(self):
        out, _ = self.generate("nolock")
        with open(os.path.join(out, ".bazelrc"), encoding="utf-8") as fh:
            self.assertNotIn("--lockfile_mode", fh.read())
        self.assertFalse(
            os.path.exists(os.path.join(out, "MODULE.bazel.lock")))

    def test_options_validation(self):
        with self.assertRaises(ValueError):
            Options(target_loc=0)
        with self.assertRaises(ValueError):
            Options(target_loc=100, layers=0)
        with self.assertRaises(ValueError):
            Options(target_loc=100, files_per_package=0)
        with self.assertRaises(ValueError):
            Options(target_loc=100, test_ratio=1.5)
        with self.assertRaises(ValueError):
            Options(target_loc=100, layers=2, edit_layer=2)
        with self.assertRaises(ValueError):
            generate_flutter_monorepo(
                os.path.join(self.tmp, "x"), "/nonexistent", [],
                small_opts())


class ModuleTextTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="gen-mono-mod-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_fake_fixture(self):
        hello = os.path.join(self.tmp, "rules", "e2e", "hello_world")
        os.makedirs(hello)
        with open(os.path.join(hello, "MODULE.bazel"), "w",
                  encoding="utf-8", newline="\n") as fh:
            fh.write("module(name = \"rules_flutter_hello_world\")\n"
                     "local_path_override(\n"
                     "    module_name = \"rules_flutter\",\n"
                     "    path = \"../..\",\n"
                     ")\n")
        return os.path.join(self.tmp, "rules")

    def test_fixture_substitution(self):
        rules = self.write_fake_fixture()
        text = module_bazel_text(rules, [])
        self.assertIn("module(name = \"bench_monorepo\")", text)
        self.assertIn("path = \"%s\"," % rules, text)
        self.assertNotIn("../..", text)

    def test_extra_override_appended(self):
        rules = self.write_fake_fixture()
        text = module_bazel_text(
            rules, [("rules_dart", "/elsewhere/rules_dart")])
        self.assertIn("module_name = \"rules_dart\"", text)
        self.assertIn("/elsewhere/rules_dart", text)

    def test_fallback_module_without_fixture(self):
        rules = os.path.join(self.tmp, "empty-rules")
        os.makedirs(rules)
        text = module_bazel_text(rules, [])
        self.assertIn("module(name = \"bench_monorepo\")", text)
        self.assertIn("path = \"%s\"," % rules, text)

    def dep_line(self, module_name, repo_name=None):
        line = "bazel_dep(name = \"%s\", version = \"0.0.0\"" % module_name
        if repo_name is not None:
            line += ", repo_name = \"%s\"" % repo_name
        return line + ")\n"

    def write_tree_module(self, rules, flutter_name, dart_name, pin,
                          dart_repo=None):
        with open(os.path.join(rules, "MODULE.bazel"), "w",
                  encoding="utf-8", newline="\n") as fh:
            fh.write("module(name = \"%s\")\n" % flutter_name
                     + self.dep_line(dart_name, dart_repo)
                     + pin)

    def write_full_fixture(self, rules, flutter_name, dart_name, pin,
                           flutter_repo=None, dart_repo=None):
        hello = os.path.join(rules, "e2e", "hello_world")
        os.makedirs(hello, exist_ok=True)
        with open(os.path.join(hello, "MODULE.bazel"), "w",
                  encoding="utf-8", newline="\n") as fh:
            fh.write("module(name = \"rules_flutter_hello_world\")\n"
                     + self.dep_line(flutter_name, flutter_repo)
                     + self.dep_line(dart_name, dart_repo)
                     + "# labels keep repo names: @rules_dart//dart:defs.bzl\n"
                     + "local_path_override(\n"
                     "    module_name = \"%s\",\n"
                     "    path = \"../..\",\n"
                     ")\n"
                     "%s" % (flutter_name, pin))
        return rules

    def write_renamed_pair(self, subdir, comment=None):
        """Tree + fixture in the full renamed shape (bazel_deps carry
        repo_name, the pin lives under the ai_ module name)."""
        rules = os.path.join(self.tmp, subdir)
        os.makedirs(rules)
        tree_text = ("module(name = \"ai_rules_flutter\")\n"
                     + self.dep_line("ai_rules_dart", "rules_dart")
                     + self.GIT_PIN % ("ai_rules_dart", "TREE123"))
        if comment is not None:
            tree_text = comment + tree_text
        with open(os.path.join(rules, "MODULE.bazel"), "w",
                  encoding="utf-8", newline="\n") as fh:
            fh.write(tree_text)
        self.write_full_fixture(
            rules, "ai_rules_flutter", "ai_rules_dart",
            self.GIT_PIN % ("ai_rules_dart", "TREE123"),
            flutter_repo="rules_flutter", dart_repo="rules_dart")
        return rules

    def assert_renamed_output(self, text, rules):
        self.assertIn("module(name = \"bench_monorepo\")", text)
        self.assertIn("module_name = \"ai_rules_flutter\"", text)
        self.assertIn("module_name = \"ai_rules_dart\"", text)
        self.assertIn("path = \"%s\"," % rules, text)
        self.assertNotIn("module_name = \"rules_flutter\"", text)
        self.assertNotIn("module_name = \"rules_dart\"", text)
        for repo in ("rules_flutter", "rules_dart"):
            bare = re.findall(r"(?<![A-Za-z_])name\s*=\s*\"%s\"" % repo,
                              text)
            self.assertEqual([], bare)
        self.assertIn("@rules_dart//dart:defs.bzl", text)

    def test_renamed_shape_resolves_dart_dep(self):
        rules = self.write_renamed_pair("rz-rules")
        text = module_bazel_text(rules, [])
        self.assert_renamed_output(text, rules)
        self.assertIn("TREE123", text)

    def test_renamed_shape_repo_name_override(self):
        rules = self.write_renamed_pair("rz-rules-repo")
        text = module_bazel_text(
            rules, [("rules_dart", "/elsewhere/rules_dart")])
        self.assert_renamed_output(text, rules)
        self.assertIn("/elsewhere/rules_dart", text)
        self.assertNotIn("TREE123", text)

    def test_renamed_shape_module_name_override(self):
        rules = self.write_renamed_pair("rz-rules-mod")
        text = module_bazel_text(
            rules, [("ai_rules_dart", "/elsewhere/rules_dart")])
        self.assert_renamed_output(text, rules)
        self.assertIn("/elsewhere/rules_dart", text)
        self.assertNotIn("TREE123", text)

    def test_comment_mentioning_dep_is_ignored(self):
        rules = self.write_renamed_pair(
            "rz-rules-comment",
            comment="# bazel_dep(name = \"rules_dart\", version = \"0.0.0\")\n"
                    "# module(name = \"rules_flutter\")\n")
        text = module_bazel_text(rules, [])
        self.assert_renamed_output(text, rules)
        self.assertIn("TREE123", text)

    GIT_PIN = ("git_override(\n"
               "    module_name = \"%s\",\n"
               "    remote = \"https://github.com/Mivr/ai_rules_dart.git\",\n"
               "    commit = \"%s\"\n"
               ")\n")

    def test_repo_scheme_tree_pin_wins(self):
        rules = os.path.join(self.tmp, "rules")
        os.makedirs(rules)
        self.write_tree_module(rules, "rules_flutter", "rules_dart",
                               self.GIT_PIN % ("rules_dart", "TREE123"))
        self.write_full_fixture(rules, "rules_flutter", "rules_dart",
                                self.GIT_PIN % ("rules_dart", "FIXTURE999"))
        text = module_bazel_text(rules, [])
        self.assertIn("TREE123", text)
        self.assertNotIn("FIXTURE999", text)
        self.assertIn("@rules_dart//dart:defs.bzl", text)

    def test_ai_scheme_names_come_from_tree(self):
        rules = os.path.join(self.tmp, "ai-rules")
        os.makedirs(rules)
        self.write_tree_module(rules, "ai_rules_flutter", "ai_rules_dart",
                               self.GIT_PIN % ("ai_rules_dart", "TREE123"))
        self.write_full_fixture(rules, "ai_rules_flutter", "ai_rules_dart",
                                self.GIT_PIN % ("ai_rules_dart", "TREE123"))
        text = module_bazel_text(rules, [])
        self.assertIn("module_name = \"ai_rules_flutter\"", text)
        self.assertIn("module_name = \"ai_rules_dart\"", text)
        self.assertIn("path = \"%s\"," % rules, text)
        self.assertNotIn("module_name = \"rules_flutter\"", text)
        self.assertNotIn("module_name = \"rules_dart\"", text)
        self.assertIn("@rules_dart//dart:defs.bzl", text)

    def test_repo_name_override_maps_to_ai_module(self):
        rules = os.path.join(self.tmp, "ai-rules2")
        os.makedirs(rules)
        self.write_tree_module(rules, "ai_rules_flutter", "ai_rules_dart",
                               self.GIT_PIN % ("ai_rules_dart", "TREE123"))
        self.write_full_fixture(rules, "ai_rules_flutter", "ai_rules_dart",
                                self.GIT_PIN % ("ai_rules_dart", "TREE123"))
        text = module_bazel_text(
            rules, [("rules_dart", "/elsewhere/rules_dart")])
        self.assertIn("module_name = \"ai_rules_dart\"", text)
        self.assertIn("/elsewhere/rules_dart", text)
        self.assertNotIn("TREE123", text)

    def test_module_name_override_accepted(self):
        rules = os.path.join(self.tmp, "ai-rules3")
        os.makedirs(rules)
        self.write_tree_module(rules, "ai_rules_flutter", "ai_rules_dart",
                               self.GIT_PIN % ("ai_rules_dart", "TREE123"))
        self.write_full_fixture(rules, "ai_rules_flutter", "ai_rules_dart",
                                self.GIT_PIN % ("ai_rules_dart", "TREE123"))
        text = module_bazel_text(
            rules, [("ai_rules_dart", "/elsewhere/rules_dart")])
        self.assertIn("module_name = \"ai_rules_dart\"", text)
        self.assertIn("/elsewhere/rules_dart", text)

    def test_single_version_pin_scheme(self):
        pin = ("single_version_override(\n"
               "    module_name = \"rules_dart\",\n"
               "    version = \"0.13.2\",\n"
               ")\n")
        rules = os.path.join(self.tmp, "sv-rules")
        os.makedirs(rules)
        self.write_tree_module(rules, "rules_flutter", "rules_dart", pin)
        self.write_full_fixture(rules, "rules_flutter", "rules_dart", pin)
        text = module_bazel_text(rules, [])
        self.assertIn("single_version_override(", text)
        self.assertIn("0.13.2", text)

    def test_archive_pin_scheme(self):
        pin = ("archive_override(\n"
               "    module_name = \"rules_dart\",\n"
               "    urls = \"https://example.com/rules_dart.tar.gz\",\n"
               "    integrity = \"sha256-abc=\",\n"
               ")\n")
        rules = os.path.join(self.tmp, "ar-rules")
        os.makedirs(rules)
        self.write_tree_module(rules, "rules_flutter", "rules_dart", pin)
        self.write_full_fixture(rules, "rules_flutter", "rules_dart", pin)
        text = module_bazel_text(rules, [])
        self.assertIn("archive_override(", text)
        self.assertIn("sha256-abc=", text)

    def test_tree_fixture_name_mismatch_raises(self):
        rules = os.path.join(self.tmp, "bad-rules")
        os.makedirs(rules)
        self.write_tree_module(rules, "ai_rules_flutter", "ai_rules_dart",
                               self.GIT_PIN % ("ai_rules_dart", "TREE123"))
        self.write_full_fixture(rules, "rules_flutter", "rules_dart",
                                self.GIT_PIN % ("rules_dart", "TREE123"))
        with self.assertRaises(ValueError):
            module_bazel_text(rules, [])

    def test_fallback_uses_tree_module_names(self):
        rules = os.path.join(self.tmp, "ai-empty")
        os.makedirs(rules)
        self.write_tree_module(rules, "ai_rules_flutter", "ai_rules_dart",
                               self.GIT_PIN % ("ai_rules_dart", "TREE123"))
        text = module_bazel_text(rules, [])
        self.assertIn("module_name = \"ai_rules_flutter\"", text)
        self.assertIn("module(name = \"bench_monorepo\")", text)

    def test_bazelrc_filtering(self):
        self.assertNotIn("--lockfile_mode",
                         bazelrc_text("/nonexistent"))
        rules = self.write_fake_fixture()
        hello = os.path.join(rules, "e2e", "hello_world")
        with open(os.path.join(hello, ".bazelrc"), "w",
                  encoding="utf-8", newline="\n") as fh:
            fh.write("common --lockfile_mode=update\n"
                     "common --@rules_flutter//flutter:extra_dart_defines=X\n"
                     "test --aspects=@rules_dart//dart:analyze.bzl%dart_analyze\n")
        text = bazelrc_text(rules)
        self.assertNotIn("extra_dart_defines", text)
        self.assertNotIn("--lockfile_mode", text)
        self.assertIn("test --aspects=", text)

    def write_dev_fixture(self, subdir, module_text, bazelrc=None):
        rules = os.path.join(self.tmp, subdir)
        hello = os.path.join(rules, "e2e", "hello_world")
        os.makedirs(hello)
        with open(os.path.join(hello, "MODULE.bazel"), "w",
                  encoding="utf-8", newline="\n") as fh:
            fh.write(module_text)
        if bazelrc is not None:
            with open(os.path.join(hello, ".bazelrc"), "w",
                      encoding="utf-8", newline="\n") as fh:
                fh.write(bazelrc)
        return rules

    DEV_MODULE = (
        "module(name = \"rules_flutter_hello_world\")\n"
        "\n"
        "bazel_dep(name = \"rules_flutter\", version = \"0.0.0\")\n"
        "bazel_dep(name = \"rules_dart\", version = \"0.7.3\")\n"
        "\n"
        "bazel_dep(name = \"llvm\", version = \"0.8.19\", dev_dependency = True)\n"
        "\n"
        "local_path_override(\n"
        "    module_name = \"rules_flutter\",\n"
        "    path = \"../..\",\n"
        ")\n"
        "\n"
        "git_override(\n"
        "    module_name = \"rules_dart\",\n"
        "    commit = \"FIXTURE999\",\n"
        "    remote = \"https://github.com/Mivr/ai_rules_dart.git\",\n"
        ")\n"
        "\n"
        "register_toolchains(\n"
        "    \"@llvm//toolchain:linux_x86_64_to_linux_x86_64\",\n"
        "    \"@llvm//toolchain:macos_x86_64_to_linux_x86_64\",\n"
        "    dev_dependency = True,\n"
        ")\n"
    )

    DEV_MODULE_DROPPED = (
        "module(name = \"bench_monorepo\")\n"
        "\n"
        "bazel_dep(name = \"rules_flutter\", version = \"0.0.0\")\n"
        "bazel_dep(name = \"rules_dart\", version = \"0.7.3\")\n"
        "\n"
        "local_path_override(\n"
        "    module_name = \"rules_flutter\",\n"
        "    path = \"%s\",\n"
        ")\n"
        "\n"
        "git_override(\n"
        "    module_name = \"rules_dart\",\n"
        "    commit = \"FIXTURE999\",\n"
        "    remote = \"https://github.com/Mivr/ai_rules_dart.git\",\n"
        ")\n"
        "\n"
    )

    def test_dev_dependencies_dropped_byte_exact(self):
        rules = self.write_dev_fixture("dev-rules", self.DEV_MODULE)
        text = module_bazel_text(rules, [])
        self.assertEqual(text, self.DEV_MODULE_DROPPED % rules)
        self.assertNotIn("llvm", text)
        self.assertNotIn("register_toolchains", text)
        self.assertNotIn("dev_dependency", text)

    def test_dev_use_extension_fails_naming_call(self):
        module = (
            "module(name = \"rules_flutter_hello_world\")\n"
            "bazel_dep(name = \"rules_flutter\", version = \"0.0.0\")\n"
            "local_path_override(\n"
            "    module_name = \"rules_flutter\",\n"
            "    path = \"../..\",\n"
            ")\n"
            "my_ext = use_extension(\"@rules_foo//:ext.bzl\", \"my_ext\",\n"
            "    dev_dependency = True)\n"
            "use_repo(my_ext, \"my_repo\")\n"
        )
        rules = self.write_dev_fixture("devext-rules", module)
        with self.assertRaises(ValueError) as ctx:
            module_bazel_text(rules, [])
        self.assertIn("use_extension", str(ctx.exception))

    def test_dev_comment_mention_drops_nothing(self):
        module = (
            "module(name = \"rules_flutter_hello_world\")\n"
            "# bazel_dep(name = \"llvm\", version = \"0.8.19\","
            " dev_dependency = True)\n"
            "bazel_dep(name = \"rules_flutter\", version = \"0.0.0\")\n"
            "local_path_override(\n"
            "    module_name = \"rules_flutter\",\n"
            "    path = \"../..\",\n"
            ")\n"
        )
        rules = self.write_dev_fixture("devcomment-rules", module)
        text = module_bazel_text(rules, [])
        self.assertIn("# bazel_dep(name = \"llvm\"", text)
        self.assertIn("module(name = \"bench_monorepo\")", text)

    def test_dropped_module_reference_still_named_fails(self):
        module = (
            "module(name = \"rules_flutter_hello_world\")\n"
            "bazel_dep(name = \"rules_flutter\", version = \"0.0.0\")\n"
            "bazel_dep(name = \"llvm\", version = \"0.8.19\","
            " dev_dependency = True)\n"
            "local_path_override(\n"
            "    module_name = \"rules_flutter\",\n"
            "    path = \"../..\",\n"
            ")\n"
            "register_toolchains(\"@llvm//toolchain:linux_x86_64_to_linux_x86_64\")\n"
        )
        rules = self.write_dev_fixture("devref-rules", module)
        with self.assertRaises(ValueError) as ctx:
            module_bazel_text(rules, [])
        self.assertIn("llvm", str(ctx.exception))


class EditTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="gen-mono-edit-")
        self.rules_dir = os.path.join(self.tmp, "rules")
        os.makedirs(self.rules_dir)
        self.ws = os.path.join(self.tmp, "ws")
        generate_flutter_monorepo(self.ws, self.rules_dir, [],
                                 small_opts())

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def read_manifest_target(self, key):
        with open(os.path.join(self.ws, "bench-edit-manifest.json"),
                  encoding="utf-8") as fh:
            rel = json.load(fh)[key]
        with open(os.path.join(self.ws, rel), encoding="utf-8") as fh:
            return (rel, fh.read())

    def test_body_edit_keeps_api(self):
        rel, original = self.read_manifest_target("body_edit")
        backup = apply_body_edit(self.ws)
        self.assertEqual(backup, original)
        with open(os.path.join(self.ws, rel), encoding="utf-8") as fh:
            edited = fh.read()
        self.assertNotEqual(edited, original)
        # No public member added: outline-affecting lines unchanged.
        for line in edited.split("\n"):
            if line.startswith("  int get extra") or \
                    line.startswith("int addedApi"):
                self.fail("body edit changed the API")

    def test_api_edit_adds_member(self):
        rel, original = self.read_manifest_target("api_edit")
        apply_api_edit(self.ws)
        with open(os.path.join(self.ws, rel), encoding="utf-8") as fh:
            edited = fh.read()
        self.assertNotEqual(edited, original)
        self.assertIn("extra", edited)

    def test_app_edit_changes_main(self):
        with open(os.path.join(self.ws, "app/lib/main.dart"),
                  encoding="utf-8") as fh:
            original = fh.read()
        apply_app_edit(self.ws)
        with open(os.path.join(self.ws, "app/lib/main.dart"),
                  encoding="utf-8") as fh:
            edited = fh.read()
        self.assertNotEqual(edited, original)
        self.assertIn("+ 1", edited)

    def test_edits_fail_closed(self):
        os.remove(os.path.join(self.ws, "bench-edit-manifest.json"))
        with self.assertRaises(Exception):
            apply_body_edit(self.ws)


class HelperTest(unittest.TestCase):
    def spec(self, package=5, file=1, files_per_package=12, deps=(0, 2),
             method_count=3):
        return _LibSpec(package, file, files_per_package, deps, method_count)

    def test_lib_spec_shape_flags(self):
        self.assertTrue(self.spec(file=1).has_sibling)
        self.assertFalse(self.spec(file=0).has_sibling)
        self.assertTrue(self.spec(file=8).has_part)
        self.assertFalse(self.spec(file=1).has_part)
        self.assertTrue(self.spec(file=1).odd_file)
        self.assertFalse(self.spec(file=2).odd_file)
        self.assertEqual(self.spec(file=3).factor, 5)
        self.assertEqual(self.spec(file=7).pad, pad_file(12, 7))

    def test_lib_import_lines(self):
        lines = _lib_import_lines(self.spec())
        self.assertEqual(lines, sorted(l for l in lines if l.startswith(
            "import ")) + [l for l in lines if not l.startswith("import ")])
        text = "\n".join(lines)
        self.assertIn("import 'package:pkg0/pkg0.dart';", text)
        self.assertIn("import 'package:pkg5/src/f00.dart';", text)
        self.assertIn("typedef D5x1A0 = C0x0<int>;", text)
        self.assertNotIn("part ", text)
        first = _lib_import_lines(self.spec(file=0, deps=()))
        self.assertNotIn("src/f", "\n".join(first))
        part = _lib_import_lines(self.spec(file=8, deps=()))
        self.assertIn("part 'f08.part.dart';", "\n".join(part))

    def test_lib_class_lines(self):
        text = "\n".join(_lib_class_lines(self.spec()))
        self.assertIn("class C5x1<T> {", text)
        self.assertIn("T? pick(List<T> items)", text)
        mixed = "\n".join(_lib_class_lines(self.spec(file=8)))
        self.assertIn("class C5x8<T> with M5x8 {", mixed)

    def test_lib_method_lines(self):
        lines = _lib_method_lines(self.spec(method_count=3))
        self.assertEqual(len(lines), 24)
        self.assertIn("    return total + m1(x);", lines)
        self.assertIn("    return total;", lines)
        self.assertNotIn("    return total + m3(x);", lines)
        self.assertEqual(_lib_method_lines(self.spec(method_count=1))[6],
                         "    return total;")

    def test_lib_helpers_assemble_full_render(self):
        for file, deps in [(0, []), (1, [0, 1]), (8, [0]), (9, [1, 3])]:
            spec = self.spec(file=file, deps=tuple(deps))
            rendered = render_lib_file(5, file, 12, deps, 3)
            for block in [_lib_import_lines(spec), _lib_class_lines(spec),
                          _lib_method_lines(spec)]:
                self.assertIn("\n".join(block), rendered)
            order = [rendered.index("\n".join(block)) for block in
                     [_lib_import_lines(spec), _lib_class_lines(spec),
                      _lib_method_lines(spec)]]
            self.assertEqual(order, sorted(order))

    def test_check_fixture_text(self):
        good = ("module(name = \"rules_flutter_hello_world\")\n"
                "local_path_override(\n"
                "    module_name = \"rules_flutter\",\n"
                "    path = \"../..\",\n"
                ")\n")
        _check_fixture_text("fixture", good)
        with self.assertRaises(ValueError):
            _check_fixture_text("fixture", good.replace(
                "rules_flutter_hello_world", "other"))
        with self.assertRaises(ValueError):
            _check_fixture_text(
                "fixture", good.replace("../..", "../../.."))

    def test_apply_pin_replacement(self):
        pin_block = ("git_override(\n"
                     "    module_name = \"rules_dart\",\n"
                     "    commit = \"OLD\"\n"
                     ")\n")
        out = "header\n" + pin_block + "tail\n"
        swapped = _apply_pin_replacement(
            out, "", _PinReplacement("rules_dart", "/dd", pin_block, None))
        self.assertIn("/dd", swapped.out)
        self.assertNotIn("OLD", swapped.out)
        self.assertEqual(swapped.extra, "")
        appended = _apply_pin_replacement(
            "header\n", "x\n",
            _PinReplacement("rules_dart", "/dd", None, None))
        self.assertIn("/dd", appended.extra)
        tree = _apply_pin_replacement(
            out, "", _PinReplacement("rules_dart", None, pin_block,
                                     pin_block.replace("OLD", "NEW")))
        self.assertIn("NEW", tree.out)
        self.assertNotIn("OLD", tree.out)
        same = _apply_pin_replacement(
            out, "", _PinReplacement("rules_dart", None, pin_block,
                                     pin_block))
        self.assertEqual(same.out, out)
        self.assertEqual(same.extra, "")

    def test_package_build_texts(self):
        build = _package_build_text(3, [0, 1])
        self.assertIn("name = \"pkg3\",", build)
        self.assertIn("//packages/pkg0", build)
        self.assertIn("//packages/pkg1", build)
        test_build = _package_test_build_text(3, [0])
        self.assertIn("name = \"pkg3_test\",", test_build)
        self.assertIn("flutter_test(", test_build)

    def test_write_helpers(self):
        import types
        tmp = tempfile.mkdtemp(prefix="gen-mono-helper-")
        try:
            rules_dir = os.path.join(tmp, "rules")
            os.makedirs(rules_dir)
            out = os.path.join(tmp, "ws")
            os.makedirs(out)
            _write_root_files(_ScaffoldFiles(out, rules_dir, []))
            for rel in ["MODULE.bazel", "BUILD.bazel", ".bazelrc",
                        ".bazelversion", "pubspec.yaml", "pubspec.lock",
                        "analysis_options.yaml"]:
                self.assertTrue(os.path.isfile(os.path.join(out, rel)), rel)
            plan = types.SimpleNamespace(
                dag={"deps": [[], [0]]}, has_test=[False, True])
            targets = _write_package_builds(out, plan)
            self.assertEqual(targets, 3)
            with open(os.path.join(out, "packages/pkg1/BUILD.bazel"),
                      encoding="utf-8") as fh:
                pkg1 = fh.read()
            self.assertIn("flutter_test(", pkg1)
            with open(os.path.join(out, "packages/pkg0/BUILD.bazel"),
                      encoding="utf-8") as fh:
                self.assertNotIn("flutter_test(", fh.read())
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


PUBSPEC_YAML_WITH_PATHS = (
    "name: hello_world\n"
    "publish_to: none\n"
    "\n"
    "environment:\n"
    "  sdk: ^3.13.0\n"
    "\n"
    "dependencies:\n"
    "  flutter:\n"
    "    sdk: flutter\n"
    "  cupertino_icons: ^1.0.8\n"
    "  path_probe:\n"
    "    path: path_probe\n"
    "  platform_assets:\n"
    "    path: platform_assets\n"
    "  unversioned_path:\n"
    "    path: unversioned_path\n"
    "dev_dependencies:\n"
    "  very_good_analysis: ^10.3.0\n"
    "  flutter_test:\n"
    "    sdk: flutter\n"
)


LOCK_WITH_PATHS = (
    "packages:\n"
    "  async:\n"
    "    dependency: transitive\n"
    "    description:\n"
    "      name: async\n"
    "      sha256: \"e2eb0491ba5ddb6177742d2da23904574082139b07c1e33b8503b9f46f3e1a37\"\n"
    "      url: \"https://pub.dev\"\n"
    "    source: hosted\n"
    "    version: \"2.13.1\"\n"
    "  unversioned_path:\n"
    "    dependency: \"direct main\"\n"
    "    description:\n"
    "      path: \"unversioned_path\"\n"
    "      relative: true\n"
    "    source: path\n"
    "    version: \"1.0.0\"\n"
    "  platform_assets:\n"
    "    dependency: \"direct main\"\n"
    "    description:\n"
    "      path: \"platform_assets\"\n"
    "      relative: true\n"
    "    source: path\n"
    "    version: \"0.1.0\"\n"
    "  path:\n"
    "    dependency: transitive\n"
    "    description:\n"
    "      name: path\n"
    "      sha256: \"75cca69d1490965be98c73ceaea117e8a04dd21217b37b292c9ddbec0d955bc5\"\n"
    "      url: \"https://pub.dev\"\n"
    "    source: hosted\n"
    "    version: \"1.9.1\"\n"
    "sdks:\n"
    "  dart: \">=3.13.0 <4.0.0\"\n"
    "  flutter: \">=3.18.0-18.0.pre.54\"\n"
)


class PathDepStripTest(unittest.TestCase):
    """The generated workspace must not name fixture path dependencies."""

    def test_strip_pubspec_path_deps(self):
        out = strip_pubspec_path_deps(PUBSPEC_YAML_WITH_PATHS)
        self.assertNotIn("path_probe", out)
        self.assertNotIn("platform_assets", out)
        self.assertNotIn("unversioned_path", out)
        self.assertIn("cupertino_icons: ^1.0.8", out)
        self.assertIn("very_good_analysis: ^10.3.0", out)
        self.assertIn("flutter:\n    sdk: flutter", out)
        self.assertIn("dev_dependencies:", out)

    def test_strip_lock_path_packages(self):
        out = strip_lock_path_packages(LOCK_WITH_PATHS)
        self.assertIn("async", out)
        self.assertIn("path:", out)  # the hosted `path` package stays
        self.assertNotIn("unversioned_path", out)
        self.assertNotIn("platform_assets", out)
        self.assertIn("sdks:", out)
        self.assertIn('dart: ">=3.13.0 <4.0.0"', out)

    def test_copy_pub_files_writes_fallback_without_fixture(self):
        tmp = tempfile.mkdtemp(prefix="gen-mono-pubfall-")
        try:
            out = os.path.join(tmp, "ws")
            os.makedirs(out)
            copy_pub_files(out, os.path.join(tmp, "no-rules"))
            with open(os.path.join(out, "pubspec.yaml"),
                      encoding="utf-8") as fh:
                self.assertEqual(
                    fh.read(),
                    "name: bench_monorepo\nenvironment:\n  sdk: ^3.9.0\n")
            with open(os.path.join(out, "pubspec.lock"),
                      encoding="utf-8") as fh:
                self.assertIn("packages: {}", fh.read())
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_generated_workspace_drops_fixture_path_deps(self):
        tmp = tempfile.mkdtemp(prefix="gen-mono-path-")
        try:
            rules = os.path.join(tmp, "rules")
            hello = os.path.join(rules, "e2e", "hello_world")
            os.makedirs(hello)
            with open(os.path.join(hello, "MODULE.bazel"), "w",
                      encoding="utf-8", newline="\n") as fh:
                fh.write("module(name = \"rules_flutter_hello_world\")\n"
                         "local_path_override(\n"
                         "    module_name = \"rules_flutter\",\n"
                         "    path = \"../..\",\n"
                         ")\n")
            with open(os.path.join(hello, "pubspec.yaml"), "w",
                      encoding="utf-8", newline="\n") as fh:
                fh.write(PUBSPEC_YAML_WITH_PATHS)
            with open(os.path.join(hello, "pubspec.lock"), "w",
                      encoding="utf-8", newline="\n") as fh:
                fh.write(LOCK_WITH_PATHS)
            out = os.path.join(tmp, "ws")
            generate_flutter_monorepo(out, rules, [], small_opts())
            with open(os.path.join(out, "pubspec.yaml"),
                      encoding="utf-8") as fh:
                self.assertNotIn("path:", fh.read())
            with open(os.path.join(out, "pubspec.lock"),
                      encoding="utf-8") as fh:
                lock = fh.read()
            self.assertNotIn("source: path", lock)
            self.assertNotIn("unversioned_path", lock)
            self.assertIn("sdks:", lock)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def read_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


class LockFileStagingTest(unittest.TestCase):
    """Workspace-local lock_file labels are staged into the workspace."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="gen-mono-lock-")
        self.rules = os.path.join(self.tmp, "rules")
        self.hello = os.path.join(self.rules, "e2e", "hello_world")
        os.makedirs(self.hello)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, rel, data):
        path = os.path.join(self.hello, *rel.split("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(data)

    def module(self, body):
        self.write("MODULE.bazel", (
            "module(name = \"rules_flutter_hello_world\")\n"
            "local_path_override(\n"
            "    module_name = \"rules_flutter\",\n"
            "    path = \"../..\",\n"
            ")\n" + body
        ).encode("utf-8"))

    def generate(self, name="ws"):
        out = os.path.join(self.tmp, name)
        stats = generate_flutter_monorepo(out, self.rules, [], small_opts())
        return (out, stats)

    def test_real_checkout_stages_android_maven_lock(self):
        out = os.path.join(self.tmp, "real")
        generate_flutter_monorepo(out, REPO_ROOT, [], small_opts())
        with open(os.path.join(out, "MODULE.bazel"), encoding="utf-8") as fh:
            self.assertIn(
                'lock_file = "//:rules_android_maven_install.json"', fh.read())
        self.assertEqual(
            read_bytes(os.path.join(out, "rules_android_maven_install.json")),
            read_bytes(os.path.join(
                REPO_ROOT, "e2e", "hello_world",
                "rules_android_maven_install.json")))
        with open(os.path.join(out, "pubspec.lock"), encoding="utf-8") as fh:
            self.assertNotIn("source: path", fh.read())
        out2 = os.path.join(self.tmp, "real2")
        generate_flutter_monorepo(out2, REPO_ROOT, [], small_opts())
        self.assertEqual(tree_hash(out), tree_hash(out2))

    def test_stages_each_label_form_with_exact_bytes(self):
        self.module(
            "maven.install(lock_file = \"//:rules_android_maven_install.json\")\n"
            "maven.install(lock_file = \"//maven:extra_install.json\")\n"
            "maven.install(lock_file = \"@//:at.json\")\n"
            "maven.install(lock_file = \"@@//:atat.json\")\n"
            "maven.install(lock_file = \":colon.json\")\n"
            "maven.install(lock_file = \"//:rules_android_maven_install.json\")\n")
        blobs = {
            "rules_android_maven_install.json": b'{"a": 1}\r\n\x00',
            "maven/extra_install.json": b"extra",
            "at.json": b"at",
            "atat.json": b"atat",
            "colon.json": b"colon",
        }
        for rel, data in blobs.items():
            self.write(rel, data)
        (out, stats) = self.generate()
        for rel, data in blobs.items():
            self.assertEqual(
                read_bytes(os.path.join(out, *rel.split("/"))), data)
        plain = os.path.join(self.tmp, "plain")
        self.module("")
        base = generate_flutter_monorepo(plain, self.rules, [], small_opts())
        for key in ("files", "lines", "targets"):
            self.assertEqual(stats[key], base[key])

    def test_comments_and_external_labels_ignored(self):
        self.module(
            "# lock_file = \"//:commented_out.json\"\n"
            "maven.install(  # lock_file = \"//:trailing.json\"\n"
            "    lock_file = \"@other_repo//:lock.json\",\n"
            "    other = \"@@other_repo//pkg:lock.json\",\n"
            "    lock_file = \"@@other//:l.json\",\n"
            ")\n")
        (out, _) = self.generate()
        self.assertFalse(os.path.exists(os.path.join(out, "commented_out.json")))
        self.assertFalse(os.path.exists(os.path.join(out, "lock.json")))

    def test_missing_fixture_lockfile_raises(self):
        self.module(
            "maven.install(lock_file = \"//:rules_android_maven_install.json\")\n")
        with self.assertRaises(ValueError) as ctx:
            self.generate()
        self.assertIn("rules_android_maven_install.json", str(ctx.exception))
        self.assertIn("//:rules_android_maven_install.json", str(ctx.exception))
        self.assertIn(os.path.join("e2e", "hello_world"), str(ctx.exception))

    def test_missing_fixture_error_names_declared_label(self):
        self.module("maven.install(lock_file = \"@//maven:extra.json\")\n")
        with self.assertRaises(ValueError) as ctx:
            self.generate()
        self.assertIn("@//maven:extra.json", str(ctx.exception))
        self.assertIn("extra.json", str(ctx.exception))

    def test_escaping_or_malformed_labels_raise(self):
        for label in ("//:../outside.json", "//:", "", "plain.json",
                      "//pkg", "//:/abs.json", "//../x:y.json", "//:a/../b"):
            self.module("maven.install(lock_file = \"%s\")\n" % label)
            with self.assertRaises(ValueError) as ctx:
                self.generate()
            self.assertIn(label, str(ctx.exception))
            shutil.rmtree(os.path.join(self.tmp, "ws"), ignore_errors=True)

    def test_module_without_lock_file_succeeds(self):
        self.module("maven.install(name = \"x\")\n")
        (out, _) = self.generate()
        self.assertFalse(os.path.exists(
            os.path.join(out, "rules_android_maven_install.json")))


if __name__ == "__main__":
    unittest.main()
