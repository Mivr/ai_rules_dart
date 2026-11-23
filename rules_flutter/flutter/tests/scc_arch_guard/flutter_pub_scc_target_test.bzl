"""Regression tests for the merged SCC spoke target and its generators.

The fixture target is a real `flutter_pub_scc_member_target` whose `deps`
holds an outside `dart_library`; the unit test checks it still forwards
`DartInfo` and `FlutterInfo`. The generators that moved into
`flutter_pub_package_helpers.bzl` or gained docstrings are exercised directly.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@rules_dart//dart:defs.bzl", "dart_library")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("//flutter:providers.bzl", "FlutterInfo")
load("//flutter/private:flutter_library.bzl", "flutter_library")
load(
    "//flutter/private:flutter_pub_package_helpers.bzl",
    "format_pub_asset_attrs_with_shaders",
)
load(
    "//flutter/private:flutter_pub_scc_build.bzl",
    "adapt_scc_member_android_overlay_content",
    "scc_flutter_test_package_bzl_content",
)
load("//flutter/private:flutter_pub_scc_target.bzl", "flutter_pub_scc_member_target")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_FIXTURE = "//flutter/tests/scc_arch_guard:scc_fixture_target"

def _target_providers_test_impl(ctx):
    env = unittest.begin(ctx)
    target = ctx.attr.target
    asserts.true(env, DartInfo in target, "member target must forward DartInfo")
    asserts.true(env, FlutterInfo in target, "member target must carry FlutterInfo")
    asserts.equals(env, "scc_fixture_lib", target[DartInfo].package_name)
    return unittest.end(env)

_target_providers_test = unittest.make(
    _target_providers_test_impl,
    attrs = {"target": attr.label(default = _FIXTURE, providers = [DartInfo, FlutterInfo])},
)

def _shader_attrs_test_impl(ctx):
    env = unittest.begin(ctx)
    plain = format_pub_asset_attrs_with_shaders("", {}, {":a.txt": "a.txt"}, {})
    asserts.equals(env, '    pkg_assets = {\n        ":a.txt": "a.txt",\n    },\n', plain)
    shaded = format_pub_asset_attrs_with_shaders("", {}, {}, {":s/g.frag": "s/g.frag"})
    asserts.true(env, '    pkg_shaders = {\n        ":s/g.frag": "s/g.frag",\n    },\n' in shaded, shaded)
    asserts.true(env, '"s/**/*.frag"' in shaded, shaded)
    asserts.true(env, shaded.endswith("allow_empty = True,\n    ),\n"), shaded)
    return unittest.end(env)

_shader_attrs_test = unittest.make(_shader_attrs_test_impl)

def _scc_content_test_impl(ctx):
    env = unittest.begin(ctx)
    content = scc_flutter_test_package_bzl_content()
    asserts.true(env, 'load("@rules_flutter//flutter:providers.bzl", "FlutterInfo")' in content, content)
    asserts.true(env, "for p in (DartKernelInfo, DartAnalyzableInfo, FlutterInfo):" in content, content)
    adapted = adapt_scc_member_android_overlay_content(
        "pkg_a",
        'deps = ["//:lib"], visibility = ["//android:__pkg__"]',
    )
    asserts.equals(env, 'deps = ["//pkg_a:lib"], visibility = ["//pkg_a/android:__pkg__"]', adapted)
    return unittest.end(env)

_scc_content_test = unittest.make(_scc_content_test_impl)

def flutter_pub_scc_target_test_suite(name):
    """Defines the fixture targets and the SCC target regression suite.

    Args:
        name: The `test_suite` name, also the prefix of the member tests.
    """
    dart_library(
        name = "scc_fixture_lib",
        package_name = "scc_fixture_lib",
        srcs = ["lib/fixture.dart"],
        tags = ["manual"],
    )
    dart_library(
        name = "scc_fixture_outside",
        package_name = "scc_fixture_outside",
        srcs = ["lib/fixture.dart"],
        tags = ["manual"],
    )
    flutter_library(
        name = "scc_fixture_member",
        srcs = ["lib/fixture.dart"],
        tags = ["manual"],
    )
    flutter_pub_scc_member_target(
        name = "scc_fixture_target",
        package_name = "scc_fixture_lib",
        library = ":scc_fixture_lib",
        scc_members = [":scc_fixture_member"],
        deps = [":scc_fixture_outside"],
        tags = ["manual"],
    )
    small_unittest_suite(
        name,
        _target_providers_test,
        _shader_attrs_test,
        _scc_content_test,
    )
