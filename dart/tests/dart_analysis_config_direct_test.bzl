"""Direct `rules_testing` tests for `dart_analysis_config`.

The rule registers an action only when it has a `baseline`: the validation of
that file. Without one it just validates and collects the listed options, so
there are two tests. The first pins what a baseline-less config publishes: the
options file and its packages, the staged ruleset files, no baseline and no
default output. The second adds a baseline and pins the same providers together
with the validation action: its flags, and the baseline and tool it reads.
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:truth.bzl", "matching")
load("//dart:defs.bzl", "dart_analysis_config", "dart_analysis_options", "dart_library")
load("//dart/private:dart_analyze_aspect.bzl", "DartAnalysisConfigInfo")
load(":truth_helpers.bzl", "action_of", "expect_inputs", "package_names", "provider_of", "short_path_subject", "short_paths")

_ATTRS = {
    "options_files": short_paths,
    "packages": package_names,
    "files": short_paths,
    "baseline": short_path_subject,
}

def _expect_collected(env, target, baseline):
    """Asserts the options, packages and baseline a config collected."""
    config = provider_of(env, target, DartAnalysisConfigInfo, "DartAnalysisConfigInfo", _ATTRS)
    config.options_files().contains_exactly(["dart/tests/direct_options/analysis_options.yaml"])
    config.packages().contains_exactly(["direct_ruleset"])
    config.files().contains_exactly(["dart/tests/lib/direct_model.dart"])
    config.baseline().equals(baseline)

def _dart_analysis_config_test(env, target):
    """Asserts a baseline-less `dart_analysis_config` publishes the collected options only."""
    _expect_collected(env, target, "")
    env.expect.that_target(target).default_outputs().contains_exactly([])

def _dart_analysis_config_baseline_test(env, target):
    """Asserts the providers and the `DartBaselineValidate` action of a config with a baseline."""
    _expect_collected(env, target, "dart/tests/direct_options/analysis_baseline.json")
    env.expect.that_target(target).default_outputs().contains_predicate(
        matching.file_basename_contains(".baseline.json"),
    )
    action = action_of(env, target, "DartBaselineValidate")
    action.argv().contains_at_least(["--validate-only", "--config", "--baseline", "--out"])
    action.argv().contains_predicate(matching.str_endswith("direct_options/analysis_baseline.json"))
    expect_inputs(action, ["dart/tests/direct_options/analysis_baseline.json", "*baseline_slice*"])

def dart_analysis_config_direct_test_suite(name):
    """Declares the direct tests of `dart_analysis_config`.

    Args:
      name: Name of the generated `test_suite`.
    """
    dart_library(
        name = name + "_ruleset",
        srcs = [":lib/direct_model.dart"],
        package_name = "direct_ruleset",
        tags = ["manual"],
    )
    dart_analysis_options(
        name = name + "_options",
        src = ":direct_options/analysis_options.yaml",
        tags = ["manual"],
        deps = [":" + name + "_ruleset"],
    )
    dart_analysis_config(
        name = name + "_subject",
        options = [":" + name + "_options"],
        tags = ["manual"],
    )
    dart_analysis_config(
        name = name + "_baseline_subject",
        baseline = ":direct_options/analysis_baseline.json",
        options = [":" + name + "_options"],
        tags = ["manual"],
    )
    analysis_test(
        name = name + "_test",
        attr_values = {"size": "small"},
        impl = _dart_analysis_config_test,
        target = ":" + name + "_subject",
    )
    analysis_test(
        name = name + "_baseline_test",
        attr_values = {"size": "small"},
        impl = _dart_analysis_config_baseline_test,
        target = ":" + name + "_baseline_subject",
    )
    native.test_suite(name = name, tests = [":" + name + "_test", ":" + name + "_baseline_test"])
