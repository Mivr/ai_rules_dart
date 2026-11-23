"""Analysis tests for an executable's `defines` as configuration.

A `dart_test`, or a `dart_binary` that links modules, makes its own `defines`
the configuration of its `deps` edge. Every module of its closure compiles with
them, its entry compiles with the same canonical list, and it stays modular.
Bazel keys an action by its outputs, and a module's outputs live in its
configuration's output directory, so equal module paths are one set of module
actions. The tests pin:

- a test and a kernel binary with `defines` link modules (`DartKernelLink`),
  and the entry and every dependency module carry the canonical `-D`s;
- two tests with equal `defines`, written in another order and with a
  repeated key, compile the same modules;
- a test with other `defines`, or none, compiles the same number of modules,
  none shared with the first;
- an `exe` binary, which compiles from sources, leaves its closure in the
  configuration of a binary without `defines`;
- the closure facts a test with `defines` reads through its `deps` edge are
  those of the transitioned configuration, and still clean, so it keeps the
  clean-closure fast path (`clean_closure`, `executable_package`).
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:providers.bzl", "DartInfo", "DartKernelInfo")
load("//dart/private:closure_facts.bzl", "clean_closure", "facts_of")

visibility(["//dart/tests/..."])

_FIXTURE = "//dart/tests/executable_defines_fixture"

_ModulesInfo = provider(
    doc = "The module compiles below one executable.",
    fields = {
        "kmods": "depset of module directory paths.",
        "argv": "depset of (label, its `-D`s joined by spaces) for each library's module compile.",
        "clean": "Whether every direct dependency's closure facts are clean, as `executable_package` reads them.",
    },
)

def _modules_aspect_impl(target, ctx):
    deps = getattr(ctx.rule.attr, "deps", [])
    kmods = []
    argv = []
    if DartKernelInfo in target and target[DartKernelInfo].kmod != None:
        kmods.append(target[DartKernelInfo].kmod.path)
        for action in target.actions:
            if action.mnemonic == "DartKernel":
                argv.append((str(target.label), " ".join([a for a in action.argv if a.startswith("-D") and not a.startswith("-Ddart.vm.")])))
    clean = all([DartInfo in d and clean_closure(facts_of(d[DartInfo])) != None for d in deps])
    return [_ModulesInfo(
        clean = clean,
        kmods = depset(kmods, transitive = [d[_ModulesInfo].kmods for d in deps if _ModulesInfo in d]),
        argv = depset(argv, transitive = [d[_ModulesInfo].argv for d in deps if _ModulesInfo in d]),
    )]

_modules_aspect = aspect(
    implementation = _modules_aspect_impl,
    attr_aspects = ["deps"],
)

_CompareInfo = provider(doc = "Each executable's modules, by target name.", fields = ["executables"])

def _compare_impl(ctx):
    return [_CompareInfo(executables = {
        t.label.name: struct(
            clean = t[_ModulesInfo].clean,
            kmods = sorted(t[_ModulesInfo].kmods.to_list()),
            argv = t[_ModulesInfo].argv.to_list(),
        )
        for t in ctx.attr.executables
    })]

_compare = rule(
    implementation = _compare_impl,
    attrs = {"executables": attr.label_list(aspects = [_modules_aspect])},
)

def _shares_test_impl(ctx):
    env = analysistest.begin(ctx)
    e = analysistest.target_under_test(env)[_CompareInfo].executables
    a = e["test_a"].kmods
    asserts.equals(env, 2, len(a), "the closure has two library modules, got %s" % a)
    asserts.equals(env, a, e["test_a_twin"].kmods, "equal defines must share every module")
    for other in ["test_b", "test_plain"]:
        asserts.equals(env, len(a), len(e[other].kmods), "%s must compile the closure's modules once" % other)
        asserts.equals(env, [], [k for k in e[other].kmods if k in a], "%s must share no module with other defines" % other)
    for label, defines in e["test_a"].argv:
        asserts.equals(env, "-DA=1 -DB=2", defines, "%s: the module must take the test's canonical defines" % label)
    for label, defines in e["test_plain"].argv:
        asserts.equals(env, "", defines, "%s: a test without defines adds none" % label)
    for label, defines in e["kernel_a"].argv:
        asserts.equals(env, "-DA=1 -DB=2", defines, "%s: the module must take the binary's defines" % label)
    for name in ["test_a", "test_b", "test_plain", "kernel_a"]:
        asserts.true(env, e[name].clean, "%s: the closure facts behind its deps edge must stay clean" % name)
    asserts.equals(
        env,
        e["exe_plain"].kmods,
        e["exe_a"].kmods,
        "a binary that compiles from sources must leave its closure's configuration alone",
    )
    return analysistest.end(env)

_shares_test = analysistest.make(_shares_test_impl)

def _modular_entry_test_impl(ctx):
    env = analysistest.begin(ctx)
    mnemonics = [a.mnemonic for a in analysistest.target_actions(env)]
    asserts.true(env, "DartKernelLink" in mnemonics, "an executable with defines must link modules, got %s" % mnemonics)
    entries = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(entries), "one entry module compile, got %s" % mnemonics)
    if entries:
        defines = [a for a in entries[0].argv if a.startswith("-D") and not a.startswith("-Ddart.vm.")]
        asserts.equals(env, ["-DA=1", "-DB=2"], defines, "the entry must take the canonical defines")
    return analysistest.end(env)

_modular_entry_test = analysistest.make(_modular_entry_test_impl)

def executable_defines_test_suite(name):
    """Fixtures and tests for an executable's `defines` as configuration.

    Args:
        name: The test suite name.
    """
    _compare(
        name = name + "_compare",
        executables = [
            _FIXTURE + ":" + n
            for n in ["test_a", "test_a_twin", "test_b", "test_plain", "kernel_a", "exe_a", "exe_plain"]
        ],
        testonly = True,
        tags = ["manual"],
    )
    _shares_test(name = name + "_shares", target_under_test = ":" + name + "_compare", size = "small")
    _modular_entry_test(name = name + "_test_entry", target_under_test = _FIXTURE + ":test_a", size = "small")
    _modular_entry_test(name = name + "_kernel_entry", target_under_test = _FIXTURE + ":kernel_a", size = "small")
    native.test_suite(
        name = name,
        tests = [":" + name + s for s in ["_shares", "_test_entry", "_kernel_entry"]],
    )
