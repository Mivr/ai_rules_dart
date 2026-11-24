"""Unit tests for the pure parts of a hook's C toolchain (`build_hooks.bzl`)."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/private:build_hooks.bzl", "is_msvc_toolchain", "msvc_developer_prompt")
load(":small_suite.bzl", "small_unittest_suite")

visibility(["//dart/..."])

# What Bazel's MSVC toolchain (`local_config_cc`, `msvc_env`,
# `msvc_compile_env`, `msvc_link_env`) gives a compile and a link action.
_MSVC_ENV = {
    "INCLUDE": "C:\\VS\\VC\\Tools\\MSVC\\14.44\\include;C:\\Kits\\10\\include\\ucrt",
    "LIB": "C:\\VS\\VC\\Tools\\MSVC\\14.44\\lib\\x64;C:\\Kits\\10\\lib\\ucrt\\x64",
    "PATH": "C:\\VS\\VC\\Tools\\MSVC\\14.44\\bin\\HostX64\\x64;C:\\Windows\\system32",
    "TEMP": "C:\\Users\\runner\\AppData\\Local\\Temp",
    "TMP": "C:\\Users\\runner\\AppData\\Local\\Temp",
}

def _msvc_detection_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, is_msvc_toolchain("msvc-cl", "C:/VS/VC/Tools/MSVC/14.44/bin/HostX64/x64/cl.exe"))
    asserts.true(env, is_msvc_toolchain("clang-cl", "C:/LLVM/bin/clang-cl.exe"))
    asserts.true(env, is_msvc_toolchain("", "C:/VS/bin/CL.EXE"), "by the compiler's name when the toolchain names no compiler")
    asserts.false(env, is_msvc_toolchain("clang", "external/llvm/bin/clang"))
    asserts.false(env, is_msvc_toolchain("gcc", "/usr/bin/gcc"))
    return unittest.end(env)

def _msvc_prompt_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "@echo off\r\n" +
        'set "INCLUDE=C:\\VS\\VC\\Tools\\MSVC\\14.44\\include;C:\\Kits\\10\\include\\ucrt"\r\n' +
        'set "LIB=C:\\VS\\VC\\Tools\\MSVC\\14.44\\lib\\x64;C:\\Kits\\10\\lib\\ucrt\\x64"\r\n' +
        'set "PATH=C:\\VS\\VC\\Tools\\MSVC\\14.44\\bin\\HostX64\\x64;C:\\Windows\\system32"\r\n',
        msvc_developer_prompt(_MSVC_ENV),
        "the toolchain's INCLUDE, LIB and PATH, without its TEMP and TMP",
    )
    return unittest.end(env)

def _msvc_prompt_escapes_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        '@echo off\r\nset "INCLUDE=C:\\100%%\\include"\r\nset "LIB=C:\\lib"\r\n',
        msvc_developer_prompt({"INCLUDE": "C:\\100%\\include", "LIB": "C:\\lib"}),
        "a `%` is doubled, as a batch file reads it once",
    )
    return unittest.end(env)

def _msvc_prompt_without_env_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        None,
        msvc_developer_prompt({"PATH": "C:\\Windows\\system32"}),
        "no INCLUDE: no script, and native_toolchain_c runs the vcvars of cl.exe's Visual Studio",
    )
    asserts.equals(
        env,
        None,
        msvc_developer_prompt({"INCLUDE": "C:\\inc", "PATH": "C:\\Windows\\system32"}),
        "no LIB: the same, rather than a script that compiles but cannot link",
    )
    return unittest.end(env)

_t0_test = unittest.make(_msvc_detection_test_impl)
_t1_test = unittest.make(_msvc_prompt_test_impl)
_t2_test = unittest.make(_msvc_prompt_escapes_test_impl)
_t3_test = unittest.make(_msvc_prompt_without_env_test_impl)

def build_hooks_test_suite(name):
    small_unittest_suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
    )
