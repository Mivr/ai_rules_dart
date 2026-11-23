"""Unit tests for starlark helpers
See https://bazel.build/rules/testing#testing-starlark-utilities
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/private:versions.bzl", "TOOL_VERSIONS", "semver_gt")
load(":small_suite.bzl", "small_unittest_suite")

visibility(["//dart/..."])

def _newest_version_first_test_impl(ctx):
    env = unittest.begin(ctx)
    versions = TOOL_VERSIONS.keys()
    asserts.true(env, len(versions) > 0, "TOOL_VERSIONS lists no SDK")
    for i in range(len(versions) - 1):
        asserts.true(
            env,
            semver_gt(versions[i], versions[i + 1]),
            "%s is listed before %s: list the newest version first" % (versions[i], versions[i + 1]),
        )
    return unittest.end(env)

# The per-platform checksum coverage that used to live here — a hand-listed set
# plus `len(versions) == 5` — is now `toolchains_test.bzl`'s
# `_checksums_cover_every_host_test`, which checks every pinned version against
# `PLATFORMS` rather than one version against a literal count. A bare count
# cannot catch a *wrong* key, and it broke on every platform change.

_t0_test = unittest.make(_newest_version_first_test_impl)

def versions_test_suite(name):
    small_unittest_suite(name, _t0_test)
