"""Compares a package's generated files with what stock `build_runner` wrote."""

load("@bazel_skylib//rules:diff_test.bzl", "diff_test")

def stock_reference_test(name, package, outs):
    """One `diff_test` per generated file against `//reference:<package>/<path>`.

    Args:
      name: Name of the test suite.
      package: The Dart package, the directory under `reference/`.
      outs: The generated files, relative to the package root.
    """
    tests = []
    for out in outs:
        test = "%s_%s" % (name, out.replace("/", "_").replace(".", "_"))
        diff_test(
            name = test,
            size = "small",
            file1 = ":" + out,
            file2 = "//reference:%s/%s" % (package, out),
        )
        tests.append(test)
    native.test_suite(name = name, tests = tests)
