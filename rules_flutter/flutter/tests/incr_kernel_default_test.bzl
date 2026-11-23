"""Analysis tests for `//flutter:incremental_kernel` being on by default for debug builds.

A debug (`-c dbg`) whole-program compile takes the worker route with the flag
left at its default. Fastbuild and opt compiles, AOT and web compiles, and a
debug compile that opts out with the flag set to false keep the stock
`kernel_filter` action: no worker requirements and no worker marker.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load(":incr_kernel_fixture.bzl", "ReqInfo", "incr_caller")

visibility(["//flutter/tests/..."])

_INCR = str(Label("//flutter:incremental_kernel"))
_MODE = "//command_line_option:compilation_mode"

def _compile(env):
    kernels = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterKernelCompile"]
    asserts.equals(env, 1, len(kernels), "expected one FlutterKernelCompile")
    reqs = analysistest.target_under_test(env)[ReqInfo].requirements
    asserts.equals(env, 1, len(reqs), "expected one recorded run")
    return struct(argv = kernels[0].argv, reqs = reqs[0] if reqs else {})

def _worker_impl(ctx):
    """The compile runs through the persistent worker."""
    env = analysistest.begin(ctx)
    action = _compile(env)
    asserts.true(env, "supports-workers" in action.reqs, "the worker route must be on: %s" % action.reqs)
    asserts.equals(env, "json", action.reqs.get("requires-worker-protocol"))
    asserts.false(env, "no-remote-cache" in action.reqs, "default must stay cacheable: %s" % action.reqs)
    return analysistest.end(env)

def _stock_impl(ctx):
    """The compile is the stock action: no worker requirements, no worker argv."""
    env = analysistest.begin(ctx)
    action = _compile(env)
    asserts.equals(env, {}, action.reqs, "the stock action carries no execution requirements")
    asserts.false(env, "--declared-inputs" in action.argv[:1], "no worker prefix expected: %s" % action.argv)
    return analysistest.end(env)

_worker_default_test = analysistest.make(_worker_impl, config_settings = {_MODE: "dbg"})
_fastbuild_test = analysistest.make(_stock_impl, config_settings = {_MODE: "fastbuild"})
_opt_test = analysistest.make(_stock_impl, config_settings = {_MODE: "opt"})
_opt_out_test = analysistest.make(_stock_impl, config_settings = {_MODE: "dbg", _INCR: False})
_opt_in_dbg_test = analysistest.make(_worker_impl, config_settings = {_MODE: "dbg", _INCR: True})
_aot_test = analysistest.make(_stock_impl, config_settings = {_MODE: "dbg"})
_web_test = analysistest.make(_stock_impl, config_settings = {_MODE: "dbg"})

def incr_kernel_default_test_suite(name):
    """Fixtures and tests for the debug default of `//flutter:incremental_kernel`.

    Args:
        name: The test suite name.
    """
    incr_caller(name = "_default_caller", main = "compile_api_main.dart", tags = ["manual"])
    incr_caller(name = "_aot_caller", main = "compile_api_main.dart", aot = True, tags = ["manual"])
    incr_caller(name = "_web_caller", main = "compile_api_main.dart", target = "dartdevc", tags = ["manual"])
    cases = {
        "_debug_default": (_worker_default_test, ":_default_caller"),
        "_debug_explicit_on": (_opt_in_dbg_test, ":_default_caller"),
        "_fastbuild": (_fastbuild_test, ":_default_caller"),
        "_opt": (_opt_test, ":_default_caller"),
        "_opt_out": (_opt_out_test, ":_default_caller"),
        "_aot": (_aot_test, ":_aot_caller"),
        "_web": (_web_test, ":_web_caller"),
    }
    for suffix, case in cases.items():
        case[0](name = name + suffix, target_under_test = case[1])
    native.test_suite(name = name, tests = [":" + name + s for s in cases])
