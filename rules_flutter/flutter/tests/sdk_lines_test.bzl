"""Unit tests of how a Flutter version selects its release line's behaviour."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:sdk_lines.bzl", "FLUTTER_SDK_LINES", "flutter_sdk_line_name")
load("//flutter/private:versions.bzl", "FLUTTER_VERSIONS")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _line_name_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "3.47", flutter_sdk_line_name("3.47.7"), "a stock patch")
    asserts.equals(env, "3.47", flutter_sdk_line_name("3.47.70"), "a custom release of the line")
    asserts.equals(env, "3.50", flutter_sdk_line_name("3.50.1"), "a stock patch")
    asserts.equals(env, "3.50", flutter_sdk_line_name("3.50.10"), "a custom release of the line")
    asserts.equals(env, "3.47", flutter_sdk_line_name("3.48.0-1.0.pre"), "a version between two lines takes the older")
    asserts.equals(env, "3.50", flutter_sdk_line_name("3.53.0"), "a version above the newest line takes the newest")
    asserts.equals(env, "3.47", flutter_sdk_line_name("3.41.7"), "a version below the oldest line takes the oldest")
    asserts.equals(env, "3.50", flutter_sdk_line_name("3.100.0"), "minors compare as numbers")
    return unittest.end(env)

_line_name_test = unittest.make(_line_name_test_impl)

def _every_listed_version_has_its_line_test_impl(ctx):
    env = unittest.begin(ctx)
    for version in FLUTTER_VERSIONS:
        line = ".".join(version.split(".")[:2])
        asserts.true(env, line in FLUTTER_SDK_LINES, "Flutter %s is listed and its line %s is not" % (version, line))
    return unittest.end(env)

_every_listed_version_has_its_line_test = unittest.make(_every_listed_version_has_its_line_test_impl)

def sdk_lines_test_suite(name):
    """Defines the unit tests of `sdk_lines.bzl`.

    Args:
      name: The test_suite target name.
    """
    small_unittest_suite(name, _line_name_test, _every_listed_version_has_its_line_test)
