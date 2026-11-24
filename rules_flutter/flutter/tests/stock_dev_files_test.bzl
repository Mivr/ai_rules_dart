"""Analysis tests: the `flutter_dev_files` aspect's groups for `flutter_dev`.

- `flutter_stock_dev` holds the application's package config and the JSON that names it, and
  nothing else of the application (no kernel), so a web session builds no kernel;
- `flutter_stock_dev_generated` holds a generated Dart source the application lists in `srcs`,
  with the JSON that maps it to its generator, and no source file;
- the group the old dev tool reads still holds the application's whole `DefaultInfo`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//flutter:defs.bzl", "flutter_application")
load("//flutter:dev_files.bzl", "flutter_dev_files")
load("//flutter/private:common.bzl", "HOST_COMPATIBLE")

visibility(["//flutter/tests/..."])

_DBG = {"//command_line_option:compilation_mode": "dbg"}

def _probe_impl(ctx):
    """Returns the output groups the aspect gave its dep."""
    return [ctx.attr.dep[OutputGroupInfo]]

_probe = rule(
    implementation = _probe_impl,
    attrs = {"dep": attr.label(aspects = [flutter_dev_files], mandatory = True)},
    doc = "Applies `flutter_dev_files` to `dep`, as `flutter_dev` does on the command line.",
)

def _basenames(target, group):
    return sorted([f.basename for f in getattr(target[OutputGroupInfo], group).to_list()])

def _groups_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(
        env,
        ["_stock_dev_app.flutter_stock_dev.json", "_stock_dev_app.package_config.json"],
        _basenames(target, "flutter_stock_dev"),
    )
    asserts.equals(
        env,
        ["_stock_dev_app.flutter_stock_dev_generated.json", "stock_dev_generated.dart"],
        _basenames(target, "flutter_stock_dev_generated"),
    )
    generated = [f for f in target[OutputGroupInfo].flutter_stock_dev_generated.to_list() if f.extension == "dart"]
    asserts.false(env, generated[0].is_source, "only generated sources are linked")
    asserts.equals(env, "flutter/tests/lib/stock_dev_generated.dart", generated[0].short_path)
    return analysistest.end(env)

_groups_test = analysistest.make(_groups_impl, config_settings = _DBG)

def stock_dev_files_test_suite(name):
    """Declares the fixture application and the tests.

    Args:
        name: The test_suite name.
    """
    write_file(
        name = "_stock_dev_generated",
        out = "lib/stock_dev_generated.dart",
        content = ["const int generated = 1;", ""],
        tags = ["manual"],
    )
    flutter_application(
        name = "_stock_dev_app",
        package_name = "inputs_fixture",
        srcs = ["lib/language_version_main.dart", ":_stock_dev_generated"],
        main = "lib/language_version_main.dart",
        deps = ["//flutter/tests/registrant_twin_fixture/app"],
        tags = ["manual"],
        target_compatible_with = HOST_COMPATIBLE,
    )
    _probe(name = "_stock_dev_probe", dep = ":_stock_dev_app", tags = ["manual"])
    _groups_test(name = name + "_groups", target_under_test = ":_stock_dev_probe")
    native.test_suite(name = name, tests = [name + "_groups"])
