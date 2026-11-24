"""A merged pub dependency cycle is one Flutter kernel module.

The merged `dart_library` (`members`) compiles into one module that owns every
member's sources and carries every member's package record; each member's
public target (`flutter_pub_scc_member_target`) is that module and compiles
none of its own. Every source has one owner, the merged library.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//flutter/private:flutter_kernel_module.bzl", "FlutterKernelModuleInfo", "flutter_kernel_module_aspect")

visibility(["//flutter/tests/..."])

_DBG = {
    "//command_line_option:compilation_mode": "dbg",
    str(Label("//flutter:profile")): False,
}
_FIXTURE = "//flutter/tests/scc_module_fixture"
_SOURCES = ["package:scc_module_a/a.dart", "package:scc_module_b/b.dart"]
_FILES = ["flutter/tests/scc_module_fixture/a/lib/a.dart", "flutter/tests/scc_module_fixture/b/lib/b.dart"]

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
    """The Flutter module compiles registered for the target under test (a `dart_library`'s own VM module aside)."""
    return [
        a
        for a in analysistest.target_under_test(env)[_ActionsInfo].actions
        if a.mnemonic == "DartKernel" and [f for f in a.outputs.to_list() if f.basename.endswith(".flutter.kmod")]
    ]

def _flag_values(argv, flag):
    """Every value that follows `flag` in `argv`."""
    return [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == flag]

def _merged_impl(ctx):
    """One module over both members' sources, with both members' records first."""
    env = analysistest.begin(ctx)
    compiles = _compiles(env)
    asserts.equals(env, 1, len(compiles), "the merged cycle compiles one module")
    if compiles:
        action = compiles[0]
        outs = [f.basename for f in action.outputs.to_list() if f.basename.endswith(".kmod")]
        asserts.equals(env, ["merged.flutter.kmod"], outs)
        asserts.equals(env, _SOURCES, sorted(_flag_values(action.argv, "--source")), "every member's source, named by its member's package")
        records = _flag_values(action.argv, "--record")
        own = sorted([r.split("|")[0] for r in records[:2]])
        asserts.equals(env, ["scc_module_a", "scc_module_b"], own, "both members' records come first: %s" % records)
        inputs = [f.short_path for f in action.inputs.to_list()]
        for path in _FILES:
            asserts.true(env, path in inputs, "the module reads %s" % path)
    kernel = analysistest.target_under_test(env)[FlutterKernelModuleInfo].kernel_info
    asserts.true(env, kernel.modular, "the merged cycle is modular: %s" % getattr(kernel, "not_modular", None))
    owners = {label: True for label, _path in kernel.owned.to_list()}
    asserts.equals(env, 1, len(owners), "one owner for every source: %s" % owners.keys())
    asserts.true(env, all([label.endswith("scc_module_fixture:merged") for label in owners]), "the owner is the merged library: %s" % owners.keys())
    return analysistest.end(env)

_merged_test = analysistest.make(_merged_impl, config_settings = _DBG, extra_target_under_test_aspects = [_inspect_aspect])

def _member_impl(ctx):
    """A member's target compiles nothing and is the merged library's module."""
    env = analysistest.begin(ctx)
    asserts.equals(env, [], _compiles(env), "a member compiles no module of its own")
    kernel = analysistest.target_under_test(env)[FlutterKernelModuleInfo].kernel_info
    asserts.true(env, kernel.modular, "a member is modular: %s" % getattr(kernel, "not_modular", None))
    asserts.true(env, kernel.kmod != None and kernel.kmod.basename == "merged.flutter.kmod", "a member is the merged module: %s" % kernel.kmod)
    return analysistest.end(env)

_member_test = analysistest.make(_member_impl, config_settings = _DBG, extra_target_under_test_aspects = [_inspect_aspect])

def scc_module_test_suite(name):
    """Declares the merged-cycle module tests.

    Args:
        name: The test_suite name.
    """
    _merged_test(name = name + "_merged", target_under_test = _FIXTURE + ":merged")
    tests = [name + "_merged"]
    for m in ["a", "b"]:
        _member_test(name = "%s_member_%s" % (name, m), target_under_test = "%s:member_%s" % (_FIXTURE, m))
        tests.append("%s_member_%s" % (name, m))
    native.test_suite(name = name, tests = tests)
