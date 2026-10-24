"""Analysis tests for the guarded kernel-compile surface.

`gen_kernel_args` used to be public through `dart/utils.bzl`, handing out a
`gen_kernel` command line whose `--filesystem-root .` mounts the exec root
with no declared-input guard: a rule built on it compiles a relative import
of an undeclared workspace file under the local strategy. The symbol is gone;
the only kernel path left is the guarded wrapper, which these tests pin: a
whole-program kernel compile runs `gen_kernel` through the
isolated-filesystem wrapper whose executable is a declared input. The second
test pins the rest of the public surface that stayed: the module still loads
and its pure helpers still answer.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:defs.bzl", "dart_binary")
load("//dart:utils.bzl", "collect_transitive_srcs", "runfiles_path")
load("//dart/tests:small_suite.bzl", "small_unittest_suite")

def _utils_surface_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "ws/a/b.dart",
        runfiles_path(struct(short_path = "a/b.dart"), "ws"),
        "the public surface still resolves runfiles paths",
    )
    asserts.equals(
        env,
        [],
        collect_transitive_srcs([]).to_list(),
        "the public surface still collects empty closures",
    )
    return unittest.end(env)

_utils_surface_test = unittest.make(_utils_surface_test_impl)

def _guarded_kernel_test_impl(ctx):
    env = analysistest.begin(ctx)
    kernels = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "DartKernel"
    ]
    asserts.equals(env, 1, len(kernels), "one whole-program DartKernel action")
    argv = kernels[0].argv
    asserts.true(
        env,
        "--gen-kernel" in argv,
        "the kernel compile runs through the guarded wrapper: %s" % argv,
    )
    runner = argv[0].split("/")[-1]
    basenames = [f.basename for f in kernels[0].inputs.to_list()]
    asserts.true(
        env,
        runner in basenames,
        "the wrapper executable %s is a declared input: %s" % (runner, basenames),
    )
    return analysistest.end(env)

_guarded_kernel_test = analysistest.make(_guarded_kernel_test_impl)

def lows_b_c_suite(name):
    """Declares the guarded kernel-compile tests.

    Args:
      name: Name of the generated `test_suite`.
    """
    dart_binary(
        name = name + "_kernel",
        compile_mode = "kernel",
        main = "main.dart",
        modular_kernel = False,
        tags = ["manual"],
    )
    _guarded_kernel_test(
        name = name + "_guarded_kernel_test",
        target_under_test = ":" + name + "_kernel",
        size = "small",
    )
    small_unittest_suite(
        name + "_unit",
        _utils_surface_test,
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_guarded_kernel_test",
        ],
    )
