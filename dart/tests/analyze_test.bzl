"""Tests for the `dart_analyze` aspect and the provider it reads from executables.

The aspect's verdicts are checked by building it: `analyzed_test` and
`formatted_test` apply it to one target and pass only if that target's analysis
or format check ran and came back clean. Its red paths live in
`e2e/analysis_failure`, where CI asserts each build fails with the expected
diagnostic. The analysis tests here pin which targets the aspect takes on at
all.

The rest of this file covers an executable. A `dart_binary`/`dart_test`
entrypoint belongs to no package's `lib/`, so it reaches the aspect through
`DartAnalyzableInfo` rather than `DartInfo`, and the cases below pin that the
provider carrying it is still not something `deps` will accept.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:providers.bzl", "DartAnalyzableInfo", "DartInfo")
load("//dart/private:common.bzl", "WINDOWS_CONSTRAINT_ATTR", "noop_test_executable")
load("//dart/private:dart_analyze_aspect.bzl", "DartAnalysisModeInfo", "DartFixOutputsInfo", "dart_analyze", "resolve_format_mode")

# The fixture's entrypoint and its dependency, by the suffix of their
# `short_path`. Named here rather than passed in: these tests exist for one
# fixture, and a path an assertion cannot find is the failure they report.
_ENTRYPOINT = "/analyzable_fixture/main.dart"
_DEP_PACKAGE = "analyzable_dep"

def _checked_test_impl(group):
    def impl(ctx):
        groups = ctx.attr.target[OutputGroupInfo] if OutputGroupInfo in ctx.attr.target else None
        if groups == None or not hasattr(groups, group):
            fail("%s: the dart_analyze aspect has no %s check for %s" % (ctx.label, group, ctx.attr.target.label))
        noop = noop_test_executable(ctx, ctx.attr._tool)
        return [DefaultInfo(
            executable = noop.executable,
            runfiles = ctx.runfiles(transitive_files = getattr(groups, group)).merge(noop.runfiles),
        )]

    return impl

_CHECKED_TEST_ATTRS = dict({
    "target": attr.label(mandatory = True, aspects = [dart_analyze]),
    "_tool": attr.label(
        default = "//dart/private/tools:noop",
        executable = True,
        cfg = "exec",
    ),
}, **WINDOWS_CONSTRAINT_ATTR)

# Passes when `target`'s analysis ran and found nothing: the aspect's stamp is
# in the runfiles, and it is only written when `dart analyze` exits clean.
# Independent of `.bazelrc`, so it holds however the suite is invoked.
analyzed_test = rule(
    implementation = _checked_test_impl("dart_analyze"),
    attrs = _CHECKED_TEST_ATTRS,
    test = True,
)

# The same for the format check: passes when `dart format` would change none of
# `target`'s own files under the options that govern them.
formatted_test = rule(
    implementation = _checked_test_impl("dart_format"),
    attrs = _CHECKED_TEST_ATTRS,
    test = True,
)

def _aspect_applies_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    groups = target[OutputGroupInfo] if OutputGroupInfo in target else None
    analyzed = groups != None and hasattr(groups, "dart_analyze")
    asserts.equals(
        env,
        ctx.attr.expect_analyzed,
        analyzed,
        "the dart_analyze aspect %s %s" % ("analyzed" if analyzed else "skipped", target.label),
    )
    formatted = groups != None and hasattr(groups, "dart_format")
    asserts.equals(
        env,
        ctx.attr.expect_formatted,
        formatted,
        "the dart_analyze aspect %s the format check of %s" % (
            "ran" if formatted else "skipped",
            target.label,
        ),
    )
    asserts.equals(
        env,
        ctx.attr.expect_fixable,
        DartFixOutputsInfo in target,
        "whether `dart_fix` can fix %s" % target.label,
    )
    return analysistest.end(env)

# Whether the aspect analyzes a target, format-checks it, and offers `dart_fix`
# fixes for it: none for a target with nothing hand-written of its own, and
# each opt-out tag removes its own check and nothing else.
aspect_applies_test = analysistest.make(
    _aspect_applies_test_impl,
    attrs = {
        "expect_analyzed": attr.bool(mandatory = True),
        "expect_formatted": attr.bool(mandatory = True),
        "expect_fixable": attr.bool(mandatory = True),
    },
    extra_target_under_test_aspects = [dart_analyze],
)

def _config_refused_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

# A `dart_analysis_config` that must be refused, and the error that says why.
config_refused_test = analysistest.make(
    _config_refused_test_impl,
    attrs = {"message": attr.string(mandatory = True)},
    expect_failure = True,
)

def _analyzable_provider_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)

    # The whole point of the wrapper: analyzable, and still not a dependency.
    # `deps` everywhere in this rule set and downstream gates on `DartInfo`, so
    # an executable handing one out would make `dart_library(deps = [":bin"])`
    # legal — the rule-level guard on that is `binary_not_a_dep_test` below.
    asserts.true(
        env,
        DartAnalyzableInfo in target,
        "a dart_binary must provide DartAnalyzableInfo",
    )
    asserts.false(
        env,
        DartInfo in target,
        "a dart_binary must NOT provide DartInfo — that is what `deps` requires",
    )
    if DartAnalyzableInfo not in target:
        return analysistest.end(env)

    analyzable = target[DartAnalyzableInfo]

    # The entrypoint, which no `DartInfo` can carry: it is under no package's
    # `lib/`, so no `DartPackageInfo` names it and no `package:` URI reaches it.
    srcs = sorted([f.short_path for f in analyzable.srcs.to_list()])
    asserts.true(
        env,
        [p for p in srcs if p.endswith(_ENTRYPOINT)] != [],
        "the entrypoint is missing from DartAnalyzableInfo.srcs: %s" % srcs,
    )

    # And the closure around it, which one is: staging the entrypoint alone
    # would leave its imports unresolvable.
    names = sorted([
        p.package_name
        for p in analyzable.dart_info.transitive_packages.to_list()
    ])
    asserts.true(
        env,
        _DEP_PACKAGE in names,
        "the dependency's package record is missing from the nested DartInfo: %s" % names,
    )

    return analysistest.end(env)

analyzable_provider_test = analysistest.make(_analyzable_provider_test_impl)

def _binary_not_a_dep_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "mandatory providers")
    return analysistest.end(env)

# The guard on the central tension. `dart_binary` is analyzable *and* an invalid
# dep, and nothing but Bazel's own provider constraint enforces the second half
# — there is no negative provider constraint to say "not this one". If an
# executable ever starts returning `DartInfo`, this is what goes red.
binary_not_a_dep_test = analysistest.make(
    _binary_not_a_dep_test_impl,
    expect_failure = True,
)

def _resolve_format_mode_test_impl(ctx):
    env = unittest.begin(ctx)

    m_latest = resolve_format_mode("3.13.5", "latest")
    asserts.true(env, m_latest.in_process)
    asserts.equals(env, "3.13", m_latest.language_version)

    m_empty = resolve_format_mode("3.13.4", "")
    asserts.true(env, m_empty.in_process)
    asserts.equals(env, "3.13", m_empty.language_version)

    m_short = resolve_format_mode("3.13.5", "3.6")
    asserts.true(env, m_short.in_process)
    asserts.equals(env, "3.6", m_short.language_version)

    m_min = resolve_format_mode("3.13.4", "2.12")
    asserts.true(env, m_min.in_process)
    asserts.equals(env, "2.12", m_min.language_version)

    m_max_2x = resolve_format_mode("3.13.5", "2.19")
    asserts.true(env, m_max_2x.in_process)
    asserts.equals(env, "2.19", m_max_2x.language_version)

    m_bad_2x = resolve_format_mode("3.13.5", "2.20")
    asserts.false(env, m_bad_2x.in_process)
    asserts.equals(env, "2.20", m_bad_2x.language_version)

    m_pre_null = resolve_format_mode("3.13.5", "2.11")
    asserts.false(env, m_pre_null.in_process)
    asserts.equals(env, "2.11", m_pre_null.language_version)

    m_future_lv = resolve_format_mode("3.13.5", "3.14")
    asserts.false(env, m_future_lv.in_process)
    asserts.equals(env, "3.14", m_future_lv.language_version)

    m_old_patch = resolve_format_mode("3.13.3", "latest")
    asserts.false(env, m_old_patch.in_process)
    asserts.equals(env, "3.13", m_old_patch.language_version)

    m_sdk_311 = resolve_format_mode("3.11.0", "latest")
    asserts.false(env, m_sdk_311.in_process)
    asserts.equals(env, "3.11", m_sdk_311.language_version)

    m_sdk_314 = resolve_format_mode("3.14.0-100.0.dev", "latest")
    asserts.false(env, m_sdk_314.in_process)
    asserts.equals(env, "3.14", m_sdk_314.language_version)

    return unittest.end(env)

resolve_format_mode_test = unittest.make(_resolve_format_mode_test_impl)

def _format_action_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    checks = target[DartAnalysisModeInfo].format_checks
    asserts.equals(env, 1, len(checks), "expected one DartFormat check")
    if checks:
        check = checks[0]
        asserts.true(
            env,
            "HOME" in check.env or ("USERPROFILE" in check.env and "LOCALAPPDATA" in check.env),
            "DartFormat must set writable_home_env, got: %s" % check.env,
        )
        asserts.equals(env, ctx.attr.expected_language_version, check.mode.language_version)
        asserts.equals(env, not ctx.attr.expect_compile_files, check.mode.in_process)
        input_basenames = [f.basename for f in check.sdk_inputs.to_list()]
        has_compile = "gen_kernel_aot.dart.snapshot" in input_basenames
        asserts.equals(
            env,
            ctx.attr.expect_compile_files,
            has_compile,
            "DartFormat compile_files presence mismatch: %s" % input_basenames,
        )
    return analysistest.end(env)

format_action_test = analysistest.make(
    _format_action_test_impl,
    attrs = {
        "expected_language_version": attr.string(mandatory = True),
        "expect_compile_files": attr.bool(mandatory = True),
    },
    extra_target_under_test_aspects = [dart_analyze],
)
