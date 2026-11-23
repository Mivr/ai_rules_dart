"""The SDK `flutter` module has a registrant twin, a helper swaps it in, and the swap links."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@rules_dart//dart:utils.bzl", "kernel_link_action")
load("//flutter:utils.bzl", "FLUTTER_MODULAR_KERNEL_ATTRS", "FLUTTER_MODULAR_KERNEL_TOOLCHAINS")
load(
    "//flutter/private:flutter_kernel_module.bzl",
    "FlutterKernelModuleInfo",
    "flutter_kernel_module_aspect",
    "swap_flutter_registrant_twin",
)

visibility(["//flutter/tests/..."])

_DEFINE = "flutter.dart_plugin_registrant="
_URI = "org-dartlang-app:///_flutter_debug_agent/plugin_registrant.dart"
_DBG = {
    "//command_line_option:compilation_mode": "dbg",
    str(Label("//flutter:profile")): False,
}
_FIXTURE = "//flutter/tests/registrant_twin_fixture"

_ActionsInfo = provider(
    doc = "The actions registered for the target by the kernel module aspect.",
    fields = ["actions"],
)

def _inspect_impl(target, _ctx):
    """Exposes the target's actions."""
    return [_ActionsInfo(actions = target.actions)]

_inspect_aspect = aspect(
    implementation = _inspect_impl,
    requires = [flutter_kernel_module_aspect],
    doc = "Exposes the actions of the target, the kernel module aspect's among them.",
)

def _compiles(env):
    """The debug module compiles registered for the target under test."""
    actions = analysistest.target_under_test(env)[_ActionsInfo].actions
    return [a for a in actions if a.mnemonic == "DartKernel" and "_product" not in _out(a)]

def _out(action):
    """The `.kmod` directory an action writes."""
    return [f.basename for f in action.outputs.to_list() if f.basename.endswith(".kmod")][0]

def _input_paths(action):
    """The action's input paths, the twin's output stem mapped to the plain one."""
    return [f.path.replace(".flutter_registrant.", ".flutter.") for f in action.inputs.to_list()]

def _twin_impl(ctx):
    """The SDK flutter package has a twin with the define; the plain module is unchanged."""
    env = analysistest.begin(ctx)
    by_out = {_out(a): a for a in _compiles(env)}
    asserts.equals(env, ["flutter.flutter.kmod", "flutter.flutter_registrant.kmod"], sorted(by_out.keys()))
    plain = by_out.get("flutter.flutter.kmod")
    twin = by_out.get("flutter.flutter_registrant.kmod")
    if plain and twin:
        asserts.equals(env, [], [a for a in plain.argv if _DEFINE in a], "the plain module takes no registrant define")
        defines = [a for a in twin.argv if a.endswith(_DEFINE + _URI)]
        asserts.equals(env, 1, len(defines), "the twin carries the define once")
        rest = [a.replace(".flutter_registrant.", ".flutter.") for a in twin.argv if _DEFINE not in a]
        asserts.equals(env, plain.argv, rest, "the twin differs from the plain module by the define and outputs")
        asserts.equals(env, _input_paths(plain), _input_paths(twin), "the twin reads the plain module's inputs")
        names = [f.basename for f in twin.outputs.to_list()]
        asserts.true(env, not any([n.startswith("flutter.flutter.") for n in names]), "distinct outputs: %r" % names)
    groups = analysistest.target_under_test(env)[OutputGroupInfo]
    in_group = [f.basename for f in groups.flutter_registrant_twin.to_list()]
    asserts.true(env, "flutter.flutter_registrant.kmod" in in_group, "the twin is in its output group: %r" % in_group)
    default = [f.basename for f in analysistest.target_under_test(env)[DefaultInfo].files.to_list()]
    asserts.true(env, not any(["registrant" in n for n in default]), "a default build does not build the twin")
    return analysistest.end(env)

def _no_twin_impl(ctx):
    """A package other than the SDK flutter has no twin."""
    env = analysistest.begin(ctx)
    outs = [_out(a) for a in _compiles(env)]
    asserts.equals(env, ["other.flutter.kmod"], outs, "only the SDK flutter package has a twin")
    asserts.false(env, hasattr(analysistest.target_under_test(env)[OutputGroupInfo], "flutter_registrant_twin"))
    return analysistest.end(env)

_twin_test = analysistest.make(
    _twin_impl,
    config_settings = _DBG,
    extra_target_under_test_aspects = [_inspect_aspect],
)
_no_twin_test = analysistest.make(
    _no_twin_impl,
    config_settings = _DBG,
    extra_target_under_test_aspects = [_inspect_aspect],
)

def _swap_impl(ctx):
    """The helper swaps the plain module for the twin, and returns the closure unchanged without one."""
    env = unittest.begin(ctx)
    closure = depset(["a", "flutter", "b"], order = "postorder")
    twins = depset([struct(plain = "flutter", kmod = "twin")])
    asserts.equals(env, ["a", "twin", "b"], swap_flutter_registrant_twin(closure, twins).to_list())
    asserts.true(env, swap_flutter_registrant_twin(closure, None) == closure, "no twins: unchanged")
    asserts.true(env, swap_flutter_registrant_twin(closure, depset()) == closure, "empty twins: unchanged")
    other = depset([struct(plain = "elsewhere", kmod = "twin")])
    asserts.equals(env, ["a", "flutter", "b"], swap_flutter_registrant_twin(closure, other).to_list())
    return unittest.end(env)

_swap_test = unittest.make(_swap_impl)

def _link_impl(ctx):
    """Links the dependant over the plain closure and over the swapped one."""
    info = ctx.attr.deps[0][FlutterKernelModuleInfo]
    kernel = info.kernel_info
    outs = {}
    for name, closure in [
        ("plain", kernel.transitive_kmods),
        ("swapped", swap_flutter_registrant_twin(kernel.transitive_kmods, info.registrant_twins)),
    ]:
        outs[name] = ctx.actions.declare_file("%s.%s.dill" % (ctx.label.name, name))
        kernel_link_action(ctx, closure, None, outs[name], seed_modules = [kernel.kmod])
    return [
        DefaultInfo(files = depset(outs.values())),
        OutputGroupInfo(plain = depset([outs["plain"]]), swapped = depset([outs["swapped"]])),
    ]

_link = rule(
    implementation = _link_impl,
    attrs = FLUTTER_MODULAR_KERNEL_ATTRS,
    toolchains = FLUTTER_MODULAR_KERNEL_TOOLCHAINS,
    doc = "Links the first dep twice: over its plain closure and over the one with the twin swapped in.",
)

def registrant_twin_test_suite(name):
    """Declares the registrant twin tests and the link fixture; the link check is `registrant_twin_link_test`.

    Args:
        name: The test_suite name.
    """
    _twin_test(name = name + "_twin", target_under_test = _FIXTURE + "/flutter")
    _no_twin_test(name = name + "_no_twin", target_under_test = _FIXTURE + "/other")
    _swap_test(name = name + "_swap")
    _link(name = "registrant_twin_links", deps = [_FIXTURE + "/app"], tags = ["manual"])
    for group in ["plain", "swapped"]:
        native.filegroup(
            name = "registrant_twin_" + group,
            srcs = [":registrant_twin_links"],
            output_group = group,
            tags = ["manual"],
        )
    native.test_suite(name = name, tests = [name + "_twin", name + "_no_twin", name + "_swap"])
