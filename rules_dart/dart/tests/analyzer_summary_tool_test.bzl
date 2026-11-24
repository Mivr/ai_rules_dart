"""Tests for the public `//dart:analyzer_summary_tool` label flag.

`dart_analyze` runs its analysis worker through
`//dart/private:analyzer_summary_tool`, which aliases the public
`//dart:analyzer_summary_tool` label flag. Downstream rulesets swap in an
extended worker by setting the flag. These tests pin the flag's default
and the alias wiring.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load(":summaries_flag_test_lib.bzl", "SUMMARIES_FLAG")

visibility(["//dart/..."])

def _default_tool_test_impl(ctx):
    """Checks the flag defaults to the bundled summary worker."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(
        env,
        Label("//dart/private/tools:analyzer_summary"),
        target.label,
        "the default `//dart:analyzer_summary_tool` worker",
    )
    return analysistest.end(env)

analyzer_summary_tool_default_test = analysistest.make(
    _default_tool_test_impl,
)

def _alias_tool_test_impl(ctx):
    """Checks the private alias selects the public flag while summaries are on."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(
        env,
        Label("//dart/private/tools:analyzer_summary"),
        target.label,
        "`//dart/private:analyzer_summary_tool` with summaries on",
    )
    return analysistest.end(env)

analyzer_summary_tool_alias_test = analysistest.make(
    _alias_tool_test_impl,
    config_settings = {SUMMARIES_FLAG: True},
)

analyzer_summary_tool_alias_summaries_off_test = analysistest.make(
    _alias_tool_test_impl,
    config_settings = {SUMMARIES_FLAG: False},
)

def _override_tool_test_impl(ctx):
    """Checks setting `//dart:analyzer_summary_tool` swaps the summary worker."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(
        env,
        Label("//dart/private/tools:noop"),
        target.label,
        "`//dart/private:analyzer_summary_tool` when overridden via flag",
    )
    return analysistest.end(env)

analyzer_summary_tool_override_test = analysistest.make(
    _override_tool_test_impl,
    config_settings = {
        SUMMARIES_FLAG: True,
        str(Label("//dart:analyzer_summary_tool")): Label("//dart/private/tools:noop"),
    },
)

def analyzer_summary_tool_test_suite(name):
    """Declares the `//dart:analyzer_summary_tool` flag tests.

    Args:
      name: Name prefix of the generated test targets.
    """
    analyzer_summary_tool_default_test(
        name = name + "_default",
        size = "small",
        target_under_test = "//dart:analyzer_summary_tool",
    )
    analyzer_summary_tool_alias_test(
        name = name + "_alias",
        size = "small",
        target_under_test = "//dart/private:analyzer_summary_tool",
    )
    analyzer_summary_tool_alias_summaries_off_test(
        name = name + "_alias_summaries_off",
        size = "small",
        target_under_test = "//dart/private:analyzer_summary_tool",
    )
    analyzer_summary_tool_override_test(
        name = name + "_override",
        size = "small",
        target_under_test = "//dart/private:analyzer_summary_tool",
    )
