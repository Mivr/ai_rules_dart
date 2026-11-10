"""Analysis tests for dart_test include_tags and exclude_tags attributes."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:defs.bzl", "dart_test")

visibility(["//dart/..."])

def _normalized_actions(target, target_name):
    """Returns a comparable list of `(mnemonic, argv, inputs)` for a target's actions.

    Args:
        target: The analyzed `Target` under inspection.
        target_name: The target's own name, normalized to `<target>` in paths/args.

    Returns:
        A list of `(mnemonic, argv, input_short_paths)` tuples.
    """
    summary = []
    for action in target.actions:
        argv = [arg.replace(target_name, "<target>") for arg in (action.argv or [])]
        inputs = sorted([f.short_path.replace(target_name, "<target>") for f in action.inputs.to_list()])
        summary.append((action.mnemonic, argv, inputs))
    return summary

def _tag_env_test_impl(ctx):
    """Verifies that include_tags and exclude_tags propagate to the test environment without altering actions.

    Args:
        ctx: Analysis test context.

    Returns:
        The analysis test result struct.
    """
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    run_env = target[RunEnvironmentInfo].environment

    if ctx.attr.expected_include:
        asserts.true(
            env,
            "RULES_DART_INCLUDE_TAGS" in run_env,
            "expected RULES_DART_INCLUDE_TAGS in environment",
        )
        asserts.equals(env, ctx.attr.expected_include, run_env.get("RULES_DART_INCLUDE_TAGS"))
    else:
        asserts.true(
            env,
            "RULES_DART_INCLUDE_TAGS" not in run_env,
            "expected RULES_DART_INCLUDE_TAGS to be absent from environment",
        )

    if ctx.attr.expected_exclude:
        asserts.true(
            env,
            "RULES_DART_EXCLUDE_TAGS" in run_env,
            "expected RULES_DART_EXCLUDE_TAGS in environment",
        )
        asserts.equals(env, ctx.attr.expected_exclude, run_env.get("RULES_DART_EXCLUDE_TAGS"))
    else:
        asserts.true(
            env,
            "RULES_DART_EXCLUDE_TAGS" not in run_env,
            "expected RULES_DART_EXCLUDE_TAGS to be absent from environment",
        )

    if ctx.attr.baseline_target != None:
        asserts.equals(
            env,
            _normalized_actions(ctx.attr.baseline_target, ctx.attr.baseline_target.label.name),
            _normalized_actions(target, target.label.name),
        )

    return analysistest.end(env)

_tag_env_test = analysistest.make(
    _tag_env_test_impl,
    attrs = {
        "baseline_target": attr.label(
            doc = "Optional baseline `dart_test` target whose normalized actions must match `target_under_test`.",
        ),
        "expected_exclude": attr.string(
            default = "",
            doc = "Expected `RULES_DART_EXCLUDE_TAGS` value, or empty when absent.",
        ),
        "expected_include": attr.string(
            default = "",
            doc = "Expected `RULES_DART_INCLUDE_TAGS` value, or empty when absent.",
        ),
    },
    doc = "Checks `dart_test` launcher environment and action invariance for tag attributes.",
)

def _tag_failure_test_impl(ctx):
    """Verifies that invalid tag selectors cause an expected analysis failure.

    Args:
        ctx: Analysis test context.

    Returns:
        The analysis test result struct.
    """
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_target)
    asserts.expect_failure(env, ctx.attr.expected_attr)
    return analysistest.end(env)

_tag_failure_test = analysistest.make(
    _tag_failure_test_impl,
    attrs = {
        "expected_attr": attr.string(
            mandatory = True,
            doc = "Attribute name that must appear in the analysis failure message.",
        ),
        "expected_target": attr.string(
            mandatory = True,
            doc = "Target name that must appear in the analysis failure message.",
        ),
    },
    expect_failure = True,
    doc = "Checks that invalid `dart_test` tag entries fail analysis naming the target and attribute.",
)

def _declare_refusal_tests():
    """Declares analysis tests and fixtures for invalid tag selectors.

    Returns:
        List of test target labels to include in the suite.
    """
    dart_test(
        name = "empty_include_entry_fixture",
        main = "//dart/private/tools:noop.dart",
        include_tags = [""],
        tags = ["manual"],
    )
    dart_test(
        name = "newline_include_entry_fixture",
        main = "//dart/private/tools:noop.dart",
        include_tags = ["smoke\nother"],
        tags = ["manual"],
    )
    dart_test(
        name = "empty_exclude_entry_fixture",
        main = "//dart/private/tools:noop.dart",
        exclude_tags = [""],
        tags = ["manual"],
    )
    dart_test(
        name = "newline_exclude_entry_fixture",
        main = "//dart/private/tools:noop.dart",
        exclude_tags = ["broken\nother"],
        tags = ["manual"],
    )

    _tag_failure_test(
        name = "dart_test_empty_include_tag_refusal_test",
        target_under_test = ":empty_include_entry_fixture",
        expected_target = "empty_include_entry_fixture",
        expected_attr = "include_tags",
    )
    _tag_failure_test(
        name = "dart_test_newline_include_tag_refusal_test",
        target_under_test = ":newline_include_entry_fixture",
        expected_target = "newline_include_entry_fixture",
        expected_attr = "include_tags",
    )
    _tag_failure_test(
        name = "dart_test_empty_exclude_tag_refusal_test",
        target_under_test = ":empty_exclude_entry_fixture",
        expected_target = "empty_exclude_entry_fixture",
        expected_attr = "exclude_tags",
    )
    _tag_failure_test(
        name = "dart_test_newline_exclude_tag_refusal_test",
        target_under_test = ":newline_exclude_entry_fixture",
        expected_target = "newline_exclude_entry_fixture",
        expected_attr = "exclude_tags",
    )

    return [
        ":dart_test_empty_include_tag_refusal_test",
        ":dart_test_newline_include_tag_refusal_test",
        ":dart_test_empty_exclude_tag_refusal_test",
        ":dart_test_newline_exclude_tag_refusal_test",
    ]

def dart_test_tags_test_suite(name):
    """Suite of analysis tests for dart_test tag selection attributes.

    Args:
        name: Target name for the test suite.
    """
    dart_test(
        name = "default_tags_fixture",
        main = "//dart/private/tools:noop.dart",
        tags = ["manual"],
    )
    dart_test(
        name = "valid_tags_fixture",
        main = "//dart/private/tools:noop.dart",
        include_tags = ["smoke", "fast"],
        exclude_tags = ["broken", "flaky"],
        tags = ["manual"],
    )
    dart_test(
        name = "compound_tags_fixture",
        main = "//dart/private/tools:noop.dart",
        include_tags = ["smoke || fast", "linux"],
        exclude_tags = ["ios ? slow : broken", "flaky"],
        tags = ["manual"],
    )
    dart_test(
        name = "empty_tags_fixture",
        main = "//dart/private/tools:noop.dart",
        include_tags = [],
        exclude_tags = [],
        tags = ["manual"],
    )

    _tag_env_test(
        name = "dart_test_valid_tags_env_test",
        target_under_test = ":valid_tags_fixture",
        baseline_target = ":default_tags_fixture",
        expected_include = "(smoke) && (fast)",
        expected_exclude = "(broken) || (flaky)",
    )
    _tag_env_test(
        name = "dart_test_compound_tags_env_test",
        target_under_test = ":compound_tags_fixture",
        baseline_target = ":default_tags_fixture",
        expected_include = "(smoke || fast) && (linux)",
        expected_exclude = "(ios ? slow : broken) || (flaky)",
    )
    _tag_env_test(
        name = "dart_test_empty_tags_env_test",
        target_under_test = ":empty_tags_fixture",
        baseline_target = ":default_tags_fixture",
    )

    refusal_tests = _declare_refusal_tests()

    native.test_suite(
        name = name,
        tests = [
            ":dart_test_valid_tags_env_test",
            ":dart_test_compound_tags_env_test",
            ":dart_test_empty_tags_env_test",
        ] + refusal_tests,
    )
