"""Compares a package's generated files with what stock `build_runner` wrote."""

load("@bazel_skylib//rules:diff_test.bzl", "diff_test")

def stock_reference_test(name, package, generated):
    """One `diff_test` per generated file against `//reference:<package>/<path>`.

    Args:
      name: Name of the test suite.
      package: The Dart package, the directory under `reference/`.
      generated: The generated files, relative to the package root. (Not
        `outs`: Gazelle takes a rule's `outs` for files that rule writes.)
    """
    tests = []
    for out in generated:
        test = "%s_%s" % (name, out.replace("/", "_").replace(".", "_"))
        diff_test(
            name = test,
            size = "small",
            file1 = ":" + out,
            file2 = "//reference:%s/%s" % (package, out),
        )
        tests.append(test)
    native.test_suite(name = name, tests = tests)
