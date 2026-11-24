"""Analysis tests for defines as configuration.

A debug target's own environment (its `defines`, its flavor and its
`dart_defines`) is the configuration of its `deps` edge, so its dependency
modules compile with it. Bazel keys an action by its outputs, and a module's
outputs live in its configuration's output directory, so equal module output
paths are one set of module actions. The tests pin:

- two targets with equal settings, the defines written in another order,
  compile the same modules;
- a target with other settings compiles the same number of modules, all of
  them its own; so does a target with no settings, whose modules are the
  default configuration's, shared with every target that has none;
- two targets naming the same `dart_defines` target share modules, and two
  naming different targets with equal values do not;
- native code below the closure (a plugin's `native_deps`) is configured once:
  in the default configuration, whatever the environment above it, while the
  plugin's own Dart is configured with the environment.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:utils.bzl", "DartDefinesInfo")
load("//flutter/private:flutter_defines_files.bzl", "defines_transition")
load("//flutter/private:flutter_kernel_module.bzl", "FlutterKernelModuleInfo", "flutter_kernel_module_aspect")

visibility(["//flutter/tests/..."])

def _native_probe_impl(_ctx):
    return [DefaultInfo()]

native_probe = rule(
    implementation = _native_probe_impl,
    doc = "Stands in for native code below a plugin: a target whose configuration the tests read.",
)

_BinDirInfo = provider(doc = "The output directory of each target below.", fields = ["dirs"])

def _bin_dir_aspect_impl(target, ctx):
    transitive = [
        dep[_BinDirInfo].dirs
        for name in ("deps", "native_deps")
        for dep in getattr(ctx.rule.attr, name, [])
        if _BinDirInfo in dep
    ]
    return [_BinDirInfo(dirs = depset([(str(target.label), ctx.bin_dir.path)], transitive = transitive))]

_bin_dir_aspect = aspect(
    implementation = _bin_dir_aspect_impl,
    attr_aspects = ["deps", "native_deps"],
)

_ProbeInfo = provider(doc = "What one probe's closure compiled, and where.", fields = ["kmods", "bin_dirs"])

def _env_probe_impl(ctx):
    kmods = depset(transitive = [
        dep[FlutterKernelModuleInfo].kernel_info.transitive_kmods
        for dep in ctx.attr.deps
    ]).to_list()
    return [_ProbeInfo(
        kmods = sorted([f.path for f in kmods]),
        bin_dirs = dict(depset(transitive = [dep[_BinDirInfo].dirs for dep in ctx.attr.deps]).to_list()),
    )]

# A debug target reduced to what the tests read: the `deps` edge every Flutter
# target with an environment takes, and the module aspect over it.
_env_probe = rule(
    implementation = _env_probe_impl,
    attrs = {
        "deps": attr.label_list(
            cfg = defines_transition,
            aspects = [flutter_kernel_module_aspect, _bin_dir_aspect],
        ),
        "defines": attr.string_list(),
        "flavor": attr.string(),
        "dart_defines": attr.label(cfg = defines_transition, providers = [DartDefinesInfo]),
    },
)

_CompareInfo = provider(doc = "The probes, by name, and the default output directory.", fields = ["probes", "bin_dir"])

def _compare_impl(ctx):
    return [_CompareInfo(
        probes = {p.label.name: p[_ProbeInfo] for p in ctx.attr.probes},
        bin_dir = ctx.bin_dir.path,
    )]

_compare = rule(
    implementation = _compare_impl,
    attrs = {"probes": attr.label_list(providers = [_ProbeInfo])},
)

_PLUGIN = "//flutter/tests/defines_config_fixture:plugin"
_NATIVE = "//flutter/tests/defines_config_fixture:native"

def _defines_config_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[_CompareInfo]
    p = info.probes
    dev = p["_defines_config_dev"].kmods
    asserts.true(env, len(dev) > 0, "the probe's closure must compile modules")
    asserts.equals(env, dev, p["_defines_config_dev_twin"].kmods, "equal settings must share every module")
    for other in ["_defines_config_prod", "_defines_config_plain", "_defines_config_file_a"]:
        kmods = p[other].kmods
        asserts.equals(env, len(dev), len(kmods), "%s must compile the closure's modules once" % other)
        asserts.equals(env, [], [k for k in kmods if k in dev], "%s must share no module with other settings" % other)
    asserts.equals(
        env,
        p["_defines_config_file_a"].kmods,
        p["_defines_config_file_a_twin"].kmods,
        "targets naming the same dart_defines target must share every module",
    )
    asserts.equals(
        env,
        [],
        [k for k in p["_defines_config_file_b"].kmods if k in p["_defines_config_file_a"].kmods],
        "another dart_defines target is another configuration",
    )

    plugin = str(Label(_PLUGIN))
    native = str(Label(_NATIVE))
    for name, probe in p.items():
        asserts.equals(
            env,
            info.bin_dir,
            probe.bin_dirs.get(native),
            "%s: native code below the closure must keep the default configuration" % name,
        )
        if name != "_defines_config_plain":
            asserts.false(
                env,
                probe.bin_dirs.get(plugin) == info.bin_dir,
                "%s: the plugin's Dart must be configured with the environment" % name,
            )
    asserts.equals(env, info.bin_dir, p["_defines_config_plain"].bin_dirs.get(plugin))
    return analysistest.end(env)

_defines_config_test = analysistest.make(_defines_config_test_impl)

def defines_config_test_suite(name):
    """Fixtures and tests for defines as configuration.

    Args:
        name: The test suite name.
    """
    probes = {
        "_defines_config_plain": {},
        "_defines_config_dev": {"defines": ["B=2", "A=1"], "flavor": "dev"},
        "_defines_config_dev_twin": {"defines": ["A=1", "B=0", "B=2"], "flavor": "dev"},
        "_defines_config_prod": {"defines": ["A=1", "B=2"], "flavor": "prod"},
        "_defines_config_file_a": {"dart_defines": "//flutter/tests/defines_config_fixture:defines_a"},
        "_defines_config_file_a_twin": {"dart_defines": "//flutter/tests/defines_config_fixture:defines_a"},
        "_defines_config_file_b": {"dart_defines": "//flutter/tests/defines_config_fixture:defines_b"},
    }
    for probe, kwargs in probes.items():
        _env_probe(name = probe, deps = [_PLUGIN], tags = ["manual"], **kwargs)
    _compare(name = "_defines_config_compare", probes = [":" + n for n in probes], tags = ["manual"])
    _defines_config_test(name = name + "_shares_and_resets", target_under_test = ":_defines_config_compare")
    native.test_suite(name = name, tests = [":" + name + "_shares_and_resets"])
