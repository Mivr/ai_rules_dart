"""Tests that the `@flutter_toolchains` hub carries the xtool Darwin cc toolchains.

The xtool SDK repository is only fetched once Bazel loads a target in it. A
`register_toolchains("@<name>_xtool_darwin_sdk//:all")` loads it for every
build; the hub's `toolchain()` entries mirror the SDK repository's constraints,
so the repository is loaded only by a build that matches them.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:toolchains_repo.bzl", "generate_toolchains_build")
load("//flutter/private:xtool_darwin_sdk_repo.bzl", "XTOOL_DARWIN_TARGETS", "generate_xtool_darwin_sdk_build")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _hub_xtool_toolchains_test_impl(ctx):
    """The hub declares one xtool cc toolchain per Darwin target, pointing into the SDK repository."""
    env = unittest.begin(ctx)
    hub = generate_toolchains_build("flutter")
    for key in XTOOL_DARWIN_TARGETS:
        asserts.true(env, 'name = "xtool_%s_cc_toolchain",' % key in hub, "hub lacks the xtool %s toolchain" % key)
        impl = 'toolchain = "@flutter_xtool_darwin_sdk//:%s_cc_toolchain_impl",' % key
        asserts.true(env, impl in hub, "hub toolchain %s does not point into the SDK repository" % key)
    asserts.true(env, hub.count("@rules_flutter//flutter/settings:use_xtool_backend") == len(XTOOL_DARWIN_TARGETS))
    return unittest.end(env)

_hub_xtool_toolchains_test = unittest.make(_hub_xtool_toolchains_test_impl)

def _hub_mirrors_sdk_constraints_test_impl(ctx):
    """Each hub entry keeps the exec and target constraints of the SDK repository's own toolchain."""
    env = unittest.begin(ctx)
    hub = generate_toolchains_build("flutter")
    sdk_build = generate_xtool_darwin_sdk_build(sdk_available = False)
    for key, meta in XTOOL_DARWIN_TARGETS.items():
        sdk_block = sdk_build.split('name = "%s_cc_toolchain",' % key)[1].split("toolchain_type")[0]
        hub_block = hub.split('name = "xtool_%s_cc_toolchain",' % key)[1].split("toolchain_type")[0]
        for constraint in ["@platforms//os:linux", meta.os_constraint, meta.cpu_constraint]:
            asserts.true(env, constraint in sdk_block, "SDK repository toolchain %s lost %s" % (key, constraint))
            asserts.true(env, constraint in hub_block, "hub toolchain %s lacks %s" % (key, constraint))
    return unittest.end(env)

_hub_mirrors_sdk_constraints_test = unittest.make(_hub_mirrors_sdk_constraints_test_impl)

def xtool_hub_toolchains_test_suite(name):
    """Defines the unit tests for the xtool toolchains in the toolchains hub.

    Args:
      name: The test_suite target name.
    """
    small_unittest_suite(name, _hub_xtool_toolchains_test, _hub_mirrors_sdk_constraints_test)
