"""Unit tests for the symbols the public facades re-export.

Generated repositories, `e2e/` workspaces and `tests/rules_testing` load these
from `@rules_flutter//flutter:*.bzl` rather than from `flutter/private`, so a
facade that drops one breaks them at load time. Each symbol is loaded here
and asserted non-None.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@rules_dart//dart:providers.bzl", "DartTestRunnerInfo", "DartTestRunnerSnapshotInfo")
load("//flutter:android.bzl", "flutter_android_engine", "flutter_android_engine_jar")
load("//flutter:ios.bzl", "flutter_ios_framework")
load("//flutter:macos.bzl", "flutter_apple_plugin_objc_library", "flutter_apple_plugin_objc_settings")
load("//flutter:providers.bzl", "FlutterLinuxPluginInfo", "FlutterWindowsPluginInfo")
load("//flutter:repositories.bzl", "flutter_sky_engine_repo")
load(
    "//flutter:toolchain.bzl",
    "flutter_sdk_binary",
    "xtool_darwin_cc_toolchain_config",
    "xtool_darwin_sdk_status",
    "xtool_darwin_sdk_target",
)
load(
    "//flutter:utils.bzl",
    "flutter_pub_scc_member_target",
    "pinned_download",
    "pinned_download_and_extract",
)
load("//flutter/private:flutter_pub_apple.bzl", "apple_plugin_targets")
load("//flutter/private:flutter_pub_apple_local_targets.bzl", "with_apple_local_targets")
load("//flutter/private:flutter_pub_package_helpers.bzl", "make_flutter_test_package_bzl_content")
load("//flutter/private:flutter_pub_scc_build.bzl", "make_scc_merged_spoke_build_content")
load("//flutter/private:xtool_darwin_sdk_repo.bzl", "generate_xtool_darwin_sdk_build")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _android_facade_test_impl(ctx):
    """Asserts Android engine symbols are exported on `//flutter:android.bzl`."""
    env = unittest.begin(ctx)
    asserts.true(env, flutter_android_engine != None)
    asserts.true(env, flutter_android_engine_jar != None)
    return unittest.end(env)

def _apple_facades_test_impl(ctx):
    """Asserts Apple framework and ObjC plugin symbols are exported on `ios.bzl` and `macos.bzl`."""
    env = unittest.begin(ctx)
    asserts.true(env, flutter_ios_framework != None)
    asserts.true(env, flutter_apple_plugin_objc_library != None)
    asserts.true(env, flutter_apple_plugin_objc_settings != None)
    return unittest.end(env)

def _toolchain_facade_test_impl(ctx):
    """Asserts SDK binary and xtool Darwin SDK rules are exported on `//flutter:toolchain.bzl`."""
    env = unittest.begin(ctx)
    asserts.true(env, flutter_sdk_binary != None)
    asserts.true(env, xtool_darwin_cc_toolchain_config != None)
    asserts.true(env, xtool_darwin_sdk_status != None)
    asserts.true(env, xtool_darwin_sdk_target != None)
    return unittest.end(env)

def _utils_and_repositories_facade_test_impl(ctx):
    """Asserts sky_engine repo, SCC member target, and download helpers are publicly exported."""
    env = unittest.begin(ctx)
    asserts.true(env, flutter_sky_engine_repo != None)
    asserts.true(env, flutter_pub_scc_member_target != None)
    asserts.true(env, pinned_download != None)
    asserts.true(env, pinned_download_and_extract != None)
    return unittest.end(env)

def _providers_facade_test_impl(ctx):
    """Asserts desktop plugin and Dart test runner providers are exported on `providers.bzl`."""
    env = unittest.begin(ctx)
    asserts.true(env, FlutterLinuxPluginInfo != None)
    asserts.true(env, FlutterWindowsPluginInfo != None)
    asserts.true(env, DartTestRunnerInfo != None)
    asserts.true(env, DartTestRunnerSnapshotInfo != None)
    return unittest.end(env)

def _generated_test_package_loads_test_impl(ctx):
    """Asserts generated `flutter_test_package.bzl` loads test runner providers from `dart:providers.bzl`."""
    env = unittest.begin(ctx)
    for forward in (False, True):
        providers_ctx = struct(
            path = lambda label: label,
            read = lambda _path: "DartTestRunnerSnapshotInfo",
        )
        content = make_flutter_test_package_bzl_content(
            forward_flutter_providers = forward,
            ctx = providers_ctx,
        )
        asserts.true(env, "@rules_dart//dart:providers.bzl" in content, content)
        asserts.true(env, "DartTestRunnerSnapshotInfo" in content, content)
        asserts.true(env, "dart/private" not in content, content)
    return unittest.end(env)

def _generated_repo_loads_test_impl(ctx):
    """Asserts generated external-repository BUILD templates emit public facade loads."""
    env = unittest.begin(ctx)
    xtool_build = generate_xtool_darwin_sdk_build(sdk_available = False)
    asserts.true(env, "@rules_flutter//flutter:toolchain.bzl" in xtool_build, xtool_build)
    asserts.true(env, "flutter/private:" not in xtool_build, xtool_build)

    scc_build = make_scc_merged_spoke_build_content("hub__scc__a__b", ["a", "b"], [])
    asserts.true(env, "@rules_flutter//flutter:utils.bzl" in scc_build, scc_build)
    asserts.true(env, "flutter/private:" not in scc_build, scc_build)

    apple_base = apple_plugin_targets("p", ["ios/Classes"], [], "ios")
    local_rendered = struct(
        ok = True,
        labels = [":p_apple_ios__local"],
        xtool_files = [],
        text = 'flutter_apple_plugin_objc_library(\n    name = "p_apple_ios__local",\n)\n',
    )
    apple_patched = with_apple_local_targets(apple_base, "p", "ios", local_rendered)
    asserts.true(env, "@rules_flutter//flutter:macos.bzl" in apple_patched, apple_patched)
    asserts.true(env, "flutter/private:" not in apple_patched, apple_patched)
    return unittest.end(env)

_android_facade_test = unittest.make(_android_facade_test_impl)
_apple_facades_test = unittest.make(_apple_facades_test_impl)
_toolchain_facade_test = unittest.make(_toolchain_facade_test_impl)
_utils_and_repositories_facade_test = unittest.make(_utils_and_repositories_facade_test_impl)
_providers_facade_test = unittest.make(_providers_facade_test_impl)
_generated_test_package_loads_test = unittest.make(_generated_test_package_loads_test_impl)
_generated_repo_loads_test = unittest.make(_generated_repo_loads_test_impl)

def facade_reexports_test_suite(name):
    """Defines the facade re-export tests.

    Args:
      name: The `test_suite` target name.
    """
    small_unittest_suite(
        name,
        _android_facade_test,
        _apple_facades_test,
        _toolchain_facade_test,
        _utils_and_repositories_facade_test,
        _providers_facade_test,
        _generated_test_package_loads_test,
        _generated_repo_loads_test,
    )
