"""A three-library chain stays modular and links every module.

Each level of a `dart_library` chain compiles its own sources into a module
against a package config naming the whole closure. The test pins that shape:
every level provides a modular kernel and the entry's link consumes all three
module directories, in dependency order.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:providers.bzl", "DartKernelInfo")

visibility(["//dart/..."])

def _chain_modular_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, DartKernelInfo in target, "chain library provides DartKernelInfo")
    asserts.true(env, target[DartKernelInfo].modular, "chain library stays modular")
    return analysistest.end(env)

_chain_modular_test = analysistest.make(_chain_modular_test_impl)

def _chain_no_config_action_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    config_actions = [a for a in actions if a.mnemonic == "DartPackageConfig"]
    asserts.equals(env, 0, len(config_actions), "no process per library writes the package config")
    kernel_actions = [a for a in actions if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(kernel_actions), "the library registers one module action")
    argv = kernel_actions[0].argv
    records = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "--record"]
    names = [r.split("|")[0] for r in records]
    for want in ctx.attr.want_packages:
        asserts.true(env, want in names, "the module worker request names package %s" % want)
    asserts.true(env, "--packages-file" in argv, "the module worker request names the config it writes")
    outputs = [f.basename for f in kernel_actions[0].outputs.to_list()]
    asserts.true(
        env,
        [o for o in outputs if o.endswith(".package_config.json")] != [],
        "the module action declares the package config as its output",
    )
    return analysistest.end(env)

_chain_no_config_action_test = analysistest.make(
    _chain_no_config_action_test_impl,
    attrs = {"want_packages": attr.string_list()},
)

def _chain_link_test_impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    link_actions = [a for a in actions if a.mnemonic == "DartKernelLink"]
    asserts.equals(env, 1, len(link_actions), "chain app registers one DartKernelLink action")
    link_inputs = [f.basename for f in link_actions[0].inputs.to_list()]
    for want in ["chain_leaf.kmod", "chain_mid.kmod", "chain_top.kmod"]:
        asserts.true(env, want in link_inputs, "link consumes %s" % want)
    return analysistest.end(env)

_chain_link_test = analysistest.make(_chain_link_test_impl)

def modular_chain_test_suite(name):
    """Declares the three-library modular chain tests as one suite.

    Args:
      name: Name of the generated `test_suite`.
    """
    _chain_modular_test(
        name = name + "_leaf_test",
        target_under_test = "//dart/tests/modular_chain_fixture/chain_leaf:chain_leaf",
        size = "small",
    )
    _chain_modular_test(
        name = name + "_mid_test",
        target_under_test = "//dart/tests/modular_chain_fixture/chain_mid:chain_mid",
        size = "small",
    )
    _chain_modular_test(
        name = name + "_top_test",
        target_under_test = "//dart/tests/modular_chain_fixture/chain_top:chain_top",
        size = "small",
    )
    _chain_link_test(
        name = name + "_link_test",
        target_under_test = "//dart/tests/modular_chain_fixture/chain_app:chain_app",
        size = "small",
    )
    for level, want in {
        "leaf": ["chain_leaf"],
        "mid": ["chain_mid", "chain_leaf"],
        "top": ["chain_top", "chain_mid", "chain_leaf"],
    }.items():
        _chain_no_config_action_test(
            name = name + "_" + level + "_no_config_action_test",
            target_under_test = "//dart/tests/modular_chain_fixture/chain_%s:chain_%s" % (level, level),
            want_packages = want,
            size = "small",
        )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_leaf_no_config_action_test",
            ":" + name + "_mid_no_config_action_test",
            ":" + name + "_top_no_config_action_test",
            ":" + name + "_leaf_test",
            ":" + name + "_mid_test",
            ":" + name + "_top_test",
            ":" + name + "_link_test",
        ],
    )
