"""`exe` and `aot-snapshot` binaries take the source path; `kernel` stays modular."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:defs.bzl", "dart_binary")
load("//dart/tests:pruned_inputs.bzl", "pruned_inputs_settings")

visibility(["//dart/tests/..."])

_CHAIN = ["//dart/tests/modular_chain_fixture/chain_top"]

def _source_path_impl(ctx):
    """No module compile, no link, no `--from-dill` front end; sources are read."""
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    mnemonics = [a.mnemonic for a in actions]
    asserts.equals(env, [], [m for m in mnemonics if m == "DartKernelLink"], "no module link")
    kernels = [a for a in actions if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(kernels), "one whole-program front end: %s" % mnemonics)
    if kernels:
        argv = kernels[0].argv
        asserts.equals(env, [], [x for x in argv if x.startswith("--from-dill=")], "reads no linked kernel")
        asserts.true(env, "--aot" in argv, "the front end targets AOT: %s" % argv)
        asserts.true(env, [f for f in kernels[0].inputs.to_list() if f.extension == "dart"] != [], "reads .dart sources")
        asserts.false(env, [x for x in argv if x.endswith("vm_platform_strong.dill")] != [], "not the JIT platform")
    return analysistest.end(env)

_source_path_test = analysistest.make(_source_path_impl, config_settings = pruned_inputs_settings())

def _kernel_modular_impl(ctx):
    """A `kernel` binary keeps module actions against the strong platform."""
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    modules = [
        a
        for a in actions
        if a.mnemonic == "DartKernel" and [x for x in a.argv if x.endswith("vm_platform_strong.dill")]
    ]
    asserts.true(env, len(modules) > 0, "module actions compile against the strong platform")
    asserts.equals(env, 1, len([a for a in actions if a.mnemonic == "DartKernelLink"]), "modules are linked")
    return analysistest.end(env)

_kernel_modular_test = analysistest.make(_kernel_modular_impl, config_settings = pruned_inputs_settings())

def exe_source_path_test_suite(name):
    """Declares the analysis tests as one suite.

    Args:
      name: Name of the generated `test_suite`.
    """
    tests = []
    for mode in ["exe", "aot-snapshot", "kernel"]:
        suffix = mode.replace("-", "_")
        fixture = "%s_%s_fixture" % (name, suffix)
        dart_binary(
            name = fixture,
            compile_mode = mode,
            main = "//dart/private/tools:noop.dart",
            deps = _CHAIN,
            tags = ["manual"],
        )
        test = "%s_%s_test" % (name, suffix)
        if mode == "kernel":
            _kernel_modular_test(name = test, target_under_test = ":" + fixture, size = "small")
        else:
            _source_path_test(name = test, target_under_test = ":" + fixture, size = "small")
        tests.append(":" + test)
    native.test_suite(name = name, tests = tests)
