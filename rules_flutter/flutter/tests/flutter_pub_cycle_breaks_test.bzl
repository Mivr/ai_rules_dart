"""Unit tests for the `flutter.pub(cycle_breaks = ...)` helpers.

The helpers are pure: the spoke side takes plain dependency names and the
extension side takes the lock's package names, so these tests drive both with
fake input. They pin the exact contract a stale entry must not slip past:
only the named spoke-to-spoke edge is dropped, a break on an edge the pubspec
does not declare fails naming the package and the entry, and a key or value
naming no lock package fails naming `cycle_breaks` and the entry.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_cycle_breaks.bzl",
    "apply_cycle_breaks",
    "cycle_breaks_lock_error",
)
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

_DIO_DEPS = ["async", "collection", "dio_web_adapter", "path"]
_OTHER_DEPS = ["collection", "meta"]

def _drops_only_the_named_edge_test_impl(ctx):
    """A break returns the other declared deps and leaves another package."""
    env = unittest.begin(ctx)

    dio = apply_cycle_breaks("dio", _DIO_DEPS, ["dio_web_adapter"])
    asserts.equals(env, "", dio.error)
    asserts.equals(env, ["async", "collection", "path"], dio.dependencies)

    other = apply_cycle_breaks("other", _OTHER_DEPS, [])
    asserts.equals(env, "", other.error)
    asserts.equals(env, _OTHER_DEPS, other.dependencies)

    return unittest.end(env)

def _break_on_an_undeclared_edge_fails_test_impl(ctx):
    """A break naming no declared dependency names the package and entry."""
    env = unittest.begin(ctx)

    result = apply_cycle_breaks("dio", _DIO_DEPS, ["dio_web_adapter", "ghost"])
    asserts.equals(env, [], result.dependencies)
    asserts.true(env, "dio" in result.error, result.error)
    asserts.true(env, "ghost" in result.error, result.error)
    asserts.true(env, "cycle_breaks" in result.error, result.error)

    return unittest.end(env)

def _lock_membership_test_impl(ctx):
    """A key or value naming no lock package names `cycle_breaks` and entry."""
    env = unittest.begin(ctx)

    asserts.equals(env, "", cycle_breaks_lock_error({}, ["dio"]))
    asserts.equals(
        env,
        "",
        cycle_breaks_lock_error({"dio": []}, ["dio", "dio_web_adapter"]),
    )

    bad_key = cycle_breaks_lock_error({"ghost": []}, ["dio"])
    asserts.true(env, "cycle_breaks" in bad_key, bad_key)
    asserts.true(env, "ghost" in bad_key, bad_key)

    bad_value = cycle_breaks_lock_error({"dio": ["ghost"]}, ["dio"])
    asserts.true(env, "cycle_breaks" in bad_value, bad_value)
    asserts.true(env, "dio" in bad_value, bad_value)
    asserts.true(env, "ghost" in bad_value, bad_value)

    sdk_lock = ["dio", "flutter_test", "integration_test"]
    asserts.equals(
        env,
        "flutter.pub(cycle_breaks = ...): key \"integration_test\" is a Flutter SDK package; " +
        "Flutter SDK packages are not configurable through cycle_breaks. Remove the entry.",
        cycle_breaks_lock_error({"integration_test": ["flutter_test"]}, sdk_lock, ["flutter_test", "integration_test"]),
    )
    asserts.equals(
        env,
        "",
        cycle_breaks_lock_error({"dio": ["flutter_test"]}, ["dio", "flutter_test"], {"flutter_test": True}),
    )
    alpha_first = cycle_breaks_lock_error({"integration_test": [], "alpha": []}, sdk_lock, ["integration_test"])
    asserts.true(env, "key \"alpha\" is not a package in the lock" in alpha_first, alpha_first)
    driver_first = cycle_breaks_lock_error(
        {"zebra": [], "flutter_driver": []},
        ["flutter_driver"],
        ["flutter_driver"],
    )
    asserts.true(env, "key \"flutter_driver\" is a Flutter SDK package" in driver_first, driver_first)

    return unittest.end(env)

_drops_only_the_named_edge_test = unittest.make(
    _drops_only_the_named_edge_test_impl,
)
_break_on_an_undeclared_edge_fails_test = unittest.make(
    _break_on_an_undeclared_edge_fails_test_impl,
)
_lock_membership_test = unittest.make(_lock_membership_test_impl)

def flutter_pub_cycle_breaks_test_suite(name):
    """Defines the cycle-break helper unit tests.

    Args:
        name: Name of the test suite.
    """
    small_unittest_suite(
        name,
        _drops_only_the_named_edge_test,
        _break_on_an_undeclared_edge_fails_test,
        _lock_membership_test,
    )
