"""Unit tests for the `ai_rules_dart` floor check.

The floor probe runs `pubspec_sdk_constraint_error` (public since before the
floor) over a pubspec stream with a non-map `environment`: a reader older than
the floor accepts the non-map `environment`, the floor reader refuses it.
The old-reader stand-in below mimics the accept, so these tests fail on a base
without the check and never fetch an old rules_dart. The pinned-reader test runs
the real probe against the resolved rules_dart and fails if it ever accepts the
non-map `environment`.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:rules_dart_floor.bzl", "RULES_DART_FLOOR", "check_rules_dart_floor", "rules_dart_floor_error")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _old_reader(_content):
    """Stand-in for a pre-floor reader: accepts the non-map environment."""
    return None

def _new_reader(_content):
    """Stand-in for the floor reader: refuses the non-map environment."""
    return "floor_probe in pubspec.yaml: \"environment\" field must be a map."

def _floor_version_test_impl(ctx):
    """The floor constant tracks MODULE.bazel's ai_rules_dart floor."""
    env = unittest.begin(ctx)
    asserts.equals(env, "0.28.3", RULES_DART_FLOOR)
    return unittest.end(env)

def _old_reader_error_test_impl(ctx):
    """A reader that accepts the non-map environment reports the floor error."""
    env = unittest.begin(ctx)
    err = rules_dart_floor_error(_old_reader)
    asserts.true(env, err != None, "an accepting reader must report the floor error")
    for part in ["ai_rules_dart", "0.28.3", "archive_override", "git_override", "local_path_override", "single_version_override"]:
        asserts.true(env, part in err, "floor message must name " + part)
    return unittest.end(env)

def _new_reader_clean_test_impl(ctx):
    """A reader that refuses the non-map environment reports no error."""
    env = unittest.begin(ctx)
    asserts.equals(env, None, rules_dart_floor_error(_new_reader))
    return unittest.end(env)

def _pinned_reader_clean_test_impl(ctx):
    """The resolved rules_dart refuses the probe's non-map environment."""
    env = unittest.begin(ctx)
    asserts.equals(env, None, rules_dart_floor_error())
    return unittest.end(env)

def _check_pass_through_test_impl(ctx):
    """The failing wrapper stays quiet when the reader meets the floor."""
    env = unittest.begin(ctx)
    asserts.equals(env, None, check_rules_dart_floor(_new_reader))
    return unittest.end(env)

_t0_test = unittest.make(_floor_version_test_impl)
_t1_test = unittest.make(_old_reader_error_test_impl)
_t2_test = unittest.make(_new_reader_clean_test_impl)
_t3_test = unittest.make(_pinned_reader_clean_test_impl)
_t4_test = unittest.make(_check_pass_through_test_impl)

def rules_dart_floor_test_suite(name):
    """Defines the floor-check unit tests.

    Args:
        name: Name of the test suite.
    """
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test)
