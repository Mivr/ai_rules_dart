"""Tests that `//dart:jit_snapshot_lock_timeout` and the training key reach both snapshot actions' argv.

The deadline bounds the wait for the keyed training lock. Both snapshot
actions (`dart_binary` in `jit-snapshot` mode and
`dart_test_runner_snapshot`) must carry it on the command line only when it
differs from the default, so builds with a non-default deadline and builds
without one have different action keys, while default builds keep one key.
Both actions always carry `--train-key=`, the 16-lowercase-hex key of the
declared output's root-relative path, so two different targets train in
parallel and only concurrent trainings of one output contend.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:defs.bzl", "dart_binary")
load("//dart/private:dart_test.bzl", "dart_test_kernel")
load("//dart/private:dart_test_runner.bzl", "dart_test_runner_snapshot")

_TIMEOUT_FLAG = str(Label("//dart:jit_snapshot_lock_timeout"))
_TIMEOUT_ARG = "--lock-timeout="
_TRAIN_KEY_ARG = "--train-key="

# On Windows jit-snapshot trains through `dart compile` and there is no runner snapshot action, so these argv tests run on POSIX hosts only.
_POSIX_ONLY = select({
    "@platforms//os:windows": ["@platforms//:incompatible"],
    "//conditions:default": [],
})

_HEX = "0123456789abcdef"

def _argv_for(env, mnemonic):
    """The argv of the target's action with `mnemonic`, or None if absent."""
    for action in analysistest.target_actions(env):
        if action.mnemonic == mnemonic:
            return action.argv
    return None

def _is_key(value):
    """Whether `value` is a 16-lowercase-hex training key."""
    if len(value) != 16:
        return False
    for ch in value.elems():
        if ch not in _HEX:
            return False
    return True

def _snapshot_argv_test_impl(ctx):
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
    timeouts = [a for a in argv if a.startswith(_TIMEOUT_ARG)]
    keys = [a for a in argv if a.startswith(_TRAIN_KEY_ARG)]
    if ctx.attr.expect_timeout:
        asserts.equals(
            env,
            ["%s%d" % (_TIMEOUT_ARG, ctx.attr.expect_timeout)],
            timeouts,
            "%s must carry %s%d with //dart:jit_snapshot_lock_timeout=%s: %s" % (
                ctx.attr.mnemonic,
                _TIMEOUT_ARG,
                ctx.attr.expect_timeout,
                ctx.attr.expect_timeout,
                argv,
            ),
        )
    else:
        asserts.equals(
            env,
            [],
            timeouts,
            "%s must not carry %s with the default //dart:jit_snapshot_lock_timeout: %s" % (
                ctx.attr.mnemonic,
                _TIMEOUT_ARG,
                argv,
            ),
        )
    asserts.equals(
        env,
        1,
        len(keys),
        "%s must carry exactly one %s argv entry: %s" % (
            ctx.attr.mnemonic,
            _TRAIN_KEY_ARG,
            argv,
        ),
    )
    if len(keys) == 1:
        asserts.true(
            env,
            _is_key(keys[0][len(_TRAIN_KEY_ARG):]),
            "%s train key must be 16 lowercase hex: %s" % (
                ctx.attr.mnemonic,
                keys,
            ),
        )
    return analysistest.end(env)

def _snapshot_argv_test(timeout):
    """Returns an analysis test with `//dart:jit_snapshot_lock_timeout` at `timeout`, or the default for None."""
    return analysistest.make(
        _snapshot_argv_test_impl,
        attrs = {
            "mnemonic": attr.string(
                doc = "The snapshot action mnemonic whose argv is checked.",
                mandatory = True,
            ),
            "expect_timeout": attr.int(
                doc = "The `--lock-timeout=` seconds expected in argv, or 0 for the default (absent).",
                mandatory = True,
            ),
        },
        config_settings = {} if timeout == None else {_TIMEOUT_FLAG: timeout},
    )

_jit_default_test = _snapshot_argv_test(None)
_jit_flag_test = _snapshot_argv_test(20)
_runner_default_test = _snapshot_argv_test(None)
_runner_flag_test = _snapshot_argv_test(20)

def jit_lock_timeout_test_suite(name):
    """Registers the `jit_snapshot_lock_timeout` and `--train-key` argv tests.

    Args:
      name: Aggregating `test_suite` target name.
    """
    dart_binary(
        name = "jit_timeout_fixture",
        compile_mode = "jit-snapshot",
        main = "//dart/private/tools:noop.dart",
        tags = ["manual"],
    )
    dart_test_kernel(
        name = "jit_timeout_training_fixture",
        main = "//dart/private/tools:noop.dart",
        tags = ["manual"],
    )
    dart_test_runner_snapshot(
        name = "jit_timeout_runner_fixture",
        runner = "//dart/private/tools:analyze_runner",
        tags = ["manual"],
        training = ":jit_timeout_training_fixture",
    )
    _jit_default_test(
        name = "jit_timeout_default_test",
        size = "small",
        target_compatible_with = _POSIX_ONLY,
        expect_timeout = 0,
        mnemonic = "DartJitSnapshot",
        target_under_test = ":jit_timeout_fixture",
    )
    _jit_flag_test(
        name = "jit_timeout_explicit_test",
        size = "small",
        target_compatible_with = _POSIX_ONLY,
        expect_timeout = 20,
        mnemonic = "DartJitSnapshot",
        target_under_test = ":jit_timeout_fixture",
    )
    _runner_default_test(
        name = "runner_timeout_default_test",
        size = "small",
        target_compatible_with = _POSIX_ONLY,
        expect_timeout = 0,
        mnemonic = "DartTestRunnerSnapshot",
        target_under_test = ":jit_timeout_runner_fixture",
    )
    _runner_flag_test(
        name = "runner_timeout_explicit_test",
        size = "small",
        target_compatible_with = _POSIX_ONLY,
        expect_timeout = 20,
        mnemonic = "DartTestRunnerSnapshot",
        target_under_test = ":jit_timeout_runner_fixture",
    )
    native.test_suite(
        name = name,
        tests = [
            ":jit_timeout_default_test",
            ":jit_timeout_explicit_test",
            ":runner_timeout_default_test",
            ":runner_timeout_explicit_test",
        ],
    )
