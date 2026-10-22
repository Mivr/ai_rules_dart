"""Tests that `//dart:jit_snapshot_fallback` reaches both snapshot actions' argv.

The flag opts into the private-scratch fallback when the keyed training
path is unavailable. Both snapshot actions (`dart_binary` in `jit-snapshot`
mode and `dart_test_runner_snapshot`) must carry it on the command line, so
builds that allow the fallback and builds that do not have different action
keys: without the flag in argv, one host's fallback bytes could be served from
the remote cache to a constant-path host under the same key.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:defs.bzl", "dart_binary")
load("//dart/private:dart_test.bzl", "dart_test_kernel")
load("//dart/private:dart_test_runner.bzl", "dart_test_runner_snapshot")

_FLAG = str(Label("//dart:jit_snapshot_fallback"))
_FALLBACK_ARG = "--fallback-allowed"

# On Windows jit-snapshot trains through `dart compile` and there is no runner snapshot action, so these argv tests run on POSIX hosts only.
_POSIX_ONLY = select({
    "@platforms//os:windows": ["@platforms//:incompatible"],
    "//conditions:default": [],
})

def _argv_for(env, mnemonic):
    """The argv of the target's action with `mnemonic`, or None if absent."""
    for action in analysistest.target_actions(env):
        if action.mnemonic == mnemonic:
            return action.argv
    return None

def _fallback_argv_test_impl(ctx):
    # The flag's value decides one argv entry on the snapshot action: present
    # when allowed, absent when not. Either way the entry is the only thing
    # that differs, so the action key follows the flag.
    env = analysistest.begin(ctx)
    argv = _argv_for(env, ctx.attr.mnemonic)
    if argv == None:
        asserts.true(
            env,
            False,
            "expected a %s action, saw %s" %
            (ctx.attr.mnemonic, [a.mnemonic for a in analysistest.target_actions(env)]),
        )
        return analysistest.end(env)
    asserts.equals(
        env,
        ctx.attr.expect_fallback,
        _FALLBACK_ARG in argv,
        "%s must%s carry %s with //dart:jit_snapshot_fallback=%s: %s" % (
            ctx.attr.mnemonic,
            "" if ctx.attr.expect_fallback else " not",
            _FALLBACK_ARG,
            ctx.attr.expect_fallback,
            argv,
        ),
    )
    return analysistest.end(env)

def _fallback_argv_test(flag):
    """Returns an analysis test with `//dart:jit_snapshot_fallback` at `flag`, or the default for None."""
    return analysistest.make(
        _fallback_argv_test_impl,
        attrs = {
            "mnemonic": attr.string(
                doc = "The snapshot action mnemonic whose argv must carry the flag.",
                mandatory = True,
            ),
            "expect_fallback": attr.bool(
                doc = "Whether `--fallback-allowed` must be in that action's argv.",
                mandatory = True,
            ),
        },
        config_settings = {} if flag == None else {_FLAG: flag},
    )

_jit_default_test = _fallback_argv_test(None)
_jit_flag_test = _fallback_argv_test(True)
_runner_default_test = _fallback_argv_test(None)
_runner_flag_test = _fallback_argv_test(True)

def jit_fallback_test_suite(name):
    """Registers the `jit_snapshot_fallback` argv tests.

    Args:
      name: Aggregating `test_suite` target name.
    """
    dart_binary(
        name = "jit_fallback_fixture",
        compile_mode = "jit-snapshot",
        main = "//dart/private/tools:noop.dart",
        tags = ["manual"],
    )
    dart_test_kernel(
        name = "jit_fallback_training_fixture",
        main = "//dart/private/tools:noop.dart",
        tags = ["manual"],
    )
    dart_test_runner_snapshot(
        name = "jit_fallback_runner_fixture",
        runner = "//dart/private/tools:analyze_runner",
        tags = ["manual"],
        training = ":jit_fallback_training_fixture",
    )
    _jit_default_test(
        name = "jit_fallback_default_test",
        size = "small",
        target_compatible_with = _POSIX_ONLY,
        expect_fallback = False,
        mnemonic = "DartJitSnapshot",
        target_under_test = ":jit_fallback_fixture",
    )
    _jit_flag_test(
        name = "jit_fallback_enabled_test",
        size = "small",
        target_compatible_with = _POSIX_ONLY,
        expect_fallback = True,
        mnemonic = "DartJitSnapshot",
        target_under_test = ":jit_fallback_fixture",
    )
    _runner_default_test(
        name = "runner_fallback_default_test",
        size = "small",
        target_compatible_with = _POSIX_ONLY,
        expect_fallback = False,
        mnemonic = "DartTestRunnerSnapshot",
        target_under_test = ":jit_fallback_runner_fixture",
    )
    _runner_flag_test(
        name = "runner_fallback_enabled_test",
        size = "small",
        target_compatible_with = _POSIX_ONLY,
        expect_fallback = True,
        mnemonic = "DartTestRunnerSnapshot",
        target_under_test = ":jit_fallback_runner_fixture",
    )
    native.test_suite(
        name = name,
        tests = [
            ":jit_fallback_default_test",
            ":jit_fallback_enabled_test",
            ":runner_fallback_default_test",
            ":runner_fallback_enabled_test",
        ],
    )
