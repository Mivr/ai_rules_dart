"""Test-suite helper that gives every Starlark unit test an explicit size.

`unittest.suite(name, *test_rules)` creates one `<name>_test_<i>` target per
member, and a member that is not given a `size` inherits Bazel's implicit
`medium` budget (300 s). Starlark unit tests and analysis tests are hermetic
and finish in well under a second, so a hung one should fail in a minute, not
after five. `small_unittest_suite` is the only place that choice is written
down, so no suite can forget it.
"""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "unittest")

visibility(["//flutter/tests/..."])

def small_unittest_suite(name, *test_rules):
    """Defines a `unittest.suite` whose member test targets all have `size = "small"`.

    Behaves exactly like `unittest.suite`: one test target named
    `<name>_test_<i>` is created per member, plus a `test_suite` named `name`
    that holds them. The only difference is that every member target is
    created with `size = "small"`, which `unittest.suite` forwards to each
    member through a `partial`.

    Args:
      name: The name of the `test_suite` target and the prefix of the member
        targets.
      *test_rules: The test rules made by `unittest.make` or `analysistest.make`.
        They must be plain rules, not already-bound partials, because each one
        is bound to the size here.
    """
    unittest.suite(
        name,
        *[partial.make(t, size = "small") for t in test_rules]
    )
