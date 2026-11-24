"""Tests that every Apple plugin of one configuration shares one Flutter engine import.

`flutter_apple_plugin_library` on the `rules_apple` backend depends on the one
engine import and module-map wrapper per platform in `//flutter/private`, never
on a `_<plugin>__flutter_framework` pair of its own. A plugin compile receives
only the xcframework slice it builds for, and still sees the engine module map
that `@import Flutter;` needs.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//flutter:ios.bzl", _ios_plugin = "flutter_apple_plugin_library")
load("//flutter:macos.bzl", _macos_plugin = "flutter_apple_plugin_library")

visibility(["//flutter/tests/..."])

# The label form `native.existing_rules()` reports for a dep in the main repository.
_IOS_ENGINE = "//flutter/private:apple_engine_framework_ios"
_MACOS_ENGINE = "//flutter/private:apple_engine_framework_macos"

def _shared_engine_test_impl(ctx):
    """Every plugin names the platform's one engine wrapper and none emits its own."""
    env = unittest.begin(ctx)
    asserts.equals(env, [], ctx.attr.per_plugin_framework_rules, "no per-plugin framework rule may exist")
    for dep, plugin in zip(ctx.attr.engine_deps, ctx.attr.plugins):
        asserts.equals(env, ctx.attr.expected_engine, dep, "%s must use the shared engine wrapper" % plugin)
    asserts.true(env, len(ctx.attr.plugins) > 1, "the test needs at least two plugins")
    return unittest.end(env)

_shared_engine_test = unittest.make(
    _shared_engine_test_impl,
    attrs = {
        "engine_deps": attr.string_list(mandatory = True),
        "expected_engine": attr.string(mandatory = True),
        "per_plugin_framework_rules": attr.string_list(),
        "plugins": attr.string_list(mandatory = True),
    },
)

def _engine_inputs_test_impl(ctx):
    """The plugin compile gets one engine slice's headers and the engine module map.

    A compile stages the `CcInfo` headers of its deps, so those are its engine inputs.
    """
    env = analysistest.begin(ctx)
    tut = analysistest.target_under_test(env)
    paths = [f.path for f in tut[CcInfo].compilation_context.headers.to_list()]
    engine = [p for p in paths if ctx.attr.engine_marker in p]
    asserts.true(env, engine, "the compile has no engine input: %s" % paths)
    slices = {p.split(ctx.attr.engine_marker)[1].split("/")[0]: True for p in engine} if ctx.attr.sliced else {}
    expected = 1 if ctx.attr.sliced else 0
    asserts.equals(env, expected, len(slices), "engine slices in the compile inputs: %s" % slices.keys())
    asserts.true(
        env,
        any([p.endswith(ctx.attr.modulemap_suffix) for p in engine]),
        "`@import Flutter;` needs %s among the compile inputs: %s" % (ctx.attr.modulemap_suffix, engine),
    )
    return analysistest.end(env)

def _engine_inputs_attrs():
    return {
        "engine_marker": attr.string(mandatory = True),
        "modulemap_suffix": attr.string(mandatory = True),
        "sliced": attr.bool(default = False),
    }

def _config(platform):
    return {
        "//command_line_option:extra_execution_platforms": [str(Label("//flutter/platforms:macos_arm64"))],
        "//command_line_option:platforms": str(Label("//flutter/platforms:%s_arm64" % platform)),
        "//command_line_option:xcode_version_config": str(Label("//flutter/tests:ios_test_fake_xcode_config")),
        str(Label("//flutter:profile")): False,
    }

_ios_engine_inputs_test = analysistest.make(
    _engine_inputs_test_impl,
    attrs = _engine_inputs_attrs(),
    config_settings = _config("ios"),
)
_macos_engine_inputs_test = analysistest.make(
    _engine_inputs_test_impl,
    attrs = _engine_inputs_attrs(),
    config_settings = _config("macos"),
)

def apple_shared_engine_test_suite(name):
    """Declares plugins of one app on both platforms and the tests over them.

    Args:
        name: Prefix for every target declared here.
    """
    content = ["int " + name + "(void) { return 1; }"]
    write_file(name = name + "_m", out = name + ".m", content = content, tags = ["manual"])
    write_file(name = name + "_swift", out = name + ".swift", content = ["public func f() {}"], tags = ["manual"])
    plugins = {}
    for platform, macro in (("ios", _ios_plugin), ("macos", _macos_plugin)):
        for kind, src in (("a", name + ".m"), ("b", name + ".m"), ("swift", name + ".swift")):
            plugin = "%s_%s_%s" % (name, platform, kind)
            macro(name = plugin, srcs = [src], module_name = plugin, platform = platform, tags = ["manual"])
            plugins.setdefault(platform, []).append(plugin)

    rules = native.existing_rules()
    tests = []
    for platform, engine in (("ios", _IOS_ENGINE), ("macos", _MACOS_ENGINE)):
        names = plugins[platform]
        prefix = "_%s_%s" % (name, platform)
        deps = [
            str(rules[p if p.endswith("_swift") else "_%s__objc" % p]["deps"][0])
            for p in names
        ]
        _shared_engine_test(
            name = "%s_%s_shared_engine" % (name, platform),
            plugins = names,
            engine_deps = deps,
            expected_engine = engine,
            per_plugin_framework_rules = [k for k in rules if k.startswith(prefix) and "__flutter_framework" in k],
        )
        tests.append(":%s_%s_shared_engine" % (name, platform))

    for kind, target in (("objc", "_%s_ios_a__objc"), ("swift", "%s_ios_swift")):
        _ios_engine_inputs_test(
            name = "%s_ios_%s_engine_inputs" % (name, kind),
            target_under_test = ":" + target % name,
            engine_marker = "Flutter.xcframework/",
            modulemap_suffix = "Flutter.framework/Modules/module.modulemap",
            sliced = True,
        )
        tests.append(":%s_ios_%s_engine_inputs" % (name, kind))
    _macos_engine_inputs_test(
        name = name + "_macos_objc_engine_inputs",
        target_under_test = ":_%s_macos_a__objc" % name,
        engine_marker = "FlutterMacOS.framework/",
        modulemap_suffix = "FlutterMacOS.framework/Modules/module.modulemap",
    )
    tests.append(":" + name + "_macos_objc_engine_inputs")
    native.test_suite(name = name, tests = tests)
