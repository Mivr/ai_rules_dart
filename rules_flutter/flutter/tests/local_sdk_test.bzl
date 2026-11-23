"""Unit tests for the local-SDK helpers behind `flutter.toolchain(local_path = ...)`.

Covers the engine-cache layout mapping (which must follow flutter_tool's
`Cache` tables in `packages/flutter_tools/lib/src/flutter_cache.dart`,
verified against the real 3.47.7 install), and the exact wording of the two
failure messages whose placeholders once rendered literally.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_sky_engine_repo.bzl", "scan_local_files")
load("//flutter/private:local_sdk.bzl", "copy_failed_message", "engine_cache_dir", "host_engine_cache_dir", "local_sdk_vm_environment", "local_sdk_vm_path", "macos_framework_cache_path", "missing_local_file_message", "missing_local_source_message")
load("//flutter/private:versions.bzl", "unknown_version_message")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _engine_cache_dir_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "common", engine_cache_dir("flutter_patched_sdk.zip"))
    asserts.equals(env, "common", engine_cache_dir("flutter_patched_sdk_product.zip"))
    asserts.equals(env, "darwin-x64", engine_cache_dir("darwin-x64/artifacts.zip"))
    asserts.equals(env, "darwin-x64-release", engine_cache_dir("darwin-x64-release/artifacts.zip"))
    asserts.equals(env, "darwin-x64", engine_cache_dir("darwin-x64/FlutterMacOS.framework.zip"))
    asserts.equals(env, "ios", engine_cache_dir("ios/artifacts.zip"))
    asserts.equals(env, "ios-release", engine_cache_dir("ios-release/artifacts.zip"))
    asserts.equals(env, "ios-profile", engine_cache_dir("ios-profile/artifacts.zip"))
    asserts.equals(env, "android-arm64", engine_cache_dir("android-arm64/artifacts.zip"))
    asserts.equals(env, "android-arm64-release", engine_cache_dir("android-arm64-release/artifacts.zip"))

    # Cross-compile gen_snapshot archives live one level deeper.
    asserts.equals(
        env,
        "android-arm64-release/linux-x64",
        engine_cache_dir("android-arm64-release/linux-x64.zip"),
    )
    asserts.equals(
        env,
        "android-arm64-profile/linux-x64",
        engine_cache_dir("android-arm64-profile/linux-x64.zip"),
    )
    asserts.equals(
        env,
        "android-arm64-release/windows-x64",
        engine_cache_dir("android-arm64-release/windows-x64.zip"),
    )

    # The Linux and Windows debug desktop engines publish under a `-debug`
    # artifact directory but extract into the bare host directory, shared
    # with the host tools.
    asserts.equals(
        env,
        "linux-x64",
        engine_cache_dir("linux-x64-debug/linux-x64-flutter-gtk.zip"),
    )
    asserts.equals(
        env,
        "windows-x64",
        engine_cache_dir("windows-x64-debug/windows-x64-flutter.zip"),
    )
    asserts.equals(
        env,
        "linux-x64-profile",
        engine_cache_dir("linux-x64-profile/linux-x64-flutter-gtk.zip"),
    )
    asserts.equals(
        env,
        "windows-x64-release",
        engine_cache_dir("windows-x64-release/windows-x64-flutter.zip"),
    )
    return unittest.end(env)

def _host_engine_cache_dir_test_impl(ctx):
    env = unittest.begin(ctx)

    # macOS is one universal directory on every Mac, even Apple Silicon.
    asserts.equals(env, "darwin-x64", host_engine_cache_dir("darwin-arm64"))
    asserts.equals(env, "darwin-x64", host_engine_cache_dir("darwin-x64"))

    # Linux and Windows keep their architecture.
    asserts.equals(env, "linux-x64", host_engine_cache_dir("linux-x64"))
    asserts.equals(env, "linux-arm64", host_engine_cache_dir("linux-arm64"))
    asserts.equals(env, "windows-x64", host_engine_cache_dir("windows-x64"))
    return unittest.end(env)

def _macos_framework_cache_path_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64/FlutterMacOS.framework",
        macos_framework_cache_path("darwin-x64"),
    )
    asserts.equals(
        env,
        "darwin-x64-profile/FlutterMacOS.xcframework/macos-arm64_x86_64/FlutterMacOS.framework",
        macos_framework_cache_path("darwin-x64-profile"),
    )
    return unittest.end(env)

def _missing_local_source_message_test_impl(ctx):
    env = unittest.begin(ctx)
    message = missing_local_source_message(
        "bin/cache/dart-sdk",
        "the Flutter-bundled Dart SDK",
        "third_party/flutter",
    )
    asserts.true(env, "bin/cache/dart-sdk" in message)
    asserts.true(env, "the Flutter-bundled Dart SDK" in message)
    asserts.true(env, "third_party/flutter" in message)

    # The placeholders must render, not print literally (L-13).
    asserts.true(env, "{rel}" not in message)
    asserts.true(env, "{what}" not in message)
    asserts.true(env, "{root}" not in message)
    return unittest.end(env)

def _unknown_version_message_test_impl(ctx):
    env = unittest.begin(ctx)
    message = unknown_version_message("3.47.70")
    asserts.true(env, "3.47.70" in message)
    asserts.true(env, "{v}" not in message)
    return unittest.end(env)

def _missing_local_file_message_test_impl(ctx):
    env = unittest.begin(ctx)
    message = missing_local_file_message(
        "/sdk/bin/cache/dart-sdk/bin/snapshots/dartdev_aot.dart.snapshot",
        "the dartdev AOT snapshot",
    )
    asserts.true(env, "/sdk/bin/cache/dart-sdk/bin/snapshots/dartdev_aot.dart.snapshot" in message)
    asserts.true(env, "the dartdev AOT snapshot" in message)

    # The placeholders must render, not print literally (L-13).
    asserts.true(env, "{src}" not in message)
    asserts.true(env, "{what}" not in message)
    return unittest.end(env)

def _copy_failed_message_test_impl(ctx):
    env = unittest.begin(ctx)
    message = copy_failed_message("/sdk/x", "the gen-l10n subset file y", "cp: boom")
    asserts.true(env, "/sdk/x" in message)
    asserts.true(env, "the gen-l10n subset file y" in message)
    asserts.true(env, "cp: boom" in message)
    asserts.true(env, "{src}" not in message)
    asserts.true(env, "{what}" not in message)
    asserts.true(env, "{err}" not in message)
    return unittest.end(env)

def _fake_file(name):
    """A fake non-directory `readdir` entry (a file or a file symlink)."""
    return struct(basename = name, is_dir = False, realpath = "/real/" + name)

def _fake_dir(name, entries, real = None):
    """A fake directory entry whose `readdir` lists `entries`."""
    return struct(
        basename = name,
        is_dir = True,
        realpath = real or "/real/" + name,
        readdir = lambda: entries,
    )

def _fake_root(entries):
    """A fake walk root listing `entries`."""
    return _fake_dir("root", entries, "/real/root")

def _scan_local_files_test_impl(ctx):
    """Checks the walk's nested, symlinked and sorted output."""
    env = unittest.begin(ctx)
    root = _fake_root([
        _fake_dir("b", [_fake_file("z.dart"), _fake_dir("deep", [_fake_file("y.dart")])]),
        _fake_file("link.dart"),
        _fake_dir("a", [_fake_file("x.dart")]),
    ])
    result = scan_local_files(root, "lib", "/sdk/lib")
    asserts.equals(env, "", result.error)
    asserts.equals(env, ["a/x.dart", "b/deep/y.dart", "b/z.dart", "link.dart"], result.files)
    return unittest.end(env)

def _scan_local_files_failures_test_impl(ctx):
    """Checks the empty, step-bound and cycle failures."""
    env = unittest.begin(ctx)
    chain = _fake_root([_fake_dir("d", [_fake_dir("e", [_fake_file("f")])])])
    empty = scan_local_files(_fake_root([_fake_dir("d", [])]), "the lib", "/sdk/lib")
    asserts.true(env, "listed no files under the lib (/sdk/lib)" in empty.error, empty.error)
    bound = scan_local_files(chain, "the lib", "/sdk/lib", 2)
    asserts.true(env, "the lib (/sdk/lib) exceeded 2 directories" in bound.error, bound.error)
    asserts.equals(env, ["d/e/f"], scan_local_files(chain, "the lib", "/sdk/lib", 3).files)
    loop = _fake_root([_fake_dir("loop", [_fake_dir("again", [], "/real/root")])])
    cycle = scan_local_files(loop, "the lib", "/sdk/lib")
    asserts.true(env, "directory symlink cycle at loop/again" in cycle.error, cycle.error)
    return unittest.end(env)

def _vm_selection_test_impl(ctx):
    """Checks the bundled VM choice and its scrubbed environment."""
    env = unittest.begin(ctx)
    present = lambda *names: struct(get_child = lambda n: struct(exists = n in names, name = n))
    asserts.equals(env, "dartvm", local_sdk_vm_path(present("dartvm", "dart"), False).name)
    asserts.equals(env, "dart", local_sdk_vm_path(present("dart"), False).name)
    asserts.equals(env, "dartvm.exe", local_sdk_vm_path(present("dartvm.exe", "dart.exe"), True).name)
    asserts.equals(env, "dart.exe", local_sdk_vm_path(present("dart.exe"), True).name)
    asserts.equals(env, {"HOME": ""}, local_sdk_vm_environment(False))
    asserts.equals(env, {"USERPROFILE": "", "LOCALAPPDATA": ""}, local_sdk_vm_environment(True))
    return unittest.end(env)

_t0_test = unittest.make(_engine_cache_dir_test_impl)
_t1_test = unittest.make(_host_engine_cache_dir_test_impl)
_t2_test = unittest.make(_macos_framework_cache_path_test_impl)
_t3_test = unittest.make(_missing_local_source_message_test_impl)
_t4_test = unittest.make(_unknown_version_message_test_impl)
_t5_test = unittest.make(_missing_local_file_message_test_impl)
_t6_test = unittest.make(_copy_failed_message_test_impl)
_t7_test = unittest.make(_scan_local_files_test_impl)
_t8_test = unittest.make(_scan_local_files_failures_test_impl)
_t9_test = unittest.make(_vm_selection_test_impl)

def local_sdk_test_suite(name):
    small_unittest_suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
        _t8_test,
        _t9_test,
    )
