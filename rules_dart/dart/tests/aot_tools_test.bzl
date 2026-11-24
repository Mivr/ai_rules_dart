"""Tests that `kernel_link` and `analyzer_summary` are AOT executables.

Both tools are `aot-snapshot` binaries run by `dartaotruntime`. No action of
the `DartKernelLink`, `DartAnalyzerSummary`, `DartAnalyzerSdkSummary` or
`DartAnalyze` mnemonics may run a `.dill` under `dart`.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:util.bzl", "util")
load("//dart:providers.bzl", "DartCompileInfo")
load("//dart/private:dart_analyze_aspect.bzl", "dart_analyze")
load("//dart/private:dart_analyzer_summary.bzl", "dart_analyzer_summary")

visibility(["//dart/..."])

_TESTING_ASPECT = util.make_testing_aspect([dart_analyze, dart_analyzer_summary])

_MNEMONICS = ["DartKernelLink", "DartAnalyzerSummary", "DartAnalyzerSdkSummary", "DartAnalyze"]

def _tool_is_aot_test_impl(env, target):
    """Asserts that the tool target is compiled as an AOT snapshot."""
    env.expect.that_str(target[DartCompileInfo].compile_mode).equals("aot-snapshot")
    env.expect.that_str(target[DartCompileInfo].executable.basename).contains(".aot")

def _check_action(env, action):
    """Asserts that one action runs an `.aot` under `dartaotruntime`, never a `.dill` under `dart`."""
    exe = action.argv[0]
    env.expect.that_str(exe.split("/")[-1]).contains("dartaotruntime")
    env.expect.that_bool(any([a.endswith(".dill") and "kernel_link" in a for a in action.argv])).equals(False)
    env.expect.that_bool(any([a.endswith("analyzer_summary.dill") for a in action.argv])).equals(False)
    env.expect.that_bool(any([a.endswith(".aot") for a in action.argv[:2]])).equals(True)

def _actions_run_aot_test_impl(env, target):
    """Asserts that every action of the tool mnemonics runs the AOT executable."""
    found = [a for a in target.actions if a.mnemonic in _MNEMONICS]
    env.expect.that_int(len(found)).is_greater_than(0)
    for action in found:
        _check_action(env, action)

def aot_tools_test_suite(name):
    """Declares the AOT tool tests.

    Args:
      name: Prefix for declared test targets.
    """
    for tool in ["kernel_link", "analyzer_summary"]:
        analysis_test(
            name = "%s_%s_is_aot" % (name, tool),
            attr_values = {"size": "small"},
            impl = _tool_is_aot_test_impl,
            target = "//dart/private/tools:" + tool,
        )
    analysis_test(
        name = name + "_link_runs_aot",
        attr_values = {"size": "small"},
        impl = _actions_run_aot_test_impl,
        target = "//dart/tests:kernel_test_modular_binary_fixture",
    )
    analysis_test(
        name = name + "_sdk_summary_runs_aot",
        attr_values = {"size": "small"},
        impl = _actions_run_aot_test_impl,
        target = "//dart/private:analyzer_sdk_summary",
    )
    analysis_test(
        name = name + "_summary_and_analyze_run_aot",
        attr_values = {"size": "small"},
        impl = _actions_run_aot_test_impl,
        target = "//dart/tests/analyze_mode_parity_fixture/consumer:consumer",
        testing_aspect = _TESTING_ASPECT,
    )
