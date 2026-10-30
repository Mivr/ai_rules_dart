"""Tests of analyzer-summary mode: which packages are covered, which mode a target is checked in, and when summary mode is off.

`dart_analyze`'s summary mode analyzes a target from summaries only when every
package in its closure is covered (`_summaries_ready`). A package is covered
when a summary covers it. An opaque `srcs_dir` library has no summary, so its
package must be left uncovered; otherwise a dependent would be analyzed against
a summary that does not exist.

Flutter's `sky_engine` (`lib/_embedder.yaml`) builds an embedder SDK summary
that adds `dart:ui` to the SDK summary, so `sky_engine` and the targets above it
are covered and analyzed from summaries. A non-`sky_engine` package with a
`lib/_embedder.yaml` has no embedder SDK summary, so its closure is analyzed
from source.

The summary and mode tests set `//dart:analyzer_summaries` explicitly where
they need it, and `default_mode_test` leaves it at its default, so the default
is itself tested. The version gate is a function, tested directly.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dart/private:dart_analyze_aspect.bzl", "DartAnalysisModeInfo", "dart_analyze")
load("//dart/private:dart_analyzer_summary.bzl", "DartAnalyzerSummaryInfo", "analyzer_summaries_supported", "dart_analyzer_summary")
load(":small_suite.bzl", "small_unittest_suite")

_FLAG = str(Label("//dart:analyzer_summaries"))

def _summary_packages_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    covered = [k.split("|")[0] for k in target[DartAnalyzerSummaryInfo].packages.to_list()]
    for name in ctx.attr.expect_covered:
        asserts.true(
            env,
            name in covered,
            "%s: package %s is not covered; covered: %s" % (target.label, name, covered),
        )
    for name in ctx.attr.expect_uncovered:
        asserts.false(
            env,
            name in covered,
            "%s: package %s is covered, but it has no summary; covered: %s" % (target.label, name, covered),
        )
    return analysistest.end(env)

summary_packages_test = analysistest.make(
    _summary_packages_test_impl,
    attrs = {
        "expect_covered": attr.string_list(),
        "expect_uncovered": attr.string_list(),
    },
    config_settings = {_FLAG: True},
    extra_target_under_test_aspects = [dart_analyzer_summary],
)

def _summary_file_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    summary = target[DartAnalyzerSummaryInfo].summary
    has_summary = summary != None
    asserts.equals(
        env,
        ctx.attr.expect_summary,
        has_summary,
        "%s: whether the target builds a summary of its own" % target.label,
    )
    checks = depset([summary] if summary != None else [])
    return analysistest.end(env) + [OutputGroupInfo(_validation = checks, dart_analyze = checks)]

# Whether a target builds a summary of its own.
summary_file_test = analysistest.make(
    _summary_file_test_impl,
    attrs = {"expect_summary": attr.bool(mandatory = True)},
    config_settings = {_FLAG: True},
    extra_target_under_test_aspects = [dart_analyzer_summary],
)

def _analysis_mode_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    expected = ctx.attr._summaries_flag[BuildSettingInfo].value if ctx.attr.use_flag else ctx.attr.expect_summaries
    asserts.equals(
        env,
        expected,
        target[DartAnalysisModeInfo].summaries,
        "%s: whether `dart_analyze` read dependency summaries" % target.label,
    )
    groups = target[OutputGroupInfo] if OutputGroupInfo in target else None
    checks = depset(transitive = [
        getattr(groups, g)
        for g in ["dart_analyze", "dart_format"]
        if groups != None and hasattr(groups, g)
    ])
    return analysistest.end(env) + [OutputGroupInfo(_validation = checks, dart_analyze = checks)]

def _analysis_mode_test(flag, use_flag = False):
    """Returns an analysis test whose `//dart:analyzer_summaries` is `flag`.

    With `use_flag` the test compares against the flag's effective value rather
    than a fixed expectation, so a command-line override of the default is
    tested too. Without it the test pins the value `config_settings` sets.
    """
    return analysistest.make(
        _analysis_mode_test_impl,
        attrs = {
            "expect_summaries": attr.bool(mandatory = True),
            "use_flag": attr.bool(default = use_flag),
            "_summaries_flag": attr.label(
                default = Label("//dart:analyzer_summaries"),
                providers = [BuildSettingInfo],
            ),
        },
        config_settings = {} if flag == None else {_FLAG: flag},
        extra_target_under_test_aspects = [dart_analyze],
    )

# The mode `dart_analyze` checks a target in, with the flag at its default, on,
# and off. The default is the one a user gets, so it is the one that must be on;
# when a command line overrides it, the test follows the effective value.
default_mode_test = _analysis_mode_test(None, use_flag = True)
summaries_on_mode_test = _analysis_mode_test(True)
summaries_off_mode_test = _analysis_mode_test(False)

def _version_gate_test_impl(ctx):
    env = unittest.begin(ctx)
    for version, expected in [
        ("3.11.0", True),
        ("3.12.2", True),
        ("3.13.0", True),
        ("3.13.5", True),
        ("3.13.5-dev.1.0", True),
        ("3.14.0", True),
        ("3.14.0-1.0.dev", True),
        ("3.15.0", False),
        ("3.15.0-1.0.dev", False),
        ("4.0.0", False),
        ("", False),
        ("3", False),
        ("latest", False),
    ]:
        asserts.equals(
            env,
            expected,
            analyzer_summaries_supported(version),
            "analyzer_summaries_supported(%r)" % version,
        )
    return unittest.end(env)

_version_gate_test = unittest.make(_version_gate_test_impl)

def analyzer_summary_test_suite(name):
    """Declares the unit tests of the summary-mode version gate.

    Args:
      name: Name of the generated `test_suite`.
    """
    small_unittest_suite(name, _version_gate_test)
