"""Unit tests for the Windows C++ client wrapper checks in engine_helpers.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:engine_helpers.bzl",
    "WINDOWS_CPP_CLIENT_WRAPPER_FILES",
    "cpp_client_wrapper_artifact_path",
    "cpp_client_wrapper_missing_error",
    "cpp_client_wrapper_sha_error",
)
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _artifact_path_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "windows-x64/flutter-cpp-client-wrapper.zip",
        cpp_client_wrapper_artifact_path("x64"),
    )
    asserts.equals(
        env,
        "windows-arm64/flutter-cpp-client-wrapper.zip",
        cpp_client_wrapper_artifact_path("arm64"),
    )
    return unittest.end(env)

def _sha_error_windows_test_impl(ctx):
    env = unittest.begin(ctx)

    # An empty Windows checksum fails naming the archive and the attribute.
    err = cpp_client_wrapper_sha_error("windows", "x64", "")
    asserts.true(env, err != None)
    asserts.true(env, "windows-x64/flutter-cpp-client-wrapper.zip" in err)
    asserts.true(env, "cpp_client_wrapper_sha256" in err)

    # A pinned Windows checksum passes in every mode.
    asserts.equals(env, None, cpp_client_wrapper_sha_error("windows", "x64", "0" * 64))
    asserts.equals(env, None, cpp_client_wrapper_sha_error("windows", "arm64", "0" * 64))
    return unittest.end(env)

def _sha_error_non_windows_test_impl(ctx):
    env = unittest.begin(ctx)

    # A checksum nothing verifies fails naming the attribute and the OS.
    err = cpp_client_wrapper_sha_error("linux", "x64", "0" * 64)
    asserts.true(env, err != None)
    asserts.true(env, "cpp_client_wrapper_sha256" in err)
    asserts.true(env, "linux" in err)
    mac_err = cpp_client_wrapper_sha_error("macos", "x64", "0" * 64)
    asserts.true(env, mac_err != None)
    asserts.true(env, "cpp_client_wrapper_sha256" in mac_err)
    asserts.true(env, "macos" in mac_err)

    # An empty checksum passes off Windows.
    asserts.equals(env, None, cpp_client_wrapper_sha_error("linux", "x64", ""))
    asserts.equals(env, None, cpp_client_wrapper_sha_error("macos", "x64", ""))
    return unittest.end(env)

def _missing_error_test_impl(ctx):
    env = unittest.begin(ctx)

    # A complete extraction passes, even with extra files alongside.
    asserts.equals(env, None, cpp_client_wrapper_missing_error("x64", WINDOWS_CPP_CLIENT_WRAPPER_FILES))
    asserts.equals(
        env,
        None,
        cpp_client_wrapper_missing_error("x64", WINDOWS_CPP_CLIENT_WRAPPER_FILES + ["cpp-client-wrapper/extra.h"]),
    )

    # An empty extraction fails on the first aliased file.
    empty_err = cpp_client_wrapper_missing_error("x64", [])
    asserts.true(env, empty_err != None)
    asserts.true(env, WINDOWS_CPP_CLIENT_WRAPPER_FILES[0] in empty_err)
    asserts.true(env, "windows-x64/flutter-cpp-client-wrapper.zip" in empty_err)

    # A gap fails on the missing file, not on a later one.
    dropped = [p for p in WINDOWS_CPP_CLIENT_WRAPPER_FILES if p != WINDOWS_CPP_CLIENT_WRAPPER_FILES[5]]
    gap_err = cpp_client_wrapper_missing_error("arm64", dropped)
    asserts.true(env, gap_err != None)
    asserts.true(env, WINDOWS_CPP_CLIENT_WRAPPER_FILES[5] in gap_err)
    asserts.true(env, "windows-arm64/flutter-cpp-client-wrapper.zip" in gap_err)
    return unittest.end(env)

def _wrapper_files_shape_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, len(WINDOWS_CPP_CLIENT_WRAPPER_FILES) > 0)
    for path in WINDOWS_CPP_CLIENT_WRAPPER_FILES:
        asserts.true(env, path.startswith("cpp-client-wrapper/"), "wrapper file outside cpp-client-wrapper/: " + path)
    return unittest.end(env)

_t0_test = unittest.make(_artifact_path_test_impl)
_t1_test = unittest.make(_sha_error_windows_test_impl)
_t2_test = unittest.make(_sha_error_non_windows_test_impl)
_t3_test = unittest.make(_missing_error_test_impl)
_t4_test = unittest.make(_wrapper_files_shape_test_impl)

def cpp_client_wrapper_test_suite(name):
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test)
