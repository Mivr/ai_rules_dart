"""Analysis tests for `//flutter:dev_incremental_serialization`.

The setting only has an effect together with `//flutter:incremental_kernel`.
With both on, the `FlutterKernelCompile` action's argv carries the
`--dev-incremental-serialization` marker and its execution requirements hold
`no-remote-cache` and `no-remote-exec` next to the worker requirements. With
the setting off (the default), with `incremental_kernel` on or off, both are
absent and the argv has no marker. The setting alone never reaches the
`kernel_filter` path.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load(":incr_kernel_fixture.bzl", "ReqInfo", "incr_caller")

visibility(["//flutter/tests/..."])

_MARKER = "--dev-incremental-serialization"
_INCR = str(Label("//flutter:incremental_kernel"))
_DEV = str(Label("//flutter:dev_incremental_serialization"))

def _compile(env):
    kernels = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterKernelCompile"]
    asserts.equals(env, 1, len(kernels), "expected one FlutterKernelCompile")
    reqs = analysistest.target_under_test(env)[ReqInfo].requirements
    asserts.equals(env, 1, len(reqs), "expected one recorded run")
    return struct(argv = kernels[0].argv, reqs = reqs[0] if reqs else {})

def _on_impl(ctx):
    """Both on: the marker and the no-remote requirements are present."""
    env = analysistest.begin(ctx)
    action = _compile(env)
    asserts.equals(env, "1", action.reqs.get("no-remote-cache"), "missing no-remote-cache: %s" % action.reqs)
    asserts.equals(env, "1", action.reqs.get("no-remote-exec"), "missing no-remote-exec: %s" % action.reqs)
    asserts.true(env, "supports-workers" in action.reqs, "worker requirements must stay: %s" % action.reqs)
    asserts.true(env, _MARKER in action.argv, "argv must hold the marker: %s" % action.argv)
    return analysistest.end(env)

def _off_impl(ctx):
    """Setting off, worker on: no marker and no no-remote requirements."""
    env = analysistest.begin(ctx)
    action = _compile(env)
    asserts.true(env, "supports-workers" in action.reqs, "the worker route must be on: %s" % action.reqs)
    asserts.false(env, "no-remote-cache" in action.reqs, "unexpected no-remote-cache: %s" % action.reqs)
    asserts.false(env, "no-remote-exec" in action.reqs, "unexpected no-remote-exec: %s" % action.reqs)
    asserts.false(env, _MARKER in action.argv, "argv must not hold the marker: %s" % action.argv)
    return analysistest.end(env)

def _batch_impl(ctx):
    """Setting on without `incremental_kernel`: the stock action, untouched."""
    env = analysistest.begin(ctx)
    action = _compile(env)
    asserts.equals(env, [], [k for k in action.reqs if k.startswith("no-remote") or k.startswith("supports")], "the batch action must carry no requirements: %s" % action.reqs)
    asserts.false(env, _MARKER in action.argv, "argv must not hold the marker: %s" % action.argv)
    return analysistest.end(env)

_DBG = {"//command_line_option:compilation_mode": "dbg"}
_on_test = analysistest.make(_on_impl, config_settings = _DBG | {_INCR: True, _DEV: True})
_off_test = analysistest.make(_off_impl, config_settings = _DBG | {_INCR: True, _DEV: False})
_batch_test = analysistest.make(_batch_impl, config_settings = _DBG | {_INCR: False, _DEV: True})

def dev_incremental_serialization_test_suite(name):
    """Fixtures and tests for `//flutter:dev_incremental_serialization`.

    Args:
        name: The test suite name.
    """
    incr_caller(
        name = "_dev_incr_caller",
        main = "compile_api_main.dart",
        tags = ["manual"],
    )
    _on_test(name = name + "_on", target_under_test = ":_dev_incr_caller")
    _off_test(name = name + "_off", target_under_test = ":_dev_incr_caller")
    _batch_test(name = name + "_batch", target_under_test = ":_dev_incr_caller")
    native.test_suite(
        name = name,
        tests = [":" + name + "_on", ":" + name + "_off", ":" + name + "_batch"],
    )
