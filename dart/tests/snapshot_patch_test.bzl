"""Tests that comma-containing `-D` defines run a patched SDK snapshot.

`gen_kernel` and `kernel_worker` split `-D`/`--define` values on commas, so a
compile whose defines contain a comma must run the toolchain's patched
snapshot (a declared action output taken as a tool input) and pass the
`--comma-patched-snapshot` marker the tools enforce. A compile without comma
defines runs the pristine snapshot with no marker. A comma `-D` in
`dart_compile_flags` takes the same path as one in `defines`. The patch
actions themselves run the SDK's `dartvm` directly, declared as an input, so
they work wherever the launcher's sibling lookup does not (remote execution).
These tests pin the selection at analysis time; the Dart unit tests pin the
patch bytes and the tools' loud failure, and the oracle fixture proves the
value survives.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:defs.bzl", "dart_binary")
load("//dart/private:common.bzl", "has_comma_define")
load(":small_suite.bzl", "small_unittest_suite")

# --- has_comma_define ---

def _comma_value_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, has_comma_define(["FOO=a,b"]), "comma value detected")
    asserts.true(env, has_comma_define(["A=1", "B=x,y"]), "comma among others detected")
    return unittest.end(env)

def _clean_defines_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.false(env, has_comma_define([]), "no defines is clean")
    asserts.false(env, has_comma_define(["FOO=a", "BAR="]), "comma-free values are clean")
    asserts.false(env, has_comma_define(["KEY"]), "a bare key is clean")
    return unittest.end(env)

_comma_value_test = unittest.make(_comma_value_test_impl)
_clean_defines_test = unittest.make(_clean_defines_test_impl)

# --- whole-program action structure ---

def _whole_program_comma_test_impl(ctx):
    env = analysistest.begin(ctx)
    kernel_actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "DartKernel"
    ]
    asserts.equals(env, 1, len(kernel_actions), "one whole-program DartKernel action")
    argv = kernel_actions[0].argv
    asserts.true(
        env,
        "-DCOMMA_VAL=a,b" in argv,
        "the comma define reaches the front-end step: %s" % argv,
    )
    asserts.true(
        env,
        "--comma-patched-snapshot" in argv,
        "the wrapper authorizes the patched snapshot: %s" % argv,
    )
    snapshots = [arg for arg in argv if arg.endswith(".snapshot")]
    asserts.true(
        env,
        any([s.endswith("gen_kernel_nocomma.snapshot") for s in snapshots]),
        "the action runs the toolchain's patched gen_kernel snapshot: %s" % snapshots,
    )
    asserts.false(
        env,
        any([s.endswith("bin/snapshots/gen_kernel_aot.dart.snapshot") for s in snapshots]),
        "the pristine gen_kernel snapshot is not run: %s" % snapshots,
    )
    input_basenames = [f.basename for f in kernel_actions[0].inputs.to_list()]
    asserts.true(
        env,
        "gen_kernel_nocomma.snapshot" in input_basenames,
        "the patched snapshot is an action input: %s" % input_basenames,
    )
    return analysistest.end(env)

_whole_program_comma_test = analysistest.make(_whole_program_comma_test_impl)

def _whole_program_plain_test_impl(ctx):
    env = analysistest.begin(ctx)
    kernel_actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "DartKernel"
    ]
    asserts.equals(env, 1, len(kernel_actions), "one whole-program DartKernel action")
    argv = kernel_actions[0].argv
    asserts.false(
        env,
        "--comma-patched-snapshot" in argv,
        "no marker without comma defines: %s" % argv,
    )
    asserts.false(
        env,
        any(["nocomma" in arg for arg in argv]),
        "the patched snapshot is not wired in without comma defines: %s" % argv,
    )
    return analysistest.end(env)

_whole_program_plain_test = analysistest.make(_whole_program_plain_test_impl)

def _whole_program_comma_flag_test_impl(ctx):
    env = analysistest.begin(ctx)
    kernel_actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "DartKernel"
    ]
    asserts.equals(env, 1, len(kernel_actions), "one whole-program DartKernel action")
    argv = kernel_actions[0].argv
    asserts.true(
        env,
        "-DCOMMA_FLAG=a,b" in argv,
        "the comma -D flag reaches the front-end step: %s" % argv,
    )
    asserts.true(
        env,
        "--comma-patched-snapshot" in argv,
        "a comma -D in dart_compile_flags authorizes the patched snapshot: %s" % argv,
    )
    snapshots = [arg for arg in argv if arg.endswith(".snapshot")]
    asserts.true(
        env,
        any([s.endswith("gen_kernel_nocomma.snapshot") for s in snapshots]),
        "the action runs the toolchain's patched gen_kernel snapshot: %s" % snapshots,
    )
    return analysistest.end(env)

_whole_program_comma_flag_test = analysistest.make(_whole_program_comma_flag_test_impl)

def _patch_action_dartvm_test_impl(ctx):
    # The `gen_kernel` step runs the `jit_tool` wrapper with `dartvm` as its
    # executable (see `dart_compile.bzl`): the `dart` launcher finds its
    # sibling `dartvm` by following its own path, which works only when the
    # sandbox lays the SDK out as siblings. The wrapper must run a declared
    # input directly so the compile works wherever that lookup does not
    # (remote execution).
    env = analysistest.begin(ctx)
    kernel_actions = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "DartKernel"
    ]
    asserts.equals(env, 1, len(kernel_actions), "one whole-program DartKernel action")
    action = kernel_actions[0]
    runner = action.argv[0].split("/")[-1]
    input_basenames = [f.basename for f in action.inputs.to_list()]
    asserts.true(
        env,
        runner in input_basenames,
        "the wrapper's executable %s is a declared input: %s" % (runner, input_basenames),
    )
    if "dartvm" in input_basenames or "dartvm.exe" in input_basenames:
        asserts.true(
            env,
            runner in ("dartvm", "dartvm.exe"),
            "with dartvm declared, the wrapper runs it directly " +
            "instead of the dart launcher: %s" % action.argv,
        )
    return analysistest.end(env)

_patch_action_dartvm_test = analysistest.make(_patch_action_dartvm_test_impl)

def snapshot_patch_test_suite(name):
    """Declares the patched-snapshot selection tests as one suite.

    Args:
      name: Name of the generated `test_suite`.
    """
    dart_binary(
        name = name + "_comma_fixture",
        compile_mode = "kernel",
        defines = ["COMMA_VAL=a,b"],
        main = "//dart/tests/defines_fixture:main.dart",
        modular_kernel = False,
        tags = ["manual"],
    )
    dart_binary(
        name = name + "_plain_fixture",
        compile_mode = "kernel",
        main = "//dart/tests/defines_fixture:main.dart",
        modular_kernel = False,
        tags = ["manual"],
    )
    dart_binary(
        name = name + "_comma_flag_fixture",
        compile_mode = "kernel",
        dart_compile_flags = ["-DCOMMA_FLAG=a,b"],
        main = "//dart/tests/defines_fixture:main.dart",
        modular_kernel = False,
        tags = ["manual"],
    )
    _whole_program_comma_test(
        name = name + "_whole_program_comma_test",
        target_under_test = ":" + name + "_comma_fixture",
        size = "small",
    )
    _whole_program_plain_test(
        name = name + "_plain_action_test",
        target_under_test = ":" + name + "_plain_fixture",
        size = "small",
    )
    _whole_program_comma_flag_test(
        name = name + "_whole_program_comma_flag_test",
        target_under_test = ":" + name + "_comma_flag_fixture",
        size = "small",
    )
    _patch_action_dartvm_test(
        name = name + "_patch_action_dartvm_test",
        target_under_test = ":" + name + "_comma_fixture",
        size = "small",
    )
    small_unittest_suite(
        name + "_unit",
        _comma_value_test,
        _clean_defines_test,
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_whole_program_comma_test",
            ":" + name + "_plain_action_test",
            ":" + name + "_whole_program_comma_flag_test",
            ":" + name + "_patch_action_dartvm_test",
        ],
    )
