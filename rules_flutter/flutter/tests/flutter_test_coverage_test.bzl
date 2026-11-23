"""Unit tests for the library scope a `flutter_test` coverage run is limited to.

The VM is asked only for these URI prefixes, so the list must name the test's
own code exactly as the compile path does, and nothing generated.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_test.bzl", "test_coverage_libraries")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _file(short_path):
    return struct(path = short_path, short_path = short_path, owner = None)

def _scope_with_package_test_impl(ctx):
    """Package prefix, then main, then srcs; no duplicate, nothing generated."""
    env = unittest.begin(ctx)
    main = _file("pkg/test/a_test.dart")
    lib_src = _file("pkg/lib/src/b.dart")
    asserts.equals(
        env,
        [
            "package:hello_world/",
            "org-dartlang-app:///pkg/test/a_test.dart",
            "package:hello_world/src/b.dart",
        ],
        test_coverage_libraries("hello_world", "pkg", main, [main, lib_src]),
    )
    return unittest.end(env)

def _scope_without_package_test_impl(ctx):
    """With no `package_name` only the sources' URIs, never `package:/`."""
    env = unittest.begin(ctx)
    main = _file("pkg/test/a_test.dart")
    other = _file("pkg/test/b.dart")
    result = test_coverage_libraries("", "pkg", main, [other])
    asserts.equals(
        env,
        [
            "org-dartlang-app:///pkg/test/a_test.dart",
            "org-dartlang-app:///pkg/test/b.dart",
        ],
        result,
    )
    asserts.false(env, "package:/" in result)
    return unittest.end(env)

_scope_with_package_test = unittest.make(_scope_with_package_test_impl)
_scope_without_package_test = unittest.make(_scope_without_package_test_impl)

def flutter_test_coverage_test_suite(name):
    """Defines the coverage-scope unit tests.

    Args:
        name: The name of the `test_suite`.
    """
    small_unittest_suite(
        name,
        _scope_with_package_test,
        _scope_without_package_test,
    )
