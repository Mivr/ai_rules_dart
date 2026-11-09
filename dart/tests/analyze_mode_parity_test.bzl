"""Tests for analyzer summary and full-source mode parity under `//dart:analyzer_summaries`.

Covers the three manager-specified requirements for queue item 165:
1. Two-library lint parity fixture (`dep` + `consumer`) under `//:analysis_config`
   cleanly analyzed in both summary mode and full-source mode, plus companion
   negative fixture validation.
2. Direct inspection of `DartAnalyze` action under `--//dart:analyzer_summaries=false`
   confirming `analyzer_summary` tool execution, `--sdk-summary`, zero `--summary` flags,
   transitive `.dart` source staging, zero `DartSummarize` actions, and source mode.
3. Verification of fallback to `analyze_runner` when the SDK is outside
   the supported range (< 3.13 or > 3.14) or when an unbacked embedder
   is in the closure (`yaml_only`).
"""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:util.bzl", "util")
load("//dart:defs.bzl", "dart_analysis_test", "dart_test")
load("//dart/private:dart_analyze_aspect.bzl", "DartAnalysisModeInfo", "dart_analyze")
load("//dart/private:dart_analyzer_summary.bzl", "dart_analyzer_summary")
load(":summaries_flag_test_lib.bzl", "SUMMARIES_FLAG")

visibility(["//dart/..."])

_TESTING_ASPECT = util.make_testing_aspect([dart_analyze, dart_analyzer_summary])

def _source_mode_pure_dart_test_impl(env, target):
    """Asserts that pure-Dart targets in source mode use `analyzer_summary` with zero summaries."""
    action = env.expect.that_target(target).action_named("DartAnalyze")
    action.mnemonic().equals("DartAnalyze")

    input_names = [f.basename for f in action.actual.inputs.to_list()]
    env.expect.that_int(len([b for b in input_names if "analyzer_summary" in b])).is_greater_than(0)
    env.expect.that_collection([b for b in input_names if "analyze_runner" in b]).has_size(0)

    env.expect.that_collection([b for b in input_names if b == "analyzer_sdk_summary.sum"]).has_size(1)
    dep_sums = [
        b
        for b in input_names
        if b.endswith(".sum") and b != "analyzer_sdk_summary.sum" and not b.endswith(".embedder_sdk.sum")
    ]
    env.expect.that_collection(dep_sums).has_size(0)

    env.expect.that_collection(input_names).contains_at_least(["dep.dart", "consumer.dart"])

    summarize_actions = [a for a in target.actions if a.mnemonic == "DartSummarize"]
    env.expect.that_collection(summarize_actions).has_size(0)

    env.expect.that_bool(target[DartAnalysisModeInfo].summaries).equals(False)

def _source_mode_flutter_test_impl(env, target):
    """Asserts that Flutter targets in source mode use `analyzer_summary` with embedder SDK summary."""
    action = env.expect.that_target(target).action_named("DartAnalyze")
    action.mnemonic().equals("DartAnalyze")

    input_names = [f.basename for f in action.actual.inputs.to_list()]
    env.expect.that_int(len([b for b in input_names if "analyzer_summary" in b])).is_greater_than(0)
    env.expect.that_collection([b for b in input_names if "analyze_runner" in b]).has_size(0)

    env.expect.that_collection([b for b in input_names if b.endswith(".embedder_sdk.sum")]).has_size(1)
    dep_sums = [
        b
        for b in input_names
        if b.endswith(".sum") and not b.endswith(".embedder_sdk.sum") and b != "analyzer_sdk_summary.sum"
    ]
    env.expect.that_collection(dep_sums).has_size(0)

    env.expect.that_collection(input_names).contains("app.dart")
    env.expect.that_bool(target[DartAnalysisModeInfo].summaries).equals(False)

def _assert_stock_fallback(env, target):
    """Asserts that analysis of `target` runs stock SDK `analyze_runner`."""
    action = env.expect.that_target(target).action_named("DartAnalyze")
    action.mnemonic().equals("DartAnalyze")

    input_names = [f.basename for f in action.actual.inputs.to_list()]
    env.expect.that_int(len([b for b in input_names if "analyze_runner" in b])).is_greater_than(0)
    env.expect.that_collection([b for b in input_names if "analyzer_summary" in b]).has_size(0)

    env.expect.that_bool(target[DartAnalysisModeInfo].summaries).equals(False)

def _unsupported_sdk_fallback_test_impl(env, target):
    """Asserts fallback to stock `analyze_runner` above the 3.14 ceiling."""
    _assert_stock_fallback(env, target)

def _unsupported_sdk_floor_fallback_test_impl(env, target):
    """Asserts fallback to stock `analyze_runner` below the 3.13 floor."""
    _assert_stock_fallback(env, target)

def _unbacked_embedder_fallback_test_impl(env, target):
    """Asserts that an unbacked `_embedder.yaml` falls back to stock SDK `analyze_runner`."""
    _assert_stock_fallback(env, target)

def _negative_target_analyzed_test_impl(env, target):
    """Asserts that the negative fixture is not skipped and generates `DartAnalyze`."""
    action = env.expect.that_target(target).action_named("DartAnalyze")
    action.mnemonic().equals("DartAnalyze")

def analyze_mode_parity_test_suite(name):
    """Declares the test suite for analyzer summary and full-source mode parity.

    Args:
      name: Prefix for declared test targets.
    """

    # Group 1: Two-library lint parity fixture and companion negative check
    dart_analysis_test(
        name = name + "_lint_parity",
        size = "small",
        targets = [
            "//dart/tests/analyze_mode_parity_fixture/dep:dep",
            "//dart/tests/analyze_mode_parity_fixture/consumer:consumer",
        ],
    )

    analysis_test(
        name = name + "_negative_analyzed_summaries_on",
        attr_values = {"size": "small"},
        config_settings = {SUMMARIES_FLAG: True},
        impl = _negative_target_analyzed_test_impl,
        target = "//dart/tests/analyze_mode_parity_fixture/negative:negative",
        testing_aspect = _TESTING_ASPECT,
    )

    analysis_test(
        name = name + "_negative_analyzed_summaries_off",
        attr_values = {"size": "small"},
        config_settings = {SUMMARIES_FLAG: False},
        impl = _negative_target_analyzed_test_impl,
        target = "//dart/tests/analyze_mode_parity_fixture/negative:negative",
        testing_aspect = _TESTING_ASPECT,
    )

    dart_test(
        name = name + "_negative_violation_test",
        size = "small",
        args = [
            "$(rlocationpath //dart/private/tools:analyzer_summary)",
            "$(rlocationpath //dart/private:analyzer_sdk_summary)",
        ],
        data = [
            "//dart/private:analyzer_sdk_summary",
            "//dart/private/tools:analyzer_summary",
        ],
        main = "analyze_mode_parity_negative_test.dart",
        deps = [
            "//dart/runfiles",
            "@ext_pub_deps//:path",
            "@ext_pub_deps//:test",
        ],
    )

    # Group 2: Starlark analysis test inspecting DartAnalyze under summaries=false
    analysis_test(
        name = name + "_source_mode_pure_dart",
        attr_values = {"size": "small"},
        config_settings = {SUMMARIES_FLAG: False},
        impl = _source_mode_pure_dart_test_impl,
        target = "//dart/tests/analyze_mode_parity_fixture/consumer:consumer",
        testing_aspect = _TESTING_ASPECT,
    )

    analysis_test(
        name = name + "_source_mode_flutter",
        attr_values = {"size": "small"},
        config_settings = {SUMMARIES_FLAG: False},
        impl = _source_mode_flutter_test_impl,
        target = "//dart/tests/analyzer_summary_fixture/flutter/app:flutter_app",
        testing_aspect = _TESTING_ASPECT,
    )

    # Group 3: Starlark analysis test verifying fallback conditions to analyze_runner
    analysis_test(
        name = name + "_fallback_unsupported_sdk",
        attr_values = {"size": "small"},
        config_settings = {
            "//command_line_option:extra_toolchains": [
                str(Label("//dart/tests:synthetic_3_15_exec_toolchain")),
                str(Label("//dart/tests:synthetic_3_15_target_toolchain")),
            ],
        },
        impl = _unsupported_sdk_fallback_test_impl,
        target = "//dart/tests/analyze_mode_parity_fixture/consumer:consumer",
        testing_aspect = _TESTING_ASPECT,
    )

    analysis_test(
        name = name + "_fallback_unsupported_sdk_floor",
        attr_values = {"size": "small"},
        config_settings = {
            "//command_line_option:extra_toolchains": [
                str(Label("//dart/tests:synthetic_3_12_exec_toolchain")),
                str(Label("//dart/tests:synthetic_3_12_target_toolchain")),
            ],
        },
        impl = _unsupported_sdk_floor_fallback_test_impl,
        target = "//dart/tests/analyze_mode_parity_fixture/consumer:consumer",
        testing_aspect = _TESTING_ASPECT,
    )

    analysis_test(
        name = name + "_fallback_unbacked_embedder_summaries_on",
        attr_values = {"size": "small"},
        config_settings = {SUMMARIES_FLAG: True},
        impl = _unbacked_embedder_fallback_test_impl,
        target = "//dart/tests/analyzer_summary_fixture/flutter/yaml_only:yaml_only",
        testing_aspect = _TESTING_ASPECT,
    )

    analysis_test(
        name = name + "_fallback_unbacked_embedder_summaries_off",
        attr_values = {"size": "small"},
        config_settings = {SUMMARIES_FLAG: False},
        impl = _unbacked_embedder_fallback_test_impl,
        target = "//dart/tests/analyzer_summary_fixture/flutter/yaml_only:yaml_only",
        testing_aspect = _TESTING_ASPECT,
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_lint_parity",
            ":" + name + "_negative_analyzed_summaries_on",
            ":" + name + "_negative_analyzed_summaries_off",
            ":" + name + "_negative_violation_test",
            ":" + name + "_source_mode_pure_dart",
            ":" + name + "_source_mode_flutter",
            ":" + name + "_fallback_unsupported_sdk",
            ":" + name + "_fallback_unsupported_sdk_floor",
            ":" + name + "_fallback_unbacked_embedder_summaries_on",
            ":" + name + "_fallback_unbacked_embedder_summaries_off",
        ],
    )
