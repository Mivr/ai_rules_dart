"""Unit tests for the shared SDK extraction and the per-mode iOS engine repositories.

Both run offline: the repository rules are replaced by recorders, and the
engine fetch runs against a fake repository context whose download only records
the URL it was asked for. A real Bazel run of the same layout (a `-c dbg` build
fetched only the debug repository) backs the claim that an alias does not pull
in the unselected mode's repository.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:artifact_urls.bzl", "engine_artifact_url", "ios_engine_artifact_path")
load("//flutter/private:flutter_ios_engine_repo.bzl", "flutter_ios_engine_mode_repo_impl", "flutter_ios_engine_repos", "ios_engine_hub_build")
load("//flutter/private:flutter_sdk_package.bzl", "copy_sdk_package_from_source", "declare_sdk_source", "declare_sdk_spokes")
load("//flutter/private:repo_metadata.bzl", "download_mode_metadata")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_REVISION = "0123456789abcdef0123456789abcdef01234567"
_BASE = "https://engines.example.com"
_RELEASE_SHA = "a" * 64
_DEBUG_SHA = "b" * 64

def _fake_mode_ctx(mode, sha256, requests, files):
    """A repository context whose download records the URL and never touches the network."""

    def download_and_extract(**kwargs):
        requests.append(kwargs)

    return struct(
        name = "fake_" + mode,
        attr = struct(
            mode = mode,
            engine_revision = _REVISION,
            engine_base_url = _BASE,
            local_path = "",
            sha256 = sha256,
        ),
        download_and_extract = download_and_extract,
        file = lambda path, content: files.update({path: content}),
        repo_metadata = lambda reproducible: struct(reproducible = reproducible),
    )

def _fetch(mode, sha256):
    requests = []
    files = {}
    metadata = flutter_ios_engine_mode_repo_impl(_fake_mode_ctx(mode, sha256, requests, files))
    return struct(requests = requests, files = files, metadata = metadata)

def _release_repo_never_requests_the_debug_archive_test_impl(ctx):
    env = unittest.begin(ctx)
    fetched = _fetch("release", _RELEASE_SHA)
    release_url = engine_artifact_url(_REVISION, ios_engine_artifact_path("release"), _BASE)
    debug_url = engine_artifact_url(_REVISION, ios_engine_artifact_path("debug"), _BASE)
    asserts.equals(env, [release_url], [r["url"] for r in fetched.requests])
    asserts.equals(env, [_RELEASE_SHA], [r["sha256"] for r in fetched.requests])
    asserts.false(env, debug_url in [r["url"] for r in fetched.requests])
    asserts.true(env, fetched.metadata.reproducible)
    return unittest.end(env)

def _debug_repo_never_requests_the_release_archive_test_impl(ctx):
    env = unittest.begin(ctx)
    fetched = _fetch("debug", _DEBUG_SHA)
    release_url = engine_artifact_url(_REVISION, ios_engine_artifact_path("release"), _BASE)
    debug_url = engine_artifact_url(_REVISION, ios_engine_artifact_path("debug"), _BASE)
    asserts.equals(env, [debug_url], [r["url"] for r in fetched.requests])
    asserts.equals(env, [_DEBUG_SHA], [r["sha256"] for r in fetched.requests])
    asserts.false(env, release_url in [r["url"] for r in fetched.requests])
    return unittest.end(env)

def _mode_repo_exposes_one_xcframework_target_test_impl(ctx):
    env = unittest.begin(ctx)
    for mode in ["release", "debug"]:
        build = _fetch(mode, _RELEASE_SHA).files["BUILD.bazel"]
        asserts.true(env, 'name = "Flutter_xcframework"' in build)
        asserts.true(env, 'glob(["Flutter.xcframework/**"])' in build)
    return unittest.end(env)

def _hub_aliases_each_label_to_its_own_mode_test_impl(ctx):
    env = unittest.begin(ctx)
    build = ios_engine_hub_build("hub_release", "hub_debug")
    asserts.true(env, 'name = "Flutter_xcframework",\n    actual = "@hub_release//:Flutter_xcframework"' in build)
    asserts.true(env, 'name = "Flutter_xcframework_debug",\n    actual = "@hub_debug//:Flutter_xcframework"' in build)
    asserts.true(env, 'name = "gen_snapshot_arm64",\n    actual = "@hub_release//:gen_snapshot_arm64"' in build)

    # The hub carries no archive of its own.
    asserts.false(env, "http" in build)
    return unittest.end(env)

def _ios_engine_repos_are_separate_rules_with_own_checksums_test_impl(ctx):
    env = unittest.begin(ctx)
    modes = []
    hubs = []
    flutter_ios_engine_repos(
        "flutter_ios_engine",
        _REVISION,
        release_sha256 = _RELEASE_SHA,
        debug_sha256 = _DEBUG_SHA,
        mode_rule = lambda **kwargs: modes.append(kwargs),
        hub_rule = lambda **kwargs: hubs.append(kwargs),
    )
    by_mode = {m["mode"]: m for m in modes}
    asserts.equals(env, ["debug", "release"], sorted(by_mode.keys()))
    asserts.equals(env, _RELEASE_SHA, by_mode["release"]["sha256"])
    asserts.equals(env, _DEBUG_SHA, by_mode["debug"]["sha256"])
    asserts.equals(env, "flutter_ios_engine_release", by_mode["release"]["name"])
    asserts.equals(env, "flutter_ios_engine_debug", by_mode["debug"]["name"])

    # The hub keeps the public name and holds no checksum or archive.
    asserts.equals(env, 1, len(hubs))
    asserts.equals(env, "flutter_ios_engine", hubs[0]["name"])
    asserts.equals(env, "flutter_ios_engine_release", hubs[0]["release_repo"])
    asserts.equals(env, "flutter_ios_engine_debug", hubs[0]["debug_repo"])
    asserts.false(env, "sha256" in hubs[0])
    return unittest.end(env)

def _spokes_of_one_version_share_one_extraction_test_impl(ctx):
    env = unittest.begin(ctx)
    sources = []
    spokes = []
    label = declare_sdk_source(
        "flutter",
        "3.47.7",
        _RELEASE_SHA,
        "",
        rule = lambda **kwargs: sources.append(kwargs),
    )
    packages = ["flutter", "flutter_test", "flutter_driver", "flutter_localizations", "flutter_web_plugins"]
    plan = struct(hub_name = "deps", all_package_names = packages, scc_targets = {})
    declare_sdk_spokes(
        plan,
        packages,
        struct(version = "3.47.7", local_path = "", source_label = label),
        rule = lambda **kwargs: spokes.append(kwargs),
    )

    # One extracting repository for five packages; no spoke carries a checksum
    # or a tarball URL, so none can unpack one.
    asserts.equals(env, 1, len(sources))
    asserts.equals(env, 5, len(spokes))
    asserts.equals(env, "flutter_sdk_source", sources[0]["name"])
    for spoke in spokes:
        asserts.equals(env, "@flutter_sdk_source//:BUILD.bazel", spoke["sdk_source"])
        asserts.false(env, "sha256" in spoke)
        asserts.false(env, "source_url" in spoke)
    asserts.equals(env, ["deps__" + p for p in packages], [s["name"] for s in spokes])
    return unittest.end(env)

def _local_sdk_spokes_do_not_use_the_shared_extraction_test_impl(ctx):
    env = unittest.begin(ctx)
    spokes = []
    plan = struct(hub_name = "deps", all_package_names = ["flutter"], scc_targets = {})
    declare_sdk_spokes(
        plan,
        ["flutter"],
        struct(version = "", local_path = "/sdk", source_label = ""),
        rule = lambda **kwargs: spokes.append(kwargs),
    )
    asserts.equals(env, "/sdk", spokes[0]["local_path"])
    asserts.equals(env, None, spokes[0]["sdk_source"])
    return unittest.end(env)

def _fake_source_tree():
    """A fake `sdk_source` directory holding `packages/flutter/{pubspec.yaml,lib/...}`."""
    src_file = struct(
        basename = "material.dart",
        is_dir = False,
        realpath = "/src/lib/src/material.dart",
        exists = True,
    )
    src_dir = struct(
        basename = "src",
        is_dir = True,
        realpath = "/src/lib/src",
        readdir = lambda: [src_file],
    )
    top_file = struct(basename = "widgets.dart", is_dir = False, realpath = "/src/lib/widgets.dart", exists = True)
    by_rel = {
        "widgets.dart": top_file,
        "src/material.dart": src_file,
    }
    lib_dir = struct(
        exists = True,
        realpath = "/src/lib",
        readdir = lambda: [src_dir, top_file],
        get_child = lambda rel: by_rel[rel],
    )
    pubspec = struct(exists = True, realpath = "/src/pubspec.yaml")
    root_children = {
        "packages/flutter/pubspec.yaml": pubspec,
        "packages/flutter/lib": lib_dir,
    }
    return struct(
        dirname = struct(get_child = lambda rel: root_children[rel]),
        contents = {
            pubspec.realpath: "name: flutter\n",
            top_file.realpath: "// widgets\n",
            src_file.realpath: "// material\n",
        },
    )

def _downloaded_spoke_copies_files_and_stays_reproducible_test_impl(ctx):
    env = unittest.begin(ctx)
    tree = _fake_source_tree()
    files = {}
    symlinks = []
    rctx = struct(
        name = "deps__flutter",
        attr = struct(
            flutter_version = "3.47.7",
            local_path = "",
            sdk_source = "@flutter_sdk_source//:BUILD.bazel",
        ),
        path = lambda _: struct(dirname = tree.dirname),
        read = lambda p: tree.contents[p.realpath],
        file = lambda path, content, executable = False: files.update({path: (content, executable)}),
        symlink = lambda src, dst: symlinks.append((src, dst)),
        repo_metadata = lambda reproducible: struct(reproducible = reproducible),
    )
    copy_sdk_package_from_source(rctx, "flutter")
    metadata = download_mode_metadata(rctx)
    asserts.true(env, metadata.reproducible)
    asserts.equals(env, [], symlinks)
    asserts.equals(
        env,
        ["lib/src/material.dart", "lib/widgets.dart", "pubspec.yaml"],
        sorted(files.keys()),
    )
    asserts.equals(env, ("// material\n", False), files["lib/src/material.dart"])
    return unittest.end(env)

_t0_test = unittest.make(_release_repo_never_requests_the_debug_archive_test_impl)
_t1_test = unittest.make(_debug_repo_never_requests_the_release_archive_test_impl)
_t2_test = unittest.make(_mode_repo_exposes_one_xcframework_target_test_impl)
_t3_test = unittest.make(_hub_aliases_each_label_to_its_own_mode_test_impl)
_t4_test = unittest.make(_ios_engine_repos_are_separate_rules_with_own_checksums_test_impl)
_t5_test = unittest.make(_spokes_of_one_version_share_one_extraction_test_impl)
_t6_test = unittest.make(_local_sdk_spokes_do_not_use_the_shared_extraction_test_impl)
_t7_test = unittest.make(_downloaded_spoke_copies_files_and_stays_reproducible_test_impl)

def sdk_source_and_ios_engine_repos_test_suite(name):
    """Declares the shared-extraction and per-mode engine repository tests.

    Args:
        name: The test suite name.
    """
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test, _t6_test, _t7_test)
