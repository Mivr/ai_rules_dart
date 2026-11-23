"""Manual fixtures for the FF6 architecture analysis cases.

The cases themselves need `rules_testing`, a dev dependency, so they live in
`//tests/rules_testing`. These fixtures only use the Flutter rules and stay
under `flutter/tests` as `manual` targets, so consumers can load this package.
"""

load("//flutter/private:flutter_asset_bundle.bzl", "flutter_asset_bundle")
load("//flutter/private:flutter_library.bzl", "flutter_library")
load("//flutter/private:flutter_plugin.bzl", "flutter_plugin")
load("//flutter/private:flutter_test.bzl", "flutter_test")

visibility(["//flutter/tests/..."])

_SRC = "architecture_fixture_main.dart"
_TEST_API = "//flutter/tests/flutter_test_analyze_fixture/fake_test_api"
_VISIBILITY = ["//tests/rules_testing:__pkg__"]

def _declare_subjects(name):
    """Declares fixtures that are valid and carry only DartInfo-bearing deps."""
    native.filegroup(name = name + "_no_dart_info", srcs = [_SRC], tags = ["manual"], visibility = _VISIBILITY)
    flutter_library(
        name = name + "_lib",
        package_name = "ai_lib",
        srcs = [_SRC],
        tags = ["manual"],
        visibility = _VISIBILITY,
    )
    flutter_plugin(
        name = name + "_plugin",
        package_name = "ai_plugin",
        platforms = ["macos"],
        plugin_class = "AiPlugin",
        tags = ["manual"],
        visibility = _VISIBILITY,
    )
    flutter_test(
        name = name + "_test",
        package_name = "ai_test",
        main = _SRC,
        deps = [_TEST_API],
        tags = ["manual"],
        visibility = _VISIBILITY,
    )
    flutter_asset_bundle(name = name + "_bundle", tags = ["manual"], visibility = _VISIBILITY)

def _declare_violations(name):
    """Declares one fixture per rule whose `deps` lists a target without DartInfo."""
    bad = ":" + name + "_no_dart_info"
    flutter_library(
        name = name + "_lib_bad_dep",
        package_name = "ai_bad",
        srcs = [_SRC],
        deps = [bad],
        tags = ["manual"],
        visibility = _VISIBILITY,
    )
    flutter_test(
        name = name + "_test_bad_dep",
        package_name = "ai_bad_test",
        main = _SRC,
        deps = [_TEST_API, bad],
        tags = ["manual"],
        visibility = _VISIBILITY,
    )
    flutter_asset_bundle(name = name + "_bundle_bad_dep", deps = [bad], tags = ["manual"], visibility = _VISIBILITY)

def architecture_fixtures(name):
    """Declares the manual FF6 fixtures, prefixed with `name`.

    Args:
        name: Prefix for every declared target.
    """
    _declare_subjects(name)
    _declare_violations(name)
