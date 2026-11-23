"""Tests for the Android edge a pub plugin's Dart target carries.

The edge is how an app finds its plugins' Android libraries on the Dart graph.
It must be selected only under the Android platform (a non-Android build never
reaches the Android repository) and only for a plugin that declares Android.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_lock_hub.bzl",
    "hub_scc_dep_targets",
    "make_flutter_pub_hub_build_content",
    "make_hub_scc_android_edge_bzl_content",
    "overlay_with_android_edge",
)
load(
    "//flutter/private:flutter_pub_package.bzl",
    "make_flutter_library_build_content",
    "make_flutter_plugin_build_content",
)
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_EDGE = 'android_libs = select({"@platforms//os:android": ["//android:lib"], "//conditions:default": []}),'

def _plugin(platforms_json):
    """Renders `make_flutter_plugin_build_content` for `platforms_json`."""
    return make_flutter_plugin_build_content(
        name = "some_plugin",
        deps = [],
        language_version = "3.4",
        code_assets = [],
        has_unreplaced_hook = "",
        plugin_platforms_json = platforms_json,
        apple_macos_srcs_dirs = [],
        apple_ios_srcs_dirs = [],
        apple_macos_include_dirs = [],
        apple_ios_include_dirs = [],
        apple_macos_privacy_manifests = [],
        apple_ios_privacy_manifests = [],
        linux_src_dir = "",
        windows_src_dir = "",
    )

def _android_plugin_has_the_edge_test_impl(ctx):
    """A native or FFI Android plugin selects `//android:lib` under the Android platform only."""
    env = unittest.begin(ctx)
    for platforms in [
        '{"android":{"package":"dev.x","pluginClass":"XPlugin"},"ios":{"pluginClass":"X"}}',
        '{"android":{"ffiPlugin":true}}',
    ]:
        content = _plugin(platforms)
        asserts.true(env, "\n    " + _EDGE + "\n" in content, content)
    return unittest.end(env)

android_plugin_has_the_edge_test = unittest.make(_android_plugin_has_the_edge_test_impl)

def _non_android_plugin_has_no_edge_test_impl(ctx):
    """Non-Android, federated-umbrella and pure-Dart Android plugins get no Android edge."""
    env = unittest.begin(ctx)
    for platforms in [
        '{"web":{"pluginClass":"W"}}',
        '{"ios":{"pluginClass":"I"}}',
        '{"android":{"default_package":"x_android"}}',
        '{"android":{"dartPluginClass":"XDart"}}',
        '{"android":{"pluginClass":"none"}}',
        "",
        "{}",
    ]:
        asserts.false(env, "android_libs" in _plugin(platforms), platforms)
    return unittest.end(env)

non_android_plugin_has_no_edge_test = unittest.make(_non_android_plugin_has_no_edge_test_impl)

def _library_has_no_edge_test_impl(ctx):
    """A pure Dart library has no Android library to reach."""
    env = unittest.begin(ctx)
    content = make_flutter_library_build_content(
        name = "lib_only",
        deps = [],
        language_version = "3.4",
        code_assets = [],
        has_unreplaced_hook = "",
        fonts_json_str = "",
        font_files = {},
        pkg_assets = {},
        pkg_shaders = {},
    )
    asserts.false(env, "android_libs" in content, content)
    return unittest.end(env)

library_has_no_edge_test = unittest.make(_library_has_no_edge_test_impl)

_OVERLAY = """\
flutter_plugin(
    name = "audio_session",
    package_name = "audio_session",
)
"""

def _overlay_gains_the_edge_test_impl(ctx):
    """An overlay's plugin call gets the edge right after its name, once."""
    env = unittest.begin(ctx)
    content = overlay_with_android_edge(_OVERLAY, "audio_session")
    asserts.equals(env, 1, content.count("android_libs"))
    asserts.true(env, 'name = "audio_session",\n    ' + _EDGE + "\n    package_name" in content, content)
    asserts.equals(env, content, overlay_with_android_edge(content, "audio_session"))
    return unittest.end(env)

overlay_gains_the_edge_test = unittest.make(_overlay_gains_the_edge_test_impl)

def _overlay_with_its_own_edge_is_untouched_test_impl(ctx):
    """An overlay that names its own `android_libs`, or another package, is left alone."""
    env = unittest.begin(ctx)
    own = _OVERLAY.replace("package_name", "android_libs = [], package_name")
    asserts.equals(env, own, overlay_with_android_edge(own, "audio_session"))
    asserts.equals(env, _OVERLAY, overlay_with_android_edge(_OVERLAY, "other"))
    return unittest.end(env)

overlay_with_its_own_edge_is_untouched_test = unittest.make(_overlay_with_its_own_edge_is_untouched_test_impl)

def _scc_hub_edge_has_android_only_select_test_impl(ctx):
    """SCC hub targets carry an Android-only `select()` edge without loading `@rules_android`."""
    env = unittest.begin(ctx)
    asserts.equals(env, {}, hub_scc_dep_targets("deps", {}))
    scc_targets = {
        "cycle_a": "@deps__scc__cycle_a__test//:cycle_a",
        "test": "@deps__scc__cycle_a__test//:test",
    }
    asserts.equals(
        env,
        {"cycle_a": "@deps//:cycle_a", "test": "@deps//:test"},
        hub_scc_dep_targets("deps", scc_targets),
    )
    bzl_content = make_hub_scc_android_edge_bzl_content()
    asserts.false(env, "rules_android" in bzl_content, bzl_content)
    asserts.false(env, "rules_kotlin" in bzl_content, bzl_content)
    asserts.true(env, "flutter_pub_scc_android_edge = rule(" in bzl_content, bzl_content)
    hub_build = make_flutter_pub_hub_build_content(["cycle_a", "test"], "deps", scc_targets = scc_targets)
    asserts.true(env, '"@deps__scc__cycle_a__test//cycle_a/android:lib"' in hub_build, hub_build)
    asserts.false(env, "//test/android:lib" in hub_build, hub_build)
    asserts.true(env, 'name = "test",\n    actual = "@deps__scc__cycle_a__test//:test",' in hub_build, hub_build)
    return unittest.end(env)

scc_hub_edge_has_android_only_select_test = unittest.make(_scc_hub_edge_has_android_only_select_test_impl)

def flutter_pub_android_edge_test_suite(name):
    """Instantiate the edge tests.

    Args:
      name: The test_suite name.
    """
    small_unittest_suite(
        name,
        android_plugin_has_the_edge_test,
        non_android_plugin_has_no_edge_test,
        library_has_no_edge_test,
        overlay_gains_the_edge_test,
        overlay_with_its_own_edge_is_untouched_test,
        scc_hub_edge_has_android_only_select_test,
    )
