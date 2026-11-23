"""Unit tests pinning the ruleset-API re-exports that other repositories load.

Generated `package:test` spoke repositories, module extensions in other
repositories, and rules_flutter load these names from the public facades
(`//dart:providers.bzl`, `//dart:utils.bzl`, `//dart/pub:defs.bzl`) instead of
reaching into `//dart/private`. A load of a name a facade does not export fails
the whole package, so this file failing to load is the regression signal; the
assertions then pin that each name is bound to something.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//dart:providers.bzl",
    "DartTestRunnerInfo",
    "DartTestRunnerSnapshotInfo",
)
load(
    "//dart:utils.bzl",
    "dart_test_kernel",
    "dart_test_package",
    "dart_test_runner_main",
    "dart_test_runner_snapshot",
    "pinned_download",
    "pinned_download_and_extract",
)
load("//dart/pub:defs.bzl", "parse_semver", "pub_package", "semver_gt")
load(":small_suite.bzl", "small_unittest_suite")

visibility(["//dart/..."])

def _providers_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, DartTestRunnerInfo != None, "DartTestRunnerInfo is exported by //dart:providers.bzl")
    asserts.true(env, DartTestRunnerSnapshotInfo != None, "DartTestRunnerSnapshotInfo is exported by //dart:providers.bzl")
    return unittest.end(env)

def _utils_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, dart_test_kernel != None, "dart_test_kernel is exported by //dart:utils.bzl")
    asserts.true(env, dart_test_package != None, "dart_test_package is exported by //dart:utils.bzl")
    asserts.true(env, dart_test_runner_main != None, "dart_test_runner_main is exported by //dart:utils.bzl")
    asserts.true(env, dart_test_runner_snapshot != None, "dart_test_runner_snapshot is exported by //dart:utils.bzl")
    asserts.true(env, pinned_download != None, "pinned_download is exported by //dart:utils.bzl")
    asserts.true(env, pinned_download_and_extract != None, "pinned_download_and_extract is exported by //dart:utils.bzl")
    return unittest.end(env)

def _pub_defs_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, pub_package != None, "pub_package is exported by //dart/pub:defs.bzl")
    asserts.true(env, parse_semver("1.2.3") < parse_semver("1.10.0"), "parse_semver orders numerically")
    asserts.true(env, semver_gt("2.0.0", "1.9.9"), "semver_gt is exported by //dart/pub:defs.bzl")
    return unittest.end(env)

_providers_test = unittest.make(_providers_test_impl)
_utils_test = unittest.make(_utils_test_impl)
_pub_defs_test = unittest.make(_pub_defs_test_impl)

def ruleset_api_reexports_test_suite(name):
    """Declares the suite checking the facades export the ruleset-API names.

    Args:
      name: Name of the generated `test_suite`.
    """
    small_unittest_suite(
        name,
        _providers_test,
        _utils_test,
        _pub_defs_test,
    )
