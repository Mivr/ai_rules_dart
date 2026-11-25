"""Unit tests of the tested range of Android Gradle plugin versions."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private/android_model:names.bzl", "AGP_TESTED", "agp_tested")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _agp_tested_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, agp_tested(AGP_TESTED[0]), "the first tested version")
    asserts.true(env, agp_tested(AGP_TESTED[1]), "the last tested version")
    asserts.true(env, agp_tested("9.2.1"), "a version between the two")
    asserts.false(env, agp_tested("8.13.1"), "a version below the range")
    asserts.false(env, agp_tested("9.10.0"), "a version above the range, compared as numbers and not as text")
    asserts.false(env, agp_tested("10.0.0-alpha01"), "a preview of a later version")
    return unittest.end(env)

_agp_tested_test = unittest.make(_agp_tested_test_impl)

def android_model_names_test_suite(name):
    """Defines the unit tests of `names.bzl`.

    Args:
      name: The test_suite target name.
    """
    small_unittest_suite(name, _agp_tested_test)
