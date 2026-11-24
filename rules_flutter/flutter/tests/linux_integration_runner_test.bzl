"""Regression test for the Linux integration-test runner compile path.

`compile_linux_runner` takes its runner, registrant and plugin inputs as one
struct per clump. The Linux integration-test caller once built
`struct(srcs = ...)` with no `hdrs`, so analysis of every
`flutter_integration_test(platform = "linux")` target failed with `'struct'
value has no field or method 'hdrs'` — a caller the unit tests never reached
because they only built `e2e/hello_world`. The analysis test below analyses
such a target, so this caller is covered without a display or device.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter:defs.bzl", "flutter_integration_test")
load(
    "//flutter/private:flutter_linux_application.bzl",
    "linux_plugin_inputs",
    "linux_registrant_inputs",
    "linux_runner_inputs",
)
load(
    "//flutter/private:flutter_windows_application.bzl",
    "windows_plugin_inputs",
    "windows_registrant_inputs",
    "windows_runner_inputs",
)
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_LINUX_ONLY = ["@platforms//os:linux"]

_DBG = {
    "//command_line_option:compilation_mode": "dbg",
    str(Label("//flutter:profile")): False,
}

def _linux_runner_defaults_test_impl(ctx):
    env = unittest.begin(ctx)
    runner = linux_runner_inputs(["runner.cc"])
    asserts.equals(env, ["runner.cc"], runner.srcs)
    asserts.equals(env, [], runner.hdrs)
    registrant = linux_registrant_inputs(["registrant.cc"], ["registrant.h"])
    asserts.equals(env, ["registrant.cc"], registrant.srcs)
    asserts.equals(env, ["registrant.h"], registrant.hdrs)
    plugins = linux_plugin_inputs(["plugin.cc"])
    asserts.equals(env, ["plugin.cc"], plugins.srcs)
    asserts.equals(env, [], plugins.hdrs)
    asserts.equals(env, [], plugins.include_dirs)
    return unittest.end(env)

def _windows_runner_defaults_test_impl(ctx):
    env = unittest.begin(ctx)
    runner = windows_runner_inputs(["runner.cpp"])
    asserts.equals(env, ["runner.cpp"], runner.srcs)
    asserts.equals(env, [], runner.hdrs)
    registrant = windows_registrant_inputs(["registrant.cc"], ["registrant.h"])
    asserts.equals(env, ["registrant.cc"], registrant.srcs)
    asserts.equals(env, ["registrant.h"], registrant.hdrs)
    plugins = windows_plugin_inputs(["plugin.cpp"])
    asserts.equals(env, ["plugin.cpp"], plugins.srcs)
    asserts.equals(env, [], plugins.hdrs)
    asserts.equals(env, [], plugins.include_dirs)
    return unittest.end(env)

def _linux_integration_runner_compiles_test_impl(ctx):
    env = analysistest.begin(ctx)
    mnemonics = [a.mnemonic for a in analysistest.target_actions(env)]
    asserts.true(
        env,
        "CppCompile" in mnemonics,
        "the Linux integration test must compile its GTK runner, got %s" % (mnemonics,),
    )
    asserts.true(
        env,
        "FlutterLinuxBundle" in mnemonics,
        "the Linux integration test must assemble its desktop bundle, got %s" % (mnemonics,),
    )
    bundle = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterLinuxBundle"][0]
    asserts.true(env, len(bundle.argv) > 0)
    asserts.true(env, any(["bundle" in arg or "--output" in arg or "--assets" in arg for arg in bundle.argv]))
    bundle_inputs = [f.basename for f in bundle.inputs.to_list()]
    asserts.true(env, any([f.endswith(".so") or f.endswith(".json") or f == "icudtl.dat" for f in bundle_inputs]))
    return analysistest.end(env)

_linux_runner_defaults_test = unittest.make(_linux_runner_defaults_test_impl)
_windows_runner_defaults_test = unittest.make(_windows_runner_defaults_test_impl)
_linux_integration_runner_compiles_test = analysistest.make(
    _linux_integration_runner_compiles_test_impl,
    config_settings = _DBG,
)

def linux_integration_runner_test_suite(name):
    """Fixtures and tests for the Linux integration-test runner compile path.

    Args:
        name: The test suite name.
    """
    flutter_integration_test(
        name = "_linux_it_under_test",
        package_name = "linux_integration_runner_fixture",
        platform = "linux",
        srcs = ["linux_integration_runner_fixture.dart"],
        deps = ["//flutter/tests/linux_integration_dep:flutter_test_dep"],
        target_compatible_with = _LINUX_ONLY,
        tags = ["manual"],
    )
    _linux_integration_runner_compiles_test(
        name = name + "_compiles",
        target_under_test = ":_linux_it_under_test",
        target_compatible_with = _LINUX_ONLY,
    )
    small_unittest_suite(
        name + "_unit",
        _linux_runner_defaults_test,
        _windows_runner_defaults_test,
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_compiles",
        ],
    )
