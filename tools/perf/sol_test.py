#!/usr/bin/env python3
"""Unit tests for sol.py (iOS speed-of-light costs, Linux fixtures)."""

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

import sol
from sol import (
    app_dir_hashes,
    bazel_info,
    build_profile,
    capture_bazel_output,
    chain_replayed,
    check_under_base,
    collect_runner_info,
    covered_by,
    cpu_seconds,
    describe_chain,
    device_verify_files,
    flow_id,
    flow_reason,
    hashes_match,
    host_tool_spawns,
    ipa_entry_hashes,
    load_sol_records,
    measure_process_tree,
    measure_with_time,
    move_aside_chain,
    output_drift,
    path_depth,
    pick_unit,
    plan_verify_snapshot,
    read_chain_report,
    read_jvm_cpu,
    read_verify_snapshot,
    rep_sort_key,
    replay_host_spawns,
    restore_tree,
    run_chain,
    save_gzipped,
    select_sol_spawns,
    sha256_file,
    sim_bundle_archives,
    sim_bundle_roots,
    snapshot_hashes,
    snapshot_tree,
    summarize_flow,
    summarize_host_tools,
    summarize_jvm,
    summarize_profile,
    summarize_sol,
    sweep_chain_side_effects,
    verify_differences,
)


def kernel_spawn():
    # Runs an exec-built frontend server (argv[0] under -exec-) to
    # produce target-configuration outputs: it belongs in the chain.
    return {
        "commandArgs": ["bazel-out/darwin_arm64-opt-exec-1234ABCD/bin/"
                        "frontend_server",
                        "--target=flutter", "main.dart"],
        "environmentVariables": [],
        "listedOutputs": ["bazel-out/darwin_arm64-dbg/bin/app/app.dill"],
        "mnemonic": "FlutterKernelCompile",
        "exitCode": 0,
        "targetLabel": "//packages/pkg0:pkg0",
    }


def aot_spawn():
    return {
        "commandArgs": ["gen_snapshot", "--macho", "out.dill"],
        "environmentVariables": [],
        "listedOutputs": ["bazel-out/darwin_arm64-opt/bin/app/App.dill"],
        "mnemonic": "FlutterAotMacho",
        "exitCode": 0,
        "targetLabel": "//app:app",
    }


def exec_spawn():
    return {
        "commandArgs": [
            "clang", "-c",
            "bazel-out/darwin_arm64-opt-exec-1234ABCD/bin/x/y.cc",
        ],
        "environmentVariables": [],
        "listedOutputs": ["bazel-out/darwin_arm64-opt-exec-1234ABCD/bin/"
                          "x/y.o"],
        "mnemonic": "CppCompile",
        "exitCode": 0,
        "targetLabel": "@@abseil-cpp+//x:y",
    }


class FlowIdTest(unittest.TestCase):
    def test_all_six_flows(self):
        self.assertEqual(flow_id("device_release", "clean"),
                         "ios-release-clean")
        self.assertEqual(flow_id("device_release", "app_edit"),
                         "ios-release-app")
        self.assertEqual(flow_id("device_release", "core_edit"),
                         "ios-release-body")
        self.assertEqual(flow_id("sim_debug", "clean"), "ios-debug-clean")
        self.assertEqual(flow_id("sim_debug", "app_edit"), "ios-debug-app")
        self.assertEqual(flow_id("sim_debug", "core_edit"), "ios-debug-body")

    def test_android_and_web_flows(self):
        expected = {
            "android_release": "android-release",
            "android_debug": "android-debug",
            "web_release": "web-release",
            "web_debug": "web-debug",
        }
        for config, prefix in expected.items():
            self.assertEqual(flow_id(config, "clean"), prefix + "-clean")
            self.assertEqual(flow_id(config, "app_edit"), prefix + "-app")
            self.assertEqual(flow_id(config, "core_edit"), prefix + "-body")

    def test_unknown_raises(self):
        with self.assertRaises(KeyError):
            flow_id("nope", "clean")


class SelectSolTest(unittest.TestCase):
    def test_exec_tool_argv_with_target_outputs_is_chain(self):
        # The defect: the old argv-based classifier dropped every action
        # that runs an exec-built tool (the kernel compile above), so the
        # SOL never did the dominant step. Output-based selection keeps it.
        runnable, skipped = select_sol_spawns([kernel_spawn(), aot_spawn()])
        self.assertEqual(len(runnable), 2)
        self.assertEqual(skipped, {})

    def test_host_tool_builds_skipped(self):
        runnable, skipped = select_sol_spawns(
            [exec_spawn(), aot_spawn()])
        self.assertEqual(runnable, [aot_spawn()])
        self.assertEqual(skipped, {"host-tool build": 1})

    def test_cached_failed_and_bare_skipped(self):
        cached = dict(aot_spawn(), cacheHit=True)
        failed = dict(kernel_spawn(), exitCode=1)
        bare = dict(aot_spawn(), commandArgs=[])
        runnable, skipped = select_sol_spawns(
            [cached, failed, bare, aot_spawn()])
        self.assertEqual(runnable, [aot_spawn()])
        self.assertEqual(skipped["cache hit"], 1)
        self.assertEqual(skipped["bazel exit 1"], 1)
        self.assertEqual(sum(skipped.values()), 3)


class HashTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-hash-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, name, data):
        path = os.path.join(self.tmp, name)
        with open(path, "wb") as fh:
            fh.write(data)
        return path

    def test_snapshot_and_match(self):
        first = self.write("a.bin", b"framework-bytes")
        second = self.write("b.bin", b"kernel-bytes")
        before = snapshot_hashes([first, second])
        self.assertTrue(hashes_match(before, snapshot_hashes([first, second])))
        self.assertEqual(len(before), 2)
        self.assertTrue(all(len(v) == 64 for v in before.values()))

    def test_changed_bytes_mismatch(self):
        path = self.write("a.bin", b"v1")
        before = snapshot_hashes([path])
        self.write("a.bin", b"v2")
        self.assertFalse(hashes_match(before, snapshot_hashes([path])))

    def test_missing_file_is_none_and_mismatch(self):
        path = os.path.join(self.tmp, "absent.bin")
        snap = snapshot_hashes([path])
        self.assertIsNone(snap[path])
        self.assertFalse(hashes_match(snap, snapshot_hashes([path])))

    def test_empty_snapshot_never_matches(self):
        self.assertFalse(hashes_match({}, {}))

    def test_cpu_seconds(self):
        self.assertAlmostEqual(
            cpu_seconds({"user_s": 1.1, "sys_s": 0.2}), 1.3)
        self.assertIsNone(cpu_seconds({"user_s": None, "sys_s": 0.2}))
        self.assertIsNone(cpu_seconds({}))


class MoveAsideChainTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-aside-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, name, data):
        path = os.path.join(self.tmp, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(data)
        return path

    def test_files_moved_and_back(self):
        first = self.write("out/App", b"original")
        second = self.write("out/kernel_blob.bin", b"kernel")
        backup_dir = os.path.join(self.tmp, "backup")
        mapping = move_aside_chain([first, second], backup_dir)
        self.assertFalse(os.path.lexists(first))
        self.assertFalse(os.path.lexists(second))
        # The chain writes fresh files in their place.
        self.write("out/App", b"chain-wrote-this")
        restore_tree(mapping)
        with open(first, "rb") as fh:
            self.assertEqual(fh.read(), b"original")
        with open(second, "rb") as fh:
            self.assertEqual(fh.read(), b"kernel")
        self.assertFalse(os.path.exists(backup_dir + "/0"))

    def test_directory_output_travels_whole(self):
        bundle = self.write("out/App.framework/App", b"original")
        tree = os.path.join(self.tmp, "out", "App.framework")
        mapping = move_aside_chain(
            [tree, os.path.join(tree, "App")],
            os.path.join(self.tmp, "backup"))
        # The directory moved whole; the inner path was not moved twice.
        self.assertEqual(list(mapping), [tree])
        self.assertFalse(os.path.lexists(tree))
        # The step failed before recreating its directory (the round-3
        # crash): restore still brings Bazel's tree back.
        restore_tree(mapping)
        with open(bundle, "rb") as fh:
            self.assertEqual(fh.read(), b"original")

    def test_restore_recreates_parent_dirs(self):
        target = self.write("out/dir/App", b"original")
        mapping = move_aside_chain([target],
                                   os.path.join(self.tmp, "backup"))
        # The chain removed the whole directory and failed: moving the
        # file back must recreate its parents, not crash.
        shutil.rmtree(os.path.join(self.tmp, "out"))
        self.assertFalse(os.path.exists(os.path.dirname(target)))
        restore_tree(mapping)
        with open(target, "rb") as fh:
            self.assertEqual(fh.read(), b"original")

    def test_missing_output_raises_and_restores_partial(self):
        first = self.write("a/App", b"original")
        with self.assertRaises(RuntimeError):
            move_aside_chain([os.path.join(self.tmp, "a", "App"),
                              os.path.join(self.tmp, "absent")],
                             os.path.join(self.tmp, "backup"))
        with open(first, "rb") as fh:
            self.assertEqual(fh.read(), b"original")

    def test_restore_with_missing_backup_raises(self):
        with self.assertRaises(RuntimeError):
            restore_tree({os.path.join(self.tmp, "App"):
                          os.path.join(self.tmp, "gone")})

    def test_covered_by(self):
        self.assertTrue(covered_by("/a/b", ["/a"]))
        self.assertTrue(covered_by("/a", ["/a"]))
        self.assertFalse(covered_by("/a", ["/a/b"]))
        self.assertFalse(covered_by("/ab", ["/a"]))

    def test_path_depth_parents_first(self):
        paths = ["/a/b/c", "/a", "/a/b"]
        self.assertEqual(sorted(paths, key=path_depth),
                         ["/a", "/a/b", "/a/b/c"])


class SweepSideEffectsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-sweep-")
        self.bazel_out = os.path.join(self.tmp, "execroot", "bazel-out")
        os.makedirs(os.path.join(self.bazel_out, "x"))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def write(self, rel, data=b"x"):
        path = os.path.join(self.bazel_out, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(data)
        return path

    def test_undeclared_sibling_removed_declared_kept(self):
        # A step leaves an undeclared side-effect file next to its
        # declared output: the sweep removes it, Bazel's own files and
        # the declared outputs stay.
        declared = self.write("x/App.framework.zip", b"declared")
        self.write("x/Info.plist", b"bazel-own")
        before = snapshot_tree(self.bazel_out)
        side = self.write("x/App.framework/App", b"side-effect")
        swept = sweep_chain_side_effects(self.bazel_out, [declared],
                                         before)
        self.assertEqual(swept["n"], 2)
        self.assertIn("x/App.framework/App", swept["paths"])
        self.assertIn("x/App.framework", swept["paths"])
        self.assertFalse(os.path.lexists(side))
        with open(declared, "rb") as fh:
            self.assertEqual(fh.read(), b"declared")

    def test_nothing_new_nothing_removed(self):
        declared = self.write("x/o.zip")
        before = snapshot_tree(self.bazel_out)
        self.assertEqual(sweep_chain_side_effects(self.bazel_out,
                                                 [declared], before),
                         {"n": 0, "paths": []})

    def test_missing_bazel_out_is_empty(self):
        shutil.rmtree(self.bazel_out)
        self.assertEqual(sweep_chain_side_effects(
            self.bazel_out, ["/nowhere/o"], snapshot_tree(self.tmp)),
            {"n": 0, "paths": []})


class SweepPassesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-passes-")
        self.bazel_out = os.path.join(self.tmp, "execroot", "bazel-out")
        os.makedirs(os.path.join(self.bazel_out, "x"))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def write(self, rel, data=b"x"):
        path = os.path.join(self.bazel_out, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(data)
        return path

    def test_protected_covers_equal_under_and_above(self):
        declared = [os.path.join(self.bazel_out, "x", "out.zip")]
        self.assertTrue(sol._is_protected(declared[0], declared))
        self.assertTrue(sol._is_protected(
            os.path.join(self.bazel_out, "x", "out.zip", "inner"), declared))
        self.assertTrue(sol._is_protected(
            os.path.join(self.bazel_out, "x"), declared))
        self.assertFalse(sol._is_protected(
            os.path.join(self.bazel_out, "x", "other.o"), declared))
        self.assertFalse(sol._is_protected(
            os.path.join(self.bazel_out, "x-out.zip"), declared))

    def test_file_pass_keeps_declared_and_before(self):
        declared = self.write("x/out.zip")
        self.write("x/Info.plist", b"bazel-own")
        before = snapshot_tree(self.bazel_out)
        side = self.write("x/side.o", b"side-effect")
        removed = []
        sol._sweep_dir_files(os.path.join(self.bazel_out, "x"), ["side.o"],
                             self.bazel_out, [os.path.normpath(declared)],
                             before, removed)
        self.assertEqual(removed, ["x/side.o"])
        self.assertFalse(os.path.lexists(side))
        self.assertTrue(os.path.isfile(declared))

    def test_link_pass_removes_undeclared_links(self):
        # Directory symlinks surface in dirnames (file symlinks ride
        # the file pass instead).
        target_dir = os.path.join(self.bazel_out, "x", "real")
        os.makedirs(target_dir)
        with open(os.path.join(target_dir, "f.o"), "wb") as fh:
            fh.write(b"x")
        before = snapshot_tree(self.bazel_out)
        link = os.path.join(self.bazel_out, "x", "alias")
        os.symlink(target_dir, link)
        removed = []
        sol._sweep_dir_links(os.path.join(self.bazel_out, "x"), ["alias"],
                             self.bazel_out, [], before, removed)
        self.assertEqual(removed, ["x/alias"])
        self.assertFalse(os.path.lexists(link))
        self.assertTrue(os.path.isdir(target_dir))

    def test_dir_entries_do_files_then_links(self):
        target_dir = os.path.join(self.bazel_out, "x", "real")
        os.makedirs(target_dir)
        before = snapshot_tree(self.bazel_out)
        side = self.write("x/side.o", b"side-effect")
        link = os.path.join(self.bazel_out, "x", "alias")
        os.symlink(target_dir, link)
        removed = []
        sol._sweep_dir_entries(os.path.join(self.bazel_out, "x"),
                               ["real", "alias"], ["side.o"],
                               self.bazel_out, [], before, removed)
        self.assertEqual(sorted(removed), ["x/alias", "x/side.o"])
        self.assertFalse(os.path.lexists(side))
        self.assertFalse(os.path.lexists(link))

    def test_failure_order_removes_link_before_raising(self):
        # One top-down walk, files-then-links per directory in walk
        # order: the top directory's undeclared link goes before the
        # deeper unremovable file raises. A whole-tree file pass first
        # would raise with the link still there.
        target = os.path.join(self.tmp, "target")
        os.makedirs(target)
        before = snapshot_tree(self.bazel_out)
        locked = os.path.join(self.bazel_out, "locked")
        os.makedirs(locked)
        only = os.path.join(locked, "only.o")
        with open(only, "wb") as fh:
            fh.write(b"x")
        link = os.path.join(self.bazel_out, "dlink")
        os.symlink(target, link)
        real_remove = os.remove

        def fake_remove(path, *args, **kwargs):
            if os.path.basename(str(path)) == "only.o":
                raise OSError("denied")
            return real_remove(path, *args, **kwargs)

        with mock.patch.object(sol.os, "remove",
                               side_effect=fake_remove):
            with self.assertRaisesRegex(RuntimeError, "cannot remove"):
                sweep_chain_side_effects(self.bazel_out, [], before)
        self.assertFalse(os.path.lexists(link))
        self.assertTrue(os.path.lexists(only))

    def test_empty_dir_pass_removes_emptied_only(self):
        self.write("x/keep.o")
        before = snapshot_tree(self.bazel_out)
        os.makedirs(os.path.join(self.bazel_out, "x", "empty", "inner"))
        removed = sol._sweep_empty_dirs(self.bazel_out, [], before)
        self.assertEqual(sorted(removed),
                         ["x/empty", "x/empty/inner"])
        self.assertFalse(os.path.lexists(
            os.path.join(self.bazel_out, "x", "empty")))
        self.assertTrue(os.path.isfile(
            os.path.join(self.bazel_out, "x", "keep.o")))

    def test_drop_failure_names_path(self):
        with mock.patch.object(sol.os, "remove",
                               side_effect=OSError("denied")):
            with self.assertRaisesRegex(RuntimeError, "cannot remove"):
                sol._drop_chain_file(os.path.join(self.bazel_out, "x", "o"))


class VerifyFilesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-verify-")
        self.bundle = os.path.join(self.tmp, "out", "Bench.app")
        fw = os.path.join(self.bundle, "Frameworks", "App.framework")
        assets = os.path.join(fw, "flutter_assets")
        os.makedirs(assets)
        with open(os.path.join(fw, "App"), "wb") as fh:
            fh.write(b"app-binary")
        with open(os.path.join(assets, "kernel_blob.bin"), "wb") as fh:
            fh.write(b"kernel")
        with open(os.path.join(assets, "AssetManifest.json"), "w",
                  encoding="utf-8") as fh:
            fh.write("{}")
        other = os.path.join(self.bundle, "Frameworks", "Other.framework")
        os.makedirs(other)
        with open(os.path.join(other, "Other"), "wb") as fh:
            fh.write(b"decoy")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_device_picks_framework_binary(self):
        listed = [
            "/exec/bazel-out/x/bin/app/Info.plist",
            "/exec/bazel-out/x/bin/app/__app_framework_framework/"
            "App.framework/App",
        ]
        self.assertEqual(device_verify_files(listed), [listed[1]])
        self.assertEqual(device_verify_files(["/exec/other.o"]), [])

    def test_bundle_roots(self):
        bundle = self.bundle
        listed = [bundle, bundle + "/Info.plist",
                  "/exec/bazel-out/x/bin/app/app.dill"]
        self.assertEqual(sim_bundle_roots(listed), [bundle])

    def test_bundle_archives(self):
        listed = ["/exec/bazel-out/x/Bench.ipa",
                  "/exec/bazel-out/x/bin/app/app.dill"]
        self.assertEqual(sim_bundle_archives(listed),
                         ["/exec/bazel-out/x/Bench.ipa"])
        self.assertEqual(sim_bundle_archives(["/exec/a.o"]), [])

    def write_ipa(self, path, stamp=(2020, 1, 1, 0, 0, 0)):
        import zipfile
        with zipfile.ZipFile(path, "w") as archive:
            for entry in ("Payload/Bench.app/App",
                          "Payload/Bench.app/flutter_assets/"
                          "kernel_blob.bin"):
                info = zipfile.ZipInfo(entry, date_time=stamp)
                archive.writestr(info, b"bytes-for-" + entry.encode())

    def test_ipa_payload_covers_kernel_and_binary(self):
        ipa = os.path.join(self.tmp, "Bench.ipa")
        self.write_ipa(ipa)
        entries = ipa_entry_hashes(ipa)
        self.assertEqual(sorted(entries),
                         ["Payload/Bench.app/App",
                          "Payload/Bench.app/flutter_assets/"
                          "kernel_blob.bin"])
        self.assertTrue(all(len(v) == 64 for v in entries.values()))

    def test_ipa_metadata_only_matches(self):
        # Same payload, different zip timestamps: archive bytes differ,
        # but the proof (entry paths and contents) matches.
        first = os.path.join(self.tmp, "first.ipa")
        second = os.path.join(self.tmp, "second.ipa")
        self.write_ipa(first, stamp=(2020, 1, 1, 0, 0, 0))
        self.write_ipa(second, stamp=(2026, 5, 6, 7, 8, 0))
        self.assertNotEqual(sha256_file(first), sha256_file(second))
        self.assertEqual(ipa_entry_hashes(first),
                         ipa_entry_hashes(second))

    def test_ipa_payload_differs(self):
        first = os.path.join(self.tmp, "first.ipa")
        second = os.path.join(self.tmp, "second.ipa")
        self.write_ipa(first)
        import zipfile
        with zipfile.ZipFile(second, "w") as archive:
            archive.writestr("Payload/Bench.app/App", b"other-bytes")
        self.assertNotEqual(ipa_entry_hashes(first),
                            ipa_entry_hashes(second))

    def test_ipa_unreadable_fails_closed(self):
        bad = os.path.join(self.tmp, "bad.ipa")
        with open(bad, "wb") as fh:
            fh.write(b"not a zip")
        with self.assertRaises(RuntimeError):
            ipa_entry_hashes(bad)
        with self.assertRaises(RuntimeError):
            ipa_entry_hashes(os.path.join(self.tmp, "absent.ipa"))

    def test_app_dir_covers_every_file(self):
        found = app_dir_hashes(self.bundle)
        self.assertIn("Frameworks/App.framework/App", found)
        self.assertIn("Frameworks/App.framework/flutter_assets/"
                      "kernel_blob.bin", found)
        self.assertIn("Frameworks/App.framework/flutter_assets/"
                      "AssetManifest.json", found)
        self.assertIn("Frameworks/Other.framework/Other", found)

    def test_app_dir_links_hashed(self):
        inner = os.path.join(self.bundle, "Frameworks", "App.framework")
        os.symlink(inner, os.path.join(self.bundle, "Current"))
        alias = os.path.join(self.bundle, "App-alias")
        os.symlink(os.path.join(inner, "App"), alias)
        found = app_dir_hashes(self.bundle)
        self.assertIn("Current", found)
        self.assertEqual(found["App-alias"],
                         found["Frameworks/App.framework/App"])
        os.remove(os.path.join(inner, "App"))
        dangling = app_dir_hashes(self.bundle)
        self.assertIsNone(dangling["App-alias"])

    def write_apk(self, path, stamp=(2020, 1, 1, 0, 0, 0),
                  extra=b""):
        import zipfile
        with zipfile.ZipFile(path, "w") as archive:
            for entry in ("classes.dex", "lib/arm64-v8a/libapp.so"):
                info = zipfile.ZipInfo(entry, date_time=stamp)
                info.extra = extra
                archive.writestr(info, b"apk-bytes-for-" + entry.encode())

    def test_apk_payload_ignores_zip_metadata(self):
        first = os.path.join(self.tmp, "first.apk")
        second = os.path.join(self.tmp, "second.apk")
        self.write_apk(first, stamp=(2020, 1, 1, 0, 0, 0))
        self.write_apk(second, stamp=(2026, 5, 6, 7, 8, 0),
                       extra=b"\xfe\xca\x02\x00ab")
        self.assertNotEqual(sha256_file(first), sha256_file(second))
        self.assertEqual(sol.archive_entry_hashes(first),
                         sol.archive_entry_hashes(second))
        self.assertIn("classes.dex", sol.archive_entry_hashes(first))

    def test_plan_android_reads_every_apk_entry(self):
        root = os.path.join(self.tmp, "execroot")
        os.makedirs(root)
        apk = os.path.join(root, "app_android.apk")
        self.write_apk(apk)
        capture = FakeCapture(root, [apk])
        plan = plan_verify_snapshot(capture, self.tmp, self.tmp, root,
                                    "android_release", True)
        snapshot = read_verify_snapshot(plan)
        self.assertEqual(len(snapshot), 2)
        self.assertTrue(all("::classes.dex" in k or
                            "::lib/arm64-v8a/libapp.so" in k
                            for k in snapshot))

    def test_plan_web_reads_every_output_file(self):
        root = os.path.join(self.tmp, "execroot")
        os.makedirs(os.path.join(root, "assets", "fonts"))
        for rel in ["index.html", "main.dart.js",
                    os.path.join("assets", "fonts", "font.ttf")]:
            path = os.path.join(root, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as fh:
                fh.write(rel.encode())
        capture = FakeCapture(root, [root])
        plan = plan_verify_snapshot(capture, self.tmp, self.tmp, root,
                                    "web_release", True)
        snapshot = read_verify_snapshot(plan)
        self.assertEqual(sorted(k.split("::", 1)[1] for k in snapshot),
                         ["assets/fonts/font.ttf", "index.html",
                          "main.dart.js"])

    def test_plan_web_debug_hashes_only_the_deployment_root(self):
        # A debug web build also declares DDC staging directories beside
        # the bundle; only the bundle that carries index.html is the
        # deployment output the proof covers.
        root = os.path.join(self.tmp, "execroot")
        bundle = os.path.join(root, "bazel-out", "x", "bin", "app",
                              "app_web_web")
        staging = os.path.join(root, "bazel-out", "x", "bin", "app",
                               "app_web_dev")
        os.makedirs(bundle)
        os.makedirs(staging)
        for path, body in [(os.path.join(bundle, "index.html"), b"page"),
                           (os.path.join(bundle, "main.dart.js"), b"js"),
                           (os.path.join(staging, "main.dart"), b"staged")]:
            with open(path, "wb") as fh:
                fh.write(body)
        capture = FakeCapture(root, [bundle, staging])
        plan = plan_verify_snapshot(capture, self.tmp, self.tmp, root,
                                    "web_debug", True)
        snapshot = read_verify_snapshot(plan)
        self.assertEqual(sorted(k.split("::", 1)[1] for k in snapshot),
                         ["index.html", "main.dart.js"])

    def test_plan_web_without_deployment_root_fails(self):
        # Several declared directories and none carrying index.html are
        # staging trees, not a web build output: fail loudly.
        root = os.path.join(self.tmp, "execroot")
        first = os.path.join(root, "bazel-out", "x", "bin", "app", "one")
        second = os.path.join(root, "bazel-out", "x", "bin", "app", "two")
        os.makedirs(first)
        os.makedirs(second)
        for path in (os.path.join(first, "a.dart"),
                     os.path.join(second, "b.dart")):
            with open(path, "wb") as fh:
                fh.write(b"staged")
        capture = FakeCapture(root, [first, second])
        with self.assertRaisesRegex(RuntimeError, "no bundle"):
            plan_verify_snapshot(capture, self.tmp, self.tmp, root,
                                 "web_debug", True)

    def test_plan_android_without_archive_fails(self):
        root = os.path.join(self.tmp, "execroot")
        dill = os.path.join(root, "bazel-out", "x", "app.dill")
        os.makedirs(os.path.dirname(dill))
        with open(dill, "wb") as fh:
            fh.write(b"dill")
        capture = FakeCapture(root, ["bazel-out/x/app.dill"])
        with self.assertRaisesRegex(RuntimeError, "no bundle"):
            plan_verify_snapshot(capture, self.tmp, self.tmp, root,
                                 "android_release", True)

    def test_plan_web_without_directory_fails(self):
        root = os.path.join(self.tmp, "execroot")
        dill = os.path.join(root, "bazel-out", "x", "app.dill")
        os.makedirs(os.path.dirname(dill))
        with open(dill, "wb") as fh:
            fh.write(b"dill")
        capture = FakeCapture(root, ["bazel-out/x/app.dill"])
        with self.assertRaisesRegex(RuntimeError, "no bundle"):
            plan_verify_snapshot(capture, self.tmp, self.tmp, root,
                                 "web_release", True)

    def test_plan_rejects_bundle_less_listing(self):
        # Declared outputs only, never a glob over bazel-out: a listing
        # with no bundle fails loudly instead of globbing leftovers.
        root = os.path.join(self.tmp, "execroot")
        dill = os.path.join(root, "bazel-out", "x", "app.dill")
        os.makedirs(os.path.dirname(dill))
        with open(dill, "wb") as fh:
            fh.write(b"dill")
        capture = FakeCapture(root, ["bazel-out/x/app.dill"])
        with self.assertRaisesRegex(RuntimeError, "no app bundle"):
            plan_verify_snapshot(capture, self.tmp, self.tmp, root,
                                 "sim_debug", True)

    def test_plan_device_lists_framework_binary(self):
        rel = ("bazel-out/x/bin/app/__app_framework_framework/"
               "App.framework/App")
        root = os.path.join(self.tmp, "execroot")
        target = os.path.join(root, rel)
        os.makedirs(os.path.dirname(target))
        with open(target, "wb") as fh:
            fh.write(b"app")
        capture = FakeCapture(root, [rel])
        plan = plan_verify_snapshot(capture, self.tmp, self.tmp, root,
                                    "device_release", True)
        self.assertEqual(plan[0], "files")
        self.assertEqual(read_verify_snapshot(plan),
                         snapshot_hashes([target]))

    def test_plan_sim_reads_bundle_payload(self):
        root = os.path.join(self.tmp, "execroot")
        os.makedirs(root)
        ipa = os.path.join(root, "Bench.ipa")
        self.write_ipa(ipa)
        capture = FakeCapture(root, [ipa])
        plan = plan_verify_snapshot(capture, self.tmp, self.tmp, root,
                                    "sim_debug", True)
        snapshot = read_verify_snapshot(plan)
        self.assertEqual(len(snapshot), 2)
        self.assertTrue(all("::Payload/Bench.app/" in key
                            for key in snapshot))


class MeasureTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-measure-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_whole_tree_cpu_without_time_bin(self):
        cost = measure_process_tree(
            [sys.executable, "-c", "pass"], self.tmp)
        self.assertIsNone(cost["instructions"])
        self.assertEqual(cost["returncode"], 0)
        self.assertEqual(cost["method"], "rusage-children")
        self.assertGreaterEqual(cost["user_s"], 0.0)
        self.assertGreaterEqual(cost["sys_s"], 0.0)

    def test_time_bin_flag_ignored_same_method(self):
        cost = measure_with_time(
            [sys.executable, "-c", "pass"], self.tmp,
            time_bin=os.path.join(self.tmp, "absent"))
        self.assertEqual(cost["method"], "rusage-children")
        self.assertGreaterEqual(cost["user_s"], 0.0)

    def test_exit_code_passes_through(self):
        cost = measure_process_tree(
            [sys.executable, "-c", "import sys; sys.exit(3)"], self.tmp)
        self.assertEqual(cost["returncode"], 3)

    def test_grandchild_cpu_included(self):
        child = ("import subprocess, sys\n"
                 "subprocess.run([sys.executable, '-c',\n"
                 " 'import time\\n'\n"
                 " 's=time.perf_counter()\\n'\n"
                 " 'while time.perf_counter()-s<0.5:\\n'\n"
                 " ' pass'])")
        cost = measure_process_tree(
            [sys.executable, "-c", child], self.tmp)
        self.assertEqual(cost["returncode"], 0)
        self.assertGreater(cost["user_s"] + cost["sys_s"], 0.1)


class ChainTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-chain-")
        self.log = os.path.join(self.tmp, "execlog.json")
        with open(self.log, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(aot_spawn()) + "\n")
            fh.write(json.dumps(dict(kernel_spawn(), cacheHit=True)) + "\n")
        self.report = os.path.join(self.tmp, "chain.json")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def fake_runner(self, spawn):
        return {"mnemonic": spawn["mnemonic"], "target": "",
                "instructions": None, "real_s": 0.1, "user_s": 0.08,
                "sys_s": 0.02, "exit_code": 0, "stderr_tail": None,
                "command": []}

    def test_chain_runs_executed_only_and_writes_report(self):
        report = run_chain(self.log, self.tmp, self.report, 60.0,
                           runner=self.fake_runner)
        self.assertEqual(report["n_replayed"], 1)
        self.assertFalse(report["stopped_early"])
        self.assertEqual(report["failed"], [])
        self.assertEqual(report["skipped"], {"cache hit": 1})
        self.assertAlmostEqual(report["sol_cpu_s"], 0.1)
        self.assertEqual(chain_replayed(self.report), 1)
        with open(self.report, encoding="utf-8") as fh:
            saved = json.load(fh)
        self.assertEqual(
            saved["by_mnemonic"]["FlutterAotMacho"]["count"], 1)

    def test_kernel_with_exec_tool_argv_is_in_chain(self):
        log = os.path.join(self.tmp, "kernel.json")
        with open(log, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(kernel_spawn()) + "\n")
        report = run_chain(log, self.tmp, self.report, 60.0,
                           runner=self.fake_runner)
        self.assertEqual(report["n_replayed"], 1)
        self.assertEqual(report["skipped"], {})

    def test_missing_report_raises(self):
        with self.assertRaises(RuntimeError):
            chain_replayed(os.path.join(self.tmp, "absent.json"))

    def test_read_chain_report_none_when_absent(self):
        self.assertIsNone(read_chain_report(
            os.path.join(self.tmp, "absent.json")))

    def test_main_chain_exit_codes(self):
        ok_log = os.path.join(self.tmp, "ok.json")
        with open(ok_log, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(aot_spawn()) + "\n")
        import types
        cmd = types.SimpleNamespace(log=ok_log, execroot=self.tmp,
                                    report=self.report, timeout=60.0)
        with mock.patch("sol.chain_all",
                        return_value={"failed": [], "n_replayed": 1,
                                      "skipped": {}}):
            self.assertEqual(sol.main_chain(cmd), 0)
        with mock.patch("sol.chain_all",
                        return_value={"failed": [{"mnemonic": "X"}],
                                      "n_replayed": 1, "skipped": {}}):
            self.assertEqual(sol.main_chain(cmd), 1)


class ChainRecordTest(unittest.TestCase):
    def report(self):
        return {
            "n_replayed": 2,
            "by_mnemonic": {"Genrule": {"count": 2, "failures": 0,
                                        "user_s_total": 1.0,
                                        "sys_s_total": 0.5,
                                        "cpu_s_missing": 0}},
            "skipped": {"host-tool build": 3},
            "failed": [],
            "ordering_failed": None,
            "sol_cpu_s": 1.5,
            "sol_real_s": 2.0,
        }

    def no_differ(self):
        return {"n": 0, "differ": []}

    def test_describe_chain_shape(self):
        chain = describe_chain(self.report(), self.no_differ())
        self.assertEqual(chain["steps"],
                         {"Genrule": {"count": 2, "cpu_s": 1.5}})
        self.assertEqual(chain["skipped"], {"host-tool build": 3})
        self.assertEqual(chain["failed"], [])
        self.assertIsNone(chain["ordering_failed"])
        self.assertEqual(chain["verify_differ"], self.no_differ())
        self.assertEqual(chain["output_drift"], {"n": 0, "paths": []})
        self.assertEqual(chain["sol_cpu_s"], 1.5)
        self.assertEqual(chain["status"], "ok")
        self.assertNotIn("command", json.dumps(chain))

    def test_describe_chain_missing_cpu(self):
        report = self.report()
        report["by_mnemonic"] = {"Genrule": {"count": 1}}
        chain = describe_chain(report, self.no_differ())
        self.assertEqual(chain["steps"],
                         {"Genrule": {"count": 1, "cpu_s": None}})

    def test_describe_chain_no_report(self):
        chain = describe_chain(None, {"n": 1, "differ": [
            {"path": "a", "before": "b", "after": None}]})
        self.assertEqual(chain["status"], "no report")
        self.assertIsNone(chain["sol_cpu_s"])

    def test_describe_chain_ordering_status(self):
        report = self.report()
        report["ordering_failed"] = {"mnemonic": "SwiftStdlibCopy",
                                     "input": "bazel-out/x/app_lipobin"}
        report["failed"] = [{"mnemonic": "SwiftStdlibCopy",
                             "exit": "ordering-failed",
                             "stderr_tail": "ordering failure"}]
        chain = describe_chain(report, self.no_differ())
        self.assertEqual(chain["status"], "ordering-failed")
        self.assertEqual(chain["ordering_failed"]["input"],
                         "bazel-out/x/app_lipobin")

    def test_verify_differences_relative(self):
        before = {"/exec/a": "1", "/exec/b": "2"}
        after = {"/exec/a": "1", "/exec/b": "3", "/exec/c": "4"}
        differ = verify_differences(before, after, "/exec")
        self.assertEqual(differ, {"n": 2, "differ": [
            {"path": "b", "before": "2", "after": "3"},
            {"path": "c", "before": None, "after": "4"}]})

    def test_verify_differences_capped_at_ten(self):
        before = {"f%02d" % n: "1" for n in range(12)}
        after = {"f%02d" % n: "2" for n in range(12)}
        differ = verify_differences(before, after, "/exec")
        self.assertEqual(differ["n"], 12)
        self.assertEqual(len(differ["differ"]), 10)
        self.assertEqual(differ["differ"][0]["before"], "1")
        self.assertEqual(differ["differ"][0]["after"], "2")

    def test_bundle_keys_shown_as_is(self):
        before = {"bazel-out/x/Bench.ipa::Payload/a": "1"}
        differ = verify_differences(before, {}, "/exec")
        self.assertEqual(differ["differ"][0]["path"],
                         "bazel-out/x/Bench.ipa::Payload/a")

    def test_flow_reason_ok(self):
        self.assertEqual(flow_reason(describe_chain(self.report(),
                                                    self.no_differ()),
                                    0),
                         "ok")

    def test_flow_reason_names_step_and_files(self):
        report = self.report()
        report["failed"] = [{"mnemonic": "Genrule", "exit": 3,
                             "stderr_tail": "boom"}]
        chain = describe_chain(
            report, {"n": 1, "differ": [
                {"path": "b/App", "before": "1", "after": None}]})
        reason = flow_reason(chain, 1)
        self.assertIn("Genrule", reason)
        self.assertIn("exit 3", reason)
        self.assertIn("b/App", reason)

    def test_flow_reason_names_ordering(self):
        report = self.report()
        report["ordering_failed"] = {"mnemonic": "SwiftStdlibCopy",
                                     "input": "bazel-out/x/app_lipobin"}
        report["failed"] = [{"mnemonic": "SwiftStdlibCopy",
                             "exit": "ordering-failed",
                             "stderr_tail": "ordering failure"}]
        reason = flow_reason(describe_chain(report, self.no_differ()), 0)
        self.assertIn("SwiftStdlibCopy", reason)
        self.assertIn("bazel-out/x/app_lipobin", reason)

    def test_flow_reason_no_report(self):
        chain = describe_chain(None, self.no_differ())
        self.assertIn("no report", flow_reason(chain, 1))

    def test_rep_sort_key_numeric(self):
        names = ["rep10", "rep2", "rep1", "other"]
        self.assertEqual(sorted(names, key=rep_sort_key),
                         ["rep1", "rep2", "rep10", "other"])

    def test_rep_sort_key_numeric(self):
        names = ["rep10", "rep2", "rep1", "other"]
        self.assertEqual(sorted(names, key=rep_sort_key),
                         ["rep1", "rep2", "rep10", "other"])


class ProfileTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-profile-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def host_spawn(self, mnemonic="Genrule", target="//tools:host_tool",
                   rel="bazel-out/darwin-opt-exec-ABCD/bin/tool"):
        return {
            "commandArgs": ["sh", "-c", "exit 0"],
            "environmentVariables": [],
            "listedOutputs": [rel],
            "mnemonic": mnemonic,
            "exitCode": 0,
            "targetLabel": target,
        }

    def write_host_output(self, rel, data=b"host-bytes"):
        path = os.path.join(self.tmp, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(data)
        return path

    def runner(self, cpu=0.5, exit_code=0):
        def run(spawn):
            del spawn
            return {"mnemonic": "", "target": "", "instructions": None,
                    "real_s": 0.1, "user_s": cpu - 0.1, "sys_s": 0.1,
                    "exit_code": exit_code,
                    "stderr_tail": "boom" if exit_code else None,
                    "command": []}
        return run

    def test_host_tool_spawns_filters(self):
        cached = dict(self.host_spawn(), cacheHit=True)
        failed = dict(self.host_spawn(), exitCode=2)
        bare = dict(self.host_spawn(), commandArgs=[])
        runnable, skipped = host_tool_spawns(
            [aot_spawn(), cached, failed, bare, self.host_spawn()])
        self.assertEqual(len(runnable), 1)
        self.assertEqual(skipped, {"cache hit": 1, "bazel exit 2": 1,
                                   "no command": 1})

    def test_replay_host_tools_aggregates(self):
        rel = "bazel-out/darwin-opt-exec-ABCD/bin/tool"
        dst = self.write_host_output(rel)
        host = replay_host_spawns(
            [aot_spawn(), self.host_spawn()], self.tmp, 60.0,
            os.path.join(self.tmp, "backup"), runner=self.runner(cpu=0.5))
        self.assertEqual(host["total"], 0.5)
        self.assertEqual(host["by_mnemonic"], {"Genrule": 0.5})
        self.assertEqual(host["top_targets"], [["//tools:host_tool", 0.5]])
        self.assertEqual(host["failed"], [])
        self.assertEqual(host["count"], 1)
        self.assertNotIn("command", json.dumps(host))
        with open(dst, "rb") as fh:
            self.assertEqual(fh.read(), b"host-bytes")

    def test_replay_continues_past_failure(self):
        first = self.host_spawn(
            rel="bazel-out/darwin-opt-exec-ABCD/bin/first")
        second = self.host_spawn(
            rel="bazel-out/darwin-opt-exec-ABCD/bin/second")
        self.write_host_output(
            "bazel-out/darwin-opt-exec-ABCD/bin/first")
        self.write_host_output(
            "bazel-out/darwin-opt-exec-ABCD/bin/second")
        calls = []

        def run(spawn):
            calls.append(spawn["listedOutputs"])
            if "first" in spawn["listedOutputs"][0]:
                return {"mnemonic": "", "target": "", "instructions": None,
                        "real_s": 0.1, "user_s": 0.1, "sys_s": 0.1,
                        "exit_code": 3, "stderr_tail": "boom", "command": []}
            return self.runner(cpu=0.5)(spawn)

        host = replay_host_spawns(
            [first, second], self.tmp, 60.0,
            os.path.join(self.tmp, "backup"), runner=run)
        self.assertEqual(len(calls), 2)
        self.assertEqual(len(host["failed"]), 1)
        self.assertEqual(host["failed"][0]["exit"], 3)
        self.assertEqual(host["total"], 0.2 + 0.5)

    def test_replay_without_hosts_is_zero(self):
        host = replay_host_spawns(
            [aot_spawn()], self.tmp, 60.0,
            os.path.join(self.tmp, "backup"), runner=self.runner())
        self.assertEqual(host["total"], 0.0)
        self.assertEqual(host["top_targets"], [])

    def test_move_aside_failure_recorded(self):
        host = replay_host_spawns(
            [self.host_spawn()], self.tmp, 60.0,
            os.path.join(self.tmp, "backup"), runner=self.runner())
        self.assertIsNone(host["total"])
        self.assertIn("move-aside", host["error"])

    def test_build_profile_sol_and_residual(self):
        jvm = {"total": 5.0, "phases": {"Initialize command": 3.0}}
        host = {"total": 1.0, "by_mnemonic": {}, "top_targets": []}
        profile = build_profile(10.0, jvm, host, {"cpu_s": 2.5}, {})
        self.assertEqual(profile["sol_source"], "sol")
        self.assertEqual(profile["sol_cpu_s"], 2.5)
        self.assertAlmostEqual(profile["residual"], 1.5)

    def test_build_profile_chain_cpu_substitution(self):
        jvm = {"total": 5.0, "phases": {}}
        host = {"total": 1.0, "by_mnemonic": {}, "top_targets": []}
        profile = build_profile(
            10.0, jvm, host, None, {"sol_cpu_s": 2.0})
        self.assertEqual(profile["sol_source"], "chain-cpu")
        self.assertEqual(profile["sol_cpu_s"], 2.0)
        self.assertAlmostEqual(profile["residual"], 2.0)

    def test_build_profile_missing_part_is_none(self):
        profile = build_profile(
            10.0, {"total": None, "phases": {}},
            {"total": 1.0}, None, {"sol_cpu_s": None})
        self.assertIsNone(profile["residual"])
        self.assertIsNone(profile["sol_cpu_s"])

    def test_summarize_jvm_medians(self):
        jvms = [{"total": 1.0, "phases": {"A": 1.0}},
                {"total": 3.0, "phases": {"A": 2.0, "B": 1.0}},
                {"total": 2.0, "phases": {"A": 3.0}}]
        self.assertEqual(summarize_jvm(jvms),
                         {"total": 2.0, "phases": {"A": 2.0, "B": 1.0}})

    def test_summarize_host_tools_medians(self):
        hosts = [{"total": 1.0, "by_mnemonic": {"G": 1.0},
                  "by_target": {"//t:x": 1.0}, "failed": []},
                 {"total": 3.0, "by_mnemonic": {"G": 3.0},
                  "by_target": {"//t:x": 2.0, "//t:y": 1.0},
                  "failed": [{"mnemonic": "G", "exit": 1}]},
                 {"total": 2.0, "by_mnemonic": {"G": 2.0},
                  "by_target": {"//t:x": 3.0, "//t:y": 2.0}, "failed": []}]
        summary = summarize_host_tools(hosts)
        self.assertEqual(summary["total"], 2.0)
        self.assertEqual(summary["by_mnemonic"], {"G": 2.0})
        self.assertEqual(summary["top_targets"],
                         [["//t:x", 2.0], ["//t:y", 2.0]])
        self.assertEqual(len(summary["failed"]), 1)

    def test_summarize_profile_sums(self):
        records = [{
            "profile": {
                "jvm": {"total": 5.0, "phases": {}},
                "host_tools": {"total": 1.0, "by_mnemonic": {},
                               "by_target": {}, "failed": []},
                "sol_cpu_s": 2.0}}]
        profile = summarize_profile(records, 10.0, 2.0, True)
        self.assertEqual(profile["sol_source"], "sol")
        self.assertAlmostEqual(profile["residual"], 2.0)
        profile = summarize_profile(records, 10.0, None, False)
        self.assertEqual(profile["sol_source"], "chain-cpu")
        self.assertAlmostEqual(profile["residual"], 2.0)

    def test_read_jvm_cpu_missing_records(self):
        jvm = read_jvm_cpu(os.path.join(self.tmp, "absent.json"))
        self.assertIsNone(jvm["total"])
        self.assertIn("error", jvm)

    def test_save_gzipped_roundtrip(self):
        src = os.path.join(self.tmp, "a.json")
        with open(src, "w", encoding="utf-8") as fh:
            fh.write('{"traceEvents": []}')
        dst = os.path.join(self.tmp, "a.json.gz")
        save_gzipped(src, dst)
        import gzip
        with gzip.open(dst, "rt", encoding="utf-8") as fh:
            self.assertEqual(fh.read(), '{"traceEvents": []}')


JVM_WARNING = (
    "OpenJDK 64-Bit Server VM warning: Options -Xverify:none and "
    "-noverify were deprecated in JDK 13 and will likely be removed in "
    "a future release.")


class FakeCapture:
    """Canned stdout for info/cquery, like capture_bazel_output."""

    def __init__(self, execroot, files):
        self.execroot = execroot
        self.files = files

    def __call__(self, argv, cwd=None):
        if "cquery" in argv:
            return "\n".join(self.files) + "\n"
        if "info" in argv:
            return self.execroot + "\n"
        return ""


class InheritingCapture(FakeCapture):
    """Reproduces cquery's `.bazelrc` `test` inheritance: `--output=files`
    also lists the unbuilt aspect outputs, `--output=starlark` over
    `target.files` lists DefaultInfo.files only."""

    def __init__(self, execroot, files, unbuilt):
        super().__init__(execroot, files)
        self.unbuilt = unbuilt

    def __call__(self, argv, cwd=None):
        if "cquery" in argv and "--output=files" in argv:
            return "\n".join(self.unbuilt + self.files) + "\n"
        return super().__call__(argv, cwd)


class CqueryArgvTest(unittest.TestCase):
    def test_argv_shape_in_both_modes(self):
        flags = ["-c", "opt"]
        for batch in (True, False):
            argv = sol.cquery_argv("/ob", "//app:app_web", flags, batch)
            head = (sol.command_prefix(batch)
                    + sol.startup_options("/ob"))
            self.assertEqual(argv[:len(head)], head)
            self.assertEqual(argv[len(head)], "cquery")
            self.assertIn("--output=starlark", argv)
            self.assertNotIn("--output=files", argv)
            exprs = [a for a in argv if a.startswith("--starlark:expr=")]
            self.assertEqual(len(exprs), 1)
            self.assertIn("target.files", exprs[0])
            self.assertIn("//app:app_web", argv)
            self.assertEqual(argv[-2:], flags)

    def test_web_listing_ignores_unbuilt_aspect_outputs(self):
        tmp = tempfile.mkdtemp(prefix="sol-web-query-")
        self.addCleanup(shutil.rmtree, tmp, True)
        out_base = os.path.join(tmp, "out")
        root = os.path.join(out_base, "execroot", "ws")
        bundle = "bazel-out/k8-opt/bin/app/app_web_web"
        staging = "bazel-out/k8-dbg/bin/app/app_web_dev"
        for rel in (bundle, staging):
            os.makedirs(os.path.join(root, rel))
        with open(os.path.join(root, bundle, "index.html"), "wb") as fh:
            fh.write(b"page")
        unbuilt = ["bazel-out/k8-opt/bin/app/app_web.dart_analyze.analyzed",
                   "bazel-out/k8-opt/bin/app/app_web.dart_analyze.formatted"]
        capture = InheritingCapture(root, [bundle, staging], unbuilt)
        with self.assertRaisesRegex(RuntimeError, "does not exist"):
            capture_files = sol.cquery_argv  # sanity: helper exists
            self.assertTrue(capture_files)
            capture(["bazel", "cquery", "--output=files"])  # leaks
            sol.check_under_base(os.path.join(root, unbuilt[0]),
                                     out_base, "cquery")
        files = sol.query_target_files(
            capture, tmp, out_base, "//app:app_web", [], False)
        self.assertEqual(files, [os.path.join(root, bundle),
                                 os.path.join(root, staging)])
        for config in ("web_release", "web_debug"):
            plan = plan_verify_snapshot(capture, tmp, out_base, root,
                                        config, True)
            snapshot = read_verify_snapshot(plan)
            self.assertEqual([k.split("::", 1)[1] for k in snapshot],
                             ["index.html"])


class QueryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-query-")
        self.out_base = os.path.join(self.tmp, "out")
        self.execroot = os.path.join(self.out_base, "execroot", "ws")
        self.rel = ("bazel-out/x/bin/app/__app_framework_framework/"
                    "App.framework/App")
        abs_path = os.path.join(self.execroot, self.rel)
        os.makedirs(os.path.dirname(abs_path))
        with open(abs_path, "wb") as fh:
            fh.write(b"app")
        self.abs_path = abs_path

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_cquery_relative_paths_resolve_against_execroot(self):
        import sol as sol_mod
        fake = FakeCapture(self.execroot, [self.rel])
        files = sol_mod.query_target_files(
            fake, self.tmp, self.out_base, "//app:__app_framework_framework",
            ["-c", "opt"], True)
        self.assertEqual(files, [self.abs_path])

    def test_absolute_paths_accepted(self):
        import sol as sol_mod
        fake = FakeCapture(self.execroot, [self.abs_path])
        self.assertEqual(
            sol_mod.query_target_files(fake, self.tmp, self.out_base,
                                       "//app:x", [], True),
            [self.abs_path])

    def test_cquery_failure_propagates(self):
        import sol as sol_mod

        def fail(argv, cwd=None):
            raise RuntimeError("bazel cquery //app:x failed (exit 1): boom")

        with self.assertRaises(RuntimeError):
            sol_mod.query_target_files(fail, self.tmp, self.out_base,
                                       "//app:x", [], True)

    def test_warning_line_in_stdout_rejected(self):
        import sol as sol_mod
        fake = FakeCapture(self.execroot, [JVM_WARNING, self.rel])
        with self.assertRaises(RuntimeError):
            sol_mod.query_target_files(fake, self.tmp, self.out_base,
                                       "//app:x", [], True)

    def test_missing_path_rejected(self):
        import sol as sol_mod
        fake = FakeCapture(
            self.execroot, ["bazel-out/x/absent.o"])
        with self.assertRaisesRegex(RuntimeError, "does not exist"):
            sol_mod.query_target_files(fake, self.tmp, self.out_base,
                                       "//app:x", [], True)

    def test_path_outside_base_rejected(self):
        import sol as sol_mod
        fake = FakeCapture(self.execroot, ["/etc/hostname"])
        with self.assertRaisesRegex(RuntimeError, "not under output base"):
            sol_mod.query_target_files(fake, self.tmp, self.out_base,
                                       "//app:x", [], True)

    def test_empty_listing_rejected(self):
        import sol as sol_mod
        fake = FakeCapture(self.execroot, [])
        with self.assertRaisesRegex(RuntimeError, "no files"):
            sol_mod.query_target_files(fake, self.tmp, self.out_base,
                                       "//app:x", [], True)

    def test_info_validates_single_line(self):
        self.assertEqual(
            bazel_info(FakeCapture(self.execroot, []), self.tmp,
                       self.out_base, "execution_root", True),
            self.execroot)
        with self.assertRaises(RuntimeError):
            bazel_info(FakeCapture(self.execroot + "\n" + self.execroot, []),
                       self.tmp, self.out_base, "execution_root", True)

    def test_check_under_base(self):
        self.assertEqual(
            check_under_base(self.abs_path, self.out_base, "test"),
            self.abs_path)
        with self.assertRaises(RuntimeError):
            check_under_base("/elsewhere/x", self.out_base, "test")


class NoisyStderrTest(unittest.TestCase):
    """A JVM warning on stderr must never corrupt parsed Bazel output.

    Runs the real capture (separate pipes) against a fake `bazel` that
    reproduces the dispatch failure: the warning on stderr, paths on
    stdout. With a merged capture the warning becomes a bogus path.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-noisy-")
        self.out_base = os.path.join(self.tmp, "out")
        self.execroot = os.path.join(self.out_base, "execroot", "ws")
        self.rel = "bazel-out/x/bin/app/App.framework/App"
        abs_path = os.path.join(self.execroot, self.rel)
        os.makedirs(os.path.dirname(abs_path))
        with open(abs_path, "wb") as fh:
            fh.write(b"app")
        self.bazel = os.path.join(self.tmp, "bazel")
        with open(self.bazel, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("#!/bin/sh\n"
                     "echo '%s' >&2\n"
                     "if [ \"$SOL_BAZEL_FAIL\" = \"1\" ]; then\n"
                     "  echo 'BUILD FAILED: missing input' >&2\n"
                     "  exit 1\n"
                     "fi\n"
                     "for arg in \"$@\"; do\n"
                     "  case \"$arg\" in\n"
                     "    cquery) printf '%%s\\n' \"$SOL_CQUERY_OUT\";;\n"
                     "    info) printf '%%s\\n' \"$SOL_INFO_OUT\";;\n"
                     "  esac\n"
                     "done\n" % JVM_WARNING)
        os.chmod(self.bazel, os.stat(self.bazel).st_mode
                 | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def swap(self, argv, cwd):
        """capture_bazel_output with the fake script as argv[0]."""
        swapped = [self.bazel if a == "bazel" else a for a in argv]
        return capture_bazel_output(swapped, cwd)

    def test_info_stdout_excludes_warning(self):
        with mock.patch.dict(os.environ, {"SOL_INFO_OUT": self.execroot}):
            out = self.swap(
                ["bazel", "--batch", "--output_base=" + self.out_base,
                 "info", "execution_root"], self.tmp)
        self.assertEqual(out.strip(), self.execroot)
        self.assertNotIn("OpenJDK", out)

    def test_cquery_resolves_despite_warning(self):
        import sol as sol_mod
        with mock.patch.dict(os.environ, {"SOL_INFO_OUT": self.execroot,
                                           "SOL_CQUERY_OUT": self.rel}):
            files = sol_mod.query_target_files(
                self.swap, self.tmp, self.out_base, "//app:x", [], True)
        self.assertEqual(files, [os.path.join(self.execroot, self.rel)])

    def test_failure_shows_stderr(self):
        with mock.patch.dict(os.environ, {"SOL_BAZEL_FAIL": "1"}):
            with self.assertRaisesRegex(RuntimeError, "BUILD FAILED"):
                self.swap(["bazel", "--batch", "info", "execution_root"],
                          self.tmp)


CHAIN_OK = {"steps": {"Genrule": {"count": 1, "cpu_s": 0.9}},
            "skipped": {}, "failed": [], "verify_differ": [],
            "output_drift": {"n": 0, "paths": []},
            "sol_cpu_s": 0.9, "status": "ok"}


def sol_record(flow, bazel_cpu, sol_cpu, identical, reason="ok", chain=None):
    return {"flow": flow, "config": "device_release", "scenario": "clean",
            "identical": identical, "reason": reason,
            "bazel": {"cpu_s": bazel_cpu, "real_s": 1.0},
            "sol": (None if sol_cpu is None
                    else {"cpu_s": sol_cpu, "real_s": 0.9}),
            "n_sol_actions": 1,
            "chain": dict(CHAIN_OK) if chain is None else chain}


class SummarizeSolTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-summary-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_records(self, config, scenario, records):
        for rep, record in enumerate(records, start=1):
            rep_dir = os.path.join(self.tmp, "sol", config, scenario,
                                   "rep%d" % rep)
            os.makedirs(rep_dir)
            with open(os.path.join(rep_dir, "record.json"), "w",
                      encoding="utf-8", newline="\n") as fh:
                fh.write(json.dumps(record) + "\n")

    def test_unit_always_cpu_seconds(self):
        self.assertEqual(pick_unit({}), "cpu_seconds")
        records = [sol_record("f", 1.0, 0.9, True)]
        self.assertEqual(pick_unit({"f": records}), "cpu_seconds")

    def test_medians_and_chain_passthrough(self):
        self.write_records("device_release", "clean", [
            sol_record("ios-release-clean", 3.0, 2.5, True),
            sol_record("ios-release-clean", 1.0, 1.5, True),
            sol_record("ios-release-clean", 2.0, 2.0, True),
        ])
        records = load_sol_records(self.tmp, "device_release", "clean")
        self.assertEqual(len(records), 3)
        flow = summarize_flow(records, "cpu_seconds")
        self.assertEqual(flow["bazel"], 2.0)
        self.assertEqual(flow["sol"], 2.0)
        self.assertTrue(flow["identical"])
        self.assertEqual(flow["reason"], "ok")
        self.assertEqual(flow["chain"], CHAIN_OK)
        self.assertEqual(flow["spread"]["n"], 3)
        self.assertEqual(flow["spread"]["bazel"], [1.0, 3.0])

    def test_mismatch_drops_sol_number(self):
        failed_chain = dict(CHAIN_OK, status="failed",
                            failed=[{"mnemonic": "Genrule", "exit": 1,
                                     "stderr_tail": "boom"}])
        records = [sol_record("f", 1.0, 0.9, True),
                   sol_record("f", 1.1, None, False,
                              reason="step Genrule failed (exit 1)",
                              chain=failed_chain)]
        flow = summarize_flow(records, "cpu_seconds")
        self.assertFalse(flow["identical"])
        self.assertIsNone(flow["sol"])
        self.assertIsNone(flow["spread"]["sol"])
        self.assertEqual(flow["bazel"], 1.1)
        self.assertIn("failed (exit 1)", flow["reason"])
        self.assertEqual(flow["chain"], CHAIN_OK)

    def test_summarize_sol_shape(self):
        self.write_records("device_release", "clean",
                           [sol_record("ios-release-clean", 1.0, 0.9, True)])
        self.write_records("sim_debug", "app_edit",
                           [sol_record("ios-debug-app", 0.5, 0.4, True)])
        summary = summarize_sol(
            self.tmp, {"sha": "0" * 40, "repeats": 1, "target_loc": 20000,
                       "seed": 1})
        self.assertEqual(summary["rules_flutter"], "0" * 40)
        self.assertEqual(summary["unit"], "cpu_seconds")
        self.assertIn("system", summary["runner"])
        self.assertIn("cpu_count", summary["runner"])
        self.assertEqual(summary["flows"]["ios-release-clean"]["bazel"], 1.0)
        self.assertEqual(summary["flows"]["ios-debug-app"]["sol"], 0.4)
        self.assertEqual(summary["flows"]["ios-release-clean"]["chain"],
                         CHAIN_OK)
        self.assertEqual(summary["flows"]["ios-debug-clean"],
                         {"error": "missing repeats"})
        self.assertEqual(summary["meta"]["repeats"], 1)

    def test_platform_summaries_write_android_and_web_files(self):
        android_flows = {
            "android-release-clean", "android-release-app",
            "android-release-body", "android-debug-clean",
            "android-debug-app", "android-debug-body",
            "android-release-api", "android-debug-api",
        }
        web_flows = {
            "web-release-clean", "web-release-app", "web-release-body",
            "web-debug-clean", "web-debug-app", "web-debug-body",
            "web-release-api", "web-debug-api",
        }
        for config, prefix in [("android_release", "android-release"),
                               ("android_debug", "android-debug"),
                               ("web_release", "web-release"),
                               ("web_debug", "web-debug")]:
            for scenario, suffix in [("clean", "clean"),
                                     ("app_edit", "app"),
                                     ("core_edit", "body"),
                                     ("api_edit", "api")]:
                self.write_records(config, scenario, [sol_record(
                    "%s-%s" % (prefix, suffix), 1.0, 0.9, True)])
        summary = summarize_sol(
            self.tmp, {"sha": "1" * 40, "repeats": 1,
                       "target_loc": 20000, "seed": 1})
        self.assertEqual(set(summary["flows"]), android_flows | web_flows)
        with open(os.path.join(self.tmp, "android-sol.json"),
                  encoding="utf-8") as fh:
            android = json.load(fh)
        with open(os.path.join(self.tmp, "web-sol.json"),
                  encoding="utf-8") as fh:
            web = json.load(fh)
        self.assertEqual(set(android["flows"]), android_flows)
        self.assertEqual(set(web["flows"]), web_flows)
        self.assertEqual(android["unit"], "cpu_seconds")
        self.assertEqual(android["rules_flutter"], "1" * 40)

    def test_ios_only_summary_is_base_ios_sol(self):
        self.write_records("device_release", "clean",
                           [sol_record("ios-release-clean", 1.0, 0.9,
                                       True)])
        self.write_records("sim_debug", "app_edit",
                           [sol_record("ios-debug-app", 0.5, 0.4, True)])
        summary = summarize_sol(
            self.tmp, {"sha": "2" * 40, "repeats": 1,
                       "target_loc": 20000, "seed": 1})
        expected = {
            "ios-release-clean", "ios-release-app", "ios-release-body",
            "ios-debug-clean", "ios-debug-app", "ios-debug-body",
            "ios-release-api", "ios-debug-api",
        }
        self.assertEqual(set(summary["flows"]), expected)
        self.assertEqual(set(summary), {"rules_flutter", "unit",
                                        "runner", "flows", "meta"})
        with open(os.path.join(self.tmp, "ios-sol.json"),
                  encoding="utf-8") as fh:
            on_disk = json.load(fh)
        self.assertEqual(set(on_disk["flows"]), expected)
        self.assertEqual(on_disk["flows"]["ios-release-clean"]["bazel"], 1.0)

    def test_empty_results(self):
        summary = summarize_sol(
            self.tmp, {"sha": "abc", "repeats": 3, "target_loc": 1,
                       "seed": 1})
        self.assertIn("ios-release-clean", summary["flows"])


class RunnerInfoTest(unittest.TestCase):
    def test_base_keys(self):
        info = collect_runner_info()
        self.assertTrue(info["system"])
        self.assertTrue(info["machine"])
        self.assertIn("cpu_count", info)


FAKE_BAZEL = """\
#!/usr/bin/env python3
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import zipfile

out_base = ""
log = ""
profile = ""
mode = ""
key = ""
seen_info = False
for arg in sys.argv[1:]:
    if arg.startswith("--output_base="):
        out_base = arg.split("=", 1)[1]
    elif arg.startswith("--execution_log_json_file="):
        log = arg.split("=", 1)[1]
    elif arg.startswith("--profile="):
        profile = arg.split("=", 1)[1]
    elif arg == "info":
        mode = "info"
        seen_info = True
    elif arg == "cquery":
        mode = "cquery"
    elif arg == "build":
        mode = "build"
    elif arg == "shutdown":
        mode = "shutdown"
    elif seen_info and not key and not arg.startswith("--"):
        key = arg
batch = "--batch" in sys.argv[1:]

# Every client-side Bazel argv, in order, for the no-batch-while-up
# test: SOL_ARGV_LOG names an append-only file of one JSON argv per
# line. The daemon re-execution (`_daemon`) is not a Bazel command and
# stays out of the log.
argv_log = os.environ.get("SOL_ARGV_LOG", "")
if argv_log and not (len(sys.argv) > 1 and sys.argv[1] == "_daemon"):
    with open(argv_log, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(sys.argv[1:]) + "\\n")


# Server mode: a non-`--batch` invocation starts or reuses a stand-in
# server process (re-executing this script as `_daemon`) and, for builds,
# runs the build's actions as that server's children, so the warm
# measurement attributes a real tree. `info server_pid` reports the
# daemon pid; `shutdown` stops it.
if len(sys.argv) > 1 and sys.argv[1] == "_daemon":
    srv = sys.argv[2]
    pid_path = os.path.join(srv, "pid")
    req_path = os.path.join(srv, "req.json")
    resp_path = os.path.join(srv, "resp.json")
    with open(pid_path, "w") as fh:
        fh.write(str(os.getpid()))
    last = None
    while True:
        try:
            with open(req_path) as fh:
                req = json.load(fh)
        except (OSError, ValueError):
            req = None
        if (not isinstance(req, dict) or req.get("id") == last
                or "cmd" not in req):
            time.sleep(0.05)
            continue
        merged = dict(os.environ)
        merged.update(req.get("env") or {})
        try:
            proc = subprocess.run(
                req["cmd"], env=merged, cwd=req.get("cwd") or srv,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL)
            code = proc.returncode
        except OSError:
            code = 127
        last = req["id"]
        with open(resp_path, "w") as fh:
            json.dump({"id": last, "returncode": code}, fh)


def actual(rel, dst):
    with open(dst, "rb") as fh:
        digest = hashlib.sha256(fh.read()).hexdigest()
    return [{"path": rel, "digest": {"hash": digest}}]


def write_profile():
    # A Bazel JSON trace profile in the shape sol.py parses: the CPU
    # usage counter (2.0 cores for 1 s, 1.0 for 1 s, 2.0 for 1 s) split
    # by two build phase markers, so jvm.total is 5.0 with
    # Initialize command 3.0 and Complete build 2.0.
    if not profile:
        return
    events = [
        {"name": "Initialize command", "ph": "X", "ts": 0, "dur": 10,
         "pid": 1, "cat": "build phase marker"},
        {"name": "CPU usage (Bazel)", "ph": "C", "ts": 0, "pid": 1,
         "args": {"cpu": 2.0}},
        {"name": "CPU usage (Bazel)", "ph": "C", "ts": 1000000, "pid": 1,
         "args": {"cpu": 1.0}},
        {"name": "Complete build", "ph": "X", "ts": 2000000, "dur": 10,
         "pid": 1, "cat": "build phase marker"},
        {"name": "CPU usage (Bazel)", "ph": "C", "ts": 2000000, "pid": 1,
         "args": {"cpu": 2.0}},
        {"name": "CPU usage (Bazel)", "ph": "C", "ts": 3000000, "pid": 1,
         "args": {"cpu": 2.0}},
    ]
    with open(profile, "w", encoding="utf-8") as fh:
        json.dump({"traceEvents": events}, fh)


IPA_ENTRIES = ("Payload/Bench.app/App",
               "Payload/Bench.app/Frameworks/App.framework/"
               "flutter_assets/kernel_blob.bin")


def write_ipa(dst, data, stamp):
    archive = zipfile.ZipFile(dst, "w")
    for entry in IPA_ENTRIES:
        archive.writestr(zipfile.ZipInfo(entry, date_time=stamp), data)
    archive.close()


# The chain command rebuilds the ipa from the edited source. Zip entry
# timestamps come from the clock, so the chain's archive bytes always
# differ from the build's while the payload (entry paths and contents)
# matches: a metadata-only difference the proof must accept.
IPA_CHAIN = (
    "import sys, time, zipfile; "
    "src, dst = sys.argv[1], sys.argv[2]; "
    "data = open(src, 'rb').read(); "
    "stamp = time.localtime()[:6]; "
    "entries = %r; "
    "archive = zipfile.ZipFile(dst, 'w'); "
    "[archive.writestr(zipfile.ZipInfo(e, date_time=stamp), data) "
    "for e in entries]; "
    "archive.close()" % (IPA_ENTRIES,))

# With SOL_DIRTY=1 the chain command writes constant wrong bytes: the
# payload differs and the proof must fail naming the entry.
IPA_DIRTY = (
    "import sys, zipfile; "
    "entries = %r; "
    "archive = zipfile.ZipFile(sys.argv[2], 'w'); "
    "[archive.writestr(e, b'wrong-content') for e in entries]; "
    "archive.close()" % (IPA_ENTRIES,))


# The build-time ipa write (fixed stamp): the daemon runs this as its
# child in server mode, while the log records IPA_CHAIN (fresh stamp),
# exactly as batch mode writes one and logs the other.
IPA_FIXED = (
    "import sys, zipfile; "
    "src, dst = sys.argv[1], sys.argv[2]; "
    "data = open(src, 'rb').read(); "
    "stamp = (2020, 1, 1, 0, 0, 0); "
    "entries = %r; "
    "archive = zipfile.ZipFile(dst, 'w'); "
    "[archive.writestr(zipfile.ZipInfo(e, date_time=stamp), data) "
    "for e in entries]; "
    "archive.close()" % (IPA_ENTRIES,))


# Writes the web bundle tree (index.html, JS and WASM) and, when asked,
# a sibling DDC staging directory, from the source file's bytes.
WEB_CHAIN = (
    "import os, shutil, sys; "
    "data = open(sys.argv[1], 'rb').read(); "
    "[shutil.rmtree(d, ignore_errors=True) for d in sys.argv[2:]]; "
    "[os.makedirs(d) for d in sys.argv[2:]]; "
    "[open(os.path.join(sys.argv[2], n), 'wb').write(n.encode() + data) "
    "for n in ('index.html', 'main.dart.js', 'main.dart.wasm')]; "
    "[open(os.path.join(d, 'main.dart'), 'wb').write(data) "
    "for d in sys.argv[3:]]")


def server_file(name):
    return os.path.join(out_base, "sol-server", name)


def daemon_alive():
    try:
        with open(server_file("pid")) as fh:
            pid = int(fh.read().strip())
    except (OSError, ValueError):
        return None
    try:
        os.kill(pid, 0)
    except OSError:
        return None
    return pid


def ensure_daemon():
    pid = daemon_alive()
    if pid is not None:
        return pid
    srv = os.path.join(out_base, "sol-server")
    os.makedirs(srv, exist_ok=True)
    for name in ("pid", "req.json", "resp.json"):
        try:
            os.remove(os.path.join(srv, name))
        except OSError:
            pass
    subprocess.Popen(
        [sys.executable, __file__, "_daemon", srv],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, start_new_session=True)
    deadline = time.time() + 60.0
    while time.time() < deadline:
        pid = daemon_alive()
        if pid is not None:
            return pid
        time.sleep(0.05)
    sys.stderr.write("fake bazel: daemon did not start\\n")
    sys.exit(1)


def daemon_run(cmd, env):
    rid = "%d-%d" % (os.getpid(), daemon_run.seq)
    daemon_run.seq += 1
    with open(server_file("req.json"), "w") as fh:
        json.dump({"id": rid, "cmd": cmd, "env": env,
                   "cwd": execroot}, fh)
    deadline = time.time() + 60.0
    while time.time() < deadline:
        try:
            with open(server_file("resp.json")) as fh:
                resp = json.load(fh)
        except (OSError, ValueError):
            resp = None
        if isinstance(resp, dict) and resp.get("id") == rid:
            return resp.get("returncode", 1)
        time.sleep(0.05)
    sys.stderr.write("fake bazel: daemon action timed out\\n")
    sys.exit(1)


daemon_run.seq = 0


def src_digest():
    with open(os.environ["SOL_SRC"], "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def read_marker():
    try:
        with open(os.path.join(out_base, ".sol_last_build")) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def write_marker(outputs):
    with open(os.path.join(out_base, ".sol_last_build"), "w") as fh:
        fh.write(json.dumps({"src": src_digest(), "outputs": outputs}))


execroot = os.path.join(out_base, "execroot")
case = os.environ.get("SOL_CASE", "")
fail_config = os.environ.get("SOL_FAIL_CONFIG", "")
sidecar = os.environ.get("SOL_SIDEEFFECT", "") == "1"
dirty = os.environ.get("SOL_DIRTY", "") == "1"
is_sim = "sim_debug" in out_base
is_web = "web_release" in out_base or "web_debug" in out_base
web_debug = "web_debug" in out_base
web_bundle = "bazel-out/k8-fastbuild/bin/app/app_web_web"
web_dev = "bazel-out/k8-fastbuild/bin/app/app_web_dev"
web_unbuilt = "bazel-out/k8-fastbuild/bin/app/app_web.dart_analyze.analyzed"
rel = "bazel-out/x/App.framework/App"
sim_rel = "bazel-out/x/Bench.ipa"
if mode == "info":
    if batch:
        print(execroot)
    else:
        pid = ensure_daemon()
        print(pid if key == "server_pid" else execroot)
elif mode == "cquery":
    if not batch:
        ensure_daemon()
    if is_web:
        # DefaultInfo.files only; `--output=files` would inherit the
        # `test` aspect output groups, which `build` never builds.
        if "--output=files" in sys.argv[1:]:
            print(web_unbuilt)
        print(web_bundle)
        if web_debug:
            print(web_dev)
    elif case == "dirfail":
        print("bazel-out/x/App.framework/App")
    elif is_sim:
        print(sim_rel)
    else:
        print(rel)
elif mode == "shutdown":
    if batch:
        sys.exit(0)
    pid = daemon_alive()
    if pid is None:
        sys.exit(0)
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
    deadline = time.time() + 30.0
    alive = True
    while time.time() < deadline:
        try:
            os.kill(pid, 0)
        except OSError:
            alive = False
            break
        time.sleep(0.05)
    if alive:
        sys.stderr.write("fake bazel: daemon did not stop\\n")
        sys.exit(1)
    shutil.rmtree(os.path.join(out_base, "sol-server"),
                  ignore_errors=True)
elif mode == "build":
    if fail_config and fail_config in out_base:
        sys.stderr.write("fake bazel: simulated build failure\\n")
        sys.exit(1)
    if not batch:
        ensure_daemon()
    # Incremental builds: an unchanged source with all outputs present
    # executes zero actions (the warm-up build's proof). SOL_WARMUP_DIRTY
    # forces a full build so the zero-action check can fail.
    if os.environ.get("SOL_WARMUP_DIRTY", "") != "1":
        marker = read_marker()
        if (isinstance(marker, dict)
                and marker.get("src") == src_digest()
                and marker.get("outputs")
                and all(os.path.lexists(p)
                        for p in marker["outputs"])):
            with open(log, "w", encoding="utf-8") as fh:
                fh.write("")
            write_profile()
            sys.exit(0)
    if is_web:
        src = os.environ["SOL_SRC"]
        dst = os.path.join(execroot, web_bundle)
        dev = os.path.join(execroot, web_dev)
        args = [src, dst] + ([dev] if web_debug else [])
        cmd = [sys.executable, "-c", WEB_CHAIN] + args
        if batch:
            subprocess.run(cmd, check=True)
        else:
            daemon_run(cmd, {})
        listed = [web_bundle] + ([web_dev] if web_debug else [])
        spawn = {
            "commandArgs": cmd,
            "environmentVariables": [],
            "listedOutputs": listed,
            "actualOutputs": [],
            "mnemonic": "Genrule",
            "exitCode": 0,
            "targetLabel": "//app:app_web",
        }
        with open(log, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(spawn) + "\\n")
        write_marker([os.path.join(execroot, p) for p in listed])
        write_profile()
        sys.exit(0)
    if case == "hosttools" and not is_sim:
        # One target spawn plus one host-tool build (outputs under an
        # -exec- directory): the chain runs the first, the host-tools
        # replay the second, both with a working copy command.
        dst = os.path.join(execroot, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        src = os.environ["SOL_SRC"]
        host_rel = "bazel-out/darwin_arm64-opt-exec-ABCD/bin/host-tool"
        host_dst = os.path.join(execroot, host_rel)
        os.makedirs(os.path.dirname(host_dst), exist_ok=True)
        if batch:
            shutil.copyfile(src, dst)
            shutil.copyfile(src, host_dst)
        else:
            daemon_run(["sh", "-c", 'cp "$SOL_SRC" "$SOL_DST"'],
                       {"SOL_SRC": src, "SOL_DST": dst})
            daemon_run(["sh", "-c", 'cp "$SOL_SRC" "$SOL_DST"'],
                       {"SOL_SRC": src, "SOL_DST": host_dst})
        target = {
            "commandArgs": ["sh", "-c", 'cp "$SOL_SRC" "$SOL_DST"'],
            "environmentVariables": [
                {"name": "SOL_SRC", "value": src},
                {"name": "SOL_DST", "value": dst},
            ],
            "listedOutputs": [rel],
            "actualOutputs": actual(rel, dst),
            "mnemonic": "Genrule",
            "exitCode": 0,
            "targetLabel": "//app:app",
        }
        host = {
            "commandArgs": ["sh", "-c", 'cp "$SOL_SRC" "$SOL_DST"'],
            "environmentVariables": [
                {"name": "SOL_SRC", "value": src},
                {"name": "SOL_DST", "value": host_dst},
            ],
            "listedOutputs": [host_rel],
            "actualOutputs": actual(host_rel, host_dst),
            "mnemonic": "Genrule",
            "exitCode": 0,
            "targetLabel": "//tools:host_tool",
        }
        with open(log, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(host) + "\\n")
            fh.write(json.dumps(target) + "\\n")
        write_marker([dst, host_dst])
        write_profile()
        sys.exit(0)
    if is_sim and case != "dirfail":
        dst = os.path.join(execroot, sim_rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        src = os.environ["SOL_SRC"]
        if batch:
            with open(src, "rb") as fh:
                data = fh.read()
            write_ipa(dst, data, (2020, 1, 1, 0, 0, 0))
        else:
            daemon_run([sys.executable, "-c", IPA_FIXED, src, dst], {})
        if dirty:
            cmd = [sys.executable, "-c", IPA_DIRTY, src, dst]
        else:
            cmd = [sys.executable, "-c", IPA_CHAIN, src, dst]
        spawn = {
            "commandArgs": cmd,
            "environmentVariables": [
                {"name": "SOL_SRC", "value": src},
                {"name": "SOL_DST", "value": dst},
            ],
            "listedOutputs": [sim_rel],
            "actualOutputs": actual(sim_rel, dst),
            "mnemonic": "Genrule",
            "exitCode": 0,
            "targetLabel": "//app:app_ios",
        }
        if case == "prefail":
            # A step fails before the bundling step runs: the bundle is
            # moved aside and never re-created, so the after-chain read
            # finds nothing. That is a flow verdict, not a config error.
            inter = "bazel-out/x/intermediate.bin"
            inter_dst = os.path.join(execroot, inter)
            with open(inter_dst, "w", encoding="utf-8") as fh:
                fh.write("intermediate")
            if not batch:
                daemon_run(["sh", "-c", "exit 3"], {})
            fail = {
                "commandArgs": ["sh", "-c", "exit 3"],
                "environmentVariables": [],
                "listedOutputs": [inter],
                "actualOutputs": actual(inter, inter_dst),
                "mnemonic": "SwiftStdlibCopy",
                "exitCode": 0,
                "targetLabel": "//app:app_ios",
            }
            bundle = dict(spawn)
            bundle["inputs"] = {inter: {}}
            bundle["mnemonic"] = "BundleApp"
            with open(log, "w", encoding="utf-8") as fh:
                fh.write(json.dumps(fail) + "\\n")
                fh.write(json.dumps(bundle) + "\\n")
            write_marker([dst, inter_dst])
            write_profile()
            sys.exit(0)
    elif case == "dirfail":
        # The verify file lives inside a directory the step declares:
        # the step fails before recreating it (the round-3 restore
        # crash shape).
        fw = os.path.join(execroot, "bazel-out", "x", "App.framework")
        os.makedirs(fw, exist_ok=True)
        dst = os.path.join(fw, "App")
        with open(dst, "w", encoding="utf-8") as fh:
            fh.write("framework-bytes")
        if not batch:
            daemon_run(["sh", "-c", "exit 3"], {})
        spawn = {
            "commandArgs": ["sh", "-c", "exit 3"],
            "environmentVariables": [],
            "listedOutputs": ["bazel-out/x/App.framework"],
            "actualOutputs": [],
            "mnemonic": "Genrule",
            "exitCode": 0,
            "targetLabel": "//app:app",
        }
    else:
        dst = os.path.join(execroot, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        src = os.environ["SOL_SRC"]
        if os.environ.get("SOL_FAIL") == "1":
            with open(dst, "w", encoding="utf-8") as fh:
                fh.write("stale-bytes")
            cmd = ["sh", "-c", "exit 3"]
            env = []
            daemon_cmd, daemon_env = cmd, {}
        elif case == "drift":
            daemon_cmd = ["sh", "-c", 'cp "$SOL_SRC" "$SOL_DST"']
            daemon_env = {"SOL_SRC": src, "SOL_DST": dst}
            cmd = ["sh", "-c", 'echo drift > "$SOL_DST"']
            env = [
                {"name": "SOL_SRC", "value": src},
                {"name": "SOL_DST", "value": dst},
            ]
        else:
            daemon_cmd = ["sh", "-c", 'cp "$SOL_SRC" "$SOL_DST"']
            daemon_env = {"SOL_SRC": src, "SOL_DST": dst}
            cmd = list(daemon_cmd)
            env = [
                {"name": "SOL_SRC", "value": src},
                {"name": "SOL_DST", "value": dst},
            ]
            if sidecar:
                # The build leaves no sidecar: only the chain step
                # writes one next to its declared output, and the sweep
                # must remove it afterwards.
                side = os.path.join(execroot, "bazel-out", "x",
                                    "sidecar.tmp")
                cmd = ["sh", "-c", 'cp "$SOL_SRC" "$SOL_DST"; '
                       'echo side-effect > "$SOL_SIDE"']
                env = env + [{"name": "SOL_SIDE", "value": side}]
        if batch:
            if os.environ.get("SOL_FAIL") != "1":
                shutil.copyfile(src, dst)
        else:
            daemon_run(daemon_cmd, daemon_env)
        spawn = {
            "commandArgs": cmd,
            "environmentVariables": env,
            "listedOutputs": [rel],
            "actualOutputs": actual(rel, dst),
            "mnemonic": "Genrule",
            "exitCode": 0,
            "targetLabel": "//app:app",
        }
    with open(log, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(spawn) + "\\n")
    write_profile()
    write_marker([os.path.join(execroot, p)
                  for p in spawn["listedOutputs"]])
else:
    sys.stderr.write("fake bazel: unknown mode\\n")
    sys.exit(1)
"""

STUB_GEN = """\
#!/usr/bin/env python3
import sys
work = sys.argv[sys.argv.index("--workspace") + 1]
with open(work + "/src.txt", "a", encoding="utf-8") as fh:
    fh.write("edit:%s\\n" % sys.argv[1])
"""


class SolEndToEndTest(unittest.TestCase):
    """run -> chain -> summarize without macOS or a real Bazel.

    A fake `bazel` on PATH answers build/info/cquery: the build copies
    a source file to a framework-style output and logs one spawn whose
    command reproduces that copy. The real chain subprocess replays it
    (with per-step output removal and move-aside proof), and summarize
    writes ios-sol.json. --time-bin points nowhere to prove measurement
    never needs it.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-e2e-")
        self.bindir = os.path.join(self.tmp, "bin")
        os.makedirs(self.bindir)
        bazel = os.path.join(self.bindir, "bazel")
        with open(bazel, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(FAKE_BAZEL)
        os.chmod(bazel, os.stat(bazel).st_mode
                 | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        self.tools = os.path.join(self.tmp, "tools")
        os.makedirs(self.tools)
        with open(os.path.join(self.tools, "gen_monorepo.py"), "w",
                  encoding="utf-8", newline="\n") as fh:
            fh.write(STUB_GEN)
        self.pristine = os.path.join(self.tmp, "pristine")
        os.makedirs(self.pristine)
        with open(os.path.join(self.pristine, "src.txt"), "w",
                  encoding="utf-8", newline="\n") as fh:
            fh.write("v1\n")
        self.work = os.path.join(self.tmp, "work")
        self.out_base = os.path.join(self.tmp, "out")
        self.results = os.path.join(self.tmp, "results")
        self.env = {"PATH": self.bindir + os.pathsep + os.environ["PATH"],
                    "SOL_SRC": os.path.join(self.work, "src.txt")}

    def tearDown(self):
        for pid in self.live_server_pids():
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        shutil.rmtree(self.tmp, ignore_errors=True)

    def live_server_pids(self):
        """Pids of stand-in servers still running under the output base."""
        pids = []
        for dirpath, _, filenames in os.walk(self.out_base):
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

    def run_argv(self, configs):
        argv = ["run", "--tools", self.tools, "--pristine", self.pristine,
                "--work", self.work, "--out-base", self.out_base,
                "--results", self.results, "--rep", "1", "--floor=off",
                "--min-clean-actions", "1",
                "--time-bin", os.path.join(self.tmp, "absent")]
        for config in configs:
            argv += ["--config", config]
        return argv

    def summarize_argv(self, out):
        return ["summarize", "--results", self.results, "--sha", "a" * 40,
                "--repeats", "1", "--target-loc", "100", "--seed", "7",
                "--out", out]

    def test_run_chain_summarize_identical(self):
        out = os.path.join(self.tmp, "ios-sol.json")
        with mock.patch.dict(os.environ, self.env):
            self.assertEqual(
                sol.main(self.run_argv(["device_release", "sim_debug"])), 0)
            self.assertEqual(sol.main(self.summarize_argv(out)), 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        self.assertEqual(summary["unit"], "cpu_seconds")
        self.assertEqual(summary["rules_flutter"], "a" * 40)
        expected = ["ios-debug-api", "ios-debug-app", "ios-debug-body",
                    "ios-debug-clean", "ios-release-api",
                    "ios-release-app", "ios-release-body",
                    "ios-release-clean"]
        self.assertEqual(sorted(summary["flows"]), expected)
        for flow in expected:
            entry = summary["flows"][flow]
            self.assertTrue(entry["identical"], flow)
            self.assertEqual(entry["reason"], "ok", flow)
            self.assertGreaterEqual(entry["bazel"], 0.0, flow)
            self.assertGreaterEqual(entry["sol"], 0.0, flow)
            self.assertEqual(entry["chain"]["steps"]["Genrule"]["count"],
                             1, flow)
            self.assertGreaterEqual(
                entry["chain"]["steps"]["Genrule"]["cpu_s"], 0.0, flow)
            self.assertEqual(entry["chain"]["failed"], [], flow)
            self.assertEqual(entry["chain"]["status"], "ok", flow)
            self.assertEqual(entry["chain"]["verify_differ"],
                             {"n": 0, "differ": []}, flow)
        # The sim chain rebuilds its ipa with fresh zip timestamps, so
        # its archive bytes always differ from the build's while the
        # payload matches: drift without verify difference.
        for flow in ["ios-debug-clean", "ios-debug-app", "ios-debug-body"]:
            drift = summary["flows"][flow]["chain"]["output_drift"]
            self.assertEqual(drift,
                             {"n": 1,
                              "paths": ["bazel-out/x/Bench.ipa"]}, flow)
        for flow in ["ios-release-clean", "ios-release-app",
                     "ios-release-body"]:
            self.assertEqual(
                summary["flows"][flow]["chain"]["output_drift"],
                {"n": 0, "paths": []}, flow)
        # Bazel's outputs are back in place after the move-aside proof.
        dst = os.path.join(self.out_base, "device_release", "execroot",
                           "bazel-out", "x", "App.framework", "App")
        with open(dst, encoding="utf-8") as fh:
            self.assertTrue(fh.read().startswith("v1\nedit:apply-app-edit"))

    def test_run_chain_summarize_web_identical(self):
        out = os.path.join(self.tmp, "web-sol.json")
        with mock.patch.dict(os.environ, self.env):
            self.assertEqual(
                sol.main(self.run_argv(["web_release", "web_debug"])), 0)
            self.assertEqual(sol.main(self.summarize_argv(out)), 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        for kind in ("release", "debug"):
            for flow, method in (("clean", "batch"),
                                 ("app", "warm-server"),
                                 ("body", "warm-server"),
                                 ("api", "warm-server")):
                name = "web-%s-%s" % (kind, flow)
                entry = summary["flows"][name]
                self.assertTrue(entry["identical"], name)
                self.assertEqual(entry["reason"], "ok", name)
                self.assertGreaterEqual(entry["sol"], 0.0, name)
                self.assertEqual(entry["method"], method, name)
        self.assertEqual(self.live_server_pids(), [])

    def test_profile_parts_sum_to_bazel(self):
        # Every flow carries a profile whose parts are present and sum
        # to the Bazel number; the fake profile integrates to 5.0 with
        # Initialize command 3.0 and Complete build 2.0.
        out = os.path.join(self.tmp, "ios-sol.json")
        with mock.patch.dict(os.environ, self.env):
            self.assertEqual(
                sol.main(self.run_argv(["device_release", "sim_debug"])), 0)
            self.assertEqual(sol.main(self.summarize_argv(out)), 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        for flow in sorted(summary["flows"]):
            entry = summary["flows"][flow]
            profile = entry["profile"]
            jvm = profile["jvm"]
            self.assertAlmostEqual(jvm["total"], 5.0, msg=flow)
            self.assertAlmostEqual(jvm["phases"]["Initialize command"],
                                   3.0, msg=flow)
            self.assertAlmostEqual(jvm["phases"]["Complete build"],
                                   2.0, msg=flow)
            host = profile["host_tools"]
            self.assertEqual(host["total"], 0.0, flow)
            self.assertEqual(host["by_mnemonic"], {}, flow)
            self.assertEqual(host["top_targets"], [], flow)
            self.assertEqual(profile["sol_source"], "sol", flow)
            self.assertAlmostEqual(profile["sol_cpu_s"], entry["sol"],
                                   msg=flow)
            self.assertAlmostEqual(
                jvm["total"] + profile["sol_cpu_s"] + host["total"]
                + profile["residual"], entry["bazel"], msg=flow)
            self.assertNotIn('"command":', json.dumps(profile))
        # The trace profile and execution log travel gzipped per build.
        record_dir = os.path.join(self.results, "sol", "device_release",
                                  "clean", "rep1")
        for name in ["trace.json.gz", "execlog.json.gz"]:
            path = os.path.join(record_dir, name)
            self.assertTrue(os.path.isfile(path), name)
            import gzip
            with gzip.open(path, "rb") as fh:
                self.assertTrue(fh.read(), name)

    def read_record(self, config, scenario):
        path = os.path.join(self.results, "sol", config, scenario,
                            "rep1", "record.json")
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)

    def test_warm_methods_parts_and_no_server_left(self):
        # Clean flows stay --batch; edit flows build against the warm
        # server and carry its per-part breakdown. Every flow states its
        # method, and no stand-in server outlives the run.
        out = os.path.join(self.tmp, "ios-sol.json")
        with mock.patch.dict(os.environ, self.env):
            self.assertEqual(
                sol.main(self.run_argv(["device_release"])), 0)
            self.assertEqual(sol.main(self.summarize_argv(out)), 0)
        for scenario, method in (("clean", "batch"),
                                 ("app_edit", "warm-server"),
                                 ("core_edit", "warm-server"),
                                 ("api_edit", "warm-server")):
            record = self.read_record("device_release", scenario)
            self.assertEqual(record["method"], method, scenario)
            self.assertTrue(record["identical"], scenario)
            if scenario == "clean":
                self.assertNotIn("warm_up", record)
            else:
                warm = record["warm_up"]
                self.assertEqual(warm["edit"], "apply-app-edit", scenario)
                self.assertGreaterEqual(warm["executed_actions"], 1)
                self.assertGreaterEqual(warm["worker_spawns"], 0)
            if method == "warm-server":
                parts = record["bazel_parts"]
                self.assertEqual(sorted(parts),
                                 ["client", "descendants",
                                  "server_reaped", "server_self"],
                                 scenario)
                for part in parts.values():
                    self.assertGreaterEqual(part["user_s"], 0.0,
                                            scenario)
                    self.assertGreaterEqual(part["sys_s"], 0.0,
                                            scenario)
                total = sum(part["user_s"] + part["sys_s"]
                            for part in parts.values())
                self.assertAlmostEqual(record["bazel"]["cpu_s"], total,
                                       msg=scenario)
            else:
                self.assertNotIn("bazel_parts", record)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        self.assertEqual(
            summary["flows"]["ios-release-clean"]["method"], "batch")
        self.assertNotIn(
            "bazel_parts", summary["flows"]["ios-release-clean"])
        for flow in ("ios-release-app", "ios-release-body",
                     "ios-release-api"):
            entry = summary["flows"][flow]
            self.assertEqual(entry["method"], "warm-server", flow)
            self.assertEqual(sorted(entry["bazel_parts"]),
                             ["client", "descendants", "server_reaped",
                              "server_self"], flow)
            for part in entry["bazel_parts"].values():
                self.assertGreaterEqual(part, 0.0, flow)
        self.assertEqual(self.live_server_pids(), [])

    def test_no_batch_while_server_up(self):
        # The fake bazel logs every client argv in order. The server
        # starts at the first argv without --batch (info server_pid)
        # and stops at the shutdown argv: nothing in between may carry
        # --batch, while the clean build before it must. The window must
        # also hold warm build, info and cquery commands, so the test
        # cannot pass vacuously.
        log = os.path.join(self.tmp, "argv.log")
        env = dict(self.env, SOL_ARGV_LOG=log)
        with mock.patch.dict(os.environ, env):
            self.assertEqual(
                sol.main(self.run_argv(["device_release"])), 0)
        with open(log, encoding="utf-8") as fh:
            invocations = [json.loads(line) for line in fh
                           if line.strip()]
        start = next(i for i, argv in enumerate(invocations)
                     if "--batch" not in argv)
        stop = next(i for i, argv in enumerate(invocations)
                    if "shutdown" in argv)
        self.assertGreater(stop, start)
        pre = invocations[:start]
        self.assertTrue(
            any("build" in argv and "--batch" in argv for argv in pre),
            "clean build runs --batch before the server starts")
        window = invocations[start:stop + 1]
        for argv in window:
            self.assertNotIn("--batch", argv, argv)
        kinds = {("build" if "build" in argv
                  else "info" if "info" in argv
                  else "cquery" if "cquery" in argv
                  else "shutdown" if "shutdown" in argv
                  else "?") for argv in window}
        self.assertTrue({"build", "info", "cquery"} <= kinds, kinds)
        self.assertEqual(self.live_server_pids(), [])

    def test_warmup_actions_fail_the_config(self):
        # A warm-up build that executes actions means the clean restore
        # perturbed the outputs: the config fails with that reason, the
        # edit flows carry it, and the server still shuts down.
        out = os.path.join(self.tmp, "ios-sol.json")
        env = dict(self.env, SOL_WARMUP_DIRTY="1")
        with mock.patch.dict(os.environ, env):
            self.assertEqual(
                sol.main(self.run_argv(["device_release"])), 1)
            self.assertEqual(sol.main(self.summarize_argv(out)), 0)
        clean = self.read_record("device_release", "clean")
        self.assertTrue(clean["identical"])
        self.assertEqual(clean["method"], "batch")
        for scenario in ("app_edit", "core_edit", "api_edit"):
            record = self.read_record("device_release", scenario)
            self.assertFalse(record["identical"], scenario)
            self.assertIsNone(record["sol"], scenario)
            self.assertIn("warm-up", record["reason"], scenario)
            self.assertEqual(record["method"], "warm-server", scenario)
            self.assertEqual(record["chain"]["status"], "error",
                             scenario)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        self.assertTrue(
            summary["flows"]["ios-release-clean"]["identical"])
        for flow in ("ios-release-app", "ios-release-body",
                     "ios-release-api"):
            entry = summary["flows"][flow]
            self.assertFalse(entry["identical"], flow)
            self.assertIsNone(entry["sol"], flow)
            self.assertIn("warm-up", entry["reason"], flow)
        self.assertEqual(self.live_server_pids(), [])

    def test_host_tools_replayed_and_summed(self):
        # A host-tool build leaves the chain out, runs under the same
        # CPU method, and lands in the profile with its target label.
        out = os.path.join(self.tmp, "ios-sol.json")
        env = dict(self.env, SOL_CASE="hosttools")
        with mock.patch.dict(os.environ, env):
            self.assertEqual(sol.main(self.run_argv(["device_release"])), 0)
            self.assertEqual(sol.main(self.summarize_argv(out)), 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        entry = summary["flows"]["ios-release-clean"]
        self.assertTrue(entry["identical"])
        self.assertEqual(entry["chain"]["skipped"], {"host-tool build": 1})
        host = entry["profile"]["host_tools"]
        self.assertGreaterEqual(host["total"], 0.0)
        self.assertGreaterEqual(host["by_mnemonic"]["Genrule"], 0.0)
        self.assertEqual(host["top_targets"][0][0], "//tools:host_tool")
        self.assertEqual(entry["profile"]["sol_source"], "sol")
        profile = entry["profile"]
        self.assertAlmostEqual(
            profile["jvm"]["total"] + profile["sol_cpu_s"]
            + host["total"] + profile["residual"], entry["bazel"])
        # Bazel's host-tool output is back with its own bytes.
        dst = os.path.join(self.out_base, "device_release", "execroot",
                           "bazel-out", "darwin_arm64-opt-exec-ABCD", "bin",
                           "host-tool")
        with open(dst, encoding="utf-8") as fh:
            self.assertTrue(fh.read().startswith("v1\nedit:apply-app-edit"))

    def test_failed_chain_uses_chain_cpu(self):
        # Without a SOL number the profile uses the chain's measured CPU
        # in its place and says so; the parts still sum to Bazel.
        out = os.path.join(self.tmp, "ios-sol.json")
        env = dict(self.env, SOL_FAIL="1")
        with mock.patch.dict(os.environ, env):
            self.assertEqual(
                sol.main(self.run_argv(["device_release"])), 0)
            self.assertEqual(sol.main(self.summarize_argv(out)), 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        entry = summary["flows"]["ios-release-clean"]
        self.assertFalse(entry["identical"])
        self.assertIsNone(entry["sol"])
        profile = entry["profile"]
        self.assertEqual(profile["sol_source"], "chain-cpu")
        self.assertGreaterEqual(profile["sol_cpu_s"], 0.0)
        self.assertAlmostEqual(
            profile["jvm"]["total"] + profile["sol_cpu_s"]
            + profile["host_tools"]["total"] + profile["residual"],
            entry["bazel"])

    def test_failed_chain_is_not_identical(self):
        out = os.path.join(self.tmp, "ios-sol.json")
        env = dict(self.env, SOL_FAIL="1")
        with mock.patch.dict(os.environ, env):
            self.assertEqual(
                sol.main(self.run_argv(["device_release"])), 0)
            self.assertEqual(sol.main(self.summarize_argv(out)), 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        for flow in ["ios-release-clean", "ios-release-app",
                     "ios-release-body"]:
            entry = summary["flows"][flow]
            self.assertFalse(entry["identical"], flow)
            self.assertIsNone(entry["sol"], flow)
            self.assertIn("Genrule", entry["reason"], flow)
            self.assertIn("exit 3", entry["reason"], flow)
            self.assertIn("verify differ", entry["reason"], flow)
            self.assertEqual(entry["chain"]["failed"][0]["exit"], 3)
            differ = entry["chain"]["verify_differ"]
            self.assertEqual(differ["n"], 1)
            self.assertEqual(len(differ["differ"]), 1)
            self.assertEqual(differ["differ"][0]["path"],
                             "bazel-out/x/App.framework/App")
            self.assertIsNone(differ["differ"][0]["after"])

    def test_sim_ipa_metadata_only_still_identical(self):
        # The chain rebuilds the ipa with fresh zip timestamps: the
        # archive bytes differ from the build's, but the payload
        # (entry paths and contents) matches, so the proof passes.
        out = os.path.join(self.tmp, "ios-sol.json")
        with mock.patch.dict(os.environ, self.env):
            self.assertEqual(sol.main(self.run_argv(["sim_debug"])), 0)
            self.assertEqual(sol.main(self.summarize_argv(out)), 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        entry = summary["flows"]["ios-debug-clean"]
        self.assertTrue(entry["identical"])
        self.assertEqual(entry["reason"], "ok")
        self.assertGreaterEqual(entry["sol"], 0.0)
        self.assertEqual(entry["chain"]["verify_differ"],
                         {"n": 0, "differ": []})
        # The proof covers the bundle payload: the App binary and the
        # kernel blob are among the verified entries.
        record_path = os.path.join(self.results, "sol", "sim_debug",
                                   "clean", "rep1", "record.json")
        with open(record_path, encoding="utf-8") as fh:
            record = json.load(fh)
        self.assertEqual(
            sorted(record["verify"]["before"]),
            ["bazel-out/x/Bench.ipa::Payload/Bench.app/App",
             "bazel-out/x/Bench.ipa::Payload/Bench.app/Frameworks/"
             "App.framework/flutter_assets/kernel_blob.bin"])

    def test_sim_payload_differs_not_identical(self):
        # The chain writes different entry contents: the proof fails
        # naming the payload entry, with no SOL number.
        out = os.path.join(self.tmp, "ios-sol.json")
        env = dict(self.env, SOL_DIRTY="1")
        with mock.patch.dict(os.environ, env):
            self.assertEqual(sol.main(self.run_argv(["sim_debug"])), 0)
            self.assertEqual(sol.main(self.summarize_argv(out)), 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        entry = summary["flows"]["ios-debug-clean"]
        self.assertFalse(entry["identical"])
        self.assertIsNone(entry["sol"])
        self.assertIn("verify differ", entry["reason"])
        differ = entry["chain"]["verify_differ"]
        self.assertEqual(differ["n"], 2)
        self.assertEqual(differ["differ"][0]["path"],
                         "bazel-out/x/Bench.ipa::Payload/Bench.app/App")
        self.assertNotEqual(differ["differ"][0]["before"],
                            differ["differ"][0]["after"])

    def test_chain_side_effect_swept(self):
        # The chain step leaves an undeclared file next to its declared
        # output: the sweep removes it, Bazel's outputs are restored,
        # and the proof still passes.
        out = os.path.join(self.tmp, "ios-sol.json")
        env = dict(self.env, SOL_SIDEEFFECT="1")
        with mock.patch.dict(os.environ, env):
            self.assertEqual(
                sol.main(self.run_argv(["device_release"])), 0)
            self.assertEqual(sol.main(self.summarize_argv(out)), 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        entry = summary["flows"]["ios-release-clean"]
        self.assertTrue(entry["identical"])
        self.assertEqual(entry["reason"], "ok")
        self.assertEqual(entry["chain"]["side_effects_removed"],
                         {"n": 1, "paths": ["x/sidecar.tmp"]})
        side = os.path.join(self.out_base, "device_release", "execroot",
                            "bazel-out", "x", "sidecar.tmp")
        self.assertFalse(os.path.lexists(side))
        dst = os.path.join(self.out_base, "device_release", "execroot",
                           "bazel-out", "x", "App.framework", "App")
        with open(dst, encoding="utf-8") as fh:
            self.assertTrue(fh.read().startswith("v1\nedit:apply-app-edit"))

    def test_failed_step_before_bundle_is_flow_verdict(self):
        # A step fails before the bundling step runs: the bundle is
        # moved aside and never re-created, so the after-chain read
        # finds nothing. The flow reports identical=false naming the
        # failed step and the missing entries (no SOL number), Bazel's
        # outputs are restored, and the run continues with the next
        # scenario instead of failing the config.
        out = os.path.join(self.tmp, "ios-sol.json")
        env = dict(self.env, SOL_CASE="prefail")
        with mock.patch.dict(os.environ, env):
            self.assertEqual(sol.main(self.run_argv(["sim_debug"])), 0)
            self.assertEqual(sol.main(self.summarize_argv(out)), 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        for flow in ["ios-debug-clean", "ios-debug-app", "ios-debug-body"]:
            entry = summary["flows"][flow]
            self.assertFalse(entry["identical"], flow)
            self.assertIsNone(entry["sol"], flow)
            self.assertIn("SwiftStdlibCopy", entry["reason"], flow)
            self.assertIn("exit 3", entry["reason"], flow)
            self.assertIn("verify differ", entry["reason"], flow)
            differ = entry["chain"]["verify_differ"]
            self.assertEqual(differ["n"], 2, flow)
            self.assertEqual(differ["differ"][0]["path"],
                             "bazel-out/x/Bench.ipa::Payload/Bench.app/App",
                             flow)
            self.assertIsNone(differ["differ"][0]["after"], flow)
        # Bazel's bundle is back with its own bytes for the next build.
        dst = os.path.join(self.out_base, "sim_debug", "execroot",
                           "bazel-out", "x", "Bench.ipa")
        import zipfile
        with zipfile.ZipFile(dst) as archive:
            self.assertEqual(
                sorted(archive.namelist()),
                ["Payload/Bench.app/App",
                 "Payload/Bench.app/Frameworks/App.framework/"
                 "flutter_assets/kernel_blob.bin"])

    def test_directory_output_failure_restores_and_continues(self):
        out = os.path.join(self.tmp, "ios-sol.json")
        env = dict(self.env, SOL_CASE="dirfail")
        with mock.patch.dict(os.environ, env):
            self.assertEqual(
                sol.main(self.run_argv(["device_release"])), 0)
            self.assertEqual(sol.main(self.summarize_argv(out)), 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        for flow in ["ios-release-clean", "ios-release-app",
                     "ios-release-body"]:
            entry = summary["flows"][flow]
            self.assertFalse(entry["identical"], flow)
            self.assertIsNone(entry["sol"], flow)
            self.assertIn("Genrule", entry["reason"], flow)
            self.assertIn("exit 3", entry["reason"], flow)
        # Bazel's directory is back with its own bytes for the next build.
        dst = os.path.join(self.out_base, "device_release", "execroot",
                           "bazel-out", "x", "App.framework", "App")
        with open(dst, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "framework-bytes")

    def test_drifted_bytes_restore_and_report(self):
        out = os.path.join(self.tmp, "ios-sol.json")
        env = dict(self.env, SOL_CASE="drift")
        with mock.patch.dict(os.environ, env):
            self.assertEqual(
                sol.main(self.run_argv(["device_release"])), 0)
            self.assertEqual(sol.main(self.summarize_argv(out)), 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        entry = summary["flows"]["ios-release-clean"]
        self.assertFalse(entry["identical"])
        self.assertIsNone(entry["sol"])
        self.assertIn("verify differ", entry["reason"])
        self.assertEqual(entry["chain"]["output_drift"]["n"], 1)
        self.assertEqual(entry["chain"]["output_drift"]["paths"],
                         ["bazel-out/x/App.framework/App"])
        # Bazel's bytes are back even though the chain wrote different
        # ones, so the next scenario still measures a clean increment.
        dst = os.path.join(self.out_base, "device_release", "execroot",
                           "bazel-out", "x", "App.framework", "App")
        with open(dst, encoding="utf-8") as fh:
            self.assertTrue(fh.read().startswith("v1\n"))

    def test_config_error_keeps_other_config(self):
        out = os.path.join(self.tmp, "ios-sol.json")
        env = dict(self.env, SOL_FAIL_CONFIG="sim_debug")
        with mock.patch.dict(os.environ, env):
            self.assertEqual(
                sol.main(self.run_argv(["device_release", "sim_debug"])),
                1)
            self.assertEqual(sol.main(self.summarize_argv(out)), 0)
        with open(out, encoding="utf-8") as fh:
            summary = json.load(fh)
        self.assertTrue(summary["flows"]["ios-release-clean"]["identical"])
        for flow in ["ios-debug-clean", "ios-debug-app", "ios-debug-body"]:
            entry = summary["flows"][flow]
            self.assertFalse(entry["identical"], flow)
            self.assertIsNone(entry["sol"], flow)
            self.assertIn("sim_debug", entry["reason"], flow)
            self.assertEqual(entry["chain"]["status"], "error", flow)


class OutputDriftTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sol-drift-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def write(self, rel, data):
        path = os.path.join(self.tmp, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(data)
        return path

    def spawn(self, rel, digest):
        spawn = {"commandArgs": ["tool"], "environmentVariables": [],
                 "listedOutputs": [rel], "mnemonic": "Genrule",
                 "exitCode": 0, "targetLabel": "//app:app"}
        if digest is not None:
            spawn["actualOutputs"] = [
                {"path": rel, "digest": {"hash": digest}}]
        return spawn

    def test_matching_digest_no_drift(self):
        rel = "bazel-out/x/o.bin"
        self.write(rel, b"bytes")
        digest = sha256_file(os.path.join(self.tmp, rel))
        self.assertEqual(output_drift([self.spawn(rel, digest)], self.tmp),
                         {"n": 0, "paths": []})

    def test_differing_digest_counted(self):
        rel = "bazel-out/x/o.bin"
        self.write(rel, b"chain-wrote-this")
        spawn = self.spawn(rel, "0" * 64)
        self.assertEqual(output_drift([spawn], self.tmp),
                         {"n": 1, "paths": ["bazel-out/x/o.bin"]})

    def test_missing_and_unrecorded_skipped(self):
        spawns = [self.spawn("bazel-out/x/absent.bin", "0" * 64),
                  self.spawn("bazel-out/x/plain.bin", None)]
        self.write("bazel-out/x/plain.bin", b"x")
        self.assertEqual(output_drift(spawns, self.tmp),
                         {"n": 0, "paths": []})

    def test_paths_capped_at_ten(self):
        spawns = []
        for n in range(12):
            rel = "bazel-out/x/o%02d.bin" % n
            self.write(rel, b"drifted")
            spawns.append(self.spawn(rel, "0" * 64))
        drift = output_drift(spawns, self.tmp)
        self.assertEqual(drift["n"], 12)
        self.assertEqual(len(drift["paths"]), 10)


from sol_rss_test import MeasurePeakTest, SummaryWallRssTest  # noqa: E402,F401


if __name__ == "__main__":
    unittest.main()
