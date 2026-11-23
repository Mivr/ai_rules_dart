"""A debug whole-program kernel compile names the agent files by constant URIs."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter/private:app_entrypoint.bzl", "app_scheme_rel_path")
load("//flutter/private:flutter_kernel_target.bzl", "flutter_kernel_target")

visibility(["//flutter/tests/..."])

_DBG = {
    "//command_line_option:compilation_mode": "dbg",
    str(Label("//flutter:profile")): False,
}
_OPT = {
    "//command_line_option:compilation_mode": "opt",
    str(Label("//flutter:profile")): False,
}
_REGISTRANT_URI = "org-dartlang-app:///_flutter_debug_agent/plugin_registrant.dart"
_DEFINE = "-Dflutter.dart_plugin_registrant="

def _compile_argv(env):
    kernels = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterKernelCompile"]
    asserts.equals(env, 1, len(kernels), "expected one FlutterKernelCompile")
    return kernels[0].argv if kernels else []

def _sources(argv):
    return [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "--source"]

def _constant_uris_impl(ctx):
    env = analysistest.begin(ctx)
    argv = _compile_argv(env)
    asserts.true(env, _DEFINE + _REGISTRANT_URI in argv, "the define is the constant registrant URI: %r" % argv)
    sources = _sources(argv)
    asserts.true(env, _REGISTRANT_URI in sources, "the registrant must be a --source: %r" % sources)
    kernels = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterKernelCompile"]
    paths = [f.path for a in kernels for f in a.inputs.to_list()]
    for name in ["agent_extensions.dart", "native_agent_extensions.dart", "plugin_registrant.dart"]:
        asserts.true(
            env,
            any([p.endswith("/_flutter_debug_agent/" + name) for p in paths]),
            "%s must be staged in one directory: %r" % (name, paths[:3]),
        )
    return analysistest.end(env)

def _no_constant_layout_impl(ctx):
    env = analysistest.begin(ctx)
    argv = _compile_argv(env)
    asserts.equals(env, [], [a for a in argv if a.startswith(_DEFINE)], "no constant registrant outside debug")
    for a in argv:
        asserts.false(env, "_flutter_debug_agent" in a, "constant layout leaked into %r" % a)
    return analysistest.end(env)

_constant_uris_test = analysistest.make(_constant_uris_impl, config_settings = _DBG)
_release_test = analysistest.make(_no_constant_layout_impl, config_settings = _OPT)
_aot_dbg_test = analysistest.make(_no_constant_layout_impl, config_settings = _DBG)

def _rel_path_impl(ctx):
    env = unittest.begin(ctx)
    gen = struct(short_path = "pkg/app.debug_agent/_flutter_debug_agent/plugin_registrant.dart")
    other = struct(short_path = "a/b/other.debug_agent/_flutter_debug_agent/plugin_registrant.dart")
    asserts.equals(env, "_flutter_debug_agent/plugin_registrant.dart", app_scheme_rel_path(gen))
    asserts.equals(env, app_scheme_rel_path(gen), app_scheme_rel_path(other))
    label_named = struct(short_path = "pkg/app_plugin_registrant.dart")
    asserts.equals(env, "pkg/app_plugin_registrant.dart", app_scheme_rel_path(label_named))
    asserts.equals(env, "external/r/x.dart", app_scheme_rel_path(struct(short_path = "../r/x.dart")))
    return unittest.end(env)

_rel_path_test = unittest.make(_rel_path_impl)

def agent_uris_test_suite(name):
    """Tests that the debug agent, native agent and registrant sit at constant URIs.

    Args:
        name: The test suite name.
    """
    flutter_kernel_target(
        name = "_agent_uris_kernel",
        package_name = "inputs_fixture",
        main = "lib/language_version_main.dart",
        tags = ["manual"],
    )
    flutter_kernel_target(
        name = "_agent_uris_kernel_aot",
        package_name = "inputs_fixture",
        main = "lib/language_version_main.dart",
        aot = True,
        tags = ["manual"],
    )
    _constant_uris_test(name = name + "_own_package", target_under_test = ":_agent_uris_kernel")
    _constant_uris_test(
        name = name + "_other_package",
        target_under_test = "//flutter/tests/agent_uris_other:other_label_kernel",
    )
    _release_test(name = name + "_release", target_under_test = ":_agent_uris_kernel")
    _aot_dbg_test(name = name + "_aot_dbg", target_under_test = ":_agent_uris_kernel_aot")
    _rel_path_test(name = name + "_rel_path")
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_own_package",
            ":" + name + "_other_package",
            ":" + name + "_release",
            ":" + name + "_aot_dbg",
            ":" + name + "_rel_path",
        ],
    )
