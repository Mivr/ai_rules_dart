"""Tests that `//dart:jit_snapshot_fallback` reaches both snapshot actions.

The flag opts into the private-scratch fallback when the keyed training
path is unavailable. Both snapshot actions (`dart_binary` in `jit-snapshot`
mode and `dart_test_runner_snapshot`) must carry it on the command line, so
builds that allow the fallback and builds that do not have different action
keys: without the flag in argv, one host's fallback bytes could be served from
the remote cache to a constant-path host under the same key.

With the flag on both actions must also carry the `no-cache`
execution requirement, so a fallback-trained snapshot is neither uploaded to
nor served from a disk or remote cache (`no-remote-cache` alone would still
let a shared disk cache store and serve it); with the flag off neither action
carries either requirement. Analysis-test actions expose no execution info on
this Bazel version (their fields are `args`, `argv`, `content`, `env`,
`inputs`, `mnemonic`, `outputs` and `substitutions`), so that half is pinned
by driving the real `dart_compile_action` and the real
`dart_test_runner_snapshot_impl` with capturing contexts below and asserting
on each action's execution requirements.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dart:defs.bzl", "dart_binary")
load("//dart/private:dart_compile.bzl", "dart_compile_action")
load("//dart/private:dart_test.bzl", "dart_test_kernel")
load("//dart/private:dart_test_runner.bzl", "DartTestKernelInfo", "dart_test_runner_snapshot", "dart_test_runner_snapshot_impl")

_FLAG = str(Label("//dart:jit_snapshot_fallback"))
_FALLBACK_ARG = "--fallback-allowed"
_NO_CACHE = "no-cache"
_NO_REMOTE_CACHE = "no-remote-cache"

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
_jit_off_test = _fallback_argv_test(False)
_runner_default_test = _fallback_argv_test(None)
_runner_flag_test = _fallback_argv_test(True)
_runner_off_test = _fallback_argv_test(False)

def _capturing_actions(runs):
    """A fake `ctx.actions` recording each `run` call's kwargs in `runs`.

    Lets a unit test drive a real action-building function and assert on the
    action it declares, including the execution requirements that
    analysis-test actions do not expose.

    Args:
      runs: The list each `run` call appends its kwargs to.

    Returns:
      A struct with the `declare_file`, `write`, `args` and `run` surface the
      snapshot actions use.
    """
    return struct(
        declare_file = lambda name: struct(basename = name, path = "out/" + name, short_path = name),
        write = lambda **_kw: None,
        args = lambda: struct(add = lambda *_a, **_kw: None),
        run = lambda **kw: runs.append(kw),
    )

def _jit_snapshot_run_kwargs(fallback):
    """The `ctx.actions.run` kwargs of the `DartJitSnapshot` action for `fallback`.

    Drives the real `dart_compile_action` in `jit-snapshot` mode over a
    prebuilt kernel with a capturing context, so the test asserts on the
    action the rule creates rather than on a copy of its logic. A prebuilt
    kernel keeps the context small: the compile goes straight to the snapshot
    training, with no front-end action first.

    Args:
      fallback: The `jit_snapshot_fallback` value the compile sees. The build
        setting defaults to `False`, so the default and explicit `False` take
        this same path.

    Returns:
      The kwargs the snapshot action's `ctx.actions.run` call received.
    """
    runs = []
    fake_actions = _capturing_actions(runs)
    fake_ctx = struct(
        label = "fake:jitsnapshot",
        var = {"COMPILATION_MODE": "fastbuild"},
        attr = struct(),
        actions = fake_actions,
    )
    dart = fake_actions.declare_file("dart")
    dart_compile_action(
        ctx = fake_ctx,
        dart_sdk_info = struct(dart = dart, compile_files = depset()),
        cfg = struct(
            main = fake_actions.declare_file("input.dill"),
            srcs = [],
            package_config = None,
            output = fake_actions.declare_file("app.jit"),
            compile_mode = "jit-snapshot",
            target_os = "",
            target_arch = "",
            extra_flags = [],
            defines = [],
            main_path = None,
            recorded_uses = None,
            jit_tool = [fake_actions.declare_file("app_jit_snapshot.dart")],
            comma_patch = fake_actions.declare_file("comma_patch.dart"),
            native_assets_yaml = None,
            embed_sources = True,
            jit_snapshot_fallback = fallback,
        ),
    )
    return runs[0]

def _runner_snapshot_run_kwargs(fallback):
    """The `ctx.actions.run` kwargs of the `DartTestRunnerSnapshot` action for `fallback`.

    Drives the real `dart_test_runner_snapshot_impl` with a capturing context,
    so the test asserts on the action the rule creates rather than on a copy
    of its logic. The fake runner carries no `DartCompileInfo`, so no SDK
    mismatch check fires; the exec and target SDKs are one shared struct, so
    their `dart` paths agree and the snapshot action is declared.

    Args:
      fallback: The `//dart:jit_snapshot_fallback` value the rule sees. The
        build setting defaults to `False`, so the default and explicit `False`
        take this same path.

    Returns:
      The kwargs the snapshot action's `ctx.actions.run` call received.
    """
    runs = []
    fake_actions = _capturing_actions(runs)
    dart = fake_actions.declare_file("dart")
    sdk = struct(
        dart = dart,
        version = "3.13.5",
        compile_files = depset(),
        runtime_files = depset(),
    )
    runner_dill = struct(
        basename = "runner.dill",
        extension = "dill",
        path = "out/runner.dill",
        short_path = "runner.dill",
    )
    fake_ctx = struct(
        label = struct(name = "jit_fallback_runner_fixture"),
        toolchains = {
            "//dart:toolchain_type": struct(dart_sdk_info = sdk),
            "//dart:exec_tools_toolchain_type": struct(dart_sdk_info = sdk),
        },
        attr = struct(
            runner = {
                DefaultInfo: struct(
                    files = depset([runner_dill]),
                    default_runfiles = struct(files = depset()),
                ),
            },
            training = {
                DartTestKernelInfo: struct(
                    dill = fake_actions.declare_file("training.dill"),
                    source = fake_actions.declare_file("training.dart"),
                    precompiled_dir = "precompiled",
                    test_path = "training_test.dart",
                ),
            },
            _enabled = {BuildSettingInfo: struct(value = True)},
            _fallback = {BuildSettingInfo: struct(value = fallback)},
            _lock_timeout = {BuildSettingInfo: struct(value = 300)},
        ),
        files = struct(
            _tool = [fake_actions.declare_file("app_jit_snapshot.dart")],
        ),
        file = struct(
            _comma_patch = fake_actions.declare_file("comma_patch.dart"),
        ),
        actions = fake_actions,
    )
    dart_test_runner_snapshot_impl(fake_ctx)
    return runs[0]

def _assert_snapshot_requirements(env, mnemonic, run_kwargs):
    """Asserts what a snapshot action's execution requirements carry for `mnemonic`.

    With the fallback on the action carries `no-cache` (and not
    `no-remote-cache`); with it off it carries neither, so default builds keep
    their action keys and their disk and remote cache hits.

    Args:
      env: The unittest environment.
      mnemonic: The snapshot action mnemonic, for failure messages.
      run_kwargs: Takes a fallback bool and returns the action's `run` kwargs.
    """
    on_reqs = run_kwargs(True).get("execution_requirements") or {}
    asserts.true(
        env,
        _NO_CACHE in on_reqs,
        "%s must carry %s with //dart:jit_snapshot_fallback=true: %s" % (mnemonic, _NO_CACHE, on_reqs),
    )
    asserts.false(
        env,
        _NO_REMOTE_CACHE in on_reqs,
        "%s must not carry %s with //dart:jit_snapshot_fallback=true: %s" % (mnemonic, _NO_REMOTE_CACHE, on_reqs),
    )
    off_reqs = run_kwargs(False).get("execution_requirements") or {}
    asserts.false(
        env,
        _NO_CACHE in off_reqs,
        "%s must not carry %s with //dart:jit_snapshot_fallback=false: %s" % (mnemonic, _NO_CACHE, off_reqs),
    )
    asserts.false(
        env,
        _NO_REMOTE_CACHE in off_reqs,
        "%s must not carry %s with //dart:jit_snapshot_fallback=false: %s" % (mnemonic, _NO_REMOTE_CACHE, off_reqs),
    )

def _jit_snapshot_requirements_test_impl(ctx):
    """Tests that the `DartJitSnapshot` action skips every shared cache only with the fallback on."""
    env = unittest.begin(ctx)
    _assert_snapshot_requirements(env, "DartJitSnapshot", _jit_snapshot_run_kwargs)
    return unittest.end(env)

_jit_snapshot_requirements_test = unittest.make(_jit_snapshot_requirements_test_impl)

def _runner_snapshot_requirements_test_impl(ctx):
    """Tests that the `DartTestRunnerSnapshot` action skips every shared cache only with the fallback on."""
    env = unittest.begin(ctx)
    _assert_snapshot_requirements(env, "DartTestRunnerSnapshot", _runner_snapshot_run_kwargs)
    return unittest.end(env)

_runner_snapshot_requirements_test = unittest.make(_runner_snapshot_requirements_test_impl)

def jit_fallback_test_suite(name):
    """Registers the `jit_snapshot_fallback` argv and execution-requirement tests.

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
    _jit_off_test(
        name = "jit_fallback_disabled_test",
        size = "small",
        target_compatible_with = _POSIX_ONLY,
        expect_fallback = False,
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
    _runner_off_test(
        name = "runner_fallback_disabled_test",
        size = "small",
        target_compatible_with = _POSIX_ONLY,
        expect_fallback = False,
        mnemonic = "DartTestRunnerSnapshot",
        target_under_test = ":jit_fallback_runner_fixture",
    )
    _jit_snapshot_requirements_test(
        name = "jit_snapshot_requirements_test",
        size = "small",
    )
    _runner_snapshot_requirements_test(
        name = "runner_snapshot_requirements_test",
        size = "small",
    )
    native.test_suite(
        name = name,
        tests = [
            ":jit_fallback_default_test",
            ":jit_fallback_enabled_test",
            ":jit_fallback_disabled_test",
            ":runner_fallback_default_test",
            ":runner_fallback_enabled_test",
            ":runner_fallback_disabled_test",
            ":jit_snapshot_requirements_test",
            ":runner_snapshot_requirements_test",
        ],
    )
