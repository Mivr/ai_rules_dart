"""`link_modules`: the linked path of `exe` / `aot-snapshot`, its default, and its validation."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:defs.bzl", "DartCodeAssetInfo", "dart_binary")
load("//dart:providers.bzl", "DartInfo")
load("//dart/private:common.bzl", "collect_transitive_srcs")
load("//dart/private:dart_kernel.bzl", "EXEC_TOOLS_TOOLCHAIN", "MODULAR_KERNEL_TOOLCHAINS", "kernel_tools_for")
load("//dart/private:dart_link_check.bzl", "LINK_CHECK_TOOL", "link_check_args")
load("//dart/tests:pruned_inputs.bzl", "pruned_inputs_settings")

visibility(["//dart/tests/..."])

_CHAIN = ["//dart/tests/modular_chain_fixture/chain_top"]
_MIRRORS = ["//dart/tests/link_modules:mirrors_dep"]

def _dart_inputs(action):
    """The `.dart` input paths of an action."""
    return [f.path for f in action.inputs.to_list() if f.extension == "dart"]

def _from_dill(actions):
    """The `DartKernel` actions that read a linked kernel through `--from-dill`."""
    return [a for a in actions if a.mnemonic == "DartKernel" and [x for x in a.argv if x.startswith("--from-dill=")]]

def _count(items, wanted):
    """How many of `items` equal `wanted`."""
    return len([i for i in items if i == wanted])

def _stamps(env):
    """The files of the `_validation` output group of the target under test."""
    return getattr(analysistest.target_under_test(env)[OutputGroupInfo], "_validation").to_list()

def _linked_impl(ctx):
    """Modules, a link, a linked-kernel front end, no `.dart` in the AOT steps, one validation."""
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    mnemonics = [a.mnemonic for a in actions]
    asserts.equals(env, 1, _count(mnemonics, "DartKernelLink"), "the modules are linked: %s" % mnemonics)
    modules = [a for a in actions if a.mnemonic == "DartKernel" and [x for x in a.argv if x.endswith("vm_platform_strong.dill")]]
    asserts.true(env, len(modules) > 0, "the entry module compiles against the strong platform")
    front_ends = _from_dill(actions)
    asserts.equals(env, 1, len(front_ends), "one front end reads the linked kernel")
    compiles = [a for a in actions if a.mnemonic == "DartCompile"]
    asserts.equals(env, 1, len(compiles), "one dart compile step")
    for a in front_ends + compiles:
        asserts.equals(env, [], _dart_inputs(a), "no .dart source is an input of %s" % a.mnemonic)
    checks = [a for a in actions if a.mnemonic == "DartLinkCheck"]
    asserts.equals(env, 1, len(checks), "one validation action: %s" % mnemonics)
    if checks:
        stamp = checks[0].outputs.to_list()[0]
        asserts.true(env, stamp in _stamps(env), "the stamp is in the _validation group")
        for a in actions:
            asserts.false(env, stamp in a.inputs.to_list(), "the stamp is no input of %s" % a.mnemonic)
        asserts.true(env, len(_dart_inputs(checks[0])) > 0, "the validation reads the closure's sources")
    return analysistest.end(env)

def _source_impl(ctx):
    """The source path with no link and no validation: the same actions as the base."""
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    mnemonics = [a.mnemonic for a in actions]
    asserts.equals(env, 0, _count(mnemonics, "DartKernelLink"), "no link: %s" % mnemonics)
    asserts.equals(env, 0, _count(mnemonics, "DartLinkCheck"), "no validation: %s" % mnemonics)
    asserts.equals(env, [], _from_dill(actions), "no linked-kernel front end")
    kernels = [a for a in actions if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(kernels), "one source front end: %s" % mnemonics)
    if kernels:
        asserts.true(env, _dart_inputs(kernels[0]) != [], "the front end reads .dart sources")
    asserts.equals(env, [], [f for f in _stamps(env) if f.basename.endswith(".link_check")], "no link_check stamp")
    return analysistest.end(env)

def _source_checked_impl(ctx):
    """An ineligible opted-in target: the source path, and the validation still runs."""
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    mnemonics = [a.mnemonic for a in actions]
    asserts.equals(env, 0, _count(mnemonics, "DartKernelLink"), "no link: %s" % mnemonics)
    asserts.equals(env, [], _from_dill(actions), "no linked-kernel front end")
    asserts.equals(env, 1, _count(mnemonics, "DartLinkCheck"), "the validation runs: %s" % mnemonics)
    kernels = [a for a in actions if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(kernels), "one source front end: %s" % mnemonics)
    if kernels:
        asserts.true(env, _dart_inputs(kernels[0]) != [], "the front end reads .dart sources")
    return analysistest.end(env)

def _validation_impl(ctx):
    """The validation reads a dependency package's sources and names the tool's flags."""
    env = analysistest.begin(ctx)
    checks = [a for a in analysistest.target_actions(env) if a.mnemonic == "DartLinkCheck"]
    asserts.equals(env, 1, len(checks), "one validation action")
    if checks:
        paths = _dart_inputs(checks[0])
        asserts.true(env, [p for p in paths if p.endswith("link_modules/lib/mirrors_dep.dart")] != [], "reads the dependency's source: %s" % paths)
        asserts.true(env, [p for p in paths if p.endswith("noop.dart")] != [], "reads the binary's main: %s" % paths)
    return analysistest.end(env)

_linked_test = analysistest.make(_linked_impl, config_settings = pruned_inputs_settings())
_source_test = analysistest.make(_source_impl, config_settings = pruned_inputs_settings())
_checked_test = analysistest.make(_source_checked_impl, config_settings = pruned_inputs_settings())
_validation_test = analysistest.make(_validation_impl, config_settings = pruned_inputs_settings())
_dbg_test = analysistest.make(
    _source_checked_impl,
    config_settings = pruned_inputs_settings({"//command_line_option:compilation_mode": "dbg"}),
)
_test_config_test = analysistest.make(
    _source_checked_impl,
    config_settings = pruned_inputs_settings({str(Label("//dart/private:vm_product")): False}),
)

def _dummy_asset_impl(ctx):
    """A code asset over a placeholder library file."""
    out = ctx.actions.declare_file(ctx.label.name + ".so")
    ctx.actions.write(output = out, content = "fake-so\n")
    return [
        DefaultInfo(files = depset([out])),
        DartCodeAssetInfo(
            asset_id = "package:link_modules_fixture/ffi.dart",
            link_mode = "dynamic_loading_bundle",
            dynamic_library = out,
            system_uri = "",
        ),
    ]

_dummy_asset = rule(implementation = _dummy_asset_impl, doc = "A code asset with a placeholder library.")

def _fixture(name, mode, **attrs):
    """Declares a manual `dart_binary` over the chain and returns its label."""
    dart_binary(
        name = name,
        compile_mode = mode,
        main = "//dart/private/tools:noop.dart",
        deps = attrs.pop("deps", _CHAIN),
        tags = ["manual"],
        **attrs
    )
    return ":" + name

def link_modules_test_suite(name):
    """Declares the `link_modules` analysis tests as one suite.

    Args:
      name: Name of the generated `test_suite`.
    """
    _dummy_asset(name = name + "_asset", tags = ["manual"])
    tests = []
    for mode in ["exe", "aot-snapshot"]:
        sfx = mode.replace("-", "_")
        base = "%s_%s_" % (name, sfx)
        cases = [
            (_linked_test, "linked", {"link_modules": True}),
            (_source_test, "default", {}),
            (_source_test, "default_modular_off", {"modular_kernel": False}),
            (_checked_test, "defines", {"link_modules": True, "defines": ["LINKED=1"]}),
            (_checked_test, "flags", {"link_modules": True, "dart_compile_flags": ["--extra-gen-snapshot-options=--optimization_level=3"]}),
            (_checked_test, "assets", {"link_modules": True, "code_assets": [":" + name + "_asset"]}),
            (_checked_test, "not_modular", {"link_modules": True, "modular_kernel": False}),
            (_checked_test, "dbg", {"link_modules": True}),
            (_checked_test, "product_off", {"link_modules": True}),
            (_validation_test, "validation", {"link_modules": True, "deps": _MIRRORS + _CHAIN}),
        ]
        for rule_fn, case, attrs in cases:
            if case == "dbg":
                rule_fn = _dbg_test
            elif case == "product_off":
                rule_fn = _test_config_test
            fixture = _fixture(base + case + "_fixture", mode, **attrs)
            rule_fn(name = base + case + "_test", target_under_test = fixture, size = "small")
            tests.append(":" + base + case + "_test")
    kernel = _fixture(name + "_kernel_fixture", "kernel", link_modules = True)
    _source_kernel_test(name = name + "_kernel_test", target_under_test = kernel, size = "small")
    tests.append(":" + name + "_kernel_test")
    native.test_suite(name = name, tests = tests)

def _kernel_impl(ctx):
    """`kernel` mode links modules as before and runs no validation."""
    env = analysistest.begin(ctx)
    mnemonics = [a.mnemonic for a in analysistest.target_actions(env)]
    asserts.equals(env, 1, _count(mnemonics, "DartKernelLink"), "modules are linked: %s" % mnemonics)
    asserts.equals(env, 0, _count(mnemonics, "DartLinkCheck"), "no validation in kernel mode")
    return analysistest.end(env)

_source_kernel_test = analysistest.make(_kernel_impl, config_settings = pruned_inputs_settings())

def _refusal_impl(ctx):
    """Runs the validation command on the closure; the action fails unless the tool refuses it."""
    tools = kernel_tools_for(ctx)
    if tools == None:
        fail("%s: no exec tools toolchain" % ctx.label)
    tool = ctx.executable._link_check
    srcs = depset(direct = [ctx.file.main], transitive = [collect_transitive_srcs(ctx.attr.deps)])
    stamp = ctx.actions.declare_file(ctx.label.name + ".stamp")
    stderr = ctx.actions.declare_file(ctx.label.name + ".stderr")
    ctx.actions.run_shell(
        command = '"$@" 2>"$OUT"; rc=$?; [ "$rc" = 1 ] || { echo "link_check exited $rc, wanted 1" >&2; exit 1; }; : >"$STAMP"',
        arguments = [tools.dartaotruntime.path, tool.path, link_check_args(ctx, "//dart/tests/link_modules:refused", srcs, stamp)],
        env = {"OUT": stderr.path, "STAMP": stamp.path},
        inputs = depset(direct = [tool], transitive = [srcs]),
        tools = [tools.dartaotruntime],
        outputs = [stderr, stamp],
        mnemonic = "DartLinkCheckRefusal",
        toolchain = EXEC_TOOLS_TOOLCHAIN,
    )
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    checks = "\n".join(['grep -F -- %s "$f" || { echo "missing: %s" >&2; cat "$f" >&2; exit 1; }' % (_quote(e), e.replace('"', "")) for e in ctx.attr.expect])
    ctx.actions.write(
        output = script,
        content = '#!/bin/sh\nf="$TEST_SRCDIR/%s/%s"\n%s\n' % (ctx.workspace_name, stderr.short_path, checks),
        is_executable = True,
    )
    return [DefaultInfo(executable = script, runfiles = ctx.runfiles(files = [stderr]))]

def _quote(text):
    """Single-quotes [text] for a POSIX shell."""
    return "'" + text.replace("'", "'\\''") + "'"

link_check_refusal_test = rule(
    implementation = _refusal_impl,
    doc = "Runs the `link_modules` validation tool over a dependency closure and asserts it refuses it, with the expected lines.",
    attrs = {
        "deps": attr.label_list(doc = "The closure to check.", providers = [DartInfo]),
        "main": attr.label(doc = "The binary's main file.", allow_single_file = [".dart"], mandatory = True),
        "expect": attr.string_list(doc = "Substrings the tool's stderr must contain."),
        "_link_check": attr.label(default = LINK_CHECK_TOOL, executable = True, cfg = "exec"),
    },
    test = True,
    toolchains = MODULAR_KERNEL_TOOLCHAINS,
)
