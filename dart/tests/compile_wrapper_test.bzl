"""Tests that `exe` and `aot-snapshot` compiles run the AOT compile wrapper.

The `DartKernel` (`gen_kernel`) and `DartCompile` actions of an `exe` or
`aot-snapshot` `dart_binary` start the prebuilt AOT snapshot of the wrapper
under `dartaotruntime`, instead of the VM parsing and JIT-compiling
`app_jit_snapshot.dart` on every action. A `jit-snapshot` binary keeps running
the tool from source, so its training action's argv is as it always was.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:defs.bzl", "dart_binary")

visibility(["//dart/..."])

_ENTRY = "app_jit_snapshot.dart"

# On Windows jit-snapshot trains through `dart compile`, so these argv tests run on POSIX hosts only.
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

def _from_source(argv):
    """Whether `argv` runs the wrapper from source: the entry is an argument."""
    return len([a for a in argv if a.endswith("/" + _ENTRY)]) > 0

def _wrapper_test_impl(ctx):
    env = analysistest.begin(ctx)
    for mnemonic in ctx.attr.mnemonics:
        argv = _argv_for(env, mnemonic)
        if argv == None:
            asserts.true(env, False, "expected a %s action" % mnemonic)
            continue
        if ctx.attr.aot:
            asserts.true(env, argv[0].endswith("/dartaotruntime"), "%s must run under dartaotruntime: %s" % (mnemonic, argv))
            asserts.true(env, argv[1].endswith("/compile_wrapper.aot"), "%s must start the AOT wrapper: %s" % (mnemonic, argv))
            asserts.false(env, _from_source(argv), "%s must not run %s from source: %s" % (mnemonic, _ENTRY, argv))
        else:
            asserts.false(env, argv[0].endswith("/dartaotruntime"), "%s must keep running the VM: %s" % (mnemonic, argv))
            asserts.true(env, _from_source(argv), "%s must keep running %s from source: %s" % (mnemonic, _ENTRY, argv))
            asserts.true(env, argv[1].startswith("--packages="), "%s keeps its `--packages` argument: %s" % (mnemonic, argv))
    return analysistest.end(env)

_wrapper_test = analysistest.make(
    _wrapper_test_impl,
    attrs = {
        "aot": attr.bool(doc = "Whether the actions must run the AOT wrapper.", mandatory = True),
        "mnemonics": attr.string_list(doc = "The actions whose argv is checked.", mandatory = True),
    },
)

def compile_wrapper_test_suite(name):
    """Registers the AOT compile wrapper argv tests.

    Args:
      name: Aggregating `test_suite` target name.
    """
    tests = []
    for mode, aot, mnemonics in [
        ("exe", True, ["DartKernel", "DartCompile"]),
        ("aot-snapshot", True, ["DartKernel", "DartCompile"]),
        ("jit-snapshot", False, ["DartKernel", "DartJitSnapshot"]),
    ]:
        fixture = "compile_wrapper_%s_fixture" % mode.replace("-", "_")
        dart_binary(
            name = fixture,
            compile_mode = mode,
            main = "//dart/private/tools:noop.dart",
            tags = ["manual"],
        )
        test = "compile_wrapper_%s_test" % mode.replace("-", "_")
        _wrapper_test(
            name = test,
            size = "small",
            aot = aot,
            mnemonics = mnemonics,
            target_compatible_with = _POSIX_ONLY,
            target_under_test = ":" + fixture,
        )
        tests.append(":" + test)
    native.test_suite(name = name, tests = tests)
