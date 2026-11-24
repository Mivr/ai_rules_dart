"""Analysis negatives proving the public compile API refuses hermeticity escapes.

Each target below must FAIL analysis with a message naming the target and the
offending parameter or flag: an absolute or climbing `filesystem_roots` value
(which would mount a host directory as a compiler root), a line break in any
argv-bound string (which would split the worker's `multiline` param file into
extra argv elements), and any `extra_flags` entry outside the allow-list
(which could smuggle an undeclared dill or a host write into the compile).
The tests assert the failure, so a passing suite means every escape is
refused before the compiler runs — on the stock path and the worker path
alike, since both share the analysis checks.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

visibility("private")

def _reject_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "filesystem_roots")
    return analysistest.end(env)

def _message_reject_test_impl(ctx):
    env = analysistest.begin(ctx)
    for expected in ctx.attr.expected_substrings:
        asserts.expect_failure(env, expected)
    return analysistest.end(env)

_reject_test = analysistest.make(_reject_test_impl, expect_failure = True)
_message_reject_test = analysistest.make(
    _message_reject_test_impl,
    expect_failure = True,
    attrs = {"expected_substrings": attr.string_list(mandatory = True)},
)

def consumer_hermetic_test_suite(name):
    """Hermetic compile-API analysis negatives.

    Args:
      name: The test_suite target name.
    """
    _reject_test(
        name = name + "_roots_abs",
        target_under_test = ":consumer_bad_roots_abs",
    )
    _reject_test(
        name = name + "_roots_escape",
        target_under_test = ":consumer_bad_roots_escape",
    )
    _reject_test(
        name = name + "_roots_empty",
        target_under_test = ":consumer_bad_roots_empty",
    )
    _message_reject_test(
        name = name + "_extra_flags_newline",
        target_under_test = ":consumer_bad_extra_flags_newline",
        expected_substrings = ["extra_flags", "line break"],
    )
    _message_reject_test(
        name = name + "_defines_newline",
        target_under_test = ":consumer_bad_defines_newline",
        expected_substrings = ["defines", "line break"],
    )
    _message_reject_test(
        name = name + "_initialize_from_dill",
        target_under_test = ":consumer_bad_initialize_from_dill",
        expected_substrings = ["extra_flags", "--initialize-from-dill"],
    )
    _message_reject_test(
        name = name + "_far_manifest",
        target_under_test = ":consumer_bad_far_manifest",
        expected_substrings = ["extra_flags", "--far-manifest"],
    )
    _message_reject_test(
        name = name + "_unknown_flag",
        target_under_test = ":consumer_bad_unknown_flag",
        expected_substrings = ["extra_flags", "--frobnicate"],
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_roots_abs",
            ":" + name + "_roots_escape",
            ":" + name + "_roots_empty",
            ":" + name + "_extra_flags_newline",
            ":" + name + "_defines_newline",
            ":" + name + "_initialize_from_dill",
            ":" + name + "_far_manifest",
            ":" + name + "_unknown_flag",
        ],
    )
