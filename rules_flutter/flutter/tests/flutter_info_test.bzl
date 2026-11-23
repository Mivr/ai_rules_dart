"""Tests for `flutter_info()` as the rules that produce `FlutterInfo` use it.

`contributing_library` stands in for `flutter_library` / `flutter_plugin`: a
rule that contributes on several channels at once and reaches `FlutterInfo`
only through the constructor. `single_channel_library` stands in for
`flutter_native_asset` / `flutter_data_asset` / `flutter_material_icons`, which
contribute on exactly one channel and forward nothing.

The claim under test: a caller gets every dependency's contribution on every
channel without naming any field, so adding a field to `FlutterInfo` cannot
silently drop what dependencies put there.

The mixed-deps case is the other half: a `deps` list may legally hold targets
with no `FlutterInfo` at all — a plain `dart_library` — and the constructor has
to skip those rather than fail on them.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:defs.bzl", "dart_library")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "dart_info", "dart_info_no_package", "dart_package_identity")
load("//flutter:providers.bzl", "FlutterInfo")
load("//flutter/private:flutter_info.bzl", "collect_flutter_plugin_deps", "flutter_asset_channels", "flutter_info", "flutter_pub_channels")

visibility(["//flutter/tests/..."])

def _contributing_library_impl(ctx):
    return [
        DefaultInfo(files = depset(ctx.files.assets)),
        dart_info_no_package(),
        flutter_info(
            deps = ctx.attr.deps,
            plugins = [
                struct(name = n, platforms = {})
                for n in ctx.attr.plugin_names
            ],
            asset_channels = flutter_asset_channels(
                asset_dirs = ctx.files.assets,
            ),
            pub_channels = flutter_pub_channels(
                pub_assets = [
                    struct(package_name = ctx.attr.pkg, asset_path = "a", file = None),
                ],
            ),
        ),
    ]

contributing_library = rule(
    implementation = _contributing_library_impl,
    attrs = {
        "assets": attr.label_list(allow_files = True),
        "plugin_names": attr.string_list(),
        "pkg": attr.string(mandatory = True),
        "deps": attr.label_list(providers = [DartInfo]),
    },
    doc = "A multi-channel producer of `FlutterInfo`, built through `flutter_info()`.",
)

def _single_channel_library_impl(ctx):
    return [
        DefaultInfo(files = depset()),
        dart_info_no_package(),
        # Tuples, not lists: these structs live in a depset, whose elements
        # must be immutable. The real `pub_fonts` contributions are built the
        # same way.
        flutter_info(pub_channels = flutter_pub_channels(pub_fonts = [
            struct(package_name = "", family = ctx.attr.family, fonts = (), files = ()),
        ])),
    ]

single_channel_library = rule(
    implementation = _single_channel_library_impl,
    attrs = {"family": attr.string(mandatory = True)},
    doc = "A one-channel producer that forwards nothing, like `flutter_material_icons`.",
)

def _field(structs, name):
    return sorted([getattr(s, name) for s in structs.to_list()])

def _short_paths(dep):
    return sorted([f.short_path for f in dep.to_list()])

def _forwards_every_channel_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[FlutterInfo]

    # The channels this target contributes on carry its own value *and* the
    # dependency's. A merge that took only `direct` would pass an
    # own-contribution check and still drop every dependency.
    assets = _short_paths(info.asset_dirs)
    asserts.true(
        env,
        [p for p in assets if p.endswith("_own.png")] != [],
        "own asset missing from asset_dirs: %s" % assets,
    )
    asserts.true(
        env,
        [p for p in assets if p.endswith("_dep.png")] != [],
        "dependency's asset missing from asset_dirs: %s" % assets,
    )
    asserts.equals(env, ["dep_plugin", "own_plugin"], sorted([p.name for p in info.plugins]))
    asserts.equals(env, ["dep_pkg", "own_pkg"], _field(info.pub_assets, "package_name"))

    # A channel neither target contributes on is still a real, empty depset —
    # consumers read it unguarded.
    asserts.equals(env, [], info.data_assets.to_list())

    return analysistest.end(env)

forwards_every_channel_test = analysistest.make(_forwards_every_channel_test_impl)

def _forwards_unknown_channel_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[FlutterInfo]

    # `contributing_library` passes nothing for `pub_fonts`; its dependency
    # contributes one. Because
    # forwarding is the constructor's job, the value survives a caller that has
    # never heard of the channel.
    asserts.equals(env, ["MaterialIcons"], _field(info.pub_fonts, "family"))

    return analysistest.end(env)

forwards_unknown_channel_test = analysistest.make(_forwards_unknown_channel_test_impl)

def _skips_deps_without_flutter_info_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[FlutterInfo]

    # One dep is a plain `dart_library`: `DartInfo`, no `FlutterInfo`. Analysis
    # reaching this point at all is the assertion — reading the provider off it
    # would fail — and the sibling dep's contribution must still arrive.
    asserts.equals(env, ["dep_plugin"], sorted([p.name for p in info.plugins]))

    return analysistest.end(env)

skips_deps_without_flutter_info_test = analysistest.make(
    _skips_deps_without_flutter_info_test_impl,
)

def _single_channel_test_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[FlutterInfo]

    asserts.equals(env, ["MaterialIcons"], _field(info.pub_fonts, "family"))

    # Every other channel is empty rather than absent. `flutter_application`
    # reads them all off every dep, so a missing one is an analysis error and an
    # empty one is the honest "contributes nothing here".
    asserts.equals(env, [], info.asset_dirs.to_list())
    asserts.equals(env, [], info.plugins)
    asserts.equals(env, [], info.native_assets.to_list())
    asserts.equals(env, [], info.apple_privacy_manifests.to_list())

    return analysistest.end(env)

single_channel_test = analysistest.make(_single_channel_test_impl)

_CollectedPluginsInfo = provider(
    doc = "The plugin list an application collects from its deps.",
    fields = {"plugins": "List of plugin structs, as `collect_flutter_plugin_deps` returns them."},
)

def _graph_node_impl(ctx):
    return [
        DefaultInfo(),
        dart_info(
            label = ctx.label,
            package = dart_package_identity(
                package_name = ctx.label.name,
                lib_root = "",
                language_version = "",
                version = ctx.attr.version,
            ),
            deps = ctx.attr.deps,
        ),
        flutter_info(
            deps = ctx.attr.deps,
            plugins = [struct(name = ctx.attr.plugin, platforms = {}, implements = "")] if ctx.attr.plugin else [],
        ),
    ]

graph_node = rule(
    implementation = _graph_node_impl,
    attrs = {
        "deps": attr.label_list(providers = [DartInfo]),
        "plugin": attr.string(doc = "Name of the plugin this node is, or empty for a library."),
        "version": attr.string(doc = "A pub-resolved version for a third-party pub package, or empty for app-owned code."),
    },
    doc = "A node of a `FlutterInfo` graph: a plugin or a library, app-owned or from pub.",
)

def _application_collector_impl(ctx):
    return [
        DefaultInfo(),
        _CollectedPluginsInfo(plugins = collect_flutter_plugin_deps(ctx.attr.deps).all_plugins),
    ]

application_collector = rule(
    implementation = _application_collector_impl,
    attrs = {"deps": attr.label_list(providers = [DartInfo])},
    doc = "Collects plugins from `deps` the way `flutter_application` does.",
)

def _direct_marks_test_impl(ctx):
    env = analysistest.begin(ctx)
    plugins = analysistest.target_under_test(env)[_CollectedPluginsInfo].plugins
    direct = sorted([p.name for p in plugins if getattr(p, "direct", False)])
    asserts.equals(env, sorted(ctx.attr.direct), direct)
    asserts.equals(env, sorted(ctx.attr.plugins), sorted([p.name for p in plugins]))
    return analysistest.end(env)

direct_marks_test = analysistest.make(
    _direct_marks_test_impl,
    attrs = {
        "direct": attr.string_list(doc = "The plugins expected to be direct."),
        "plugins": attr.string_list(doc = "Every plugin expected to be collected."),
    },
)

def _graph_tests(name):
    """Defines the direct-mark tests over small plugin graphs."""
    t = ["manual"]
    n = lambda x: ":" + name + "_" + x
    graph_node(name = name + "_sp", plugin = "sp", tags = t)
    graph_node(name = name + "_alt", plugin = "alt", tags = t)

    # An app-owned wrapper and a pub-package wrapper, each depending on `alt`.
    graph_node(name = name + "_a_wrapper", deps = [n("alt")], tags = t)
    graph_node(name = name + "_pub_wrapper", deps = [n("alt")], version = "1.0.0", tags = t)

    # Every order of the same three deps, behind one app-owned library.
    graph_node(name = name + "_lib_wrapper_first", deps = [n("a_wrapper"), n("alt"), n("sp")], tags = t)
    graph_node(name = name + "_lib_alt_first", deps = [n("alt"), n("a_wrapper"), n("sp")], tags = t)
    application_collector(name = name + "_app_pub_wrapper", deps = [n("sp"), n("pub_wrapper")], tags = t)
    application_collector(name = name + "_app_owned_wrapper", deps = [n("sp"), n("a_wrapper")], tags = t)
    application_collector(name = name + "_app_lib_wrapper_first", deps = [n("lib_wrapper_first")], tags = t)
    application_collector(name = name + "_app_lib_alt_first", deps = [n("lib_alt_first")], tags = t)
    both = ["alt", "sp"]
    for case, direct in {
        "pub_wrapper": ["sp"],
        "owned_wrapper": both,
        "lib_wrapper_first": both,
        "lib_alt_first": both,
    }.items():
        direct_marks_test(
            name = name + "_direct_" + case,
            target_under_test = n("app_" + case),
            direct = direct,
            plugins = both,
        )
    return [n("direct_" + case) for case in ["pub_wrapper", "owned_wrapper", "lib_wrapper_first", "lib_alt_first"]]

def flutter_info_test_suite(name):
    """Defines the `flutter_info()` constructor tests.

    Args:
        name: Name of the resulting test_suite.
    """
    native.genrule(
        name = name + "_own_asset",
        outs = [name + "_own.png"],
        cmd = "touch $@",
    )
    native.genrule(
        name = name + "_dep_asset",
        outs = [name + "_dep.png"],
        cmd = "touch $@",
    )

    contributing_library(
        name = name + "_dep",
        assets = [name + "_dep.png"],
        plugin_names = ["dep_plugin"],
        pkg = "dep_pkg",
        tags = ["manual"],
    )
    contributing_library(
        name = name + "_own",
        assets = [name + "_own.png"],
        plugin_names = ["own_plugin"],
        pkg = "own_pkg",
        deps = [":" + name + "_dep"],
        tags = ["manual"],
    )
    forwards_every_channel_test(
        name = name + "_forwards_every_channel",
        target_under_test = ":" + name + "_own",
    )

    single_channel_library(
        name = name + "_icons",
        family = "MaterialIcons",
        tags = ["manual"],
    )
    single_channel_test(
        name = name + "_single_channel",
        target_under_test = ":" + name + "_icons",
    )

    contributing_library(
        name = name + "_font_consumer",
        pkg = "consumer",
        deps = [":" + name + "_icons"],
        tags = ["manual"],
    )
    forwards_unknown_channel_test(
        name = name + "_forwards_unknown_channel",
        target_under_test = ":" + name + "_font_consumer",
    )

    dart_library(
        name = name + "_plain_dart",
        package_name = "plain_dart",
        tags = ["manual"],
    )
    contributing_library(
        name = name + "_mixed",
        pkg = "mixed",
        deps = [":" + name + "_dep", ":" + name + "_plain_dart"],
        tags = ["manual"],
    )
    skips_deps_without_flutter_info_test(
        name = name + "_skips_deps_without_flutter_info",
        target_under_test = ":" + name + "_mixed",
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_forwards_every_channel",
            ":" + name + "_single_channel",
            ":" + name + "_forwards_unknown_channel",
            ":" + name + "_skips_deps_without_flutter_info",
        ] + _graph_tests(name),
    )
