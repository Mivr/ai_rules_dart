"""A debug `flutter_kernel_target` whose closure holds the registrant twin compiles modularly.

The entry module carries the staged agent, native agent and registrant, and the link uses the twin
in place of the plain SDK `flutter` module. A define stays modular: it is the configuration of the
target's `deps`, so every dependency module compiles with it, and so does the entry. A closure without
the twin, or a non-debug build, keeps the whole-program `FlutterKernelCompile`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:flutter_kernel_module.bzl", "flutter_kernel_module_aspect")
load("//flutter/private:flutter_kernel_target.bzl", "flutter_kernel_target")

visibility(["//flutter/tests/..."])

_DBG = {"//command_line_option:compilation_mode": "dbg", str(Label("//flutter:profile")): False}
_TWIN_DEPS = ["//flutter/tests/registrant_twin_fixture/app"]
_ENTRY_FILES = [
    "/_flutter_debug_agent/agent_extensions.dart",
    "/_flutter_debug_agent/native_agent_extensions.dart",
    "/_flutter_debug_agent/plugin_registrant.dart",
    "/_flutter_debug_agent/registrant_lookup.dart",
]

def _by_mnemonic(env, mnemonic):
    return [a for a in analysistest.target_actions(env) if a.mnemonic == mnemonic]

def _paths(action):
    return [f.path for f in action.inputs.to_list()]

def _has_output(action, suffix):
    return any([f.basename.endswith(suffix) for f in action.outputs.to_list()])

def assert_kernel_target_dbg_modular(env):
    """Asserts a debug non-AOT `flutter_kernel_target` with the twin registers modules and one link.

    Args:
        env: The analysis test environment.
    """
    asserts.true(env, len(_by_mnemonic(env, "DartKernel")) > 0, "registers DartKernel modules")
    links = _by_mnemonic(env, "DartKernelLink")
    asserts.equals(env, 1, len(links), "one DartKernelLink")
    entry = [a for a in _by_mnemonic(env, "DartKernel") if _has_output(a, ".flutter_entry.kmod")]
    asserts.equals(env, 1, len(entry), "one entry module")
    if entry:
        paths = _paths(entry[0])
        for suffix in _ENTRY_FILES:
            asserts.true(env, any([p.endswith(suffix) for p in paths]), "entry compiles %s: %s" % (suffix, paths))
    if links:
        paths = _paths(links[0])
        asserts.true(env, any([".flutter_registrant.kmod" in p for p in paths]), "the link uses the twin: %s" % paths)
        asserts.false(env, any([".flutter.flutter.kmod" in p for p in paths]), "the link drops the plain SDK module")

def _whole_program_impl(ctx):
    """A define, or a closure with no twin, keeps the whole-program compile and no link."""
    env = analysistest.begin(ctx)
    asserts.equals(env, 1, len(_by_mnemonic(env, "FlutterKernelCompile")), "one whole-program compile")
    asserts.equals(env, [], _by_mnemonic(env, "DartKernelLink"), "no DartKernelLink")
    return analysistest.end(env)

_ActionsInfo = provider(
    doc = "The actions registered for a target and its `deps` closure.",
    fields = ["actions"],
)

def _inspect_impl(target, ctx):
    """Exposes the target's actions and its deps' (the kernel module aspect's among them)."""
    actions = list(target.actions)
    for dep in getattr(ctx.rule.attr, "deps", []):
        if _ActionsInfo in dep:
            actions += dep[_ActionsInfo].actions
    return [_ActionsInfo(actions = actions)]

_inspect_aspect = aspect(
    implementation = _inspect_impl,
    attr_aspects = ["deps"],
    requires = [flutter_kernel_module_aspect],
    doc = "Collects the actions of the target and of its dependency closure.",
)

def _source_reach_impl(ctx):
    """A body edit in one package reaches only that package's module, the entry and the link."""
    env = analysistest.begin(ctx)
    actions = analysistest.target_under_test(env)[_ActionsInfo].actions
    modules = [a for a in actions if a.mnemonic == "DartKernel" and not _has_output(a, "_product.kmod")]
    reading = [a for a in modules if any([p.endswith("registrant_twin_fixture/app/lib/app.dart") for p in _paths(a)])]
    names = sorted([[f.basename for f in a.outputs.to_list() if f.basename.endswith(".kmod")][0] for a in reading])
    asserts.equals(env, ["app.flutter.kmod"], names, "only the edited package's module reads its sources")
    link = _by_mnemonic(env, "DartKernelLink")[0]
    asserts.false(env, any(["app.dart" in p for p in _paths(link)]), "the link reads modules, not sources")
    plain = [p for p in _paths(link) if p.endswith("flutter.flutter.kmod")]
    asserts.equals(env, [], plain, "the plain SDK module is not linked")
    return analysistest.end(env)

def _define_modular_impl(ctx):
    """A define stays modular, and every module of the closure and the entry compile with it."""
    env = analysistest.begin(ctx)
    asserts.equals(env, [], _by_mnemonic(env, "FlutterKernelCompile"), "no whole-program compile")
    asserts.equals(env, 1, len(_by_mnemonic(env, "DartKernelLink")), "one DartKernelLink")
    actions = analysistest.target_under_test(env)[_ActionsInfo].actions
    modules = [a for a in actions if a.mnemonic == "DartKernel"]
    asserts.true(env, len(modules) > 2, "dependency modules and the entry: %s" % len(modules))
    for action in modules:
        name = [f.basename for f in action.outputs.to_list() if f.basename.endswith(".kmod")]
        asserts.true(env, "-DA=1" in action.argv, "%s compiles with the define: %s" % (name, action.argv))
    return analysistest.end(env)

_whole_program_test = analysistest.make(_whole_program_impl, config_settings = _DBG)
_define_modular_test = analysistest.make(
    _define_modular_impl,
    config_settings = _DBG,
    extra_target_under_test_aspects = [_inspect_aspect],
)
_source_reach_test = analysistest.make(
    _source_reach_impl,
    config_settings = _DBG,
    extra_target_under_test_aspects = [_inspect_aspect],
)

def kernel_target_modular_test_suite(name):
    """Declares the fixtures, the analysis tests and the dill test.

    Args:
        name: The test_suite name.
    """
    flutter_kernel_target(
        name = "kernel_target_modular_twin",
        package_name = "inputs_fixture",
        main = "lib/language_version_main.dart",
        tags = ["manual"],
        deps = _TWIN_DEPS,
    )
    flutter_kernel_target(
        name = "_kernel_target_twin_define",
        package_name = "inputs_fixture",
        main = "lib/language_version_main.dart",
        defines = ["A=1"],
        tags = ["manual"],
        deps = _TWIN_DEPS,
    )
    flutter_kernel_target(
        name = "_kernel_target_no_twin",
        package_name = "inputs_fixture",
        main = "lib/language_version_main.dart",
        tags = ["manual"],
        deps = ["//flutter/tests/registrant_twin_fixture/other"],
    )
    _define_modular_test(name = name + "_define", target_under_test = ":_kernel_target_twin_define")
    _whole_program_test(name = name + "_no_twin", target_under_test = ":_kernel_target_no_twin")
    _source_reach_test(name = name + "_source_reach", target_under_test = ":kernel_target_modular_twin")
    native.test_suite(
        name = name,
        tests = [name + "_define", name + "_no_twin", name + "_source_reach"],
    )
