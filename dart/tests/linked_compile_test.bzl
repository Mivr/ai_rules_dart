"""`exe` and `aot-snapshot` binaries compile from linked per-library kernels.

For a modular-eligible `dart_binary` the whole-program front end reads the
linked kernel (`gen_kernel --from-dill`), so a body edit in one library
recompiles that module only and no `.dart` source is an input of the
whole-program steps. Each case the SDK cannot take a linked kernel for keeps
the source path: `defines`, `dart_compile_flags`, native code assets,
`modular_kernel = False` (attribute and build setting), a closure that names
one package at two roots, and the `dbg` compilation mode, whose `--enable-asserts`
the modules cannot carry.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart:defs.bzl", "DartCodeAssetInfo", "dart_binary", "dart_library")
load(":pruned_inputs.bzl", "pruned_inputs_settings")

visibility(["//dart/..."])

_CHAIN = ["//dart/tests/modular_chain_fixture/chain_top"]

def _dart_inputs(action):
    """The `.dart` input paths of an action."""
    return [f.path for f in action.inputs.to_list() if f.extension == "dart"]

def _from_dill_actions(actions):
    """The `DartKernel` actions that read a linked kernel through `--from-dill`."""
    return [a for a in actions if a.mnemonic == "DartKernel" and [x for x in a.argv if x.startswith("--from-dill=")]]

def _linked_test_impl(ctx):
    """The modules are linked and the whole-program steps read no `.dart` source."""
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)

    links = [a for a in actions if a.mnemonic == "DartKernelLink"]
    asserts.equals(env, 1, len(links), "one DartKernelLink action links the modules")
    link_inputs = [f.basename for f in links[0].inputs.to_list()] if links else []
    for want in ["chain_leaf.kmod", "chain_mid.kmod", "chain_top.kmod"]:
        asserts.true(env, want in link_inputs, "the link consumes %s: %s" % (want, link_inputs))
    asserts.true(env, "--platform" in (links[0].argv if links else []), "the link prepends the platform")

    front_ends = _from_dill_actions(actions)
    asserts.equals(env, 1, len(front_ends), "one whole-program front end reads the linked kernel")
    if front_ends:
        argv = front_ends[0].argv
        for flag in ["--aot", "--tfa", "--no-embed-sources"]:
            asserts.true(env, flag in argv, "the front end passes %s: %s" % (flag, argv))
        asserts.equals(env, [], _dart_inputs(front_ends[0]), "no .dart source is an input of the front end")
        asserts.false(env, "--packages" in argv, "the front end reads no package config")

    compiles = [a for a in actions if a.mnemonic == "DartCompile"]
    asserts.equals(env, 1, len(compiles), "one dart compile step")
    for compile in compiles:
        asserts.equals(env, [], _dart_inputs(compile), "no .dart source is an input of the dart compile step")
    return analysistest.end(env)

_linked_test = analysistest.make(_linked_test_impl, config_settings = pruned_inputs_settings())

def _fallback_test_impl(ctx):
    """The source path is kept: no link, and a front end that reads sources."""
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    asserts.equals(
        env,
        [],
        [a.mnemonic for a in actions if a.mnemonic == "DartKernelLink"],
        "no module is linked on the source path",
    )
    asserts.equals(env, [], _from_dill_actions(actions), "the front end does not read a linked kernel")
    kernels = [a for a in actions if a.mnemonic == "DartKernel"]
    asserts.equals(env, 1, len(kernels), "one whole-program source front end")
    if kernels:
        asserts.true(env, "--tfa" in kernels[0].argv, "the source front end tree-shakes: %s" % kernels[0].argv)
        asserts.true(env, _dart_inputs(kernels[0]) != [], "the source front end reads .dart sources")
    return analysistest.end(env)

_fallback_test = analysistest.make(_fallback_test_impl, config_settings = pruned_inputs_settings())
_dbg_fallback_test = analysistest.make(
    _fallback_test_impl,
    config_settings = pruned_inputs_settings({"//command_line_option:compilation_mode": "dbg"}),
)
_modular_off_fallback_test = analysistest.make(
    _fallback_test_impl,
    config_settings = pruned_inputs_settings({str(Label("//dart:modular_kernel")): False}),
)

def _dummy_asset_impl(ctx):
    """A code asset over a placeholder library file."""
    out = ctx.actions.declare_file(ctx.label.name + ".so")
    ctx.actions.write(output = out, content = "fake-so\n")
    return [
        DefaultInfo(files = depset([out])),
        DartCodeAssetInfo(
            asset_id = "package:linked_fixture/ffi.dart",
            link_mode = "dynamic_loading_bundle",
            dynamic_library = out,
            system_uri = "",
        ),
    ]

_dummy_asset = rule(implementation = _dummy_asset_impl, doc = "A code asset with a placeholder library.")

def _fixtures(name, mode, extra):
    """Declares the manual fixture `<name>_<mode>_<case>` per case and returns case -> label.

    Args:
      name: Suite name prefix.
      mode: The `compile_mode` of every fixture.
      extra: Case name -> the `dart_binary` attrs that force that fallback.

    Returns:
      The dict of case name to fixture label.
    """
    labels = {}
    for case, attrs in dict({"linked": {}}, **extra).items():
        fixture = "%s_%s_%s" % (name, mode.replace("-", "_"), case)
        dart_binary(
            name = fixture,
            compile_mode = mode,
            main = "//dart/private/tools:noop.dart",
            deps = _CHAIN + attrs.pop("extra_deps", []),
            tags = ["manual"],
            **attrs
        )
        labels[case] = ":" + fixture
    return labels

def linked_compile_test_suite(name):
    """Declares the linked-kernel compile tests as one suite.

    Args:
      name: Name of the generated `test_suite`.
    """
    _dummy_asset(name = name + "_asset", tags = ["manual"])
    dart_library(
        name = name + "_conflict_lib",
        package_name = "chain_leaf",
        srcs = [],
        tags = ["manual"],
    )
    tests = []
    for mode in ["exe", "aot-snapshot"]:
        labels = _fixtures(name, mode, {
            "defines": {"defines": ["LINKED=1"]},
            "flags": {"dart_compile_flags": ["--extra-gen-snapshot-options=--optimization_level=3"]},
            "assets": {"code_assets": [":" + name + "_asset"]},
            "not_modular": {"modular_kernel": False},
            "conflict": {"extra_deps": [":" + name + "_conflict_lib"]},
            "dbg": {},
            "flag_off": {},
        })
        suffix = mode.replace("-", "_")
        _linked_test(name = "%s_%s_linked_test" % (name, suffix), target_under_test = labels["linked"], size = "small")
        tests.append(":%s_%s_linked_test" % (name, suffix))
        for case in ["defines", "flags", "assets", "not_modular", "conflict"]:
            _fallback_test(name = "%s_%s_%s_test" % (name, suffix, case), target_under_test = labels[case], size = "small")
            tests.append(":%s_%s_%s_test" % (name, suffix, case))
        _dbg_fallback_test(name = "%s_%s_dbg_test" % (name, suffix), target_under_test = labels["dbg"], size = "small")
        _modular_off_fallback_test(
            name = "%s_%s_flag_off_test" % (name, suffix),
            target_under_test = labels["flag_off"],
            size = "small",
        )
        tests.extend([":%s_%s_dbg_test" % (name, suffix), ":%s_%s_flag_off_test" % (name, suffix)])
    native.test_suite(name = name, tests = tests)
