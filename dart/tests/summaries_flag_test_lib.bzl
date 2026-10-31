"""Shared helpers for `//dart:analyzer_summaries` analysis tests."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

SUMMARIES_FLAG = str(Label("//dart:analyzer_summaries"))

def effective_summaries_expected(ctx):
    """Returns whether summaries are expected under `ctx`'s effective flag."""
    if not ctx.attr.use_flag:
        return ctx.attr.expect_summaries
    return (
        ctx.attr.expect_summaries and
        ctx.attr._summaries_flag[BuildSettingInfo].value
    )

def summaries_flag_test_kwargs(flag, aspect_dep, use_flag = False):
    """Keyword arguments for an `analysistest.make` that sets or reads `//dart:analyzer_summaries`.

    Each test file passes its own implementation to `analysistest.make`, so
    the assertions stay next to the rule they check. With `use_flag` the test
    expects summaries only when the target's own expectation and the flag's
    effective value both allow them, so a command-line override of the
    default is tested too. Without it the test pins the value
    `config_settings` sets.

    Args:
      flag: Bool value to pin `//dart:analyzer_summaries` to, or `None` to
        keep the build's effective flag value.
      aspect_dep: Aspect applied to `target_under_test`.
      use_flag: Whether `effective_summaries_expected` reads the effective flag.

    Returns:
      A dict with `attrs`, `config_settings` and
      `extra_target_under_test_aspects`.
    """
    return {
        "attrs": {
            "expect_summaries": attr.bool(
                doc = "Whether the scenario itself supports summary mode.",
                mandatory = True,
            ),
            "use_flag": attr.bool(
                default = use_flag,
                doc = "Whether to intersect `expect_summaries` with the effective flag.",
            ),
            "_summaries_flag": attr.label(
                default = Label("//dart:analyzer_summaries"),
                doc = "Effective `//dart:analyzer_summaries` build setting.",
                providers = [BuildSettingInfo],
            ),
        },
        "config_settings": {} if flag == None else {SUMMARIES_FLAG: flag},
        "extra_target_under_test_aspects": [aspect_dep],
    }
