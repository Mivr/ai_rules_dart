"""Regression test: `dart_test_runner.bzl` stays loadable from other repositories.

rules_flutter v0.28.1 to v0.28.5 generate a `flutter_test_package.bzl` that
loads `DartTestRunnerInfo` and `DartTestRunnerSnapshotInfo` from
`@rules_dart//dart/private:dart_test_runner.bzl`. Two checks guard that:

* The `load()` below fails at load time unless `dart_test_runner.bzl` itself
  exports both names, since a loaded name is not re-exported.
* The test rule scans the file's text for `visibility("public")` and for the
  re-exports, since a second module cannot be built offline.
"""

load("//dart/private:dart_test_runner.bzl", "DartTestRunnerInfo", "DartTestRunnerSnapshotInfo")

visibility(["//dart/..."])

_SCRIPT = """#!/bin/sh
set -eu
f='{path}'
grep -q '^visibility("public")$' "$f" || {{ echo "FAIL: $f lacks visibility(\\"public\\")" >&2; exit 1; }}
grep -q '^DartTestRunnerInfo = ' "$f" || {{ echo "FAIL: $f does not export DartTestRunnerInfo" >&2; exit 1; }}
grep -q '^DartTestRunnerSnapshotInfo = ' "$f" || {{ echo "FAIL: $f does not export DartTestRunnerSnapshotInfo" >&2; exit 1; }}
echo PASS
"""

def _impl(ctx):
    """Writes a test script that scans the runner source for the public surface."""
    srcs = [f for f in ctx.files.src if f.basename == "dart_test_runner.bzl"]
    if len(srcs) != 1:
        fail("expected exactly one dart_test_runner.bzl in `src`, got %s" % srcs)
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(script, _SCRIPT.format(path = srcs[0].short_path), is_executable = True)
    return [DefaultInfo(executable = script, runfiles = ctx.runfiles(files = srcs))]

_visibility_test = rule(
    implementation = _impl,
    attrs = {
        "src": attr.label(
            doc = "The `bzl_library` that holds `dart_test_runner.bzl`.",
            mandatory = True,
        ),
    },
    doc = "Asserts `dart_test_runner.bzl` is public and exports both runner providers.",
    test = True,
)

def dart_test_runner_visibility_test(name, src):
    """Declares the visibility regression test.

    Args:
      name: Name of the test target.
      src: Label of the `bzl_library` holding `dart_test_runner.bzl`.
    """
    if not DartTestRunnerInfo or not DartTestRunnerSnapshotInfo:
        fail("dart_test_runner.bzl must export both runner providers")
    _visibility_test(
        name = name,
        src = src,
        size = "small",
        # The test emits a `.sh` executable, which Windows cannot launch; the load() above still runs there.
        target_compatible_with = select({
            "@platforms//os:windows": ["@platforms//:incompatible"],
            "//conditions:default": [],
        }),
    )
